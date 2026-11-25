// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {HoldbackRules} from "holdback/HoldbackRules.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {HoldbackModule} from "../../src/modules/holdback/HoldbackModule.sol";
import {PayModule} from "../mocks/PayModule.sol";
import {VaultBuyerBase} from "../VaultBuyerBase.sol";

/// Red team, second pass before the outside scan. Every `test_attack_*` passes when the defence holds and fails when
/// the attack works. Every `test_finding_*` asserts the behaviour it reports, so it passes while the behaviour stands.
/// The world is `VaultBuyerBase`: the vault is the deal's buyer and payer, through a module deployed with
/// `VAULT_IS_BUYER`; the agent (`buyer`, `BUYER_PK`) holds `agentGrant` (one hold per deal, three a day, two open, the
/// default list with the test merchant).
contract ReadinessRedTeamTest is VaultBuyerBase {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );

    // Invariant 1: nothing reaches an agent's key

    /// RT-1. A grant that names no list may pay anyone, and "anyone" includes the agent itself. The agent writes terms
    /// that name its own key as seller, payout address and primary adjudicator, signs every part, delivers and accepts
    /// early for the vault: the price lands in the agent's key, with no third party involved. The limits still bound
    /// it; the list is the only control that keeps the money off the agent's key.
    function test_finding_RT1_anUnlistedGrant_paysTheAgentsOwnKey() public {
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, false, true));
        H.Terms memory t = _bterms(vault);
        (t.seller, t.sellerPayoutAddress, t.adjudicator) = (buyer, buyer, buyer);
        uint256 keyBefore = usdc.balanceOf(buyer);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        bytes32 id = module.agreeAndFund(
            t,
            _sellerSig(t, BUYER_PK),
            _acceptance(t, BUYER_PK),
            _agreeAs(t, BUYER_PK),
            H.Funding({signature: new bytes(65)})
        );
        Early memory e = _earlyAs(t, id, BUYER_PK);
        e.dsig = _deliverySig(id, e.d, BUYER_PK);
        _acceptEarly(t, e);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));
        assertEq(usdc.balanceOf(buyer) - keyBefore, t.price, "observed: the price reached the agent's own key");
        assertEq(vaultBefore - usdc.balanceOf(address(vault)), t.price, "the vault paid exactly the price");

        // With the default list back on the grant, the same self-dealing terms are refused at the agent's grant.
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true));
        H.Terms memory u = _bterms(vault);
        (u.seller, u.sellerPayoutAddress, u.adjudicator) = (buyer, buyer, buyer);
        _expectFundRefused(
            u, _agreeAs(u, BUYER_PK), abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );
    }

    /// The pair to RT-1, for an agent following an encoded or smuggled instruction: with a list on its grant, every
    /// route that ends at its own key is refused, through a sub-agent with no list and through a child vault with none.
    function test_attack_aHijackedAgentRoutesThePriceToItsOwnKey_refusedAtEveryRoute() public {
        uint256 keyBefore = usdc.balanceOf(buyer);
        H.Terms memory t = _bterms(vault);
        (t.seller, t.sellerPayoutAddress) = (buyer, buyer);
        _expectFundRefused(
            t, _agreeAs(t, BUYER_PK), abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );

        vm.prank(buyer);
        vault.grant(agentGrant, sub2, _wide(), bytes32("unlisted sub-agent"), "");
        H.Terms memory u = _bterms(vault);
        (u.seller, u.sellerPayoutAddress) = (sub2, buyer);
        _expectFundRefused(
            u, _agreeAs(u, SUB2_PK), abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );

        (CrestVault child,) = _agentChild(HOLD);
        H.Terms memory w = _bterms(child);
        (w.seller, w.sellerPayoutAddress) = (sub, buyer);
        _expectFundRefused(
            w, _agreeAs(w, SUB_PK), abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentGrant)
        );

        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.withdraw(buyer, 1, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setModule(buyer, buyer, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(agentGrant, _wide(), "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(buyer), keyBefore, "nothing reached the agent's key");
    }

    // Invariant 8: the vault's answer to the token

    /// RT-2, fixed on the branch `next-version`. In the stable build (`vault-stable-1`) the token's ERC-1271 branch
    /// answered yes for any transient slot that held 1, and the fee's pending flag lived in the same transient space at
    /// a fixed, public slot, so after a payment with a fee the token got a yes for a "digest" equal to that slot. The
    /// vault now keys each approval as `keccak256(abi.encode(APPROVAL_TAG, digest))`, so the fee's flags answer no.
    function test_attack_RT2_theFeesPendingFlags_getANoFromTheToken_refused() public {
        CrestFeeSweeper sweeper = new CrestFeeSweeper(makeAddr("fee destination"));
        CrestFactory f = new CrestFactory(100, address(sweeper));
        CrestVault v = CrestVault(f.create(principal, address(usdc), bytes32("rt2")));
        PayModule pay = new PayModule(address(usdc));
        vm.startPrank(principal);
        v.setModule(address(pay), address(pay), "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        usdc.mint(address(v), 10 * HOLD);

        bytes32 flag = keccak256("crest.vault.pending.set");
        vm.prank(address(usdc));
        assertEq(v.isValidSignature(flag, ""), NO_1271, "before any payment");
        pay.pay(v, buyer, HOLD, bytes32(0));
        vm.prank(address(usdc));
        assertEq(v.isValidSignature(flag, ""), NO_1271, "a no for the fee's pending flag");
        vm.prank(address(usdc));
        assertEq(v.isValidSignature(keccak256("crest.vault.pending.nonce"), ""), NO_1271, "and for its nonce slot");
        vm.prank(stranger);
        assertEq(v.isValidSignature(flag, ""), NO_1271, "anyone but the token still gets a no");
    }

    /// RT-2's bound: after a payment with a fee, the token gets a yes for the approved digest and a no for every other
    /// hash, the fee's flag and nonce slots included.
    function testFuzz_attack_afterAFeePayment_theTokenGetsANoForEveryOtherHash(bytes32 h) public {
        CrestFeeSweeper sweeper = new CrestFeeSweeper(makeAddr("fee destination"));
        CrestFactory f = new CrestFactory(100, address(sweeper));
        CrestVault v = CrestVault(f.create(principal, address(usdc), bytes32("rt2 fuzz")));
        PayModule pay = new PayModule(address(usdc));
        vm.startPrank(principal);
        v.setModule(address(pay), address(pay), "");
        v.grant(ROOT, buyer, _wide(), 0, "");
        vm.stopPrank();
        usdc.mint(address(v), 10 * HOLD);
        bytes32 nonce = keccak256(abi.encode(address(v), uint256(0)));
        uint256 validBefore = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        RECEIVE_WITH_AUTHORIZATION_TYPEHASH, address(v), address(pay), HOLD, 0, validBefore, nonce
                    )
                )
            )
        );
        bytes32 flag = keccak256("crest.vault.pending.set");
        pay.pay(v, buyer, HOLD, bytes32(0));
        vm.startPrank(address(usdc));
        assertEq(v.isValidSignature(digest, ""), MAGIC_1271, "the approved digest");
        assertEq(v.isValidSignature(keccak256("crest.vault.pending.nonce"), ""), NO_1271, "the nonce's slot");
        assertEq(v.isValidSignature(flag, ""), NO_1271, "the fee's flag slot");
        // The approval's own slot, the one place that now holds 1, is not a digest the vault approved.
        bytes32 approvalSlot = keccak256(abi.encode(keccak256("crest.vault.approval"), digest));
        assertEq(v.isValidSignature(approvalSlot, ""), NO_1271, "the approval's own slot");
        if (h != digest) assertEq(v.isValidSignature(h, ""), NO_1271);
        vm.stopPrank();
    }

    // Invariants 5 and 8: a key moved inside the middle vault of three

    /// Three vaults: the top, the agent's child, and a grandchild whose principal is a sub-agent of the child. The
    /// agent moves that sub-agent's key inside the child while the grandchild has a funded deal. The grandchild's key
    /// and the moved sub-agent lose their voice and the grandchild stops paying; the agent above the moved grant and
    /// the top principal still sign; the money in the grandchild goes only up.
    function test_attack_aKeyMovedInTheMiddleVault_silencesTheGrandchild_andOnlyAuthorityAboveSigns_refused() public {
        _setAgentCaps(_wide());
        (CrestVault c1, uint256 pk1, uint256 g1) = _deeper(vault, BUYER_PK, agentGrant, 1);
        (CrestVault c2, uint256 pk2,) = _deeper(c1, pk1, g1, 2);
        H.Terms memory t = _bterms(c2);
        bytes32 id = _fundAs(t, pk2);

        vm.prank(buyer);
        uint256 moved = c1.grant(ROOT, vm.addr(pk1), _wide(), "moved", "the agent moves its sub-agent");
        assertTrue(c1.getGrant(g1).closed);
        assertTrue(c1.pathLive(moved));

        _expectEarlyRefused(t, _earlyAs(t, id, pk2));
        _expectEarlyRefused(t, _earlyAs(t, id, pk1));
        assertTrue(c2.signsFor(buyer, c2.getOpen(id).grant), "the agent, above the moved grant");
        assertTrue(c2.signsFor(principal, c2.getOpen(id).grant), "the top principal");
        H.Terms memory u = _bterms(c2);
        _expectFundRefused(u, _agreeAs(u, pk2), abi.encodeWithSelector(ICrestVault.GrantClosed.selector, g1));
        _acceptEarly(t, _earlyAs(t, id, BUYER_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Released));

        uint256 left = usdc.balanceOf(address(c2));
        uint256 c1Before = usdc.balanceOf(address(c1));
        vm.prank(buyer);
        c1.takeBackFromChild(address(c2), left, "");
        assertEq(usdc.balanceOf(address(c1)) - c1Before, left, "the grandchild's money went one level up");
        assertEq(usdc.balanceOf(address(c2)), 0);
    }

    // Invariants 5 and 8: cancelSignedGrant tombstones

    /// A tombstone names a key it never granted. That key has `authorityOver` the closed record, and nothing more: it
    /// cannot grant, create a child, widen, resume, land a slip under it, pay or sign for the vault. What it can do is
    /// nest further tombstones under the record, which grant nothing, and it stays a fresh key for an honest slip.
    function test_attack_aKeyNamedInATombstone_gainsNoPowerToPayDelegateOrSign_refused() public {
        address k = vm.addr(OTHER_PK);
        vm.prank(buyer);
        vault.cancelSignedGrant(agentGrant, k, bytes32("slip"), "void a slip");
        uint256 tomb = uint256(keccak256(abi.encode(agentGrant, k, bytes32("slip"))));
        assertTrue(vault.authorityOver(k, tomb), "observed: the named key has authority over the record");
        assertEq(vault.grantOf(k), 0);

        vm.startPrank(k);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, tomb));
        vault.grant(tomb, sub, _wide(), 0, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, tomb));
        vault.createChild(tomb, 0, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(tomb, _wide(), "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setPaused(tomb, false, "");
        vm.stopPrank();

        ICrestVault.SignedGrant memory s = _slip(tomb, sub2, bytes32("under the tombstone"));
        bytes memory sig = _slipSig(OTHER_PK, vault, s);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, tomb));
        vault.grantBySig(s, sig);

        H.Terms memory t = _bterms(vault);
        assertEq(vault.isValidSignature(rules.typedDataHash(hx.id(t)), _termsSig(t, OTHER_PK)), NO_1271);
        _expectFundRefused(t, _agreeAs(t, OTHER_PK), abi.encodeWithSelector(ICrestVault.NoGrant.selector));

        // Even authority above widening the record leaves it closed and unable to pay.
        vm.prank(principal);
        vault.setCaps(tomb, _wide(), "widen a tombstone");
        assertTrue(vault.getGrant(tomb).closed);
        assertFalse(vault.pathLive(tomb));

        // Observed: the named key nests a tombstone under the record. It takes an ID no grant can ever use.
        vm.prank(k);
        vault.cancelSignedGrant(tomb, sub, 0, "nested");
        assertTrue(vault.getGrant(uint256(keccak256(abi.encode(tomb, sub, bytes32(0))))).closed);
        assertEq(vault.grantOf(sub), 0);
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        assertEq(vault.grantOf(sub), subGrant, "the nested record blocks no real grant");
    }

    // Invariant 7: a clone that the factory did not make

    /// Anyone can clone the implementation and initialize it with a real vault as its parent. The clone then reads the
    /// real vault's modules (`payeeOf` asks the parent) and pays through them, but only its own money: the real vault's
    /// balance and counters do not move, the real vault does not know it as a child, and the factory does not list it.
    function test_attack_aCloneOutsideTheFactory_movesNothingOfTheRealVault_refused() public {
        address attacker = vm.addr(OTHER_PK);
        CrestVault fake = CrestVault(LibClone.clone(factory.IMPLEMENTATION()));
        vm.prank(attacker);
        fake.initialize(attacker, address(usdc), address(vault), agentGrant);
        assertFalse(factory.isVault(address(fake)));
        assertEq(fake.payeeOf(address(module)), module.payee(), "observed: it reads the real vault's modules");

        usdc.mint(address(fake), HOLD);
        uint256 realBefore = usdc.balanceOf(address(vault));
        ICrestVault.Grant memory before = vault.getGrant(agentGrant);
        H.Terms memory t = _bterms(fake);
        bytes32 id = _fundAs(t, OTHER_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held), "observed: the clone funds from its own balance");
        assertEq(usdc.balanceOf(address(fake)), 0);
        assertEq(usdc.balanceOf(address(vault)), realBefore, "the real vault paid nothing");
        ICrestVault.Grant memory afterwards = vault.getGrant(agentGrant);
        assertEq(afterwards.spent, before.spent);
        assertEq(afterwards.open, before.open);
        assertEq(afterwards.inPeriod, before.inPeriod);

        vm.prank(principal);
        vm.expectRevert(ICrestVault.UnknownChild.selector);
        vault.takeBackFromChild(address(fake), 1, "");
        vm.prank(attacker);
        vm.expectRevert(ICrestVault.UnknownChild.selector);
        vault.fundChild(address(fake), 1, "");
        // The real vault does not answer for the clone's deal.
        Early memory e = _earlyAs(t, id, PRINCIPAL_PK);
        assertEq(vault.isValidSignature(_earlyDigest(t, id, e.m), e.m.signature), NO_1271);
    }

    // Invariants 3 and 8: two Holdback deployments, one commitment ID

    /// Holdback's commitment ID does not name the rules contract, so the same terms hash alike in a second
    /// deployment. With modules for both enabled, the vault's one record per ID keeps them apart: the second module
    /// cannot open the ID again, cannot end it, and the vault does not answer its messages for it.
    function test_attack_aSecondRulesDeployment_sharesNoSlotNoEndAndNoSignature_refused() public {
        HoldbackRules rules2 = new HoldbackRules(escrow, address(collector3009), MARGIN, sim, address(usdc), 0);
        HoldbackModule m2 = new HoldbackModule(rules2, true);
        address payee2 = m2.payee();
        vm.prank(principal);
        vault.setModule(address(m2), payee2, "the next rules deployment");

        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);

        (HoldbackRules r1, HoldbackModule m1) = (rules, module);
        (rules, module) = (rules2, m2);
        H.Agree memory a2 = _agreeAs(t, BUYER_PK);
        bytes memory s2 = _sellerSig(t, SELLER_PK);
        H.Acceptance memory acc2 = _acceptance(t, ADJ_PK);
        Early memory e2 = _earlyAs(t, id, BUYER_PK);
        bytes32 early2 = _earlyDigest(t, id, e2.m);
        (rules, module) = (r1, m1);

        vm.expectRevert(ICrestVault.CommitmentOpen.selector);
        m2.agreeAndFund(t, s2, acc2, a2, H.Funding({signature: new bytes(65)}));
        assertEq(vault.isValidSignature(early2, e2.m.signature), NO_1271, "the second module did not open the deal");

        vm.warp(vm.getBlockTimestamp() + 6 days);
        vm.expectRevert(ICrestVault.NotOpen.selector);
        m2.close(t);
        assertEq(vault.getOpen(id).module, address(module), "the record still names the module that paid");
        module.close(t);
        assertEq(vault.getGrant(agentGrant).open, 0);
    }

    // Invariant 5 and 8: a key moved mid-flight, with a deal in its child vault

    /// The principal moves the agent's key to a new grant while the agent's child vault has a funded deal. The old
    /// grant closes, so the child's sub-agent and the agent (the child's principal, live again elsewhere) both lose
    /// their voice on that deal; the principal settles with the merchant; the refund lands in the child and goes only
    /// up; the agent's new grant cannot fill the old child.
    function test_attack_aMovedAgentKey_silencesItsChildVaultsSigners_andMoneyOnlyGoesUp_refused() public {
        uint256 total = usdc.balanceOf(address(vault));
        (CrestVault child,) = _agentChild(2 * HOLD);
        H.Terms memory t = _bterms(child);
        bytes32 id = _fundAs(t, SUB_PK);

        vm.prank(principal);
        uint256 moved = vault.grant(ROOT, buyer, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true), "moved", "");
        assertTrue(vault.getGrant(agentGrant).closed);
        assertEq(vault.grantOf(buyer), moved);
        assertTrue(vault.pathLive(moved), "the agent is live again, elsewhere");

        _expectEarlyRefused(t, _earlyAs(t, id, SUB_PK));
        _expectEarlyRefused(t, _earlyAs(t, id, BUYER_PK));
        _expectSettleRefused(t, _mutualAs(t, id, _fullRefund(t), BUYER_PK), IHoldbackRules.BadSignature.selector);
        _settle(t, _mutualAs(t, id, _fullRefund(t), PRINCIPAL_PK));
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Settled));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant));
        vault.fundChild(address(child), HOLD, "");
        H.Terms memory u = _bterms(child);
        _expectFundRefused(u, _agreeAs(u, SUB_PK), abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentGrant));

        uint256 inChild = usdc.balanceOf(address(child));
        vm.prank(buyer);
        vault.takeBackFromChild(address(child), inChild, "the old grant's key returns it up");
        assertEq(usdc.balanceOf(address(child)), 0);
        assertEq(usdc.balanceOf(address(vault)), total, "every unit is back in the vault");
    }

    // Invariants 3 and 11: a child's deal at the escrow's expiry

    /// A sub-agent's deal from a child vault, after the principal stops the agent: at the escrow's expiry anyone ends
    /// the commitment, which frees exactly its two slots in the child and none in the parent, once; the reclaim sends
    /// the hold to the child only, and Holdback's own timeout then closes the deal with nothing left to void.
    function test_attack_aChildDealAtExpiry_freesItsSlotsOnce_andTheReclaimReturnsOnlyToTheChild_refused() public {
        (CrestVault child, uint256 subInChild) = _agentChild(2 * HOLD);
        H.Terms memory t = _bterms(child);
        bytes32 id = _fundAs(t, SUB_PK);
        assertEq(child.getGrant(subInChild).open, 1);
        assertEq(child.getGrant(ROOT).open, 1);
        assertEq(vault.getGrant(agentGrant).open, 0, "a child's deal never counted in the parent");

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop");
        vm.warp(vm.getBlockTimestamp() + 6 days);
        vm.prank(stranger);
        module.close(t);
        assertEq(child.getGrant(subInChild).open, 0);
        assertEq(child.getGrant(ROOT).open, 0);
        vm.expectRevert(ICrestVault.NotOpen.selector);
        module.close(t);

        uint256 childBefore = usdc.balanceOf(address(child));
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        AuthCaptureEscrow.PaymentInfo memory pi = _pi(t);
        vm.prank(stranger);
        child.reclaim(address(module), pi);
        assertEq(usdc.balanceOf(address(child)) - childBefore, HOLD, "the whole hold, to the child");
        assertEq(usdc.balanceOf(address(vault)), vaultBefore);
        vm.expectRevert();
        child.reclaim(address(module), pi);
        rules.reclaim(t);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(usdc.balanceOf(address(child)) - childBefore, HOLD, "no second refund");
    }

    // Invariant 8: an ended deal's terms

    /// While a deal is open, only signers for the grant that paid answer for it. Once it ends, the vault forgets it, so
    /// another agent's yes on that deal's terms and agreement is a dry run again and passes. Holdback never funds a
    /// deal twice, so the yes moves nothing.
    function test_attack_anEndedDealsTermsSignedAgainByASibling_fundNothing_refused() public {
        vm.prank(principal);
        vault.grant(ROOT, sub2, _wide(), 0, "");
        H.Terms memory t = _bterms(vault);
        bytes32 id = _fundAs(t, BUYER_PK);
        bytes32 digest = rules.typedDataHash(hx.id(t));
        assertEq(
            vault.isValidSignature(digest, _termsSig(t, SUB2_PK)), NO_1271, "open: only the paying grant's signers"
        );

        _release(t, id);
        module.close(t);
        assertEq(vault.isValidSignature(digest, _termsSig(t, SUB2_PK)), MAGIC_1271, "observed: ended, a dry run again");

        uint256 before = usdc.balanceOf(address(vault));
        _expectFundRefused(
            t,
            _agreeAs(t, SUB2_PK),
            abi.encodeWithSelector(IHoldbackRules.WrongStage.selector, IHoldbackRules.Stage.Released)
        );
        assertEq(usdc.balanceOf(address(vault)), before);
        assertEq(vault.getGrant(vault.grantOf(sub2)).spent, 0);
    }

    // Invariant 2 and 3: fills that come back

    /// An agent that may delegate fills its child vault and takes the money back, day after day. Each fill counts at
    /// every grant above it, the root included, and a return gives nothing back, so the agent exhausts a vault-wide
    /// lifetime on the root without paying anyone, and a sibling agent is refused for good. The agent's own limits
    /// bound it, and the principal undoes it by raising the root's limit.
    function test_observe_aFillAndReturnLoop_burnsTheRootsLifetime_withoutPayingAnyone() public {
        ICrestVault.Caps memory r = _wide();
        r.lifetime = uint128(4 * HOLD);
        vm.startPrank(principal);
        vault.setCaps(ROOT, r, "a vault-wide budget");
        uint256 sib = vault.grant(ROOT, sub2, _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, true), 0, "");
        allowList.set(vault, sib, _merchant(), true, "");
        vm.stopPrank();
        uint256 balance = usdc.balanceOf(address(vault));

        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        for (uint256 d; d < 2; d++) {
            vm.prank(buyer);
            vault.fundChild(address(child), 2 * HOLD, "");
            vm.prank(buyer);
            child.returnToParent(2 * HOLD, "");
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        assertEq(usdc.balanceOf(address(vault)), balance, "no money left the vault");
        assertEq(vault.getGrant(ROOT).spent, 4 * HOLD, "observed: the root's lifetime is spent");

        H.Terms memory t = _bterms(vault);
        _expectFundRefused(t, _agreeAs(t, SUB2_PK), abi.encodeWithSelector(ICrestVault.OverLifetime.selector, ROOT));
        r.lifetime = type(uint128).max;
        vm.prank(principal);
        vault.setCaps(ROOT, r, "raise the budget");
        _fundAs(t, SUB2_PK);
    }

    // Notes: smuggled text

    /// A note with Unicode tag characters (an invisible "withdraw") is carried byte for byte in the event and changes
    /// nothing: the vault never reads a note. Whoever feeds notes to a model must treat them as untrusted text.
    function test_attack_aNoteWithHiddenUnicodeTags_isCarriedVerbatim_andGrantsNothing_refused() public {
        bytes memory note =
            bytes.concat("routine pause", hex"f3a081b7f3a081a9f3a081b4f3a081a8f3a081a4f3a081b2f3a081a1f3a081b7");
        vm.prank(buyer);
        uint256 subGrant = vault.grant(agentGrant, sub, _wide(), 0, note);
        vm.expectEmit(address(vault));
        emit ICrestVault.PausedSet(subGrant, true, buyer, note);
        vm.prank(buyer);
        vault.setPaused(subGrant, true, note);
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.withdraw(buyer, 1, note);
    }

    // Helpers

    function _slip(uint256 parentId, address controller, bytes32 s)
        internal
        view
        returns (ICrestVault.SignedGrant memory)
    {
        return ICrestVault.SignedGrant({
            parent: parentId,
            controller: controller,
            caps: _wide(),
            salt: s,
            deadline: uint40(vm.getBlockTimestamp() + 1 days),
            note: "red team 2"
        });
    }

    function _slipSig(uint256 pk, CrestVault v, ICrestVault.SignedGrant memory s)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Crest"), keccak256("1"), block.chainid, address(v)));
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_GRANT_TYPEHASH,
                s.parent,
                s.controller,
                keccak256(abi.encode(CAPS_TYPEHASH, s.caps)),
                s.salt,
                s.deadline,
                keccak256(s.note)
            )
        );
        (uint8 sv, bytes32 r, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, ss, sv);
    }
}
