// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HoldbackHandler} from "./HoldbackHandler.sol";

/// The checks on random deals through Holdback's unchanged contracts with the vault as the buyer (`HoldbackHandler`).
abstract contract HoldbackChecks is Test {
    HoldbackHandler internal h;

    function setUp() public virtual {
        h = new HoldbackHandler();
        h.setUp();
    }

    function _target() internal {
        bytes4[] memory s = new bytes4[](13);
        s[0] = HoldbackHandler.fund.selector;
        s[1] = HoldbackHandler.fund.selector;
        s[2] = HoldbackHandler.deliver.selector;
        s[3] = HoldbackHandler.decide.selector;
        s[4] = HoldbackHandler.early.selector;
        s[5] = HoldbackHandler.early.selector;
        s[6] = HoldbackHandler.settle.selector;
        s[7] = HoldbackHandler.reclaim.selector;
        s[8] = HoldbackHandler.endDeal.selector;
        s[9] = HoldbackHandler.endDeal.selector;
        s[10] = HoldbackHandler.stop.selector;
        s[11] = HoldbackHandler.withdraw.selector;
        s[12] = HoldbackHandler.wait.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
        targetContract(address(h));
    }

    /// No unit is created or lost, and none reaches the sub-agent's, a stranger's or a relayer's key.
    function check_conservation() internal view {
        IERC20 t = IERC20(h.token());
        address[] memory a = h.holders();
        uint256 sum;
        for (uint256 i; i < a.length; i++) {
            sum += t.balanceOf(a[i]);
        }
        assertEq(sum, t.totalSupply());
        address[] memory k = h.keyHolders();
        for (uint256 i; i < k.length; i++) {
            assertEq(t.balanceOf(k[i]), 0, "no key receives the vault's money");
        }
    }

    /// The escrow holds exactly one hold for every funded deal not yet released, refunded, settled or reclaimed:
    /// nothing the vault, its principal or its agents do takes money out of a hold.
    function check_theEscrowHoldsExactlyTheOpenHolds() internal view {
        assertEq(IERC20(h.token()).balanceOf(h.store()), h.inEscrowCount() * h.hold());
    }

    /// The vault counts as open exactly the deals whose commitment it has not ended.
    function check_openCommitmentsMatchTheDeals() internal view {
        assertEq(h.theVault().getGrant(1).open, h.notEndedCount());
    }

    /// No signature for the vault landed from a key the design says may not sign: a stopped agent never releases or
    /// settles a funded hold, and no commitment ends before its deal.
    function check_onlyLiveAuthoritySignsForTheVault() internal view {
        assertEq(h.violations(), 0, h.lastViolation());
    }
}

/// The campaign: the handler's moves in random order, every check after every move.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 60
/// forge-config: deep.invariant.runs = 250
/// forge-config: deep.invariant.depth = 100
contract HoldbackInvariantsTest is HoldbackChecks {
    function setUp() public override {
        super.setUp();
        _target();
    }

    function invariant_conservation() public view {
        check_conservation();
    }

    function invariant_theEscrowHoldsExactlyTheOpenHolds() public view {
        check_theEscrowHoldsExactlyTheOpenHolds();
    }

    function invariant_openCommitmentsMatchTheDeals() public view {
        check_openCommitmentsMatchTheDeals();
    }

    function invariant_onlyLiveAuthoritySignsForTheVault() public view {
        check_onlyLiveAuthoritySignsForTheVault();
    }

    function afterInvariant() external view {
        console.log("funded", h.funded(), "released", h.released());
        console.log("refunded", h.refunded(), "settled", h.settled());
        console.log("stepped in", h.steppedIn(), "stops", h.stopsLanded());
    }
}

/// A long seeded simulation through the same handler, every check every 20 moves, and the moves it must reach.
contract HoldbackSimulationTest is HoldbackChecks {
    function _run(uint256 seed, uint256 steps) internal {
        for (uint256 i; i < steps; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = uint256(keccak256(abi.encode(r, 1)));
            uint256 b = uint256(keccak256(abi.encode(r, 2)));
            uint256 kind = r % 16;
            if (kind < 3) h.fund(a);
            else if (kind < 5) h.deliver(a);
            else if (kind == 5) h.decide(a, b % 2 == 0);
            else if (kind < 8) h.early(a, b);
            else if (kind == 8) h.settle(a, b);
            else if (kind == 9) h.reclaim(a);
            else if (kind < 12) h.endDeal(a);
            else if (kind == 12 && r % 3 == 0) h.stop(a, b);
            else if (kind == 13) h.withdraw(a % (10 * h.hold()));
            else h.wait(a % 2 == 0 ? a % 6 hours : a % 2 days);
            if (i % 20 == 19) _checkAll();
        }
        _checkAll();
    }

    function _checkAll() internal view {
        check_conservation();
        check_theEscrowHoldsExactlyTheOpenHolds();
        check_openCommitmentsMatchTheDeals();
        check_onlyLiveAuthoritySignsForTheVault();
    }

    /// A fixed seed, 1,200 moves: every check holds at every checkpoint, and the run funds, releases, refunds, settles
    /// and has authority above a stopped grant sign in its place.
    function test_simulation_fixedSeed_reachesEveryOutcome() public {
        _run(0xBEEF, 1_200);
        console.log("funded", h.funded(), "released", h.released());
        console.log("refunded", h.refunded(), "settled", h.settled());
        console.log("stepped in", h.steppedIn(), "stops", h.stopsLanded());
        assertGt(h.funded(), 20, "the simulation funds");
        assertGe(h.released(), 3, "the simulation releases");
        assertGt(h.refunded(), 3, "the simulation refunds");
        assertGt(h.settled(), 0, "the simulation settles");
        assertGt(h.steppedIn(), 0, "authority above signs in a stopped grant's place");
    }

    /// Random seeds, 600 moves each.
    /// forge-config: default.fuzz.runs = 4
    /// forge-config: deep.fuzz.runs = 48
    function testFuzz_simulation_anySeed(uint256 seed) public {
        _run(seed, 600);
    }
}
