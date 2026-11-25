// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {SystemHandler} from "./SystemHandler.sol";

/// The vault system's invariants under random sequences (`SystemHandler`). `docs/audit/readiness.md` maps each one to
/// the property it checks. The in-file `default.` settings are CI's; the recorded deep runs use
/// `FOUNDRY_PROFILE=deep` and the in-file `deep.` settings.
abstract contract SystemChecks is Test {
    SystemHandler internal h;

    function _fee() internal pure virtual returns (uint256);

    function setUp() public virtual {
        h = new SystemHandler(_fee());
    }

    function _target() internal {
        bytes4[] memory s = new bytes4[](23);
        s[22] = SystemHandler.revive.selector;
        s[0] = SystemHandler.pay.selector;
        s[1] = SystemHandler.pay.selector; // payments four times as often as most other moves
        s[19] = SystemHandler.pay.selector;
        s[20] = SystemHandler.pay.selector;
        s[21] = SystemHandler.wait.selector;
        s[2] = SystemHandler.end.selector;
        s[3] = SystemHandler.fundChild.selector;
        s[4] = SystemHandler.takeBack.selector;
        s[5] = SystemHandler.returnToParent.selector;
        s[6] = SystemHandler.withdraw.selector;
        s[7] = SystemHandler.setPaused.selector;
        s[8] = SystemHandler.close.selector;
        s[9] = SystemHandler.setCaps.selector;
        s[10] = SystemHandler.grant.selector;
        s[11] = SystemHandler.grantBySig.selector;
        s[12] = SystemHandler.cancelSlip.selector;
        s[13] = SystemHandler.createChild.selector;
        s[14] = SystemHandler.setList.selector;
        s[15] = SystemHandler.handover.selector;
        s[16] = SystemHandler.collectFee.selector;
        s[17] = SystemHandler.wait.selector;
        s[18] = SystemHandler.end.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
        targetContract(address(h));
    }

    /// No token unit is created or lost, and none reaches an agent's, a principal's or a stranger's key: the money is
    /// in the vaults, with the venue, in the withdrawals' destination, or with the fee sweeper and its destination.
    function check_conservation() internal view {
        uint256 sum = h.token().balanceOf(address(h.top())) + h.token().balanceOf(address(h.module()))
            + h.token().balanceOf(h.sink()) + h.token().balanceOf(address(h.sweeper()))
            + h.token().balanceOf(h.destination());
        for (uint256 i; i < h.childCount(); i++) {
            sum += h.token().balanceOf(h.children(i));
        }
        assertEq(sum, h.token().totalSupply(), "every unit is accounted for");
        for (uint256 i; i < h.actorCount(); i++) {
            assertEq(h.token().balanceOf(h.actors(i)), 0, "no key ever holds the vault's money");
        }
    }

    /// Money leaves only to the pinned payee (exactly what was paid), to the principal's withdrawals, or as the fee to
    /// the fixed sweeper (exactly what was collected).
    function check_moneyLeavesOnlyByItsRoutes() internal view {
        assertEq(h.token().balanceOf(address(h.module())), h.paidToVenue(), "the venue got exactly what was paid");
        assertEq(h.token().balanceOf(h.sink()), h.withdrawn(), "withdrawals got exactly what was withdrawn");
        assertEq(h.token().balanceOf(h.destination()), h.feesCollected(), "the fee destination got exactly the fees");
        assertEq(h.token().balanceOf(address(h.sweeper())), 0, "the sweeper forwards everything");
    }

    /// Every fee charged is either still owed or collected, and every vault holds at least what it owes.
    function check_feesOwedAreCovered() internal view {
        uint256 owed = h.top().feeOwed();
        uint256 charged = h.feesCharged(address(h.top()));
        assertGe(h.token().balanceOf(address(h.top())), h.top().feeOwed());
        for (uint256 i; i < h.childCount(); i++) {
            CrestVault c = CrestVault(h.children(i));
            assertGe(h.token().balanceOf(address(c)), c.feeOwed(), "a vault always holds its fee owed");
            owed += c.feeOwed();
            charged += h.feesCharged(address(c));
        }
        assertEq(owed + h.feesCollected(), charged, "fees are owed or collected, never lost or doubled");
        if (_fee() == 0) assertEq(charged, 0, "at a rate of 0 no fee is ever owed");
    }

    /// Every grant counts exactly what passed through it (payments with their fee, and fills), and its open count is
    /// exactly the commitments opened at or below it and not yet ended.
    function check_everyLevelCountsWhatPassesThroughIt() internal view {
        for (uint256 i; i < h.grantCount(); i++) {
            (CrestVault v, uint256 id) = h.grantAt(i);
            ICrestVault.Grant memory g = v.getGrant(id);
            bytes32 k = h.gk(v, id);
            assertEq(g.spent, h.ghostSpent(k), "the lifetime counter");
            assertEq(g.open, h.ghostOpen(k), "the open count");
        }
    }

    /// A grant's window counts every charge since the window began, exactly while its period never changed, and at
    /// least every charge since the last change of its period otherwise: no period change hands out a fresh window.
    function check_periodCountsItsWindow() internal view {
        uint256 now_ = vm.getBlockTimestamp();
        for (uint256 i; i < h.grantCount(); i++) {
            (CrestVault v, uint256 id) = h.grantAt(i);
            ICrestVault.Grant memory g = v.getGrant(id);
            uint256 start = now_ / g.caps.period * g.caps.period;
            uint256 counted = g.windowEnd > start ? g.inPeriod : 0;
            (uint256 since, bool changed,) = h.modelWindow(v, id);
            if (changed) assertGe(counted, since, "a period change forgot spend made after it");
            else assertEq(counted, since, "the window counts exactly its charges");
        }
    }

    /// No call the design refuses ever landed: a payment past a stop, an expiry, a limit or a list at any level; a fill
    /// past a limit or with delegation off; a move by a key without authority; a slip where its signer's grant would
    /// not land, for a key that is not fresh, or twice; a withdrawal from a child or into the fee owed.
    function check_noRefusedCallLanded() internal view {
        assertEq(h.violations(), 0, h.lastViolation());
    }

    /// Every payment, fill, take-back, return and withdrawal the design allows landed, and every pause, resume, close
    /// and limits change by authority landed: a stop always lands, whatever came before it.
    function check_everyAllowedCallLanded() internal view {
        assertEq(h.unexpectedRefusals(), 0);
    }

    /// A closed grant stays closed, and the top vault's principal always holds its root.
    function check_closedIsForever_andThePrincipalHoldsTheRoot() internal view {
        for (uint256 i; i < h.grantCount(); i++) {
            (CrestVault v, uint256 id) = h.grantAt(i);
            if (h.everClosed(h.gk(v, id))) assertTrue(v.getGrant(id).closed, "a closed grant reopened");
        }
        CrestVault top = h.top();
        assertEq(top.grantOf(top.principal()), 1);
        address other = top.principal() == h.p1() ? h.p2() : h.p1();
        assertEq(top.grantOf(other), 0, "the previous principal holds nothing");
    }
}

