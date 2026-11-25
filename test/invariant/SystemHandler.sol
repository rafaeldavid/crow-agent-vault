// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";

import {CrestAllowList} from "../../src/CrestAllowList.sol";
import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {PayModule} from "../mocks/PayModule.sol";

/// Drives random sequences through a whole vault system and checks each call's outcome against a model written from
/// the design record (`docs/design.md`, sections 2, 3, 14, 15 and 17), not from the code:
/// - a top vault with a root, an agent, two sub-agents and keys granted on the way; a child vault under the agent's
///   grant with a sub-agent of its own; the default list; a fee factory or a rate-0 one; a direct venue;
/// - actions: pay (from the top vault or the child), end a commitment, fill the child, take back from it, return from
///   it, withdraw, pause and resume, close, change limits (period length included), grant, grant by signature (and
///   replay it), cancel a slip, create a child, write the list, hand the vault over, collect the fee, and wait.
///
/// For every call the model decides beforehand whether it must be refused (a stop, an expiry, a limit, a list, missing
/// authority, delegation switched off, a key that is not fresh, the fee owed). A call that lands when the model says it
/// must be refused is a violation. A payment, fill, withdrawal or take-back that the model allows but the vault refuses
/// is an unexpected refusal. Independent ghost counters record every charge each grant should have counted.
contract SystemHandler is Test {
    struct Charge {
        uint256 at;
        uint256 amount;
    }

    struct OpenRec {
        CrestVault v;
        bytes32 c;
        uint256 leaf;
        bool live;
    }

    struct GrantRef {
        CrestVault v;
        uint256 id;
    }

    uint256 internal constant ROOT = 1;
    uint256 public constant LOADED = 10_000_000;
    bytes32 public constant LISTED = keccak256("listed merchant");
    bytes32 public constant UNLISTED = keccak256("unlisted merchant");
    bytes32 public constant OTHER = keccak256("another merchant");

    MockERC3009Token public token;
    CrestAllowList public list;
    CrestFactory public factory;
    CrestFeeSweeper public sweeper;
    PayModule public module;
    CrestVault public top;
    CrestVault public child;
    address public sink = makeAddr("withdrawals");
    address public destination = makeAddr("fee destination");
    uint256 public immutable FEE_BPS;
    uint256 public agentGrant;

    // Actors: two principal keys (the vault is handed between them), the agent, and keys the tree may use.
    uint256[] internal pks;
    address[] public actors;
    address[] internal pool; // keys that may be granted
    address public p1;
    address public p2;
    address public agent;

    GrantRef[] internal grants;
    mapping(bytes32 => bool) internal knownGrant;
    address[] public children;

    // Ghosts.
    mapping(bytes32 => uint256) public ghostSpent;
    mapping(bytes32 => uint256) public ghostOpen;
    mapping(bytes32 => Charge[]) internal charges;
    mapping(bytes32 => uint256) public lastPeriodChange;
    mapping(bytes32 => bool) public everClosed;
    mapping(address => mapping(address => bool)) internal everHeld; // vault => key => held a grant or the root
    OpenRec[] internal opens;
    uint256 public paidToVenue;
    uint256 public withdrawn;
    mapping(address => uint256) public feesCharged;
    uint256 public feesCollected;

    // Outcomes.
    uint256 public violations;
    uint256 public unexpectedRefusals;
    string public lastViolation;
    uint256 public payments;
    uint256 public fills;
    uint256 public grantsLanded;
    uint256 public slipsLanded;
    uint256 public stops;
    uint256 public periodChanges;

    constructor(uint256 feeBps) {
        FEE_BPS = feeBps;
        vm.warp(1_790_000_000);
        token = new MockERC3009Token("Mock USDC", "mUSDC", 6);
        list = new CrestAllowList();
        sweeper = new CrestFeeSweeper(destination);
        factory = new CrestFactory(feeBps, feeBps == 0 ? address(0) : address(sweeper));
        module = new PayModule(address(token));

        for (uint256 i; i < 11; i++) {
            pks.push(0xC0FFEE + i);
            actors.push(vm.addr(0xC0FFEE + i));
        }
        (p1, p2, agent) = (actors[0], actors[1], actors[2]);
        for (uint256 i = 3; i < 10; i++) {
            pool.push(actors[i]);
        }
        // actors[10] is a stranger: never granted by the setup, it may still be granted by the campaign's moves.

        top = CrestVault(factory.create(p1, address(token), 0));
        _addGrant(top, ROOT);
        everHeld[address(top)][p1] = true;
        vm.startPrank(p1);
        top.setModule(address(module), address(module), "");
        agentGrant = top.grant(ROOT, agent, _caps(10_000, 30_000, 200_000, 4, 1 days, true, true), 0, "");
        list.set(top, agentGrant, LISTED, true, "");
        vm.stopPrank();
        _addGrant(top, agentGrant);
        everHeld[address(top)][agent] = true;
        token.mint(address(top), LOADED);

        vm.startPrank(agent);
        uint256 s1 = top.grant(agentGrant, pool[0], _caps(type(uint128).max, 0, 0, 0, 1 days, false, true), 0, "");
        uint256 s2 = top.grant(agentGrant, pool[1], _caps(5_000, 15_000, 60_000, 2, 1 days, false, false), 0, "");
        child = CrestVault(top.createChild(agentGrant, 0, ""));
        top.fundChild(address(child), 20_000, "");
        uint256 cs = child.grant(ROOT, pool[2], _caps(type(uint128).max, 0, 0, 0, 1 days, false, false), 0, "");
        vm.stopPrank();
        _addGrant(top, s1);
        _addGrant(top, s2);
        _addGrant(child, ROOT);
        _addGrant(child, cs);
        everHeld[address(top)][pool[0]] = true;
        everHeld[address(top)][pool[1]] = true;
        everHeld[address(child)][agent] = true;
        everHeld[address(child)][pool[2]] = true;
        children.push(address(child));
        // The setup's fill, counted by the ghosts like any other.
        _ghostCharge(top, agentGrant, 20_000, false);
    }

    // ------------------------------------------------------------------ actions

    function pay(uint256 k, uint256 amount, uint256 m, bool fromChild) external {
        // Three payments in four come from a key the setup granted; the fourth from any actor.
        address key = k % 4 == 0 ? _pick(actors, k >> 2) : [p1, agent, pool[0], pool[1], pool[2]][(k >> 2) % 5];
        CrestVault v = fromChild ? child : top;
        uint256 leaf = v.grantOf(key);
        if (leaf == 0) {
            v = fromChild ? top : child;
            leaf = v.grantOf(key);
        }
        // Mostly inside the agent's per-payment limit, sometimes past it; mostly to the listed merchant.
        amount = amount % 4 == 0 ? bound(amount, 1, 15_000) : bound(amount, 1, 4_000);
        bytes32 cp = m % 4 < 2 ? LISTED : m % 4 == 2 ? UNLISTED : OTHER;
        uint256 fee = amount * FEE_BPS / 10_000;
        uint256 total = amount + fee;
        bool may = leaf != 0 && _pathPays(v, leaf, total, cp) && _countersAllow(v, leaf, total, true)
            && token.balanceOf(address(v)) >= amount + v.feeOwed() + fee;
        try module.pay(v, key, amount, cp) returns (bytes32 c) {
            if (!may) _violation("a payment the model refuses landed");
            payments++;
            _ghostCharge(v, leaf, total, true);
            opens.push(OpenRec(v, c, leaf, true));
            paidToVenue += amount;
            feesCharged[address(v)] += fee;
        } catch {
            if (may) _unexpected();
        }
    }

    function end(uint256 i) external {
        if (opens.length == 0) return;
        uint256 at = bound(i, 0, opens.length - 1);
        // Three ends in four look for the next live commitment from a random place; the fourth tries the place itself,
        // so an end of an ended commitment is tried too.
        if (i % 4 != 0) {
            for (uint256 n; n < opens.length && !opens[at].live; n++) {
                at = (at + 1) % opens.length;
            }
        }
        OpenRec storage o = opens[at];
        if (!o.live) {
            // A commitment ended twice is refused.
            try module.end(o.v, o.c) {
                _violation("a commitment ended twice");
            } catch {}
            return;
        }
        module.end(o.v, o.c);
        o.live = false;
        for (uint256 g = o.leaf; g != 0; g = o.v.getGrant(g).parent) {
            ghostOpen[_gk(o.v, g)] -= 1;
        }
    }

    function fundChild(uint256 who, uint256 amount) external {
        // Three fills in four come from the agent or the principal; the fourth from any actor.
        address caller = who % 4 == 0 ? _pick(actors, who >> 2) : (who >> 2) % 2 == 0 ? agent : top.principal();
        amount = bound(amount, 1, 10_000);
        uint256 id = top.grantOfChild(address(child));
        bool may = _authorityOver(caller, top, id) && _delegable(top, id) && _countersAllow(top, id, amount, false)
            && token.balanceOf(address(top)) >= amount + top.feeOwed();
        vm.prank(caller);
        try top.fundChild(address(child), amount, "") {
            if (!may) _violation("a fill the model refuses landed");
            fills++;
            _ghostCharge(top, id, amount, false);
        } catch {
            if (may) _unexpected();
        }
    }

    function takeBack(uint256 who, uint256 amount) external {
        address caller = _pick(actors, who);
        amount = bound(amount, 0, token.balanceOf(address(child)));
        uint256 id = top.grantOfChild(address(child));
        bool may = _authorityOver(caller, top, id) && token.balanceOf(address(child)) >= amount + child.feeOwed();
        vm.prank(caller);
        try top.takeBackFromChild(address(child), amount, "") {
            if (!may) _violation("a take-back the model refuses landed");
        } catch {
            if (may) _unexpected();
        }
    }

    function returnToParent(uint256 who, uint256 amount) external {
        address caller = _pick(actors, who);
        amount = bound(amount, 0, token.balanceOf(address(child)));
        bool may = _authorityOver(caller, child, ROOT) && token.balanceOf(address(child)) >= amount + child.feeOwed();
        vm.prank(caller);
        try child.returnToParent(amount, "") {
            if (!may) _violation("a return the model refuses landed");
        } catch {
            if (may) _unexpected();
        }
    }

    function withdraw(uint256 who, uint256 amount) external {
        address caller = _pick(actors, who);
        amount = bound(amount, 0, token.balanceOf(address(top)));
        bool may = caller == top.principal() && token.balanceOf(address(top)) >= amount + top.feeOwed();
        vm.prank(caller);
        try top.withdraw(sink, amount, "") {
            if (!may) _violation("a withdrawal the model refuses landed");
            withdrawn += amount;
        } catch {
            if (may) _unexpected();
        }
        // A child vault can never withdraw.
        vm.prank(caller);
        try child.withdraw(sink, 0, "") {
            _violation("a child vault withdrew");
        } catch {}
    }

    function setPaused(uint256 who, uint256 g, bool paused) external {
        address caller = _pick(actors, who);
        GrantRef memory r = _grant(g);
        address controller = r.v.getGrant(r.id).controller;
        bool may = (paused && caller == controller) || _above(caller, r.v, r.id);
        vm.prank(caller);
        try r.v.setPaused(r.id, paused, "") {
            if (!may) _violation("a pause or resume the model refuses landed");
            if (paused) stops++;
        } catch {
            if (may) _unexpected();
        }
    }

    function close(uint256 who, uint256 g) external {
        // A close is permanent, so the campaign tries one in three times, or the tree would be shut down early.
        if (who % 3 != 0) return;
        address caller = _pick(actors, who / 3);
        GrantRef memory r = _grant(g);
        // The top vault's root stays open so the tree stays reachable; unit tests close it.
        if (r.v == top && r.id == ROOT) return;
        bool may = caller == r.v.getGrant(r.id).controller || _above(caller, r.v, r.id);
        vm.prank(caller);
        try r.v.close(r.id, "") {
            if (!may) _violation("a close the model refuses landed");
            everClosed[_gk(r.v, r.id)] = true;
            stops++;
        } catch {
            if (may) _unexpected();
        }
    }

    function setCaps(uint256 who, uint256 g, uint256 seed) external {
        address caller = _pick(actors, who);
        GrantRef memory r = _grant(g);
        ICrestVault.Caps memory c = _randomCaps(seed);
        ICrestVault.Grant memory x = r.v.getGrant(r.id);
        // A lifetime set below what is already spent would end the grant for good; the campaign sets it above.
        if (c.lifetime != type(uint128).max) c.lifetime += x.spent;
        bool may = _above(caller, r.v, r.id);
        uint32 before = x.caps.period;
        vm.prank(caller);
        try r.v.setCaps(r.id, c, "") {
            if (!may) _violation("a limits change the model refuses landed");
            if (c.period != before) {
                lastPeriodChange[_gk(r.v, r.id)] = vm.getBlockTimestamp();
                periodChanges++;
            }
        } catch {
            if (may) _unexpected();
        }
    }

    function grant(uint256 who, uint256 g, uint256 k, uint256 seed) external {
        GrantRef memory r = _grant(g);
        // Three grants in four come from the parent's own controller; the fourth from any actor.
        address caller = who % 4 == 0 ? _pick(actors, who >> 2) : r.v.getGrant(r.id).controller;
        address key = _pick(pool, k);
        ICrestVault.Caps memory c = _randomCaps(seed);
        bool allowedShape = _maySign(caller, r.v, r.id, key);
        vm.prank(caller);
        try r.v.grant(r.id, key, c, bytes32(seed % 4), "") returns (uint256 id) {
            if (!allowedShape) _violation("a grant the model refuses landed");
            grantsLanded++;
            _addGrant(r.v, id);
            everHeld[address(r.v)][key] = true;
        } catch {}
    }

    function grantBySig(uint256 who, uint256 g, uint256 k, uint256 seed) external {
        GrantRef memory r = _grant(g);
        // One slip in three names a key that held a grant in this vault and holds none now (a retired key), if any:
        // such a slip must never land.
        address key = _pick(pool, k);
        if (seed % 3 == 0) {
            for (uint256 j; j < pool.length; j++) {
                address c = pool[(k + j) % pool.length];
                if (everHeld[address(r.v)][c] && r.v.grantOf(c) == 0) {
                    key = c;
                    break;
                }
            }
        }
        // Three slips in four are signed by the parent's own controller; the fourth by any actor.
        uint256 i = bound(who, 0, actors.length - 1);
        if (who % 4 != 0) {
            address c = r.v.getGrant(r.id).controller;
            for (uint256 j; j < actors.length; j++) {
                if (actors[j] == c) i = j;
            }
        }
        address signer = actors[i];
        ICrestVault.SignedGrant memory s = ICrestVault.SignedGrant({
            parent: r.id,
            controller: key,
            caps: _randomCaps(seed),
            salt: bytes32(seed % 8),
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: ""
        });
        bytes memory sig = _sign(pks[i], r.v, s);
        bool may = _maySign(signer, r.v, r.id, key) && !everHeld[address(r.v)][key];
        try r.v.grantBySig(s, sig) returns (uint256 id) {
            if (!may) _violation("a slip landed where its signer's grant would not, or for a key that is not fresh");
            slipsLanded++;
            _addGrant(r.v, id);
            everHeld[address(r.v)][key] = true;
            try r.v.grantBySig(s, sig) {
                _violation("a slip landed twice");
            } catch {}
        } catch {}
    }

    function cancelSlip(uint256 who, uint256 g, uint256 k, uint256 salt) external {
        address caller = _pick(actors, who);
        GrantRef memory r = _grant(g);
        bool may = _authorityOver(caller, r.v, r.id);
        vm.prank(caller);
        try r.v.cancelSignedGrant(r.id, _pick(pool, k), bytes32(salt % 8), "") {
            if (!may) _violation("a cancel the model refuses landed");
        } catch {}
    }

    function createChild(uint256 who, uint256 g, uint256 salt) external {
        address caller = _pick(actors, who);
        GrantRef memory r = _grant(g);
        bool may =
            !(r.id == ROOT && r.v.parent() == address(0)) && _authorityOver(caller, r.v, r.id) && _delegable(r.v, r.id);
        vm.prank(caller);
        try r.v.createChild(r.id, bytes32(salt % 4 + 1), "") returns (address c) {
            if (!may) _violation("a child vault the model refuses was created");
            if (r.v.grantOfChild(c) == r.id) _addChild(c);
        } catch {}
    }

    function setList(uint256 who, uint256 g, uint256 m, bool ok) external {
        address caller = _pick(actors, who);
        GrantRef memory r = _grant(g);
        bytes32 cp = m % 3 == 0 ? LISTED : m % 3 == 1 ? UNLISTED : OTHER;
        bool may = _above(caller, r.v, r.id);
        vm.prank(caller);
        try list.set(r.v, r.id, cp, ok, "") {
            if (!may) _violation("a list write the model refuses landed");
        } catch {}
    }

    /// The principal brings the tree back after a campaign stopped it: lifts a pause on the root, widens the root again,
    /// and grants the agent's
    /// key anew under the root with its first limits when its grant is closed. A key whose grant closed may be granted
    /// again by transaction, never by a slip.
    function revive(uint256 salt) external {
        address p = top.principal();
        if (top.getGrant(ROOT).paused) {
            vm.prank(p);
            top.setPaused(ROOT, false, "");
        }
        ICrestVault.Caps memory wide = _caps(type(uint128).max, 0, 0, 0, 1 days, false, true);
        if (top.getGrant(ROOT).caps.period != 1 days) lastPeriodChange[_gk(top, ROOT)] = vm.getBlockTimestamp();
        vm.prank(p);
        top.setCaps(ROOT, wide, "");
        if (top.grantOf(agent) != 0) return;
        ICrestVault.Caps memory c = _caps(10_000, 30_000, 200_000, 4, 1 days, true, true);
        vm.prank(p);
        try top.grant(ROOT, agent, c, keccak256(abi.encode("revive", salt)), "") returns (uint256 id) {
            agentGrant = id;
            _addGrant(top, id);
            vm.prank(p);
            list.set(top, id, LISTED, true, "");
            // A new child vault under the new grant, which the campaign fills and takes back from from now on. The
            // previous child keeps what it holds; its parent grant is closed, so it can never pay again.
            vm.prank(agent);
            child = CrestVault(top.createChild(id, keccak256(abi.encode("revive", salt)), ""));
            _addChild(address(child));
            _addGrant(child, ROOT);
            everHeld[address(child)][agent] = true;
        } catch {}
    }

    function handover(bool viaWrongKey) external {
        address from = top.principal();
        address to = from == p1 ? p2 : p1;
        vm.prank(from);
        top.proposePrincipal(to, "");
        if (viaWrongKey) {
            vm.prank(agent);
            try top.acceptPrincipal("") {
                _violation("a key that was not proposed took the vault");
            } catch {}
        }
        vm.prank(to);
        top.acceptPrincipal("");
        everHeld[address(top)][to] = true;
    }

    function collectFee(bool fromChild) external {
        CrestVault v = fromChild ? child : top;
        uint256 owed = v.feeOwed();
        uint256 before = token.balanceOf(destination);
        sweeper.sweep(v);
        if (token.balanceOf(destination) - before != owed) _violation("a sweep moved other than the fee owed");
        feesCollected += owed;
    }

    function wait(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 3 days));
    }

    // ------------------------------------------------------------------ the model

    /// The state, expiry, per-payment limit and list of every grant on the path, here and in every ancestor vault.
    function _pathPays(CrestVault v, uint256 id, uint256 amount, bytes32 cp) internal view returns (bool) {
        for (uint256 g = id; g != 0; g = v.getGrant(g).parent) {
            ICrestVault.Grant memory x = v.getGrant(g);
            if (!_live(x) || amount > x.caps.perSpend) return false;
            if (x.caps.list != address(0) && !list.allowed(address(v), g, cp)) return false;
        }
        address p = v.parent();
        return p == address(0) || _pathPays(CrestVault(p), v.parentGrant(), amount, cp);
    }

    /// The state and the delegation switch of every grant on the path, here and in every ancestor vault.
    function _delegable(CrestVault v, uint256 id) internal view returns (bool) {
        for (uint256 g = id; g != 0; g = v.getGrant(g).parent) {
            ICrestVault.Grant memory x = v.getGrant(g);
            if (!_live(x) || !x.caps.mayDelegate) return false;
        }
        address p = v.parent();
        return p == address(0) || _delegable(CrestVault(p), v.parentGrant());
    }

    /// This vault's counters: open count (payments only), the current window and the lifetime, at every level.
    function _countersAllow(CrestVault v, uint256 id, uint256 amount, bool payment) internal view returns (bool) {
        uint256 now_ = vm.getBlockTimestamp();
        for (uint256 g = id; g != 0; g = v.getGrant(g).parent) {
            ICrestVault.Grant memory x = v.getGrant(g);
            if (payment && uint256(x.open) + 1 > x.caps.maxOpen) return false;
            uint256 start = now_ / x.caps.period * x.caps.period;
            uint256 inWindow = x.windowEnd > start ? x.inPeriod : 0;
            if (inWindow + amount > x.caps.perPeriod) return false;
            if (uint256(x.spent) + amount > x.caps.lifetime) return false;
        }
        return true;
    }

    function _live(ICrestVault.Grant memory x) internal view returns (bool) {
        return !x.closed && !x.paused && (x.caps.expiresAt == 0 || vm.getBlockTimestamp() < x.caps.expiresAt);
    }

    /// Who is above a grant: the top vault's principal, an open grant's controller strictly above it in this vault,
    /// or anyone above the parent grant in the parent vault.
    function _above(address who, CrestVault v, uint256 id) internal view returns (bool) {
        if (who == address(0)) return false;
        if (v.parent() == address(0) && who == v.principal()) return true;
        for (uint256 g = v.getGrant(id).parent; g != 0; g = v.getGrant(g).parent) {
            ICrestVault.Grant memory x = v.getGrant(g);
            if (x.controller == who && !x.closed) return true;
        }
        address p = v.parent();
        return p != address(0) && _above(who, CrestVault(p), v.parentGrant());
    }

    function _authorityOver(address who, CrestVault v, uint256 id) internal view returns (bool) {
        return who != address(0) && (v.getGrant(id).controller == who || _above(who, v, id));
    }

    /// What every landed grant, by transaction or by signature, must satisfy: authority over an open parent; a path
    /// that may delegate unless the signer is the top vault's principal; and, for a key held elsewhere in the vault,
    /// authority above that grant (never the root).
    function _maySign(address by, CrestVault v, uint256 parentId, address key) internal view returns (bool) {
        ICrestVault.Grant memory p = v.getGrant(parentId);
        if (p.controller == address(0) || p.closed || !_authorityOver(by, v, parentId)) return false;
        bool topPrincipal = v.parent() == address(0) && by == v.principal();
        if (!topPrincipal && !_delegable(v, parentId)) return false;
        uint256 held = v.grantOf(key);
        if (held == ROOT) return false;
        return held == 0 || _above(by, v, held);
    }

    // ------------------------------------------------------------------ views for the invariants

    function grantCount() external view returns (uint256) {
        return grants.length;
    }

    function grantAt(uint256 i) external view returns (CrestVault, uint256) {
        return (grants[i].v, grants[i].id);
    }

    function childCount() external view returns (uint256) {
        return children.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function openCount() external view returns (uint256 n) {
        for (uint256 i; i < opens.length; i++) {
            if (opens[i].live) n++;
        }
    }

    /// The model's spend in the current window: every charge since the window began and since the last change of the
    /// period's length. With no such change, the vault must count exactly this; after one, at least this.
    function modelWindow(CrestVault v, uint256 id)
        external
        view
        returns (uint256 sum, bool periodChanged, uint256 all)
    {
        bytes32 k = _gk(v, id);
        uint32 period = v.getGrant(id).caps.period;
        uint256 now_ = vm.getBlockTimestamp();
        uint256 start = now_ / period * period;
        uint256 changed = lastPeriodChange[k];
        Charge[] storage cs = charges[k];
        for (uint256 i; i < cs.length; i++) {
            if (cs[i].at >= start) {
                all += cs[i].amount;
                if (cs[i].at >= changed) sum += cs[i].amount;
            }
        }
        periodChanged = changed != 0;
    }

    function gk(CrestVault v, uint256 id) external pure returns (bytes32) {
        return _gk(v, id);
    }

    // ------------------------------------------------------------------ helpers

    function _ghostCharge(CrestVault v, uint256 leaf, uint256 amount, bool payment) internal {
        uint256 now_ = vm.getBlockTimestamp();
        for (uint256 g = leaf; g != 0; g = v.getGrant(g).parent) {
            bytes32 k = _gk(v, g);
            ghostSpent[k] += amount;
            if (payment) ghostOpen[k] += 1;
            charges[k].push(Charge(now_, amount));
        }
    }

    function _addGrant(CrestVault v, uint256 id) internal {
        bytes32 k = _gk(v, id);
        if (knownGrant[k]) return;
        knownGrant[k] = true;
        grants.push(GrantRef(v, id));
    }

    function _addChild(address c) internal {
        for (uint256 i; i < children.length; i++) {
            if (children[i] == c) return;
        }
        children.push(c);
    }

    function _grant(uint256 g) internal view returns (GrantRef memory) {
        return grants[bound(g, 0, grants.length - 1)];
    }

    function _pick(address[] storage from, uint256 i) internal view returns (address) {
        return from[bound(i, 0, from.length - 1)];
    }

    function _gk(CrestVault v, uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(address(v), id));
    }

    function _violation(string memory why) internal {
        violations++;
        lastViolation = why;
    }

    function _unexpected() internal {
        unexpectedRefusals++;
    }

    function _caps(
        uint256 perSpend,
        uint256 perPeriod,
        uint256 lifetime,
        uint32 maxOpen,
        uint32 period,
        bool restricted,
        bool mayDelegate
    ) internal view returns (ICrestVault.Caps memory) {
        return ICrestVault.Caps({
            perSpend: uint128(perSpend),
            perPeriod: perPeriod == 0 ? type(uint128).max : uint128(perPeriod),
            lifetime: lifetime == 0 ? type(uint128).max : uint128(lifetime),
            maxOpen: maxOpen == 0 ? type(uint32).max : maxOpen,
            period: period,
            expiresAt: 0,
            mayDelegate: mayDelegate,
            list: restricted ? address(list) : address(0)
        });
    }

    function _randomCaps(uint256 seed) internal view returns (ICrestVault.Caps memory c) {
        uint128[4] memory per = [uint128(5_000), 10_000, 20_000, type(uint128).max];
        uint128[4] memory periodLimits = [uint128(10_000), 30_000, 60_000, type(uint128).max];
        uint128[3] memory lifetimes = [uint128(50_000), 200_000, type(uint128).max];
        uint32[4] memory opensMax = [uint32(1), 2, 4, type(uint32).max];
        uint32[3] memory periods = [uint32(1 hours), 1 days, 7 days];
        c.perSpend = per[seed % 4];
        c.perPeriod = periodLimits[(seed >> 8) % 4];
        c.lifetime = lifetimes[(seed >> 16) % 3];
        c.maxOpen = opensMax[(seed >> 24) % 4];
        c.period = periods[(seed >> 32) % 3];
        c.expiresAt = (seed >> 40) % 4 == 0 ? uint40(vm.getBlockTimestamp() + 1 + (seed >> 48) % 10 days) : 0;
        c.mayDelegate = (seed >> 80) % 3 != 0;
        c.list = (seed >> 88) % 2 == 0 ? address(list) : address(0);
    }

    function _sign(uint256 pk, CrestVault v, ICrestVault.SignedGrant memory s) internal view returns (bytes memory) {
        bytes32 capsHash = keccak256(
            abi.encode(
                keccak256(
                    "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
                ),
                s.caps
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
                ),
                s.parent,
                s.controller,
                capsHash,
                s.salt,
                s.deadline,
                keccak256(s.note)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Crest"),
                keccak256("1"),
                block.chainid,
                address(v)
            )
        );
        (uint8 sv, bytes32 r, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, ss, sv);
    }
}
