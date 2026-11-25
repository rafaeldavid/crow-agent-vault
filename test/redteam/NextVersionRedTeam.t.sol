// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {IReceiveWithAuthorization, PayModule} from "../mocks/PayModule.sol";
import {VaultBuyerBase} from "../VaultBuyerBase.sol";

/// A module the principal enabled, its own payee. It charges with a nonce and a deadline it chooses, pulls when and as
/// often as it likes, and charges twice in one call.
contract NextVersionModule {
    address public immutable TOKEN;

    constructor(address token) {
        TOKEN = token;
    }

    /// Approves a payment and does not pull it.
    function chargeOnly(ICrestVault v, address controller, uint256 a, bytes32 commitment, uint256 vb, bytes32 nonce)
        external
    {
        v.charge(controller, a, bytes32(0), commitment, vb, nonce);
    }

    function pull(ICrestVault v, uint256 a, uint256 vb, bytes32 nonce) public {
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(address(v), address(this), a, 0, vb, nonce, "");
    }

    /// Approves one payment, pulls it, then tries to pull it again. Returns whether the second pull landed.
    function payThenPullAgain(ICrestVault v, address controller, uint256 a, uint256 vb, bytes32 nonce)
        external
        returns (bool second)
    {
        v.charge(controller, a, bytes32(0), nonce, vb, nonce);
        pull(v, a, vb, nonce);
        try this.pull(v, a, vb, nonce) {
            second = true;
        } catch {}
    }

    /// Approves two payments before it pulls either, then pulls both.
    function chargeBothThenPull(ICrestVault v, address controller, uint256 a, uint256 vb, bytes32 n1, bytes32 n2)
        external
    {
        v.charge(controller, a, bytes32(0), n1, vb, n1);
        v.charge(controller, a, bytes32(0), n2, vb, n2);
        pull(v, a, vb, n1);
        pull(v, a, vb, n2);
    }

    /// Approves and pulls one payment, then approves and pulls a second, all in one call.
    function payTwice(ICrestVault v, address controller, uint256 a, uint256 vb, bytes32 n1, bytes32 n2) external {
        v.charge(controller, a, bytes32(0), n1, vb, n1);
        pull(v, a, vb, n1);
        v.charge(controller, a, bytes32(0), n2, vb, n2);
        pull(v, a, vb, n2);
    }
}

