// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CrestVault} from "../src/CrestVault.sol";
import {ICrestVault} from "../src/ICrestVault.sol";
import {CrestBase} from "./CrestBase.sol";

/// Roadmap N221: the vault's principal switches off an agent's power to delegate by setting `mayDelegate` to false on
/// the agent's grant (`setCaps`). These tests ask whether that one switch, with no other change, stops delegation at
/// once, at every level below the agent, in every child vault below it, and by signed grant, while the agent and its
/// sub-agents keep paying. Each `test_attack_*` passes when the defence holds.
contract DelegationSwitchTest is CrestBase {
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    address internal fresh;
    uint256 internal constant FRESH_PK = 0xF4E5;

    address internal sub3;
    uint256 internal constant SUB3_PK = 0x5AB3;
    uint256 internal subGrant;
    uint256 internal grandGrant;

    function setUp() public override {
        super.setUp();
        sub3 = vm.addr(SUB3_PK);
        fresh = vm.addr(FRESH_PK);
        // The chain below the root: principal -> agent -> sub -> sub3, each wide and allowed to delegate.
        _setAgentCaps(_caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true));
        vm.prank(buyer);
        subGrant = vault.grant(agentGrant, sub, _wide(), 0, "");
        vm.prank(sub);
        grandGrant = vault.grant(subGrant, sub3, _wide(), 0, "");
    }

    /// A slip from the agent for a key that holds no grant yet, so only the switch can refuse it.
    function _slip() internal view returns (ICrestVault.SignedGrant memory) {
        return ICrestVault.SignedGrant({
            parent: agentGrant,
            controller: fresh,
            caps: _caps(HOLD, 2 * HOLD, type(uint128).max, 1, false, false),
            salt: bytes32("one task"),
            deadline: uint40(vm.getBlockTimestamp() + 1 hours),
            note: "a sub-agent for one task"
        });
    }

    function _signed(uint256 pk, ICrestVault.SignedGrant memory s) internal view returns (bytes memory) {
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
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Crest"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, ss, v);
    }

    function _idOf(ICrestVault.SignedGrant memory s) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(s.parent, s.controller, s.salt)));
    }

    /// The switch: the principal's `setCaps` on the agent's grant, every other field as it was.
    function _switchOff() internal {
        ICrestVault.Caps memory c = vault.getGrant(agentGrant).caps;
        c.mayDelegate = false;
        vm.prank(principal);
        vault.setCaps(agentGrant, c, "delegation off");
    }

    // The switch stops the agent's own delegation

    function test_attack_afterTheSwitch_theAgentGrantsASubAgent_refused() public {
        _switchOff();
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(agentGrant, sub2, _wide(), bytes32("new"), "");
    }

    function test_attack_afterTheSwitch_theAgentCreatesAndFillsAChildVault_refused() public {
        vm.prank(buyer);
        address child = vault.createChild(agentGrant, 0, ""); // made before the switch
        _switchOff();
        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.createChild(agentGrant, bytes32("two"), "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.fundChild(child, HOLD, "");
        vm.stopPrank();
    }

    // The switch reaches every level below the agent

    function test_attack_afterTheSwitch_aSubAgentMadeBeforeIt_cannotGrantFurther() public {
        _switchOff();
        vm.prank(sub);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(subGrant, sub2, _wide(), bytes32("new"), "");
    }

    function test_attack_afterTheSwitch_aSubSubAgentMadeBeforeIt_cannotGrantFurther() public {
        _switchOff();
        address sub4 = makeAddr("sub4");
        vm.prank(sub3);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(grandGrant, sub4, _wide(), bytes32("new"), "");
    }

    function test_attack_afterTheSwitch_aSubAgentsChildVault_cannotDelegate() public {
        vm.prank(sub);
        CrestVault child = CrestVault(vault.createChild(subGrant, 0, "")); // made before the switch
        vm.prank(sub);
        uint256 sub2InChild = child.grant(ROOT, sub2, _wide(), 0, ""); // its owner delegates inside it before the switch
        _switchOff();
        vm.startPrank(sub); // the child's principal, at the root of a child vault
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.grant(ROOT, sub3, _wide(), bytes32("new"), "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.createChild(subGrant, bytes32("two"), "");
        vm.stopPrank();
        vm.prank(sub2);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.createChild(sub2InChild, bytes32("deeper"), "");
    }

    function test_attack_afterTheSwitch_aSubAgentWidensItsOwnFlag_stillRefused() public {
        _switchOff();
        // The agent sits above its sub-agent and may rewrite the sub-agent's caps, but no flag below the switch
        // can lift it: the walk reads every grant on the path.
        vm.prank(buyer);
        vault.setCaps(subGrant, _wide(), "");
        vm.prank(sub);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(subGrant, sub2, _wide(), bytes32("new"), "");
    }

    function test_attack_afterTheSwitch_noOneBelowTheAgentTurnsItBackOn() public {
        _switchOff();
        ICrestVault.Caps memory on = _caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true);
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(agentGrant, on, "");
        vm.prank(sub);
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setCaps(agentGrant, on, "");
        assertFalse(vault.getGrant(agentGrant).caps.mayDelegate, "the switch is still off");
    }

    function test_attack_afterTheSwitch_aGrandchildVaultMadeBeforeIt_cannotDelegateOrBeHandedOver() public {
        vm.prank(sub);
        CrestVault child = CrestVault(vault.createChild(subGrant, 0, ""));
        vm.prank(sub);
        uint256 sub2InChild = child.grant(ROOT, sub2, _wide(), 0, "");
        vm.prank(sub2);
        CrestVault grandchild = CrestVault(child.createChild(sub2InChild, 0, ""));
        vm.prank(sub2);
        uint256 sub3InGrandchild = grandchild.grant(ROOT, sub3, _wide(), 0, "");
        _switchOff();
        vm.prank(sub2); // the grandchild's principal, at its root
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        grandchild.grant(ROOT, fresh, _wide(), 0, "");
        vm.startPrank(sub3);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        grandchild.grant(sub3InGrandchild, fresh, _wide(), 0, "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        grandchild.createChild(sub3InGrandchild, 0, "");
        vm.stopPrank();
        vm.prank(sub2);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.fundChild(address(grandchild), 1, "");
        vm.prank(sub);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.fundChild(address(grandchild), 1, "");
        // A child vault's principal cannot hand the vault, or its money, to a new key.
        vm.startPrank(sub2);
        vm.expectRevert(ICrestVault.NotTopVault.selector);
        grandchild.proposePrincipal(fresh, "");
        vm.expectRevert(ICrestVault.NotTopVault.selector);
        grandchild.withdraw(fresh, 0, "");
        vm.stopPrank();
    }

    function test_attack_afterTheSwitch_aKeyHeldBelowIsMovedToANewGrant_refused() public {
        _switchOff();
        vm.startPrank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(agentGrant, sub3, _wide(), bytes32("move"), "");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(subGrant, sub3, _wide(), bytes32("move"), "");
        vm.stopPrank();
        assertEq(vault.grantOf(sub3), grandGrant, "the key keeps the grant it had");
    }

    function test_attack_afterTheSwitch_aCancelledSlipsRecord_givesItsKeyNothing() public {
        _switchOff();
        vm.prank(buyer); // cancelling still works after the switch and writes a closed record naming the key
        vault.cancelSignedGrant(agentGrant, fresh, bytes32("x"), "");
        uint256 id = uint256(keccak256(abi.encode(agentGrant, fresh, bytes32("x"))));
        vm.startPrank(fresh);
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, id));
        vault.grant(id, stranger, _wide(), 0, "");
        vm.expectRevert(abi.encodeWithSelector(ICrestVault.GrantClosed.selector, id));
        vault.createChild(id, 0, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        vault.setPaused(id, false, "");
        vm.stopPrank();
        assertTrue(vault.getGrant(id).closed);
        assertEq(vault.grantOf(fresh), 0);
        assertFalse(vault.signsFor(fresh, id));
    }

    function test_attack_afterTheSwitch_aSubAgentsChildVault_cannotBeFilledOrAdded() public {
        vm.prank(sub);
        address child = vault.createChild(subGrant, 0, "");
        _switchOff();
        vm.prank(sub);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.fundChild(child, 1, "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.fundChild(child, 1, "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.createChild(subGrant, bytes32("b"), "");
        vm.prank(sub); // the same salt as the existing child is walked before the existing address returns
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.createChild(subGrant, 0, "");
    }

    function test_attack_theSwitchSetWhileTheAgentIsPaused_holdsAfterTheResume() public {
        vm.prank(principal);
        vault.setPaused(agentGrant, true, "");
        _switchOff();
        vm.prank(principal);
        vault.setPaused(agentGrant, false, "");
        vm.prank(buyer);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grant(agentGrant, sub2, _wide(), bytes32("n"), "");
    }

    function test_attack_theSwitchOnAGrantInsideAChildVault_holds() public {
        vm.prank(buyer);
        CrestVault child = CrestVault(vault.createChild(agentGrant, 0, ""));
        vm.prank(buyer);
        uint256 g = child.grant(ROOT, sub2, _wide(), 0, "");
        ICrestVault.Caps memory off = _wide();
        off.mayDelegate = false;
        vm.prank(principal); // the top principal reaches into the child
        child.setCaps(g, off, "");
        vm.startPrank(sub2);
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        child.grant(g, fresh, _wide(), 0, "");
        vm.expectRevert(ICrestVault.NotAuthorized.selector);
        child.setCaps(g, _wide(), "");
        vm.stopPrank();
    }

    // The switch is a signed-grant stop too

    function test_attack_aSlipSignedBeforeTheSwitch_submittedAfterIt_refused() public {
        ICrestVault.SignedGrant memory s = _slip();
        bytes memory sig = _signed(BUYER_PK, s);
        _switchOff();
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grantBySig(s, sig);
        assertEq(vault.getGrant(_idOf(s)).controller, address(0), "no grant landed");
    }

    function test_attack_aSlipSignedAfterTheSwitch_byTheAgentOrASubAgent_refused() public {
        _switchOff();
        ICrestVault.SignedGrant memory s = _slip();
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grantBySig(s, _signed(BUYER_PK, s));
        s.parent = subGrant; // a sub-agent made before the switch signs under its own grant
        s.controller = fresh;
        s.salt = bytes32("two");
        vm.expectRevert(ICrestVault.MayNotDelegate.selector);
        vault.grantBySig(s, _signed(SUB_PK, s));
    }

    // The switch leaves spending alone, and the principal can still delegate or reverse it

    function test_theSwitch_leavesTheAgentAndItsSubAgentsPaying() public {
        _switchOff();
        _fundVia(_vterms(address(vault), buyer), BUYER_PK);
        _fundVia(_vterms(address(vault), sub), SUB_PK);
        _fundVia(_vterms(address(vault), sub3), SUB3_PK);
        assertEq(_grantOf(vault, agentGrant).spent, 3 * HOLD, "the agent's day counts all three");
        assertFalse(_grantOf(vault, subGrant).closed);
        assertFalse(_grantOf(vault, agentGrant).paused);
    }

    function test_theSwitch_turnedBackOn_letsTheAgentDelegateAgain() public {
        _switchOff();
        vm.prank(principal);
        vault.setCaps(agentGrant, _caps(HOLD, 3 * HOLD, type(uint128).max, 10, true, true), "delegation on");
        vm.prank(buyer);
        vault.grant(agentGrant, sub2, _wide(), bytes32("again"), "");
    }

    function test_theSwitch_doesNotStopThePrincipalGrantingUnderTheAgent() public {
        _switchOff();
        vm.prank(principal); // by design: the top principal's own `grant` skips the walk (Open item 13)
        vault.grant(agentGrant, sub2, _wide(), bytes32("by the principal"), "");
    }
}
