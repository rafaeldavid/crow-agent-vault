// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {PayModule} from "../mocks/PayModule.sol";
import {ChargingController} from "../review/Pr21SecondFamily.t.sol";
import {VaultBuyerBase} from "../VaultBuyerBase.sol";

/// An enabled module whose venue refuses after the charge, so its whole call reverts: a failed charge.
contract ChargeThenRevert {
    function go(ICrestVault v, address controller, uint256 amount, bytes32 nonce) external {
        v.charge(controller, amount, bytes32(0), nonce, block.timestamp + 1 hours, nonce);
        revert("the venue refused");
    }
}

/// The world for the red team of SF-4 (`_requireNoUnspentApproval`, branch `next-version`): a vault with a fee of 1%
/// and a vault at a rate of 0, each with the Holdback module (the vault as the buyer), a `PayModule`, a module that
/// charges and then reverts, and a `ChargingController` (an enabled module that is also a controller with a child
/// vault, and that charges and pulls separately).
///
/// Transactions. A Foundry unit test is one transaction, so transient storage persists across its calls [measured
/// on forge 1.0.0: a value stored in a call is read back by the next call of the same test]. "Same transaction"
/// tests run their sequence inside one external self-call (`this.tx_*`), so they stay one transaction under
/// `--isolate` too. "Later transaction" tests leave the approval in `setUp`: Foundry runs `setUp` as its own
/// transaction and the test starts with transient storage cleared [measured: a value stored in `setUp` reads 0 in the
/// test].
abstract contract Sf4Base is VaultBuyerBase {
    uint256 internal constant RATE = 100; // 1%, in basis points
    uint256 internal constant CHILD_PK = 0xC41D;
    uint256 internal constant A = 1_000_000; // 1 token at 6 decimals; its fee at 1% is 10,000 base units

    struct World {
        CrestVault v;
        uint256 fg; // the deal's buyer key, Holdback module, merchant list
        uint256 mg; // the ChargingController, no list, may delegate
        uint256 sg; // `sub`, no list, for PayModule
        CrestVault child; // under `mg`; its principal is the ChargingController
    }

    CrestFeeSweeper internal sweeper;
    CrestFactory internal feeFactory;
    ChargingController internal m;
    PayModule internal pay;
    ChargeThenRevert internal bad;
    World internal w; // rate 1%
    World internal z; // rate 0

    function setUp() public virtual override {
        super.setUp();
        sweeper = new CrestFeeSweeper(makeAddr("fee destination"));
        feeFactory = new CrestFactory(RATE, address(sweeper));
        m = new ChargingController(address(usdc));
        pay = new PayModule(address(usdc));
        bad = new ChargeThenRevert();
        w = _equip(CrestVault(feeFactory.create(principal, address(usdc), bytes32("sf4 red team"))));
        z = _equip(vault);
    }

    function _equip(CrestVault v) internal returns (World memory x) {
        x.v = v;
        vm.startPrank(principal);
        v.setModule(address(module), module.payee(), "");
        v.setModule(address(m), address(m), "");
        v.setModule(address(pay), address(pay), "");
        v.setModule(address(bad), address(bad), "");
        x.fg = v.grant(ROOT, buyer, _caps(2 * HOLD, 20 * HOLD, type(uint128).max, 10, true, true), bytes32("sf4"), "");
        allowList.set(v, x.fg, _merchant(), true, "");
        x.mg = v.grant(ROOT, address(m), _wide(), 0, "");
        x.sg = v.grant(ROOT, sub, _wide(), 0, "");
        vm.stopPrank();
        x.child = CrestVault(
            abi.decode(m.exec(address(v), abi.encodeCall(ICrestVault.createChild, (x.mg, bytes32(0), ""))), (address))
        );
        usdc.mint(address(v), 20 * HOLD);
    }

    /// The ChargingController charges `v` for its own grant and does not pull.
    function _charge(CrestVault v, uint256 amount, bytes32 nonce) internal returns (uint256 vb) {
        vb = vm.getBlockTimestamp() + 1 hours;
        m.exec(address(v), abi.encodeCall(ICrestVault.charge, (address(m), amount, bytes32(0), nonce, vb, nonce)));
    }

    function _pull(CrestVault v, uint256 amount, uint256 vb, bytes32 nonce) internal {
        m.pull(address(v), amount, vb, nonce);
    }

    function _fill(CrestVault v, CrestVault child, uint256 amount) internal {
        m.exec(address(v), abi.encodeCall(ICrestVault.fundChild, (address(child), amount, "")));
    }

    function _covered(CrestVault v) internal view {
        assertGe(usdc.balanceOf(address(v)), v.feeOwed(), "the vault holds its fee owed");
    }

    function _free(CrestVault v) internal view returns (uint256) {
        return usdc.balanceOf(address(v)) - v.feeOwed();
    }

    function _expectPending() internal {
        vm.expectRevert(ICrestVault.ApprovalPending.selector);
    }

    /// A Holdback funding whose seller signature is wrong: the module charges, Holdback refuses, the call reverts.
    function _failedHoldbackFunding(CrestVault v) internal returns (bool landed) {
        H.Terms memory t = _bterms(v);
        bytes memory wrongSeller = _sellerSig(t, BUYER_PK);
        H.Acceptance memory acc = _acceptance(t, ADJ_PK);
        H.Agree memory ag = _agreeAs(t, BUYER_PK);
        try module.agreeAndFund(t, wrongSeller, acc, ag, H.Funding({signature: new bytes(65)})) {
            landed = true;
        } catch {}
    }
}