/// Red team of the next version's one change (RT-2's fix): each approved ERC-3009 digest lives at
/// `keccak256(abi.encode(APPROVAL_TAG, digest))` in transient storage, and the token's ERC-1271 question reads the same
/// slot. The property under attack: the vault answers the token yes only for a digest `charge` approved in this
/// transaction, for this vault, and never for any other hash. Every `test_attack_*` passes when the defence holds.
/// ReadinessRedTeam already holds RT-2's own tests (the fee's two fixed slots at a rate of 100 bps); these do not
/// repeat them. A Foundry test function is one transaction, so transient storage lasts for the whole test.
contract NextVersionRedTeamTest is VaultBuyerBase {
    uint256 internal constant RATE = 100; // 1%, in basis points
    bytes32 internal constant APPROVAL_TAG = keccak256("crest.vault.approval");
    bytes32 internal constant PENDING_SET = keccak256("crest.vault.pending.set");
    bytes32 internal constant PENDING_NONCE = keccak256("crest.vault.pending.nonce");

    CrestFactory internal zeroFactory;
    CrestFactory internal feeFactory;

    function setUp() public override {
        super.setUp();
        zeroFactory = new CrestFactory(0, address(0));
        feeFactory = new CrestFactory(RATE, address(new CrestFeeSweeper(makeAddr("fee destination"))));
    }

    // Helpers

    /// A top vault from `f` with `m` enabled as its own payee, the agent holding a grant with no limits, and funds.
    function _world(CrestFactory f, address m, bytes32 s) internal returns (CrestVault v) {
        v = CrestVault(f.create(principal, address(usdc), s));
        vm.startPrank(principal);
        v.setModule(m, m, "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        usdc.mint(address(v), 100 * HOLD);
    }

    /// The ERC-3009 `receiveWithAuthorization` digest `charge` builds for vault `from`.
    function _digest(address from, address payee, uint256 a, uint256 vb, bytes32 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, payee, a, uint256(0), vb, nonce))
            )
        );
    }

    /// What `v` answers `asker` for `h` with an empty signature.
    function _ask(CrestVault v, address asker, bytes32 h) internal returns (bytes4) {
        vm.prank(asker);
        return v.isValidSignature(h, "");
    }

    function _vb() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1 hours;
    }

    // 1. The token's question: only the approved digest

    /// After a payment at rates of 0 and above 0, the token gets a yes for the digest and a no for the values an
    /// attacker can name: the slot the yes lives in, the tag, zero, and the digest with any one field changed.
    function test_attack_theTokenGetsANoForTheSlotTheTagAndEveryNeighbourOfTheDigest_refused() public {
        for (uint256 i; i < 2; i++) {
            NextVersionModule m = new NextVersionModule(address(usdc));
            CrestVault v = _world(i == 0 ? zeroFactory : feeFactory, address(m), bytes32(i));
            uint256 vb = _vb();
            bytes32 n = keccak256(abi.encode("n", i));
            m.chargeOnly(v, buyer, HOLD, n, vb, n);
            bytes32 d = _digest(address(v), address(m), HOLD, vb, n);
            bytes32 slot = keccak256(abi.encode(APPROVAL_TAG, d));
            assertEq(_ask(v, address(usdc), d), MAGIC_1271, "the approved digest");
            assertEq(_ask(v, address(usdc), slot), NO_1271, "the slot the yes lives in");
            assertEq(_ask(v, address(usdc), keccak256(abi.encode(APPROVAL_TAG, slot))), NO_1271, "its slot's slot");
            assertEq(_ask(v, address(usdc), APPROVAL_TAG), NO_1271, "the tag");
            assertEq(_ask(v, address(usdc), bytes32(0)), NO_1271, "zero");
            assertEq(_ask(v, address(usdc), n), NO_1271, "the nonce itself");
            assertEq(_ask(v, address(usdc), _digest(address(v), stranger, HOLD, vb, n)), NO_1271, "another payee");
            assertEq(_ask(v, address(usdc), _digest(address(v), address(m), HOLD + 1, vb, n)), NO_1271, "more");
            assertEq(_ask(v, address(usdc), _digest(address(v), address(m), HOLD, vb + 1, n)), NO_1271, "later");
            assertEq(_ask(v, address(usdc), _digest(address(v), address(m), HOLD, vb, ~n)), NO_1271, "other nonce");
            m.pull(v, HOLD, vb, n);
        }
    }

    /// A module chooses the nonce 1, so the fee's nonce slot holds 1 as the flag slot does. In the stable build the
    /// token got a yes for both slots; here it gets a no for each, and the payment still lands.
    function test_attack_aNonceOfOne_makesTheFeesNonceSlotHoldOne_andTheTokenStillGetsANo_refused() public {
        NextVersionModule m = new NextVersionModule(address(usdc));
        CrestVault v = _world(feeFactory, address(m), "nonce one");
        uint256 vb = _vb();
        bytes32 one = bytes32(uint256(1));
        m.chargeOnly(v, buyer, HOLD, keccak256("c"), vb, one);
        assertEq(_ask(v, address(usdc), PENDING_NONCE), NO_1271, "the nonce slot, holding 1");
        assertEq(_ask(v, address(usdc), PENDING_SET), NO_1271, "the flag slot, holding 1");
        uint256 before = usdc.balanceOf(address(m));
        m.pull(v, HOLD, vb, one);
        assertEq(usdc.balanceOf(address(m)) - before, HOLD, "the payment itself lands");
    }

    /// The bound at a rate of 0, where the fee's slots are never written: the token gets a yes for the approved
    /// digest and a no for every other hash.
    function testFuzz_attack_atRateZero_theTokenGetsANoForEveryOtherHash(bytes32 h) public {
        PayModule pay = new PayModule(address(usdc));
        CrestVault v = _world(zeroFactory, address(pay), "rate zero fuzz");
        bytes32 n = keccak256(abi.encode(address(v), uint256(0)));
        bytes32 d = _digest(address(v), address(pay), HOLD, _vb(), n);
        pay.pay(v, buyer, HOLD, bytes32(0));
        assertEq(_ask(v, address(usdc), d), MAGIC_1271, "the approved digest");
        assertEq(_ask(v, address(usdc), PENDING_SET), NO_1271, "the fee's flag slot");
        if (h != d) assertEq(_ask(v, address(usdc), h), NO_1271, "any other hash");
    }

    /// Before any charge in the transaction, the token gets a no for every hash, at rates of 0 and above 0.
    function testFuzz_attack_beforeAnyCharge_theTokenGetsANoForEveryHash(bytes32 h) public {
        CrestVault v0 = _world(zeroFactory, address(new PayModule(address(usdc))), "no charge 0");
        CrestVault v1 = _world(feeFactory, address(new PayModule(address(usdc))), "no charge 1");
        assertEq(_ask(v0, address(usdc), h), NO_1271);
        assertEq(_ask(v1, address(usdc), h), NO_1271);
    }

    // 2. The approval slots and the fee's pending-approval check

    /// With a fee, a second approval while the first is unpulled is still refused: the tagged approval slot does not
    /// stand in for the token's record of a spent nonce. At a rate of 0 the same batch lands, as in the stable build.
    function test_attack_twoApprovalsBeforeAnyPull_refusedWithAFee_landAtRateZero() public {
        NextVersionModule m0 = new NextVersionModule(address(usdc));
        CrestVault v0 = _world(zeroFactory, address(m0), "batch 0");
        uint256 vb = _vb();
        uint256 before = usdc.balanceOf(address(v0));
        m0.chargeBothThenPull(v0, buyer, HOLD, vb, keccak256("a0"), keccak256("b0"));
        assertEq(before - usdc.balanceOf(address(v0)), 2 * HOLD, "rate 0: both payments left");
        assertEq(_ask(v0, address(usdc), _digest(address(v0), address(m0), HOLD, vb, keccak256("a0"))), MAGIC_1271);
        assertEq(_ask(v0, address(usdc), _digest(address(v0), address(m0), HOLD, vb, keccak256("b0"))), MAGIC_1271);

        NextVersionModule m1 = new NextVersionModule(address(usdc));
        CrestVault v1 = _world(feeFactory, address(m1), "batch 1");
        vm.expectRevert(ICrestVault.ApprovalPending.selector);
        m1.chargeBothThenPull(v1, buyer, HOLD, vb, keccak256("a1"), keccak256("b1"));
    }

    /// With a fee, two payments in one transaction that each pull before the next charge both land, and each digest
    /// answers yes; the fee owed is exactly the two fees.
    function test_attack_twoPaidChargesInOneTransaction_withAFee_eachAnswersOnlyItsOwnDigest() public {
        NextVersionModule m = new NextVersionModule(address(usdc));
        CrestVault v = _world(feeFactory, address(m), "two paid");
        uint256 vb = _vb();
        (bytes32 n1, bytes32 n2) = (keccak256("one"), keccak256("two"));
        uint256 before = usdc.balanceOf(address(v));
        m.payTwice(v, buyer, HOLD, vb, n1, n2);
        assertEq(before - usdc.balanceOf(address(v)), 2 * HOLD, "both payments left");
        assertEq(v.feeOwed(), 2 * (HOLD * RATE / 10_000), "two fees owed");
        assertEq(_ask(v, address(usdc), _digest(address(v), address(m), HOLD, vb, n1)), MAGIC_1271);
        assertEq(_ask(v, address(usdc), _digest(address(v), address(m), HOLD, vb, n2)), MAGIC_1271);
        assertEq(_ask(v, address(usdc), _digest(address(v), address(m), 2 * HOLD, vb, n1)), NO_1271, "no sum");
    }

    // 3. The token asks twice; other vaults; other tokens

    /// The token asks again after the pull: the vault still answers yes for the rest of the transaction, as in the
    /// stable build, and the token's own spent-nonce record refuses the second pull.
    function test_attack_theTokenAsksTwice_theSecondPullIsRefusedByTheSpentNonce() public {
        for (uint256 i; i < 2; i++) {
            NextVersionModule m = new NextVersionModule(address(usdc));
            CrestVault v = _world(i == 0 ? zeroFactory : feeFactory, address(m), bytes32(100 + i));
            uint256 vb = _vb();
            bytes32 n = keccak256(abi.encode("twice", i));
            uint256 before = usdc.balanceOf(address(v));
            bool second = m.payThenPullAgain(v, buyer, HOLD, vb, n);
            assertFalse(second, "the second pull is refused");
            assertEq(before - usdc.balanceOf(address(v)), HOLD, "one payment left");
            assertEq(_ask(v, address(usdc), _digest(address(v), address(m), HOLD, vb, n)), MAGIC_1271, "still yes");
        }
    }

    /// Two vaults with the same token. One approves a payment; the other answers the token no for that digest and
    /// for the same digest rebuilt in its own name.
    function test_attack_aDigestApprovedByAnotherVault_getsANo_refused() public {
        NextVersionModule m = new NextVersionModule(address(usdc));
        CrestVault a = _world(feeFactory, address(m), "vault a");
        CrestVault b = _world(feeFactory, address(m), "vault b");
        uint256 vb = _vb();
        bytes32 n = keccak256("shared nonce");
        m.chargeOnly(a, buyer, HOLD, n, vb, n);
        bytes32 da = _digest(address(a), address(m), HOLD, vb, n);
        assertEq(_ask(a, address(usdc), da), MAGIC_1271, "the vault that approved");
        assertEq(_ask(b, address(usdc), da), NO_1271, "another vault, the same digest");
        assertEq(_ask(b, address(usdc), _digest(address(b), address(m), HOLD, vb, n)), NO_1271, "in its own name");
        vm.expectRevert("MockERC3009: invalid signature");
        m.pull(b, HOLD, vb, n);
        m.pull(a, HOLD, vb, n);
    }

    /// Another ERC-3009 token is not the vault's token: it falls to the buyer-message branch and gets a no for a
    /// digest the vault approved, whatever it builds the digest from.
    function test_attack_anotherTokenAsks_forTheApprovedDigest_getsANo_refused() public {
        NextVersionModule m = new NextVersionModule(address(usdc));
        CrestVault v = _world(feeFactory, address(m), "other token");
        uint256 vb = _vb();
        bytes32 n = keccak256("n");
        m.chargeOnly(v, buyer, HOLD, n, vb, n);
        bytes32 d = _digest(address(v), address(m), HOLD, vb, n);
        address otherToken = makeAddr("another token");
        assertEq(_ask(v, otherToken, d), NO_1271, "another token");
        assertEq(_ask(v, address(m), d), NO_1271, "the module itself");
        assertEq(_ask(v, address(rules), d), NO_1271, "the rules contract");
        vm.prank(stranger);
        assertEq(v.isValidSignature(d, new bytes(65)), NO_1271, "a stranger with 65 bytes");
    }

    // 4. A child vault and its parent

    /// A child vault and its parent each approve a payment in one transaction. Each answers the token yes only for
    /// its own digest; neither answers for the other's, nor for the other's digest rebuilt in its own name.
    function test_attack_aChildAndItsParent_answerOnlyTheirOwnDigests_refused() public {
        for (uint256 i; i < 2; i++) {
            NextVersionModule m = new NextVersionModule(address(usdc));
            CrestVault p = _world(i == 0 ? zeroFactory : feeFactory, address(m), bytes32(200 + i));
            uint256 g = p.grantOf(buyer);
            vm.prank(buyer);
            CrestVault c = CrestVault(p.createChild(g, bytes32(i), ""));
            vm.prank(buyer);
            p.fundChild(address(c), 10 * HOLD, "");
            vm.prank(buyer);
            c.grant(ROOT, sub, _wide(), 0, "");
            uint256 vb = _vb();
            bytes32 n = keccak256(abi.encode("tree", i));
            m.chargeOnly(c, sub, HOLD, n, vb, n);
            m.chargeOnly(p, buyer, HOLD, keccak256(abi.encode("parent commitment", i)), vb, n);
            bytes32 dc = _digest(address(c), address(m), HOLD, vb, n);
            bytes32 dp = _digest(address(p), address(m), HOLD, vb, n);
            assertEq(_ask(c, address(usdc), dc), MAGIC_1271, "the child, its own");
            assertEq(_ask(p, address(usdc), dp), MAGIC_1271, "the parent, its own");
            assertEq(_ask(p, address(usdc), dc), NO_1271, "the parent, the child's");
            assertEq(_ask(c, address(usdc), dp), NO_1271, "the child, the parent's");
            uint256 cb = usdc.balanceOf(address(c));
            uint256 pb = usdc.balanceOf(address(p));
            m.pull(c, HOLD, vb, n);
            m.pull(p, HOLD, vb, n);
            assertEq(cb - usdc.balanceOf(address(c)), HOLD, "the child paid its own");
            assertEq(pb - usdc.balanceOf(address(p)), HOLD, "the parent paid its own");
        }
    }

    // 5. The buyer-message branch, unchanged

    /// The buyer-message branch for anyone but the token: a real buyer message signed by the agent is a yes; the same
    /// message to the token is a no (the token's branch never reads buyer messages); a stranger's key is a no.
    function test_attack_theBuyerMessageBranch_isUnchanged_andTheTokenNeverUsesIt() public {
        for (uint256 i; i < 2; i++) {
            CrestVault v =
                CrestVault((i == 0 ? zeroFactory : feeFactory).create(principal, address(usdc), bytes32(300 + i)));
            vm.startPrank(principal);
            v.setModule(address(module), module.payee(), "");
            v.grant(ROOT, buyer, _wide(), 0, "");
            vm.stopPrank();
            H.Terms memory t = _bterms(v);
            H.Agree memory a = _agreeAs(t, BUYER_PK);
            bytes32 d = _agreeDigest(t, a);
            vm.prank(address(rules));
            assertEq(v.isValidSignature(d, a.signature), MAGIC_1271, "the rules contract: the agent's agree");
            vm.prank(stranger);
            assertEq(v.isValidSignature(d, a.signature), MAGIC_1271, "anyone but the token: the same");
            vm.prank(address(usdc));
            assertEq(v.isValidSignature(d, a.signature), NO_1271, "the token: never a buyer message");
            H.Agree memory bad = _agreeAs(t, 0xBAD);
            vm.prank(address(rules));
            assertEq(v.isValidSignature(_agreeDigest(t, bad), bad.signature), NO_1271, "a key with no grant");
        }
    }

    /// A charge's approval does not leak into the buyer-message branch: anyone but the token gets a no for an approved
    /// digest with an empty signature, and with a 65-byte one.
    function test_attack_anApprovedDigest_isANoOnTheBuyerMessageBranch_refused() public {
        NextVersionModule m = new NextVersionModule(address(usdc));
        CrestVault v = _world(zeroFactory, address(m), "leak");
        uint256 vb = _vb();
        bytes32 n = keccak256("leak");
        m.chargeOnly(v, buyer, HOLD, n, vb, n);
        bytes32 d = _digest(address(v), address(m), HOLD, vb, n);
        assertEq(_ask(v, stranger, d), NO_1271, "empty");
        vm.prank(stranger);
        assertEq(v.isValidSignature(d, _ecdsa(BUYER_PK, d)), NO_1271, "65 bytes from the agent's own key");
    }

    // 6. The payment paths the stable build allowed

    /// The Holdback module with the vault as buyer funds and releases at rates of 0 and above 0; the vault answers the
    /// token yes for the collector's digest and another vault answers no.
    function test_paths_theHoldbackModuleFundsAndReleases_atRateZeroAndAboveZero() public {
        for (uint256 i; i < 2; i++) {
            CrestVault v =
                CrestVault((i == 0 ? zeroFactory : feeFactory).create(principal, address(usdc), bytes32(400 + i)));
            vm.startPrank(principal);
            v.setModule(address(module), module.payee(), "");
            v.grant(ROOT, buyer, _wide(), 0, "");
            vm.stopPrank();
            usdc.mint(address(v), 10 * HOLD);
            H.Terms memory t = _bterms(v);
            bytes32 id = _fundAs(t, BUYER_PK);
            assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held), "held");
            assertEq(usdc.balanceOf(address(v)), 9 * HOLD, "the hold left the vault");
            assertEq(v.feeOwed(), i == 0 ? 0 : HOLD * RATE / 10_000, "the fee owed");
            AuthCaptureEscrow.PaymentInfo memory pi = _pi(t);
            bytes32 d = _collectorDigest(pi);
            assertEq(_ask(v, address(usdc), d), MAGIC_1271, "the collector's digest");
            assertEq(_ask(vault, address(usdc), d), NO_1271, "another vault");
            _release(t, id);
        }
    }

    /// With a fee, two Holdback fundings from one vault in one transaction both land: the collector pulls each before
    /// the next charge, so the pending check passes.
    function test_paths_twoHoldbackFundingsInOneTransaction_withAFee_bothHold() public {
        CrestVault v = CrestVault(feeFactory.create(principal, address(usdc), "two holds"));
        vm.startPrank(principal);
        v.setModule(address(module), module.payee(), "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        usdc.mint(address(v), 10 * HOLD);
        H.Terms memory t1 = _bterms(v);
        H.Terms memory t2 = _bterms(v);
        t2.deliverableHash = keccak256("another deliverable");
        bytes32 id1 = _fundAs(t1, BUYER_PK);
        bytes32 id2 = _fundAs(t2, BUYER_PK);
        assertTrue(id1 != id2);
        assertEq(uint8(_stage(id1)), uint8(IHoldbackRules.Stage.Held));
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Held));
        assertEq(v.feeOwed(), 2 * (HOLD * RATE / 10_000));
    }

    /// The legacy module (the agent's key as the buyer) still funds from the vault, as in the stable build.
    function test_paths_theLegacyModuleFunds() public {
        _useLegacyModule();
        H.Terms memory t = _vterms(address(vault), buyer);
        bytes32 id = _fundVia(t, BUYER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        _release(t, id);
    }

    /// The direct PayModule pays at rates of 0 and above 0, twice in one transaction each.
    function test_paths_theDirectPayModulePays_atRateZeroAndAboveZero() public {
        for (uint256 i; i < 2; i++) {
            PayModule pay = new PayModule(address(usdc));
            CrestVault v = _world(i == 0 ? zeroFactory : feeFactory, address(pay), bytes32(500 + i));
            uint256 before = usdc.balanceOf(address(pay));
            pay.pay(v, buyer, HOLD, bytes32(0));
            pay.pay(v, buyer, HOLD, bytes32(0));
            assertEq(usdc.balanceOf(address(pay)) - before, 2 * HOLD, "both payments landed");
        }
    }
}
