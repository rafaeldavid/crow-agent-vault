// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";

import {SystemHandler} from "./SystemHandler.sol";
import {SystemChecks} from "./SystemInvariants.t.sol";

/// Long simulations: one seeded sequence of thousands of moves through the same handler as the invariant campaign,
/// with every invariant asserted every 25 moves. The fixed-seed test also checks the simulation reaches every kind of
/// move, so a handler that silently stops paying or granting fails here rather than passing the invariants vacuously.
abstract contract SystemSimulation is SystemChecks {
    uint256 internal constant CHECK_EVERY = 25;

    function _run(uint256 seed, uint256 steps) internal returns (uint256 handovers, uint256 waits) {
        for (uint256 i; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = uint256(keccak256(abi.encode(r, 1)));
            uint256 b = uint256(keccak256(abi.encode(r, 2)));
            uint256 c = uint256(keccak256(abi.encode(r, 3)));
            uint256 kind = r % 25;
            if (kind < 6) {
                h.pay(a, b, c, r % 7 == 0);
            } else if (kind < 8) {
                h.end(a);
            } else if (kind == 8) {
                h.fundChild(a, b);
            } else if (kind == 9) {
                h.takeBack(a, b);
            } else if (kind == 10) {
                h.returnToParent(a, b);
            } else if (kind == 11) {
                h.withdraw(a, b % 200_000);
            } else if (kind == 12) {
                h.setPaused(a, b, c % 2 == 0);
            } else if (kind == 13) {
                h.close(a, b);
            } else if (kind == 14) {
                h.setCaps(a, b, c);
            } else if (kind == 15) {
                h.grant(a, b, c, r);
            } else if (kind == 16) {
                h.grantBySig(a, b, c, r);
            } else if (kind == 17) {
                h.cancelSlip(a, b, c, r);
            } else if (kind == 18) {
                h.createChild(a, b, c);
            } else if (kind == 19) {
                h.setList(a, b, c, r % 3 != 0);
            } else if (kind == 20 && r % 5 == 0) {
                h.handover(r % 2 == 0);
                handovers++;
            } else if (kind == 21) {
                h.collectFee(r % 2 == 0);
            } else if (kind == 24) {
                h.revive(i);
            } else {
                h.wait(a % 2 == 0 ? a % 2 hours : a % 3 days);
                waits++;
            }
            if (i % CHECK_EVERY == CHECK_EVERY - 1) _checkAll();
        }
        _checkAll();
    }

    function _checkAll() internal view {
        check_conservation();
        check_moneyLeavesOnlyByItsRoutes();
        check_feesOwedAreCovered();
        check_everyLevelCountsWhatPassesThroughIt();
        check_periodCountsItsWindow();
        check_noRefusedCallLanded();
        check_everyAllowedCallLanded();
        check_closedIsForever_andThePrincipalHoldsTheRoot();
    }

    /// A fixed seed, 3,000 moves: every invariant holds at every checkpoint, and the run reaches every kind of move.
    function test_simulation_fixedSeed_reachesEveryMove() public {
        (uint256 handovers, uint256 waits) = _run(0xC0FFEE, 3_000);
        console.log("payments", h.payments(), "fills", h.fills());
        console.log("grants", h.grantsLanded(), "slips", h.slipsLanded());
        console.log("stops", h.stops(), "open now", h.openCount());
        console.log("known grants", h.grantCount(), "child vaults", h.childCount());
        console.log("handovers", handovers, "waits", waits);
        console.log("period changes", h.periodChanges());
        console.log("paid to the venue", h.paidToVenue(), "withdrawn", h.withdrawn());
        console.log("fees charged at the top", h.feesCharged(address(h.top())), "collected", h.feesCollected());
        assertGt(h.payments(), 100, "the simulation pays");
        assertGt(h.fills(), 5, "the simulation fills the child");
        assertGt(h.grantsLanded() + h.slipsLanded(), 5, "the simulation delegates");
        assertGt(h.slipsLanded(), 0, "the simulation lands signed grants");
        assertGt(h.stops(), 5, "the simulation stops grants");
        assertGt(handovers, 0, "the simulation hands the vault over");
        assertGt(h.periodChanges(), 0, "the simulation changes period lengths");
        assertGt(h.withdrawn(), 0, "the simulation withdraws");
        if (_fee() != 0) assertGt(h.feesCollected(), 0, "the simulation collects fees");
    }

    /// Random seeds, 1,500 moves each.
    function testFuzz_simulation_anySeed(uint256 seed) public {
        _run(seed, 1_500);
    }
}

/// forge-config: default.fuzz.runs = 4
/// forge-config: deep.fuzz.runs = 48
contract SystemSimulationNoFeeTest is SystemSimulation {
    function _fee() internal pure override returns (uint256) {
        return 0;
    }
}

/// forge-config: default.fuzz.runs = 4
/// forge-config: deep.fuzz.runs = 48
contract SystemSimulationFeeTest is SystemSimulation {
    function _fee() internal pure override returns (uint256) {
        return 100;
    }
}