/// Same-transaction attacks and paths. Each `test_attack_*` and `test_path_*` passes when the defence holds or the path
/// lands; each `test_observe_*` pins a blocking that lasts only to the end of the transaction of the party that left
/// its approval unpulled.
contract Sf4RedTeamTest is Sf4Base {
    // 1. Break it

    /// A module charges with a nonce the token has already spent. The pending check reads it as spent, so a fill and a
    /// withdrawal land before any pull; but the token refuses the spent nonce, so nothing can follow them out, and the
    /// vault keeps its fee owed. The dead charge still owes a fee, as an abandoned one does: the vault owes a fee when
    /// it approves a payment, not when the token pulls it, so the sweeper is owed 1% of a payment that never left.
    function test_attack_aChargeWithASpentNonce_letsAMovePass_butNothingFollowsIt() public {
        this.tx_spentNonce();
    }

    function tx_spentNonce() external {
        bytes32 n = keccak256("spent");
        uint256 vb = _charge(w.v, A, n);
        _pull(w.v, A, vb, n);
        uint256 owedAfterOne = w.v.feeOwed();
        vb = vm.getBlockTimestamp() + 1 hours;
        m.exec(address(w.v), abi.encodeCall(ICrestVault.charge, (address(m), A, bytes32(0), keccak256("c2"), vb, n)));
        assertEq(w.v.feeOwed() - owedAfterOne, A * RATE / 10_000, "observed: the dead charge owes a fee");
        _fill(w.v, w.child, _free(w.v) / 2);
        uint256 out = _free(w.v);
        vm.prank(principal);
        w.v.withdraw(principal, out, "everything above the fee owed");
        vm.expectRevert(bytes("MockERC3009: authorization is used"));
        _pull(w.v, A, vb, n);
        assertEq(usdc.balanceOf(address(w.v)), w.v.feeOwed(), "exactly the fee owed is left");
        assertEq(w.v.collectFee(), 2 * (A * RATE / 10_000));
    }

    /// A child's pending approval refuses the child's own fill of a grandchild, its return, and the parent's take-back,
    /// until the token pulls. Then each is checked against the child's fee owed.
    function test_attack_aChildsPendingApproval_refusesItsFillItsReturnAndTheTakeBack_untilThePull() public {
        this.tx_childPending();
    }

    function tx_childPending() external {
        _fill(w.v, w.child, 3 * A);
        CrestVault grand = CrestVault(
            abi.decode(
                m.exec(address(w.child), abi.encodeCall(ICrestVault.createChild, (ROOT, bytes32(0), ""))), (address)
            )
        );
        bytes32 n = keccak256("child pending");
        uint256 vb = _charge(w.child, 2 * A, n);
        uint256 rest = 3 * A - 2 * A;
        _expectPending();
        _fill(w.child, grand, rest);
        _expectPending();
        m.exec(address(w.child), abi.encodeCall(ICrestVault.returnToParent, (rest, "")));
        vm.prank(principal);
        _expectPending();
        w.v.takeBackFromChild(address(w.child), rest, "");
        _pull(w.child, 2 * A, vb, n);
        vm.prank(principal);
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        w.v.takeBackFromChild(address(w.child), rest, "");
        uint256 free = _free(w.child);
        vm.prank(principal);
        w.v.takeBackFromChild(address(w.child), free, "all above the child's fee");
        _covered(w.child);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_attack_anyMoveBetweenAChargeAndItsPull_leavesTheFeeCovered(uint64 a, uint64 x, uint8 op) public {
        this.tx_fuzzMove(a, x, op);
    }

    function tx_fuzzMove(uint64 a_, uint64 x_, uint8 op) external {
        _fill(w.v, w.child, HOLD);
        uint256 a = bound(a_, 1, 5 * HOLD);
        bytes32 n = keccak256("fuzz");
        uint256 vb = _charge(w.v, a, n);
        uint256 x = bound(x_, 0, usdc.balanceOf(address(w.v)));
        op %= 4;
        if (op == 0) {
            vm.prank(principal);
            _expectPending();
            w.v.withdraw(principal, x, "");
        } else if (op == 1) {
            _expectPending();
            _fill(w.v, w.child, x);
        } else if (op == 2) {
            // Money coming up from the child is not refused: it adds to the vault that owes.
            uint256 back = bound(x, 0, HOLD);
            vm.prank(principal);
            w.v.takeBackFromChild(address(w.child), back, "");
        } else {
            w.v.collectFee();
            _expectPending();
            _fill(w.v, w.child, x);
        }
        _pull(w.v, a, vb, n);
        _covered(w.v);
        uint256 out = bound(x, 0, _free(w.v));
        vm.prank(principal);
        w.v.withdraw(principal, out, "after the pull");
        _covered(w.v);
    }

    /// A stop between a charge and its pull, in the same transaction, does not revoke the approval: the pull still
    /// lands after the grant is paused and closed and the module is switched off. The fee owed stays covered.
    function test_observe_aStopInsideTheChargesTransaction_doesNotRevokeItsApproval() public {
        this.tx_stopThenPull();
    }

    function tx_stopThenPull() external {
        bytes32 n = keccak256("stop then pull");
        uint256 vb = _charge(w.v, A, n);
        vm.startPrank(principal);
        w.v.setPaused(w.mg, true, "");
        w.v.close(w.mg, "");
        w.v.setModule(address(m), address(0), "");
        vm.stopPrank();
        uint256 before = usdc.balanceOf(address(m));
        _pull(w.v, A, vb, n);
        assertEq(
            usdc.balanceOf(address(m)) - before, A, "observed: the approval given earlier in the transaction is pulled"
        );
        _covered(w.v);
    }

    /// An approval the token can never take (its `validBefore` is already past) blocks a move for the rest of its own
    /// transaction only, and the composer of that transaction can still pay the fee, stop, and take money back.
    function test_observe_anUnpullableApproval_blocksMovesOnlyInItsOwnTransaction() public {
        this.tx_unpullable();
    }

    function tx_unpullable() external {
        bytes32 n = keccak256("expired");
        uint256 vb = vm.getBlockTimestamp();
        m.exec(address(w.v), abi.encodeCall(ICrestVault.charge, (address(m), A, bytes32(0), n, vb, n)));
        vm.expectRevert(bytes("MockERC3009: authorization expired"));
        _pull(w.v, A, vb, n);
        vm.prank(principal);
        _expectPending();
        w.v.withdraw(principal, 0, "a withdrawal of 0");
        w.v.collectFee();
        vm.startPrank(principal);
        w.v.setPaused(w.mg, true, "");
        w.v.takeBackFromChild(address(w.child), 0, "");
        vm.stopPrank();
        _covered(w.v);
    }

    // 2. Legitimate paths in the transaction of a charge

    /// A failed charge (its call reverts) leaves no pending approval: the principal's withdrawal and take-back land in
    /// the same transaction, after a module that reverts and after a Holdback funding that Holdback refuses.
    function test_path_afterAFailedCharge_sameTransaction_withdrawAndTakeBackLand() public {
        this.tx_failedThenMove();
    }

    function tx_failedThenMove() external {
        _fill(w.v, w.child, A);
        uint256 owed = w.v.feeOwed();
        try bad.go(w.v, address(m), A, keccak256("failed")) {
            revert("the failing module landed");
        } catch {}
        assertFalse(_failedHoldbackFunding(w.v), "the refused funding landed");
        assertEq(w.v.feeOwed(), owed, "a failed charge owes nothing");
        vm.startPrank(principal);
        w.v.takeBackFromChild(address(w.child), A, "");
        w.v.withdraw(principal, A, "");
        vm.stopPrank();
        _covered(w.v);
    }

    /// An abandoned charge (approved, not pulled) blocks the principal's withdrawal and a fill until the token pulls,
    /// in that transaction only. The take-back still lands: it brings money in, and checks the child's own approvals.
    function test_observe_anAbandonedCharge_sameTransaction_blocksTheWithdrawalUntilThePull() public {
        this.tx_abandonedThenMove();
    }

    function tx_abandonedThenMove() external {
        _fill(w.v, w.child, A);
        bytes32 n = keccak256("abandoned");
        uint256 vb = _charge(w.v, A, n);
        vm.prank(principal);
        _expectPending();
        w.v.withdraw(principal, A, "");
        _expectPending();
        _fill(w.v, w.child, A);
        vm.prank(principal);
        w.v.takeBackFromChild(address(w.child), A, "a take-back lands");
        _pull(w.v, A, vb, n);
        vm.prank(principal);
        w.v.withdraw(principal, A, "lands after the pull");
        _covered(w.v);
    }

    /// A pause or a close of a grant, by its controller or the principal, lands while a charge's approval is pending.
    function test_path_aPauseOrACloseInTheMiddleOfACharge_lands() public {
        this.tx_pauseClose();
    }

    function tx_pauseClose() external {
        bytes32 n = keccak256("pause close");
        uint256 vb = _charge(w.v, A, n);
        m.exec(address(w.v), abi.encodeCall(ICrestVault.setPaused, (w.mg, true, "the controller pauses itself")));
        vm.startPrank(principal);
        w.v.setPaused(w.fg, true, "");
        w.v.setPaused(ROOT, true, "");
        w.v.close(w.sg, "");
        w.v.setPaused(ROOT, false, "");
        vm.stopPrank();
        m.exec(address(w.v), abi.encodeCall(ICrestVault.close, (w.mg, "the controller closes itself")));
        _pull(w.v, A, vb, n);
        _covered(w.v);
        assertTrue(w.v.getGrant(w.mg).closed && w.v.getGrant(w.fg).paused && w.v.getGrant(w.sg).closed);
    }

    /// Every stop path lands while an approval is pending: pause, close, `setCaps`, a module switched off, a list write.
    function test_path_everyStopPath_withAPendingApproval_lands() public {
        this.tx_stops();
    }

    function tx_stops() external {
        bytes32 n = keccak256("stops");
        uint256 vb = _charge(w.v, A, n);
        vm.startPrank(principal);
        w.v.setPaused(w.fg, true, "");
        w.v.close(w.sg, "");
        w.v.setCaps(w.mg, _caps(1, 1, 1, 1, false, false), "narrow the charging grant");
        w.v.setModule(address(pay), address(0), "");
        w.v.setModule(address(module), address(0), "");
        allowList.set(w.v, w.fg, _merchant(), false, "");
        vm.stopPrank();
        _pull(w.v, A, vb, n);
        _covered(w.v);
    }

    /// A child's approval pending: the parent's withdrawal and fill land, the take-back waits for the pull. The reverse:
    /// the parent's approval pending, the child pays, returns money up, and is taken back from; the parent's fill waits.
    function test_path_aChildAndItsParent_eachMoveWhileTheOthersApprovalIsPending() public {
        this.tx_childThenParent();
        this.tx_parentThenChild();
    }

    function tx_childThenParent() external {
        _fill(w.v, w.child, 2 * A);
        bytes32 n = keccak256("child first");
        uint256 vb = _charge(w.child, A, n);
        vm.prank(principal);
        w.v.withdraw(principal, A, "the parent's withdrawal lands");
        _fill(w.v, w.child, A);
        vm.prank(principal);
        _expectPending();
        w.v.takeBackFromChild(address(w.child), A, "");
        _pull(w.child, A, vb, n);
        vm.prank(principal);
        w.v.takeBackFromChild(address(w.child), A, "lands after the child's pull");
        _covered(w.child);
        _covered(w.v);
    }

    function tx_parentThenChild() external {
        _fill(w.v, w.child, 3 * A);
        bytes32 n = keccak256("parent first");
        uint256 vb = _charge(w.v, A, n);
        pay.pay(w.child, address(m), A, bytes32(0));
        m.exec(address(w.child), abi.encodeCall(ICrestVault.returnToParent, (A / 2, "")));
        vm.prank(principal);
        w.v.takeBackFromChild(address(w.child), A / 2, "");
        _expectPending();
        _fill(w.v, w.child, A);
        _pull(w.v, A, vb, n);
        _covered(w.child);
        _covered(w.v);
    }

    /// Holdback's own timeouts (`rules.reclaim`, `triggerFallback`, `triggerDefault`) and the vault's escrow `reclaim`
    /// return money to a vault whose approval is pending, and none of them is refused.
    function test_path_holdbackTimeoutsAndTheEscrowReclaim_withAPendingApproval_land() public {
        H.Terms memory t1 = _bterms(w.v);
        bytes32 id1 = _fundAs(t1, BUYER_PK);
        H.Terms memory t2 = _bterms(w.v);
        bytes32 id2 = _fundAs(t2, BUYER_PK);
        H.Terms memory t3 = _bterms(w.v);
        bytes32 id3 = _fundAs(t3, BUYER_PK);
        (H.Delivery memory d,) = _deliveryTo(t2.buyer);
        rules.deliver(t2, d, _deliverySig(id2, d, SELLER_PK));
        (d,) = _deliveryTo(t3.buyer);
        rules.deliver(t3, d, _deliverySig(id3, d, SELLER_PK));

        vm.warp(t1.timing.deliverBy);
        this.tx_pendingThen(1, t1);
        assertEq(uint8(_stage(id1)), uint8(IHoldbackRules.Stage.Refunded));
        vm.warp(t2.timing.judgeBy);
        this.tx_pendingThen(2, t2);
        vm.warp(t2.timing.fallbackBy);
        this.tx_pendingThen(3, t2);
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Refunded));
        vm.warp(uint256(t3.timing.fallbackBy) + t3.timing.appealDecideSec + rules.EXPIRY_MARGIN());
        this.tx_pendingThen(4, t3);
    }

    function tx_pendingThen(uint256 step, H.Terms calldata t) external {
        bytes32 n = keccak256(abi.encode("timeout", step));
        uint256 vb = _charge(w.v, A, n);
        uint256 before = usdc.balanceOf(address(w.v));
        vm.startPrank(stranger);
        if (step == 1) rules.reclaim(t);
        else if (step == 2) rules.triggerFallback(t);
        else if (step == 3) rules.triggerDefault(t);
        else w.v.reclaim(address(module), _pi(t));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(w.v)) - before, step == 2 ? 0 : HOLD, "the hold came back to the vault");
        _pull(w.v, A, vb, n);
        _covered(w.v);
    }

    /// `collectFee` and the sweeper land while an approval is pending, and the pull still finds its amount.
    function test_path_collectFeeAndTheSweeper_withAPendingApproval_land() public {
        _fundAs(_bterms(w.v), BUYER_PK);
        this.tx_collect();
    }

    function tx_collect() external {
        bytes32 n = keccak256("collect");
        uint256 vb = _charge(w.v, A, n);
        uint256 owed = w.v.feeOwed();
        assertGt(owed, 0);
        vm.prank(stranger);
        assertEq(sweeper.sweep(w.v), owed, "the sweeper took the fee owed");
        vm.prank(stranger);
        assertEq(w.v.collectFee(), 0);
        _pull(w.v, A, vb, n);
        _covered(w.v);
        assertEq(usdc.balanceOf(sweeper.DESTINATION()), owed);
    }

    /// Holdback payments, one and two per transaction, at a rate above 0 and at 0; then a withdrawal, a fill and a
    /// take-back in the same transaction. The Holdback module pulls in its own call, so nothing is pending after it.
    function test_path_holdbackPayments_oneAndTwoPerTransaction_atBothRates_thenMovesLand() public {
        this.tx_holdback(true, 1);
        this.tx_holdback(true, 2);
        this.tx_holdback(false, 1);
        this.tx_holdback(false, 2);
    }

    function tx_holdback(bool withFee, uint256 count) external {
        World memory x = withFee ? w : z;
        uint256 owed = x.v.feeOwed();
        for (uint256 i; i < count; i++) {
            bytes32 id = _fundAs(_bterms(x.v), BUYER_PK);
            assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        }
        assertEq(x.v.feeOwed() - owed, withFee ? count * (HOLD * RATE / 10_000) : 0);
        _movesLand(x);
    }

    /// PayModule payments, one and two per transaction, at both rates, from the vault and from its child; then moves.
    function test_path_payModulePayments_oneAndTwoPerTransaction_atBothRates_thenMovesLand() public {
        this.tx_pay(true, 1);
        this.tx_pay(true, 2);
        this.tx_pay(false, 1);
        this.tx_pay(false, 2);
    }

    function tx_pay(bool withFee, uint256 count) external {
        World memory x = withFee ? w : z;
        _fill(x.v, x.child, 2 * count * A);
        for (uint256 i; i < count; i++) {
            pay.pay(x.v, sub, A, bytes32(0));
            pay.pay(x.child, address(m), A, bytes32(0));
        }
        _movesLand(x);
        _covered(x.child);
    }

    /// A child vault's own Holdback payment, at a rate above 0, then the child's return and the parent's take-back in
    /// the same transaction.
    function test_path_aChildsHoldbackPayment_thenItsReturnAndTheTakeBack_land() public {
        m.exec(address(w.child), abi.encodeCall(ICrestVault.grant, (ROOT, vm.addr(CHILD_PK), _wide(), 0, "")));
        this.tx_childHoldback();
    }

    function tx_childHoldback() external {
        _fill(w.v, w.child, 2 * HOLD);
        bytes32 id = _fundAs(_bterms(w.child), CHILD_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held));
        assertEq(w.child.feeOwed(), HOLD * RATE / 10_000);
        m.exec(address(w.child), abi.encodeCall(ICrestVault.returnToParent, (HOLD / 2, "")));
        uint256 rest = _free(w.child);
        vm.prank(principal);
        w.v.takeBackFromChild(address(w.child), rest, "");
        assertEq(usdc.balanceOf(address(w.child)), w.child.feeOwed(), "the child keeps exactly its fee owed");
    }

    /// The principal's withdrawal, a fill and a take-back after the transaction's payments.
    function _movesLand(World memory x) internal {
        vm.prank(principal);
        x.v.withdraw(principal, A, "");
        _fill(x.v, x.child, A);
        vm.prank(principal);
        x.v.takeBackFromChild(address(x.child), A, "");
        _covered(x.v);
    }
}

