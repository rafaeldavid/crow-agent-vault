// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {VaultBuyerBase} from "../VaultBuyerBase.sol";

/// Random deals through Holdback's unchanged contracts with the vault as the buyer (the vault-buyer module): fundings
/// by the agent, its sub-agent, the principal or a stranger; deliveries, the primary's accept or reject, early accepts
/// and settlements signed for the vault by any of those keys; refunds at the delivery deadline and the escrow's own
/// reclaim after its expiry; ends of commitments; pauses, resumes and closes of the agent and the sub-agent;
/// withdrawals; and time. The model, from the design record (sections 12 and 19), says who may sign for the vault: the
/// controller of the grant that paid while its path is live, a controller strictly above it whose own path is live, or
/// the top principal. Every landed signature is checked against it.
contract HoldbackHandler is VaultBuyerBase {
    struct Deal {
        H.Terms t;
        bytes32 id;
        uint256 leaf;
        bool inEscrow;
        bool ended; // its commitment ended in the vault
    }

    uint256[] internal pks;
    Deal[] internal deals;
    uint256 public subGrant;
    address public sink = makeAddr("withdrawals");

    uint256 public violations;
    string public lastViolation;
    uint256 public funded;
    uint256 public released;
    uint256 public refunded;
    uint256 public settled;
    uint256 public steppedIn; // a release or settlement signed by someone other than the paying grant's controller
    uint256 public stopsLanded;

    function setUp() public override {
        super.setUp();
        pks = [PRINCIPAL_PK, BUYER_PK, SUB_PK, OTHER_PK];
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _caps(HOLD, 2 * HOLD, type(uint128).max, 2, false, false), 0, "");
    }

    // ------------------------------------------------------------------ actions

    function fund(uint256 k) external {
        uint256 pk = pks[k % pks.length];
        address key = vm.addr(pk);
        uint256 leaf = vault.grantOf(key);
        H.Terms memory t = _bterms(vault);
        H.Agree memory ag = _agreeAs(t, pk);
        bytes memory s = _sellerSig(t, SELLER_PK);
        H.Acceptance memory acc = _acceptance(t, ADJ_PK);
        bool live = leaf != 0 && vault.pathLive(leaf);
        try module.agreeAndFund(t, s, acc, ag, H.Funding({signature: new bytes(65)})) returns (bytes32 id) {
            if (!live) _violation("a funding by a key without a live grant landed");
            Deal storage d = deals.push();
            (d.t, d.id, d.leaf, d.inEscrow) = (t, id, leaf, true);
            funded++;
        } catch {}
    }

    function deliver(uint256 i) external {
        if (deals.length == 0) return;
        Deal storage d = deals[i % deals.length];
        if (_stage(d.id) != IHoldbackRules.Stage.Held || vm.getBlockTimestamp() >= d.t.timing.deliverBy) return;
        (H.Delivery memory dv,) = _deliveryTo(d.t.buyer);
        rules.deliver(d.t, dv, _deliverySig(d.id, dv, SELLER_PK));
    }

    function decide(uint256 i, bool accept) external {
        if (deals.length == 0) return;
        Deal storage d = deals[i % deals.length];
        if (_stage(d.id) != IHoldbackRules.Stage.Delivered || vm.getBlockTimestamp() >= d.t.timing.judgeBy) return;
        rules.decide(d.t, _primary(d.t, d.id, accept ? H.OUTCOME_ACCEPT : H.OUTCOME_REJECT), _noDelivery(), "");
        d.inEscrow = false;
        if (accept) released++;
        else refunded++;
    }

    function early(uint256 i, uint256 k) external {
        if (deals.length == 0) return;
        Deal storage d = deals[i % deals.length];
        uint256 pk = pks[k % pks.length];
        Early memory e = _earlyAs(d.t, d.id, pk);
        bool may = _signsFor(vm.addr(pk), d);
        try rules.earlyAccept(d.t, e.m, e.d, e.dsig, e.k) {
            if (!may) _violation("an early accept by a key that may not sign for the vault landed");
            if (!d.inEscrow) _violation("an early accept of a hold no longer in the escrow landed");
            if (vm.addr(pk) != vault.getGrant(d.leaf).controller) steppedIn++;
            d.inEscrow = false;
            released++;
        } catch {}
    }

    function settle(uint256 i, uint256 k) external {
        if (deals.length == 0) return;
        Deal storage d = deals[i % deals.length];
        uint256 pk = pks[k % pks.length];
        H.Mutual memory m = _mutualAs(d.t, d.id, _fullRefund(d.t), pk);
        bool may = _signsFor(vm.addr(pk), d);
        H.KeyProof memory none;
        try rules.mutualSettle(d.t, m, _noDelivery(), none) {
            if (!may) _violation("a settlement by a key that may not sign for the vault landed");
            if (vm.addr(pk) != vault.getGrant(d.leaf).controller) steppedIn++;
            d.inEscrow = false;
            settled++;
        } catch {}
    }

    function reclaim(uint256 i) external {
        if (deals.length == 0) return;
        Deal storage d = deals[i % deals.length];
        IHoldbackRules.Stage s = _stage(d.id);
        if (s == IHoldbackRules.Stage.Held && vm.getBlockTimestamp() >= d.t.timing.deliverBy && d.inEscrow) {
            rules.reclaim(d.t);
            d.inEscrow = false;
            refunded++;
            return;
        }
        // After the escrow's expiry, the vault's own reclaim returns any hold still in it, and only to the vault.
        uint256 expiry = uint256(d.t.timing.fallbackBy) + d.t.timing.appealDecideSec + rules.EXPIRY_MARGIN();
        if (d.inEscrow && vm.getBlockTimestamp() >= expiry) {
            vm.prank(stranger);
            vault.reclaim(address(module), _pi(d.t));
            d.inEscrow = false;
            refunded++;
        }
    }

    function endDeal(uint256 i) external {
        if (deals.length == 0) return;
        Deal storage d = deals[i % deals.length];
        if (d.ended) return;
        try module.close(d.t) {
            IHoldbackRules.Stage s = _stage(d.id);
            uint256 expiry = uint256(d.t.timing.fallbackBy) + d.t.timing.appealDecideSec + rules.EXPIRY_MARGIN();
            bool over = s == IHoldbackRules.Stage.Released || s == IHoldbackRules.Stage.Refunded
                || s == IHoldbackRules.Stage.Settled || vm.getBlockTimestamp() >= expiry;
            if (!over) _violation("a commitment ended before its deal");
            d.ended = true;
        } catch {}
    }

    /// The principal or the agent stops, resumes or closes the agent or the sub-agent.
    function stop(uint256 who, uint256 what) external {
        address caller = who % 2 == 0 ? principal : buyer;
        uint256 id = what % 2 == 0 ? agentGrant : subGrant;
        uint256 kind = (what >> 1) % 5; // pause, resume, pause, resume, close
        vm.prank(caller);
        if (kind == 4) {
            try vault.close(id, "") {
                stopsLanded++;
            } catch {}
        } else {
            try vault.setPaused(id, kind % 2 == 0, "") {
                stopsLanded++;
            } catch {}
        }
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 0, usdc.balanceOf(address(vault)));
        vm.prank(principal);
        vault.withdraw(sink, amount, "");
    }

    function wait(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 2 days));
    }

    // ------------------------------------------------------------------ the model

    /// Who may sign for the vault on a deal it paid, by the design record (section 19): the paying grant's controller
    /// while its path is live, a controller strictly above it whose own path is live, or the top principal.
    function _signsFor(address who, Deal storage d) internal view returns (bool) {
        if (vault.getOpen(d.id).module == address(0)) return false; // the vault signs for no ended commitment
        if (who == vault.principal()) return true;
        ICrestVault.Grant memory g = vault.getGrant(d.leaf);
        if (g.controller == who && _live(d.leaf)) return true;
        for (uint256 p = g.parent; p != 0; p = vault.getGrant(p).parent) {
            if (vault.getGrant(p).controller == who && _live(p)) return true;
        }
        return false;
    }

    function _live(uint256 id) internal view returns (bool) {
        for (uint256 g = id; g != 0; g = vault.getGrant(g).parent) {
            ICrestVault.Grant memory x = vault.getGrant(g);
            if (x.closed || x.paused || (x.caps.expiresAt != 0 && vm.getBlockTimestamp() >= x.caps.expiresAt)) {
                return false;
            }
        }
        return true;
    }

    function _violation(string memory why) internal {
        violations++;
        lastViolation = why;
    }

    // ------------------------------------------------------------------ views for the invariants

    function dealCount() external view returns (uint256) {
        return deals.length;
    }

    function inEscrowCount() external view returns (uint256 n) {
        for (uint256 i; i < deals.length; i++) {
            if (deals[i].inEscrow) n++;
        }
    }

    function notEndedCount() external view returns (uint256 n) {
        for (uint256 i; i < deals.length; i++) {
            if (!deals[i].ended) n++;
        }
    }

    function holders() external view returns (address[] memory a) {
        a = new address[](9);
        (a[0], a[1], a[2], a[3], a[4]) = (buyer, seller, adjudicator, fallbackAdj, appealAdj);
        (a[5], a[6], a[7], a[8]) = (address(vault), escrow.getTokenStore(address(rules)), sink, principal);
    }

    function keyHolders() external view returns (address[] memory a) {
        a = new address[](3);
        (a[0], a[1], a[2]) = (sub, stranger, relayer);
    }

    function token() external view returns (address) {
        return address(usdc);
    }

    function store() external view returns (address) {
        return escrow.getTokenStore(address(rules));
    }

    function theVault() external view returns (CrestVault) {
        return vault;
    }

    function hold() external pure returns (uint256) {
        return HOLD;
    }
}
