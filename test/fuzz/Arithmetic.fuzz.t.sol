// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {PayModule} from "../mocks/PayModule.sol";

/// Stateless fuzz on the vault's arithmetic: fixed windows of any length, the per-payment and lifetime limits at their
/// exact boundary, the fee at its exact boundary for any rate, and the largest amounts. Each test compares the vault
/// with a model of the design's rule (`docs/design.md`, sections 2 and 14), not with the vault's own formula.
contract ArithmeticFuzzTest is Test {
    uint256 internal constant ROOT = 1;
    bytes32 internal constant MERCHANT = keccak256("merchant");
    MockERC3009Token internal token;
    PayModule internal module;
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");

    function setUp() public {
        vm.warp(1_790_000_000);
        token = new MockERC3009Token("Mock USDC", "mUSDC", 6);
        module = new PayModule(address(token));
    }

    function _vault(uint256 feeBps, ICrestVault.Caps memory c) internal returns (CrestVault v, uint256 id) {
        address sweeper = feeBps == 0 ? address(0) : address(new CrestFeeSweeper(makeAddr("destination")));
        CrestFactory f = new CrestFactory(feeBps, sweeper);
        v = CrestVault(f.create(principal, address(token), 0));
        vm.startPrank(principal);
        v.setModule(address(module), address(module), "");
        id = v.grant(ROOT, agent, c, 0, "");
        vm.stopPrank();
        token.mint(address(v), type(uint128).max);
    }

    function _caps(uint256 perSpend, uint256 perPeriod, uint256 lifetime, uint32 period)
        internal
        pure
        returns (ICrestVault.Caps memory)
    {
        return ICrestVault.Caps({
            perSpend: uint128(perSpend),
            perPeriod: uint128(perPeriod),
            lifetime: uint128(lifetime),
            maxOpen: type(uint32).max,
            period: period,
            expiresAt: 0,
            mayDelegate: false,
            list: address(0)
        });
    }

    /// For any period length and any sequence of payments and waits, a payment lands exactly when the payments already
    /// made in its fixed window, `floor(t / period)`, plus itself stay within the period's limit, and the vault's
    /// window counter equals the model's sum.
    function testFuzz_aFixedPeriodCountsExactlyItsWindow(
        uint32 period,
        uint128 perPeriod,
        uint64[12] memory waits,
        uint64[12] memory amounts
    ) public {
        period = uint32(bound(period, 1, type(uint32).max));
        perPeriod = uint128(bound(perPeriod, 1, 1e12));
        (CrestVault v, uint256 id) = _vault(0, _caps(type(uint128).max, perPeriod, type(uint128).max, period));
        uint256[12] memory at;
        uint256[12] memory paid;
        uint256 n;
        for (uint256 i; i < 12; i++) {
            uint256 dt = waits[i] % 4 == 0 ? uint256(waits[i]) % (uint256(period) * 3) : uint256(waits[i]) % period;
            vm.warp(vm.getBlockTimestamp() + dt);
            uint256 now_ = vm.getBlockTimestamp();
            uint256 amount = bound(amounts[i], 1, uint256(perPeriod) / 2 + 1);
            uint256 window = now_ / period;
            uint256 sum;
            for (uint256 j; j < n; j++) {
                if (at[j] / period == window) sum += paid[j];
            }
            bool fits = sum + amount <= perPeriod;
            try module.pay(v, agent, amount, MERCHANT) {
                assertTrue(fits, "a payment past its window's limit landed");
                (at[n], paid[n]) = (now_, amount);
                n++;
                sum += amount;
            } catch (bytes memory err) {
                assertFalse(fits, "a payment inside its window's limit was refused");
                assertEq(err, abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, id));
            }
            ICrestVault.Grant memory g = v.getGrant(id);
            uint256 counted = g.windowEnd > window * period ? g.inPeriod : 0;
            assertEq(counted, sum, "the window counter is the model's sum");
        }
    }

    /// One second before a window ends, the window's spend still counts; at its end, a new window starts.
    function testFuzz_theWindowBoundary_isExact(uint32 period, uint64 offset) public {
        period = uint32(bound(period, 3, type(uint32).max));
        (CrestVault v, uint256 id) = _vault(0, _caps(type(uint128).max, 10, type(uint128).max, period));
        uint256 now_ = vm.getBlockTimestamp();
        uint256 start = now_ / period * period;
        // The token refuses any authorization at time 0, so a window that starts at 0 is entered one second in.
        vm.warp(start + bound(offset, start == 0 ? 1 : 0, period - 2));
        module.pay(v, agent, 10, MERCHANT);
        vm.warp(start + period - 1);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, id));
        module.pay(v, agent, 1, MERCHANT);
        vm.warp(start + period);
        module.pay(v, agent, 10, MERCHANT);
    }

    /// The per-payment and lifetime limits hold at their exact boundary, for any values: one unit over the per-payment
    /// limit is refused; payments up to exactly the lifetime land; one unit more is refused.
    function testFuzz_perPaymentAndLifetime_atTheExactBoundary(uint128 perSpend, uint256 lifetime) public {
        perSpend = uint128(bound(perSpend, 1, type(uint128).max / 4));
        lifetime = bound(lifetime, perSpend, 4 * uint256(perSpend));
        (CrestVault v, uint256 id) = _vault(0, _caps(perSpend, type(uint128).max, lifetime, 1 days));
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, id));
        module.pay(v, agent, uint256(perSpend) + 1, MERCHANT);
        uint256 left = lifetime;
        while (left != 0) {
            uint256 next = left > perSpend ? perSpend : left;
            module.pay(v, agent, next, MERCHANT);
            left -= next;
        }
        assertEq(v.getGrant(id).spent, lifetime);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverLifetime.selector, id));
        module.pay(v, agent, 1, MERCHANT);
    }

    /// For any rate and amount, the fee is `floor(amount × rate / 10,000)`, it counts against the per-payment limit at
    /// its exact boundary, the payee receives exactly the amount, and the fee is owed, not moved.
    function testFuzz_theFeeAtItsExactBoundary(uint16 rate, uint128 amount) public {
        uint256 bps = bound(rate, 1, 10_000);
        amount = uint128(bound(amount, 1, type(uint128).max / 2));
        uint256 fee = uint256(amount) * bps / 10_000;
        uint256 total = uint256(amount) + fee;
        (CrestVault v, uint256 id) = _vault(bps, _caps(total - 1, type(uint128).max, type(uint128).max, 1 days));
        if (fee == 0) {
            // The limit is one below the amount itself.
            vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, id));
            module.pay(v, agent, amount, MERCHANT);
            return;
        }
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, id));
        module.pay(v, agent, amount, MERCHANT);
        vm.prank(principal);
        v.setCaps(id, _caps(total, type(uint128).max, type(uint128).max, 1 days), "");
        uint256 before = token.balanceOf(address(module));
        module.pay(v, agent, amount, MERCHANT);
        assertEq(token.balanceOf(address(module)) - before, amount, "the payee receives exactly the amount");
        assertEq(v.feeOwed(), fee, "the fee is floor(amount x rate / 10,000)");
        assertLe(fee * 10_000, uint256(amount) * bps, "never above the stated rate");
        assertEq(v.getGrant(id).spent, total, "the fee counts against the limits");
    }

    /// An amount whose fee does not fit 128 bits with it, or an amount above 128 bits, is refused by name.
    function testFuzz_theLargestAmounts_areRefusedByName(uint256 amount, uint16 rate) public {
        uint256 bps = bound(rate, 1, 10_000);
        (CrestVault v, uint256 id) = _vault(bps, _caps(type(uint128).max, type(uint128).max, type(uint128).max, 1 days));
        amount = bound(amount, uint256(type(uint128).max) + 1, type(uint256).max);
        vm.prank(address(module));
        vm.expectRevert(ICrestVault.AmountTooLarge.selector);
        v.charge(agent, amount, MERCHANT, bytes32(0), 0, bytes32(0));
        uint256 a = type(uint128).max;
        if (a + a * bps / 10_000 > type(uint128).max) {
            vm.prank(address(module));
            vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerSpend.selector, id));
            v.charge(agent, a, MERCHANT, keccak256("c"), vm.getBlockTimestamp() + 1, keccak256("n"));
        }
    }

    /// Recorded (readiness note, finding V-I1): `windowEnd` is 40 bits. Within one period of 2^40 seconds (the year
    /// 36,812), the end of the window a payment lands in no longer fits, the stored end wraps to a small number, and the
    /// next payment in the same window starts from zero. No chain reaches that time; the test pins the behaviour.
    function test_observe_theWindowEndWrapsOnlyNearTheYear36812() public {
        (CrestVault v, uint256 id) = _vault(0, _caps(type(uint128).max, 10, type(uint128).max, 1 days));
        uint256 last = (uint256(1) << 40) / 1 days * 1 days; // the last window start below 2^40 whose end passes it
        vm.warp(last + 1);
        module.pay(v, agent, 10, MERCHANT);
        assertLt(v.getGrant(id).windowEnd, last, "the stored end wrapped");
        module.pay(v, agent, 10, MERCHANT); // a second full window's worth inside the same window lands
        assertEq(v.getGrant(id).spent, 20);
        // Before that point the limit holds: one period earlier the same two payments are refused.
        (CrestVault w, uint256 wid) = _vault(0, _caps(type(uint128).max, 10, type(uint128).max, 1 days));
        vm.warp(last - 1 days + 1);
        module.pay(w, agent, 10, MERCHANT);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, wid));
        module.pay(w, agent, 1, MERCHANT);
    }
}
