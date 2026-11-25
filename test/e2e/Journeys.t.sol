// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {JourneyBase} from "./JourneyBase.sol";

/// Whole journeys through the factory, the vault, its grants and child vaults, and Holdback's unchanged contracts, with
/// the vault as the deal's buyer. Each test is one owner's story from an empty chain to an empty vault, and checks after
/// every step that no token unit is created, lost or sent to an agent's key (`_assertConserved`).
contract JourneysTest is JourneyBase {
    // ------------------------------------------------------------------ journey 1: the whole life of a budget

    /// An owner creates a vault and grants an agent a budget; the agent delegates to a sub-agent and to a child vault
    /// with its own sub-agent; they pay through Holdback (the vault as the buyer) and through a direct venue; the
    /// open-commitment and daily limits bind across both venues; days roll over; the owner pauses the agent and accepts
    /// a delivered deal in its place, switches its delegation off, closes it, takes the child's money back and empties
    /// the vault, while a hold funded before the stop still ends by Holdback's own timeout and comes back.
    function test_journey_theWholeLifeOfABudget() public {
        _openOwnersVault();
        uint256 adjBefore = usdc.balanceOf(adjudicator);

        // The agent gives a sub-agent one hold at a time, two a day, six in all, no right to delegate.
        vm.prank(agent);
        uint256 subId = ov.grant(agentId, sub, _caps(HOLD, 2 * HOLD, 6 * HOLD, 2, false, false), 0, "a sub-agent");

        // Day 1. The sub-agent buys deal A through Holdback; the vault is the buyer and payer.
        H.Terms memory tA = _bterms(ov);
        bytes32 idA = _fundAs(tA, SUB_PK);
        _assertStage(idA, IHoldbackRules.Stage.Held);
        assertEq(ov.getOpen(idA).grant, subId, "the sub-agent's grant paid");
        assertEq(_spent(ov, subId), HOLD);
        assertEq(_spent(ov, agentId), HOLD, "every level above counts it");
        assertEq(_spent(ov, ROOT), HOLD);
        assertEq(_held(), HOLD, "the hold is in Holdback's escrow");
        _assertConserved();

        // The agent pays half a hold directly; the agent's two open slots are now both taken, across the two venues.
        bytes32 cDirect = _payDirect(ov, agent, HOLD / 2, DIRECT);
        assertEq(_openCount(ov, agentId), 2);
        H.Terms memory tB = _bterms(ov);
        _expectFundRefused(
            tB, _agreeAs(tB, AGENT_PK), abi.encodeWithSelector(ICrestVault.TooManyOpen.selector, agentId)
        );

        // Deal A is delivered and accepted; closing it, and ending the direct payment, frees both slots.
        uint256 sellerBefore = usdc.balanceOf(seller);
        _release(tA, idA);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE, "the listed merchant is paid the price");
        module.close(tA);
        direct.end(ov, cDirect);
        assertEq(_openCount(ov, agentId), 0);
        _assertConserved();

        // The agent buys B (2.5 holds today); C would pass the daily limit of 3 holds.
        bytes32 idB = _fundAs(tB, AGENT_PK);
        assertEq(_inPeriod(ov, agentId), 2 * HOLD + HOLD / 2);
        H.Terms memory tC = _bterms(ov);
        _expectFundRefused(
            tC, _agreeAs(tC, AGENT_PK), abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentId)
        );
        // The agent accepts B early for the vault: the price goes to the merchant, the fee back to the vault.
        _post(tB, idB);
        _acceptEarly(tB, _earlyBy(tB, idB, AGENT_PK));
        _assertStage(idB, IHoldbackRules.Stage.Released);
        module.close(tB);
        _assertConserved();

        // Day 2. A new window: C funds, and the refund of nothing gives no day back.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        tC = _bterms(ov);
        bytes32 idC = _fundAs(tC, AGENT_PK);
        assertEq(_inPeriod(ov, agentId), HOLD, "the new day counts only today's spend");
        _post(tC, idC);
        _acceptEarly(tC, _earlyBy(tC, idC, AGENT_PK));
        module.close(tC);

        // The agent creates a child vault for itself and fills it with two holds: the fill counts against its day.
        vm.startPrank(agent);
        CrestVault child = CrestVault(ov.createChild(agentId, "child", "a child vault"));
        ov.fundChild(address(child), 2 * HOLD, "fill");
        uint256 childSubId = child.grant(ROOT, childSub, _wide(), 0, "the child's sub-agent");
        vm.stopPrank();
        _track(address(child));
        assertEq(child.principal(), agent);
        assertEq(child.parent(), address(ov));
        assertEq(_inPeriod(ov, agentId), 3 * HOLD, "the fill is charged to the agent's day");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentId));
        ov.fundChild(address(child), 1, "a second fill today");
        _assertConserved();

        // The child's sub-agent is bound by the agent's list above it, and buys D through Holdback from the child.
        _expectDirectRefused(
            child,
            childSub,
            HOLD / 4,
            keccak256("a merchant no one listed"),
            abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentId)
        );
        H.Terms memory tD = _bterms(child);
        bytes32 idD = _fundAs(tD, CHILD_SUB_PK);
        assertEq(child.getOpen(idD).grant, childSubId);
        // The primary rejects D: the refund goes back to the child, not up and not to any key.
        uint256 childBefore = usdc.balanceOf(address(child));
        _deliver(tD, idD);
        rules.decide(tD, _primary(tD, idD, H.OUTCOME_REJECT), _noDelivery(), "");
        _assertStage(idD, IHoldbackRules.Stage.Refunded);
        assertGe(usdc.balanceOf(address(child)) - childBefore, PRICE, "the price comes back to the child");
        assertEq(_inPeriod(child, childSubId), HOLD, "a refund gives no period back: the counters are gross");
        module.close(tD);
        _assertConserved();

        // Day 3. The sub-agent funds F, which the seller delivers; the agent funds E, which stays undelivered.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        H.Terms memory tF = _bterms(ov);
        bytes32 idF = _fundAs(tF, SUB_PK);
        _post(tF, idF);
        H.Terms memory tE = _bterms(ov);
        bytes32 idE = _fundAs(tE, AGENT_PK);
        _assertStage(idE, IHoldbackRules.Stage.Held);

        // The owner pauses the agent: nothing at or below it pays, inside the child too, and no one at or below it
        // signs for the vault. The agent cannot lift the pause. The owner accepts F early in the agent's place.
        vm.prank(owner);
        ov.setPaused(agentId, true, "stop the agent");
        _expectDirectRefused(ov, sub, HOLD / 4, DIRECT, abi.encodeWithSelector(ICrestVault.Paused.selector, agentId));
        _expectDirectRefused(
            child, childSub, HOLD / 4, DIRECT, abi.encodeWithSelector(ICrestVault.Paused.selector, agentId)
        );
        _expectEarlyRefused(tF, _earlyBy(tF, idF, SUB_PK));
        _expectEarlyRefused(tF, _earlyBy(tF, idF, AGENT_PK));
        _expectEarlyRefused(tF, _earlyBy(tF, idF, CHILD_SUB_PK));
        vm.prank(agent);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.setPaused(agentId, false, "the agent lifts its own pause");
        sellerBefore = usdc.balanceOf(seller);
        _acceptEarly(tF, _earlyBy(tF, idF, OWNER_PK));
        _assertStage(idF, IHoldbackRules.Stage.Released);
        assertEq(usdc.balanceOf(seller) - sellerBefore, PRICE);
        module.close(tF);
        _assertConserved();

        // The owner resumes the agent and switches its delegation off, every other limit as it was.
        ICrestVault.Caps memory c = ov.getGrant(agentId).caps;
        c.mayDelegate = false;
        vm.startPrank(owner);
        ov.setPaused(agentId, false, "resume");
        ov.setCaps(agentId, c, "no more delegating");
        vm.stopPrank();
        vm.startPrank(agent);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        ov.grant(agentId, sub2, _wide(), 0, "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        ov.fundChild(address(child), 1, "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.grant(ROOT, sub2, _wide(), 0, "");
        vm.stopPrank();
        // The agent and everyone below it keep paying inside the limits.
        bytes32 cDirect2 = _payDirect(ov, agent, HOLD / 2, DIRECT);
        _payDirect(child, childSub, HOLD / 4, DIRECT);
        _assertConserved();

        // The owner closes the agent: its key is freed, nothing at or below it pays again.
        vm.prank(owner);
        ov.close(agentId, "the agent is done");
        assertEq(ov.grantOf(agent), 0, "the closed grant frees its key");
        _expectDirectRefused(ov, agent, 1, DIRECT, abi.encodeWithSelector(ICrestVault.NoGrant.selector));
        _expectDirectRefused(ov, sub, 1, DIRECT, abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentId));
        _expectDirectRefused(
            child, childSub, 1, DIRECT, abi.encodeWithSelector(ICrestVault.GrantClosed.selector, agentId)
        );
        _expectEarlyRefused(tE, _earlyBy(tE, idE, AGENT_PK));

        // The owner takes the child's money back and empties the vault. E's hold stays in the escrow, untouched.
        uint256 inChild = usdc.balanceOf(address(child));
        vm.startPrank(owner);
        ov.takeBackFromChild(address(child), inChild, "take back");
        uint256 free = usdc.balanceOf(address(ov));
        ov.withdraw(treasury, free, "empty the vault");
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(child)), 0);
        assertEq(usdc.balanceOf(address(ov)), 0);
        assertEq(_held(), HOLD, "E's hold is still in the escrow: nothing the vault does reaches it");
        _assertConserved();

        // E ends by Holdback's own timeout: anyone reclaims at its delivery deadline, and the hold comes back.
        vm.warp(tE.timing.deliverBy);
        vm.prank(stranger);
        rules.reclaim(tE);
        _assertStage(idE, IHoldbackRules.Stage.Refunded);
        assertEq(usdc.balanceOf(address(ov)), HOLD, "price and fee come back to the vault");
        module.close(tE);
        direct.end(ov, cDirect2);
        assertEq(_openCount(ov, ROOT), 0, "every commitment from the vault has ended");
        vm.prank(owner);
        ov.withdraw(treasury, HOLD, "the refund");
        assertEq(usdc.balanceOf(address(ov)), 0);
        assertEq(_held(), 0);

        // Where the owner's money went: four prices to the listed merchant (A, B, C, F), the primary's fee for its two
        // decisions (A's accept and D's reject; the early accepts void the fee back), what the direct venue was paid,
        // and the rest to the treasury.
        uint256 directTaken = usdc.balanceOf(address(direct));
        assertEq(
            directTaken, HOLD / 2 + HOLD / 2 + HOLD / 4, "the direct venue took only the three payments it was paid"
        );
        assertEq(usdc.balanceOf(adjudicator) - adjBefore, 2 * FEE, "the primary earned its fee twice");
        assertEq(usdc.balanceOf(treasury) + 4 * PRICE + 2 * FEE + directTaken, FUNDED);
        assertEq(_spent(ov, agentId), 8 * HOLD, "the agent's lifetime counter holds every payment and the fill");
        _assertConserved();
    }

    // ------------------------------------------------------------------ journey 2: signed grants and a handover

    /// The agent grants a fresh sub-agent by a signature alone, which a relayer lands; the sub-agent buys; the slip
    /// cannot land twice; an unused slip is cancelled. The owner then hands the vault to a new key: the old key loses
    /// every power at once, including signing for a funded deal, and the new key accepts and withdraws.
    function test_journey_signedGrantsThenAHandover() public {
        _openOwnersVault();

        ICrestVault.SignedGrant memory s = ICrestVault.SignedGrant({
            parent: agentId,
            controller: slipSub,
            caps: _caps(HOLD, HOLD, HOLD, 1, false, false),
            salt: "task 1",
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: "one task"
        });
        bytes memory sig = _slipSig(AGENT_PK, ov, s);
        vm.prank(relayer);
        uint256 slipId = ov.grantBySig(s, sig);
        assertEq(ov.grantOf(slipSub), slipId);
        assertEq(ov.getGrant(slipId).parent, agentId);

        // The relayer sends the sub-agent's funding; the vault charges the sub-agent's grant and the agent's.
        H.Terms memory t = _bterms(ov);
        H.Agree memory ag = _agreeAs(t, SLIP_SUB_PK);
        bytes memory sellerSig = _sellerSig(t, SELLER_PK);
        H.Acceptance memory acc = _acceptance(t, ADJ_PK);
        vm.prank(relayer);
        bytes32 id = module.agreeAndFund(t, sellerSig, acc, ag, H.Funding({signature: new bytes(65)}));
        assertEq(ov.getOpen(id).grant, slipId);
        assertEq(_spent(ov, agentId), HOLD);

        // The slip cannot land again, for this key or under another salt.
        vm.expectRevert(ICrestVault.KeyNotFresh.selector);
        ov.grantBySig(s, sig);
        s.salt = "task 1, again";
        bytes memory sig2 = _slipSig(AGENT_PK, ov, s);
        vm.expectRevert(ICrestVault.KeyNotFresh.selector);
        ov.grantBySig(s, sig2);

        // An unused slip for another key is cancelled by its signer and never lands.
        ICrestVault.SignedGrant memory s3 = s;
        s3.controller = sub2;
        s3.salt = "spare";
        bytes memory sig3 = _slipSig(AGENT_PK, ov, s3);
        vm.prank(agent);
        ov.cancelSignedGrant(agentId, sub2, "spare", "cancel the spare");
        vm.expectRevert(ICrestVault.GrantExists.selector);
        ov.grantBySig(s3, sig3);
        _assertConserved();

        // The handover: the owner proposes a new key; only that key can accept.
        uint256 newPk = 0x0E0E2;
        address newOwner = vm.addr(newPk);
        vm.prank(owner);
        ov.proposePrincipal(newOwner, "hand over");
        vm.prank(agent);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.acceptPrincipal("the agent takes the vault");
        vm.prank(newOwner);
        ov.acceptPrincipal("accepted");
        assertEq(ov.principal(), newOwner);
        assertEq(ov.grantOf(owner), 0);

        // The old key has no power left: no withdrawal, no stop, no signature for the vault on the funded deal.
        vm.startPrank(owner);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.withdraw(owner, 1, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.setPaused(agentId, true, "");
        vm.stopPrank();
        _post(t, id);
        vm.prank(newOwner);
        ov.setPaused(slipId, true, "stop the sub-agent");
        _expectEarlyRefused(t, _earlyBy(t, id, SLIP_SUB_PK));
        _expectEarlyRefused(t, _earlyBy(t, id, OWNER_PK));
        _acceptEarly(t, _earlyBy(t, id, newPk));
        _assertStage(id, IHoldbackRules.Stage.Released);
        module.close(t);

        uint256 left = usdc.balanceOf(address(ov));
        vm.prank(newOwner);
        ov.withdraw(treasury, left, "the new owner withdraws");
        assertEq(usdc.balanceOf(address(ov)), 0);
        _assertConserved();
    }

    // ------------------------------------------------------------------ journey 3: a factory with a fee

    /// A factory with a fee of 1% and a sweeper. A payment owes the fee on top, the hold receives exactly its terms,
    /// the fee counts against the limits, a refund keeps the fee owed, no withdrawal can take it, and the sweeper
    /// collects exactly what is owed to its fixed destination.
    function test_journey_aFactoryWithAFee() public {
        address destination = makeAddr("the fee destination");
        CrestFeeSweeper sweeper = new CrestFeeSweeper(destination);
        CrestFactory feeFactory = new CrestFactory(100, address(sweeper));
        CrestVault fv = CrestVault(feeFactory.create(owner, address(usdc), "fee"));
        _track(address(fv));
        _track(address(sweeper));
        _track(destination);
        usdc.mint(owner, 4 * HOLD);
        uint256 fee = HOLD / 100;
        vm.startPrank(owner);
        usdc.transfer(address(fv), 4 * HOLD);
        fv.setModule(address(module), module.payee(), "Holdback");
        // A per-payment limit of exactly one hold: the hold plus its fee passes it.
        uint256 aId = fv.grant(ROOT, agent, _caps(HOLD, 4 * HOLD, 4 * HOLD, 4, false, false), 0, "");
        vm.stopPrank();
        H.Terms memory t = _bterms(fv);
        _expectFundRefused(t, _agreeAs(t, AGENT_PK), abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, aId));
        vm.prank(owner);
        fv.setCaps(aId, _caps(HOLD + fee, 4 * HOLD, 4 * HOLD, 4, false, false), "room for the fee");

        uint256 heldBefore = _held();
        bytes32 id = _fundAs(t, AGENT_PK);
        assertEq(_held() - heldBefore, HOLD, "the hold receives exactly its terms");
        assertEq(fv.feeOwed(), fee, "the fee is owed, not paid");
        assertEq(_spent(fv, aId), HOLD + fee, "the fee counts against the limits");
        assertEq(usdc.balanceOf(address(fv)), 3 * HOLD);

        // The deal is cancelled by the agent and the merchant: the hold comes back, the fee stays owed.
        _settle(t, _mutualAs(t, id, _fullRefund(t), AGENT_PK));
        _assertStage(id, IHoldbackRules.Stage.Settled);
        assertEq(usdc.balanceOf(address(fv)), 4 * HOLD);
        assertEq(fv.feeOwed(), fee);

        // No withdrawal takes the fee owed.
        vm.prank(owner);
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        fv.withdraw(treasury, 4 * HOLD, "everything");

        // Anyone sweeps: exactly the fee goes to the fixed destination, then the owner withdraws the rest.
        vm.prank(stranger);
        sweeper.sweep(fv);
        assertEq(usdc.balanceOf(destination), fee);
        assertEq(fv.feeOwed(), 0);
        vm.prank(owner);
        fv.withdraw(treasury, 4 * HOLD - fee, "the rest");
        assertEq(usdc.balanceOf(address(fv)), 0);
        _assertConserved();
    }

    // ------------------------------------------------------------------ journey 4: everything an agent may not do

    /// One agent tries every refused move in turn. Each is refused by name, and none changes a counter or a balance.
    function test_journey_everyRefusedMove_countsNothing() public {
        _openOwnersVault();
        vm.prank(agent);
        uint256 subId = ov.grant(agentId, sub, _caps(HOLD, 3 * HOLD, 2 * HOLD, 3, false, false), 0, "");
        uint256 vaultBefore = usdc.balanceOf(address(ov));

        // Over the agent's per-payment limit.
        H.Terms memory t = _bterms(ov);
        t.price = PRICE + 1;
        _expectFundRefused(t, _agreeAs(t, AGENT_PK), abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, agentId));
        // A payout address no one listed.
        t = _bterms(ov);
        t.sellerPayoutAddress = stranger;
        _expectFundRefused(
            t, _agreeAs(t, AGENT_PK), abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentId)
        );
        // The listed payout address with an adjudicator the owner never accepted.
        t = _bterms(ov);
        t.adjudicator = stranger;
        _expectFundRefused(
            t, _agreeAs(t, AGENT_PK), abi.encodeWithSelector(ICrestVault.CounterpartyNotAllowed.selector, agentId)
        );
        // A key with no grant signs the agreement.
        t = _bterms(ov);
        _expectFundRefused(t, _agreeAs(t, OTHER_PK), abi.encodeWithSelector(ICrestVault.NoGrant.selector));
        // A funding sent straight to the rules contract, without the module: the vault answers the token no.
        t = _bterms(ov);
        bytes memory sellerSig = _sellerSig(t, SELLER_PK);
        H.Acceptance memory acc = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agreeAs(t, AGENT_PK);
        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        rules.agreeAndFund(t, sellerSig, acc, ag, H.Funding({signature: new bytes(65)}));

        // The agent acting as the owner, or widening itself.
        vm.startPrank(agent);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.withdraw(agent, 1, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.setModule(address(this), address(this), "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.setCaps(agentId, _wide(), "");
        vm.expectRevert(ICrestVault.NotChildVault.selector);
        ov.returnToParent(1, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        allowList.set(ov, agentId, keccak256("my own merchant"), true, "");
        vm.stopPrank();
        // A stranger granting, pausing, closing or reaching the tree.
        vm.startPrank(stranger);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.grant(ROOT, stranger, _wide(), 0, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.setPaused(agentId, true, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.close(agentId, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.proposePrincipal(stranger, "");
        vm.stopPrank();
        // The sub-agent widening itself or its parent.
        vm.startPrank(sub);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.setCaps(subId, _wide(), "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        ov.grant(subId, sub2, _wide(), 0, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        ov.setCaps(agentId, _wide(), "");
        vm.stopPrank();
        // A module the owner never enabled.
        vm.expectRevert(ICrestVault.ModuleNotEnabled.selector);
        ov.charge(agent, 1, DIRECT, keccak256("c"), vm.getBlockTimestamp() + 1, keccak256("n"));

        assertEq(_spent(ov, ROOT), 0, "no refused move counted anything");
        assertEq(usdc.balanceOf(address(ov)), vaultBefore, "no refused move moved anything");

        // The sub-agent's lifetime of two holds: two pay, the third is refused.
        _fundAs(_bterms(ov), SUB_PK);
        _fundAs(_bterms(ov), SUB_PK);
        t = _bterms(ov);
        _expectFundRefused(t, _agreeAs(t, SUB_PK), abi.encodeWithSelector(ICrestVault.OverLifetime.selector, subId));

        // After the agent's 30 days, nothing at or below it pays.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        t = _bterms(ov);
        _expectFundRefused(t, _agreeAs(t, AGENT_PK), abi.encodeWithSelector(ICrestVault.Expired.selector, agentId));
        _expectDirectRefused(ov, agent, 1, DIRECT, abi.encodeWithSelector(ICrestVault.Expired.selector, agentId));
        // The sub-agent's own lifetime is checked first, at its own level: the refusal names the lowest grant it meets.
        _expectDirectRefused(ov, sub, 1, DIRECT, abi.encodeWithSelector(ICrestVault.OverLifetime.selector, subId));
        _assertConserved();
    }

    // ------------------------------------------------------------------ journey 5: holds that end without the agent

    /// After the owner stops everything and switches the module off, every funded hold still ends by Holdback's terms
    /// and comes back to the vault: one undelivered (refund at the delivery deadline), one delivered whose adjudicators
    /// stay silent (the escrow's own reclaim after its expiry, sent by the vault), and one the owner and the merchant
    /// cancel after the owner switches the module back on.
    function test_journey_holdsEndByTheirTerms_withoutTheAgent() public {
        _openOwnersVault();
        H.Terms memory t1 = _bterms(ov);
        bytes32 id1 = _fundAs(t1, AGENT_PK);
        H.Terms memory t2 = _bterms(ov);
        bytes32 id2 = _fundAs(t2, AGENT_PK);
        _post(t2, id2);
        uint256 afterFunding = usdc.balanceOf(address(ov));

        vm.startPrank(owner);
        ov.setPaused(ROOT, true, "stop everything");
        ov.setModule(address(module), address(0), "switch Holdback off");
        vm.stopPrank();
        // With the module off, no one signs for the vault, not even the owner.
        _expectEarlyRefused(t2, _earlyBy(t2, id2, OWNER_PK));

        // The undelivered hold comes back at its delivery deadline.
        vm.warp(t1.timing.deliverBy);
        rules.reclaim(t1);
        _assertStage(id1, IHoldbackRules.Stage.Refunded);
        assertEq(usdc.balanceOf(address(ov)) - afterFunding, HOLD);

        // The delivered hold whose adjudicators never decide: after the escrow's expiry the vault's own reclaim, sent
        // by anyone, returns it, and only to the vault. Its commitment then ends. Switching the module back on is
        // needed for the vault's reclaim, which goes only through an enabled module.
        vm.warp(uint256(t2.timing.fallbackBy) + t2.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        address payee = module.payee();
        vm.prank(owner);
        ov.setModule(address(module), payee, "Holdback back on");
        vm.prank(stranger);
        ov.reclaim(address(module), _pi(t2));
        assertEq(usdc.balanceOf(address(ov)), afterFunding + 2 * HOLD, "both holds are back");
        module.close(t1);
        module.close(t2);
        assertEq(_openCount(ov, agentId), 0);
        _assertConserved();

        // A third deal, funded after the owner resumes, which the owner and the merchant cancel without the agent.
        vm.prank(owner);
        ov.setPaused(ROOT, false, "resume");
        H.Terms memory t3 = _bterms(ov);
        bytes32 id3 = _fundAs(t3, AGENT_PK);
        vm.prank(owner);
        ov.close(agentId, "stop the agent for good");
        _expectSettleRefused(t3, _mutualAs(t3, id3, _fullRefund(t3), AGENT_PK), IHoldbackRules.BadSignature.selector);
        _settle(t3, _mutualAs(t3, id3, _fullRefund(t3), OWNER_PK));
        _assertStage(id3, IHoldbackRules.Stage.Settled);
        module.close(t3);
        assertEq(usdc.balanceOf(address(ov)), FUNDED, "every hold came back; nothing reached the agent");
        _assertConserved();
    }

    function _slipSig(uint256 pk, CrestVault v, ICrestVault.SignedGrant memory s)
        internal
        view
        returns (bytes memory)
    {
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
