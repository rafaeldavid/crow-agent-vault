// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC3009Token} from "commerce-payments-test/mocks/MockERC3009Token.sol";

import {CrestFactory} from "../../src/CrestFactory.sol";
import {CrestFeeSweeper} from "../../src/CrestFeeSweeper.sol";
import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {IReceiveWithAuthorization} from "../mocks/PayModule.sol";

/// An enabled module that is also a controller in the vault: it charges a payment, can move money before it pulls, and
/// pulls when it likes. The trust model trusts an enabled module; these tests pin what the vault guarantees even so.
contract ChargingController {
    address public immutable TOKEN;

    constructor(address token) {
        TOKEN = token;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function pull(address vault, uint256 amount, uint256 validBefore, bytes32 nonce) external {
        IReceiveWithAuthorization(TOKEN).receiveWithAuthorization(
            vault, address(this), amount, 0, validBefore, nonce, ""
        );
    }
}

/// The points of the second-family review of PR 21 (branch `next-version`) that this branch fixes or pins.
contract Pr21SecondFamilyTest is Test {
    uint256 internal constant ROOT = 1;
    MockERC3009Token internal token;
    address internal principal = makeAddr("principal");
    ChargingController internal m;
    CrestVault internal vault;
    CrestVault internal child;
    uint256 internal g;

    function setUp() public {
        vm.warp(1_790_000_000);
        token = new MockERC3009Token("Mock USDC", "mUSDC", 6);
        m = new ChargingController(address(token));
    }

    /// A vault from a factory with a fee of `bps`, the module enabled as its own payee, a grant for the module with
    /// delegation on, a child vault under that grant, and 100 base units in the vault.
    function _world(uint256 bps) internal {
        CrestFeeSweeper sweeper = new CrestFeeSweeper(makeAddr("fee destination"));
        CrestFactory f = new CrestFactory(bps, bps == 0 ? address(0) : address(sweeper));
        vault = CrestVault(f.create(principal, address(token), 0));
        ICrestVault.Caps memory c = ICrestVault.Caps({
            perSpend: type(uint128).max,
            perPeriod: type(uint128).max,
            lifetime: type(uint128).max,
            maxOpen: type(uint32).max,
            period: 1 days,
            expiresAt: 0,
            mayDelegate: true,
            list: address(0)
        });
        vm.startPrank(principal);
        vault.setModule(address(m), address(m), "");
        g = vault.grant(ROOT, address(m), c, 0, "");
        vm.stopPrank();
        child = CrestVault(
            abi.decode(m.exec(address(vault), abi.encodeCall(vault.createChild, (g, bytes32(0), ""))), (address))
        );
        token.mint(address(vault), 100);
    }

    function _charge(uint256 amount, bytes32 nonce) internal returns (uint256 validBefore) {
        validBefore = vm.getBlockTimestamp() + 1 hours;
        m.exec(
            address(vault), abi.encodeCall(vault.charge, (address(m), amount, bytes32(0), nonce, validBefore, nonce))
        );
    }

    /// fee-flags C7. With a fee, a module that is also a controller charged 50 (fee 1 owed), filled its child vault
    /// with 50 before the token pulled the payment, then pulled: the vault ended with 0 and owed 1. The vault now
    /// refuses any move of its money while a payment approval of the same transaction is unspent (`ApprovalPending`),
    /// so a fill, a withdrawal or a return sees every earlier pull and never takes the fee owed.
    function test_attack_C7_aFillBetweenAChargeAndItsPull_takesTheFeeOwed_refused() public {
        _world(200);
        uint256 vb = _charge(50, keccak256("one"));
        assertEq(vault.feeOwed(), 1);
        vm.expectRevert(ICrestVault.ApprovalPending.selector);
        m.exec(address(vault), abi.encodeCall(vault.fundChild, (address(child), 50, "")));
        m.pull(address(vault), 50, vb, keccak256("one"));
        // Once the payment is pulled, the fill is checked against the balance that is left.
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        m.exec(address(vault), abi.encodeCall(vault.fundChild, (address(child), 50, "")));
        m.exec(address(vault), abi.encodeCall(vault.fundChild, (address(child), 49, "")));
        assertGe(token.balanceOf(address(vault)), vault.feeOwed(), "the vault holds its fee owed");
    }

    /// The same gap through a child's return to its parent, and through a withdrawal by a principal that is the module.
    /// Each charge owes a fee of at least 1, so a move before the pull would leave the vault short of it.
    function test_attack_C7_aReturnOrAWithdrawalBetweenAChargeAndItsPull_refused() public {
        _world(200);
        // The child charges 50 (fee 1 owed) and tries to return 10 to its parent before the pull.
        m.exec(address(vault), abi.encodeCall(vault.fundChild, (address(child), 60, "")));
        uint256 cvb = vm.getBlockTimestamp() + 1 hours;
        bytes32 n = keccak256("three");
        m.exec(address(child), abi.encodeCall(child.charge, (address(m), 50, bytes32(0), n, cvb, n)));
        assertEq(child.feeOwed(), 1, "the child owes a fee");
        vm.expectRevert(ICrestVault.ApprovalPending.selector);
        m.exec(address(child), abi.encodeCall(child.returnToParent, (10, "")));
        m.pull(address(child), 50, cvb, n);
        // After the pull, the return is checked against what is left: 10, of which 1 is owed.
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        m.exec(address(child), abi.encodeCall(child.returnToParent, (10, "")));
        m.exec(address(child), abi.encodeCall(child.returnToParent, (9, "")));
        assertEq(token.balanceOf(address(child)), child.feeOwed(), "the child keeps exactly its fee owed");

        // The module becomes the top vault's principal, charges 50 (fee 1 owed) and tries to withdraw before the pull.
        vm.prank(principal);
        vault.proposePrincipal(address(m), "");
        m.exec(address(vault), abi.encodeCall(vault.acceptPrincipal, ("")));
        token.mint(address(vault), 100);
        uint256 left = token.balanceOf(address(vault));
        uint256 vb = _charge(50, keccak256("two"));
        assertEq(vault.feeOwed(), 1, "the vault owes a fee");
        vm.expectRevert(ICrestVault.ApprovalPending.selector);
        m.exec(address(vault), abi.encodeCall(vault.withdraw, (address(m), left - 50, "")));
        m.pull(address(vault), 50, vb, keccak256("two"));
        vm.expectRevert(ICrestVault.BalanceBelowFee.selector);
        m.exec(address(vault), abi.encodeCall(vault.withdraw, (address(m), left - 50, "")));
        m.exec(address(vault), abi.encodeCall(vault.withdraw, (address(m), left - 51, "")));
        assertEq(token.balanceOf(address(vault)), vault.feeOwed(), "the vault keeps exactly its fee owed");
    }

    /// At a rate of 0 nothing is ever owed, so nothing is refused: a fill before the pull lands, as in the stable build,
    /// and the module's own pull then fails for want of balance, moving nothing.
    function test_atRateZero_aFillBeforeThePull_lands_andThePullFails() public {
        _world(0);
        uint256 vb = _charge(60, keccak256("four"));
        m.exec(address(vault), abi.encodeCall(vault.fundChild, (address(child), 60, "")));
        vm.expectRevert();
        m.pull(address(vault), 60, vb, keccak256("four"));
        assertEq(token.balanceOf(address(child)), 60);
        assertEq(vault.feeOwed(), 0);
    }

    /// reentrancy C10 (design). At a rate of 0, an enabled module that charges twice with the same nonce opens two
    /// commitments and counts both, and the token pulls once. The vault counts more than it paid, never less; only a
    /// module the principal enabled can do it, and the Holdback module derives each nonce from its own deal.
    function test_observe_C10_atRateZero_twoChargesOneNonce_countTwice_andPayOnce() public {
        _world(0);
        bytes32 n = keccak256("five");
        uint256 vb = vm.getBlockTimestamp() + 1 hours;
        m.exec(address(vault), abi.encodeCall(vault.charge, (address(m), 10, bytes32(0), keccak256("c1"), vb, n)));
        m.exec(address(vault), abi.encodeCall(vault.charge, (address(m), 10, bytes32(0), keccak256("c2"), vb, n)));
        m.pull(address(vault), 10, vb, n);
        vm.expectRevert();
        m.pull(address(vault), 10, vb, n);
        assertEq(vault.getGrant(g).spent, 20, "counted twice");
        assertEq(token.balanceOf(address(m)), 10, "paid once");
    }
}