/// Later transactions. `setUp` (its own transaction) leaves a failed charge and two abandoned charges, one in the
/// vault and one in its child; each test is a later transaction, with the approvals' transient flags cleared.
contract Sf4LaterTransactionTest is Sf4Base {
    bytes32 internal constant TOP = keccak256("abandoned in the vault");
    bytes32 internal constant KID = keccak256("abandoned in the child");
    uint256 internal topVb;
    uint256 internal kidVb;
    uint256 internal owedBefore;

    function setUp() public override {
        super.setUp();
        _fill(w.v, w.child, 3 * A);
        owedBefore = w.v.feeOwed();
        try bad.go(w.v, address(m), A, keccak256("failed")) {} catch {}
        _failedHoldbackFunding(w.v);
        kidVb = _charge(w.child, A, KID);
        topVb = _charge(w.v, A, TOP);
    }

    /// The withdrawal, the take-back, a fill and a return all land, and the abandoned approvals can no longer be
    /// pulled. The abandoned charges still owe their fees and keep their commitments open.
    function test_path_laterTransaction_withdrawAndTakeBack_afterAFailedAndAnAbandonedCharge_land() public {
        assertEq(
            w.v.feeOwed() - owedBefore, A * RATE / 10_000, "only the abandoned charge owes; the failed one does not"
        );
        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        _pull(w.v, A, topVb, TOP);
        vm.expectRevert(bytes("MockERC3009: invalid signature"));
        _pull(w.child, A, kidVb, KID);
        vm.startPrank(principal);
        w.v.takeBackFromChild(address(w.child), _free(w.child), "");
        w.v.withdraw(principal, _free(w.v), "");
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(w.v)), w.v.feeOwed());
        assertEq(usdc.balanceOf(address(w.child)), w.child.feeOwed());
        assertEq(w.v.getGrant(w.mg).open, 1, "observed: the abandoned commitment stays open until its module ends it");
    }

    function test_path_laterTransaction_paymentsFillsAndReturns_land() public {
        _fundAs(_bterms(w.v), BUYER_PK);
        pay.pay(w.v, sub, A, bytes32(0));
        _fill(w.v, w.child, A);
        m.exec(address(w.child), abi.encodeCall(ICrestVault.returnToParent, (A, "")));
        this.tx_chargeAndPull();
        _covered(w.v);
        _covered(w.child);
    }

    function tx_chargeAndPull() external {
        bytes32 n = keccak256("later");
        uint256 vb = _charge(w.v, A, n);
        _pull(w.v, A, vb, n);
    }
}
