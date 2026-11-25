// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IHoldbackRules} from "holdback/IHoldbackRules.sol";
import {HoldbackTypes as H} from "holdback/HoldbackTypes.sol";

import {CrestVault} from "../../src/CrestVault.sol";
import {ICrestVault} from "../../src/ICrestVault.sol";
import {PayModule} from "../mocks/PayModule.sol";
import {VaultBuyerBase} from "../VaultBuyerBase.sol";

/// The world for whole journeys: Holdback's unchanged rules contract, escrow and collector (Holdback's test world), the
/// factory, the vault-buyer Holdback module the deploy script deploys, the default list, and a second venue that takes
/// ERC-3009 payments directly (the test-only `PayModule`). Each journey starts from nothing: an owner's key creates its
/// vault through the factory, funds it, enables the venues and grants its agent a budget.
///
/// `_assertConserved` checks after every step that the token's total supply equals the balances of every address the
/// journey knows, and that no agent or sub-agent key ever holds a token unit.
abstract contract JourneyBase is VaultBuyerBase {
    uint256 internal constant OWNER_PK = 0x0E0E;
    uint256 internal constant AGENT_PK = 0xA6E7;
    uint256 internal constant CHILD_SUB_PK = 0xC5AB;
    uint256 internal constant SLIP_SUB_PK = 0x511F;
    uint256 internal constant FUNDED = 40 * HOLD;
    /// A merchant the direct venue pays. Its counterparty is any 32 bytes the venue's module names.
    bytes32 internal constant DIRECT = keccak256("a merchant paid directly");

    address internal owner;
    address internal agent;
    address internal childSub;
    address internal slipSub;
    address internal treasury;
    PayModule internal direct;
    CrestVault internal ov;
    uint256 internal agentId;
    address[] internal known;
    address[] internal keys;

    function setUp() public virtual override {
        super.setUp();
        owner = vm.addr(OWNER_PK);
        agent = vm.addr(AGENT_PK);
        childSub = vm.addr(CHILD_SUB_PK);
        slipSub = vm.addr(SLIP_SUB_PK);
        treasury = makeAddr("the owner's treasury");
        direct = new PayModule(address(usdc));
        known = [
            buyer,
            seller,
            adjudicator,
            fallbackAdj,
            appealAdj,
            address(vault),
            escrow.getTokenStore(address(rules)),
            owner,
            treasury,
            address(direct)
        ];
        keys = [agent, sub, sub2, childSub, slipSub, stranger, relayer];
    }

    /// The owner creates its vault through the factory, funds it, enables Holdback and the direct venue, grants the
    /// agent a budget (one hold per payment, three a day, twelve in all, two open at once, 30 days, may delegate) and
    /// approves one merchant on each venue in the default list.
    function _openOwnersVault() internal {
        address predicted = factory.addressOf(owner, address(usdc), "owner");
        vm.prank(stranger); // anyone may create it and pays the gas; the creator gets nothing
        ov = CrestVault(factory.create(owner, address(usdc), "owner"));
        assertEq(address(ov), predicted, "the vault lands at its predicted address");
        assertTrue(factory.isVault(address(ov)));
        assertEq(ov.principal(), owner);
        assertEq(ov.grantOf(stranger), 0, "the creator holds no grant");
        _track(address(ov));

        usdc.mint(owner, FUNDED);
        vm.startPrank(owner);
        usdc.transfer(address(ov), FUNDED);
        ov.setModule(address(module), module.payee(), "Holdback");
        ov.setModule(address(direct), address(direct), "a direct venue");
        agentId = ov.grant(ROOT, agent, _agentCaps(true), 0, "the agent's budget");
        allowList.set(ov, agentId, _merchant(), true, "the approved merchant on Holdback");
        allowList.set(ov, agentId, DIRECT, true, "the approved merchant paid directly");
        vm.stopPrank();
        _assertConserved();
    }

    function _agentCaps(bool mayDelegate) internal view returns (ICrestVault.Caps memory) {
        return ICrestVault.Caps({
            perSpend: uint128(HOLD),
            perPeriod: uint128(3 * HOLD),
            lifetime: uint128(12 * HOLD),
            maxOpen: 2,
            period: 1 days,
            expiresAt: uint40(vm.getBlockTimestamp() + 30 days),
            mayDelegate: mayDelegate,
            list: address(allowList)
        });
    }

    function _track(address a) internal {
        known.push(a);
    }

    function _sumKnown() internal view returns (uint256 s) {
        for (uint256 i; i < known.length; i++) {
            s += usdc.balanceOf(known[i]);
        }
    }

    function _assertConserved() internal view {
        assertEq(_sumKnown(), usdc.totalSupply(), "every token unit is with an address the journey knows");
        for (uint256 i; i < keys.length; i++) {
            assertEq(usdc.balanceOf(keys[i]), 0, "no agent, relayer or stranger key ever holds the vault's money");
        }
    }

    function _held() internal view returns (uint256) {
        return usdc.balanceOf(escrow.getTokenStore(address(rules)));
    }

    function _spent(CrestVault v, uint256 id) internal view returns (uint256) {
        return v.getGrant(id).spent;
    }

    function _inPeriod(CrestVault v, uint256 id) internal view returns (uint256) {
        return v.getGrant(id).inPeriod;
    }

    function _openCount(CrestVault v, uint256 id) internal view returns (uint256) {
        return v.getGrant(id).open;
    }

    function _assertStage(bytes32 id, IHoldbackRules.Stage s) internal view {
        assertEq(uint8(_stage(id)), uint8(s));
    }

    /// The seller posts its delivery, addressed to the deal's buyer, so an early accept can name it later.
    function _post(H.Terms memory t, bytes32 id) internal returns (Early memory e) {
        e = _earlyAs(t, id, AGENT_PK);
        rules.deliver(t, e.d, e.dsig);
        _assertStage(id, IHoldbackRules.Stage.Delivered);
    }

    /// An early accept of the posted delivery, signed for the vault by `pk`.
    function _earlyBy(H.Terms memory t, bytes32 id, uint256 pk) internal view returns (Early memory e) {
        e = _earlyAs(t, id, pk);
    }

    /// A direct payment, expected to land; returns its commitment.
    function _payDirect(CrestVault v, address who, uint256 amount, bytes32 merchant) internal returns (bytes32 c) {
        c = direct.pay(v, who, amount, merchant);
    }

    function _expectDirectRefused(CrestVault v, address who, uint256 amount, bytes32 merchant, bytes memory err)
        internal
    {
        vm.expectRevert(err);
        direct.pay(v, who, amount, merchant);
    }
}
