// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {VaultBuyerBase} from "../VaultBuyerBase.sol";

/// The three points a review by a model from another family left standing on `main` `7fbeed4` (2026-11-25), each pinned
/// as an observation: what the code does, so the readiness note and the design record describe it exactly. None moves
/// money outside a deal's terms or past a limit (`docs/audit/readiness.md`, section 7, SF-1 to SF-3).
contract SecondFamilyTest is VaultBuyerBase {
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );

    /// SF-1 (Info). Switching a module off while it has funded holds also shuts the vault's own escrow `reclaim`
    /// through that module, which asks for an enabled module. Holdback's own timeouts still return every hold to the
    /// vault, and the module still ends its commitments. Enabling the module again opens the vault's `reclaim` again
    /// (`test_journey_holdsEndByTheirTerms_withoutTheAgent`).
    function test_observe_SF1_aDisabledModule_shutsTheVaultsOwnReclaim_andHoldbacksTimeoutsStillReturnTheHolds()
        public
    {
        H.Terms memory t1 = _bterms(vault);
        bytes32 id1 = _fundAs(t1, BUYER_PK);
        H.Terms memory t2 = _bterms(vault);
        bytes32 id2 = _fundAs(t2, BUYER_PK);
        (H.Delivery memory d,) = _deliveryTo(t2.buyer);
        rules.deliver(t2, d, _deliverySig(id2, d, SELLER_PK));
        uint256 afterFunding = usdc.balanceOf(address(vault));

        AuthCaptureEscrow.PaymentInfo memory pi1 = _pi(t1);
        AuthCaptureEscrow.PaymentInfo memory pi2 = _pi(t2);

        vm.prank(principal);
        vault.setModule(address(module), address(0), "switch Holdback off with two holds funded");
        vm.expectRevert(ICrestVault.ModuleNotEnabled.selector);
        vault.reclaim(address(module), pi1);

        // The undelivered hold: Holdback's refund at the delivery deadline.
        vm.warp(t1.timing.deliverBy);
        rules.reclaim(t1);
        assertEq(uint8(_stage(id1)), uint8(IHoldbackRules.Stage.Refunded));
        // The delivered hold whose adjudicators stay silent: the fallback turn, then the default refund.
        vm.warp(t2.timing.judgeBy);
        rules.triggerFallback(t2);
        vm.warp(t2.timing.fallbackBy);
        vm.expectRevert(ICrestVault.ModuleNotEnabled.selector);
        vault.reclaim(address(module), pi2);
        rules.triggerDefault(t2);
        assertEq(uint8(_stage(id2)), uint8(IHoldbackRules.Stage.Refunded));
        assertEq(usdc.balanceOf(address(vault)), afterFunding + 2 * HOLD, "both holds came back to the vault");

        // The module still ends its commitments, so their slots are free again.
        module.close(t1);
        module.close(t2);
        assertEq(vault.getGrant(agentGrant).open, 0);
    }

    /// SF-2 (documentation). The top vault's principal is exempt from the delegation switch when it grants by
    /// transaction and when it grants by a signed grant: its slip lands below a grant whose delegation is off, whether
    /// it was signed before or after the switch. The agent's own slip is refused.
    function test_observe_SF2_theTopPrincipalsSlips_landBelowAGrantWhoseDelegationIsOff() public {
        ICrestVault.SignedGrant memory before = _slip(sub, "signed before the switch");
        bytes memory beforeSig = _slipSig(PRINCIPAL_PK, before);
        ICrestVault.Caps memory off = _caps(HOLD, 3 * HOLD, type(uint128).max, 2, true, false);
        _setAgentCaps(off);

        uint256 a = vault.grantBySig(before, beforeSig);
        assertEq(vault.grantOf(sub), a, "the principal's slip signed before the switch lands after it");
        ICrestVault.SignedGrant memory later = _slip(sub2, "signed after the switch");
        uint256 b = vault.grantBySig(later, _slipSig(PRINCIPAL_PK, later));
        assertEq(vault.grantOf(sub2), b, "so does one signed after it");

        ICrestVault.SignedGrant memory agents = _slip(makeAddr("a key of the agent's"), "the agent's own");
        bytes memory agentsSig = _slipSig(BUYER_PK, agents);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grantBySig(agents, agentsSig);
    }

    /// SF-3 (documentation). A narrowing binds the agent and every grant below it in the same vault from the
    /// next payment. It does not bind a child vault spending money filled before the narrowing: a child's payment checks
    /// the parent path's state, expiry, per-payment limit and lists, not its period or lifetime counters, which the fill
    /// already charged. A pause on the parent grant stops the child at once, and a take-back returns what is left.
    function test_observe_SF3_aChildSpendsAFillMadeBeforeANarrowing_untilAPauseOrATakeBack() public {
        (CrestVault child,) = _agentChild(2 * HOLD);
        _setAgentCaps(_caps(HOLD, 1, type(uint128).max, 2, true, true));

        H.Terms memory top = _bterms(vault);
        _expectFundRefused(
            top, _agreeAs(top, BUYER_PK), abi.encodeWithSelector(ICrestVault.OverPerPeriod.selector, agentGrant)
        );
        bytes32 id = _fundAs(_bterms(child), SUB_PK);
        assertEq(uint8(_stage(id)), uint8(IHoldbackRules.Stage.Held), "observed: the child spends the earlier fill");

        vm.prank(principal);
        vault.setPaused(agentGrant, true, "stop the agent and its child vault");
        H.Terms memory t = _bterms(child);
        _expectFundRefused(t, _agreeAs(t, SUB_PK), abi.encodeWithSelector(ICrestVault.Paused.selector, agentGrant));

        uint256 left = usdc.balanceOf(address(child));
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(principal);
        vault.takeBackFromChild(address(child), left, "take back the rest");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, left);
        assertEq(usdc.balanceOf(address(child)), 0);
    }

    function _slip(address key, bytes32 salt) internal view returns (ICrestVault.SignedGrant memory) {
        return ICrestVault.SignedGrant({
            parent: agentGrant,
            controller: key,
            caps: _wide(),
            salt: salt,
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: ""
        });
    }

    function _slipSig(uint256 pk, ICrestVault.SignedGrant memory s) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Crest"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
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
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, ss, v);
    }
}