/// The campaign: the handler's moves in random order, every invariant after every move.
abstract contract SystemInvariants is SystemChecks {
    function setUp() public virtual override {
        super.setUp();
        _target();
    }

    function invariant_conservation() public view {
        check_conservation();
    }

    function invariant_moneyLeavesOnlyByItsRoutes() public view {
        check_moneyLeavesOnlyByItsRoutes();
    }

    function invariant_feesOwedAreCovered() public view {
        check_feesOwedAreCovered();
    }

    function invariant_everyLevelCountsWhatPassesThroughIt() public view {
        check_everyLevelCountsWhatPassesThroughIt();
    }

    function invariant_periodCountsItsWindow() public view {
        check_periodCountsItsWindow();
    }

    function invariant_noRefusedCallLanded() public view {
        check_noRefusedCallLanded();
    }

    function invariant_everyAllowedCallLanded() public view {
        check_everyAllowedCallLanded();
    }

    function invariant_closedIsForever_andThePrincipalHoldsTheRoot() public view {
        check_closedIsForever_andThePrincipalHoldsTheRoot();
    }

    function afterInvariant() external view {
        console.log("payments", h.payments(), "fills", h.fills());
        console.log("grants", h.grantsLanded(), "slips", h.slipsLanded());
        console.log("stops", h.stops(), "open", h.openCount());
        console.log("known grants", h.grantCount(), "child vaults", h.childCount());
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
/// forge-config: deep.invariant.runs = 500
/// forge-config: deep.invariant.depth = 200
contract SystemInvariantsNoFeeTest is SystemInvariants {
    function _fee() internal pure override returns (uint256) {
        return 0;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
/// forge-config: deep.invariant.runs = 500
/// forge-config: deep.invariant.depth = 200
contract SystemInvariantsFeeTest is SystemInvariants {
    /// 1%: amounts in the handler reach 15,000 base units, so the fee ranges from 0 to 150.
    function _fee() internal pure override returns (uint256) {
        return 100;
    }
}
