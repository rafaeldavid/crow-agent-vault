// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ICrestFactory} from "./ICrestFactory.sol";
import {ICrestBuyerModule, ICrestEscrowModule, ICrestList, ICrestVault} from "./ICrestVault.sol";

interface IERC3009Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @title CrestVault
/// @notice A principal's vault and its tree of grants. `ICrestVault` describes every function, event and error.
contract CrestVault is ICrestVault, EIP712 {
    uint256 public constant ROOT = 1;
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    bytes32 internal constant CAPS_TYPEHASH = keccak256(
        "Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    bytes32 internal constant SIGNED_GRANT_TYPEHASH = keccak256(
        "SignedGrant(uint256 parent,address controller,Caps caps,bytes32 salt,uint40 deadline,bytes note)Caps(uint128 perSpend,uint128 perPeriod,uint128 lifetime,uint32 maxOpen,uint32 period,uint40 expiresAt,bool mayDelegate,address list)"
    );
    /// The gas a grant's merchant list may use to answer, measured against the default list and a registry-reading one.
    uint256 internal constant LIST_GAS = 30_000;
    /// The largest `s` of a non-malleable secp256k1 signature, `n / 2`.
    uint256 internal constant HALF_N = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant ERC1271_NO = 0xffffffff;
    /// Transient slots: whether this vault approved a payment earlier in this transaction, and that payment's nonce.
    bytes32 internal constant PENDING_SET_SLOT = keccak256("crest.vault.pending.set");
    bytes32 internal constant PENDING_NONCE_SLOT = keccak256("crest.vault.pending.nonce");
    /// An approved digest's transient slot is `keccak256(abi.encode(APPROVAL_TAG, digest))`, never the digest itself, so
    /// no other transient slot of the vault answers the token (RT-2).
    bytes32 internal constant APPROVAL_TAG = keccak256("crest.vault.approval");

    uint256 public immutable FEE_BPS;
    address public immutable FEE_SWEEPER;

    address public principal;
    address public pendingPrincipal;
    address public token;
    address public factory;
    address public parent;
    uint256 public parentGrant;

    mapping(uint256 id => Grant) internal _grants;
    mapping(address controller => uint256 id) public grantOf;
    mapping(address child => uint256 id) public grantOfChild;
    mapping(bytes32 commitment => Open) internal _opens;
    mapping(address module => address payee) internal _payees;
    /// Keys whose grant here closed, and previous principals: a signed grant never names one.
    mapping(address key => bool) internal _retired;
    uint256 public feeOwed;

    /// The factory's fee, fixed in the implementation every clone of it runs.
    constructor(uint256 feeBps, address feeSweeper) {
        if (feeBps > 10_000 || (feeBps != 0 && feeSweeper == address(0))) revert InvalidFee();
        FEE_BPS = feeBps;
        FEE_SWEEPER = feeSweeper;
        principal = address(1);
    }

    // Setup

    /// @inheritdoc ICrestVault
    function initialize(address principal_, address token_, address parent_, uint256 parentGrant_) external {
        if (principal != address(0)) revert AlreadyInitialized();
        if (principal_ == address(0) || token_ == address(0)) revert ZeroAddress();
        (principal, token, factory, parent, parentGrant) = (principal_, token_, msg.sender, parent_, parentGrant_);
        Grant storage g = _grants[ROOT];
        g.controller = principal_;
        g.caps = Caps({
            perSpend: type(uint128).max,
            perPeriod: type(uint128).max,
            lifetime: type(uint128).max,
            maxOpen: type(uint32).max,
            period: 1 days,
            expiresAt: 0,
            mayDelegate: true,
            list: address(0)
        });
        grantOf[principal_] = ROOT;
        emit Initialized(principal_, token_, parent_, parentGrant_);
        emit Granted(ROOT, 0, principal_, g.caps, msg.sender, "");
    }

    // The principal

    /// @inheritdoc ICrestVault
    function proposePrincipal(address proposed, bytes calldata note) external {
        _requireTopPrincipal();
        pendingPrincipal = proposed;
        emit PrincipalProposed(principal, proposed, note);
    }

    /// @inheritdoc ICrestVault
    function acceptPrincipal(bytes calldata note) external {
        if (parent != address(0)) revert NotTopVault();
        address proposed = pendingPrincipal;
        if (proposed == address(0) || msg.sender != proposed) revert NotAuthorized();
        uint256 held = grantOf[proposed];
        if (held != 0 && held != ROOT) {
            _grants[held].closed = true;
            emit Closed(held, proposed, note);
        }
        address previous = principal;
        delete grantOf[previous];
        _retired[previous] = true;
        (principal, pendingPrincipal) = (proposed, address(0));
        _grants[ROOT].controller = proposed;
        grantOf[proposed] = ROOT;
        emit PrincipalChanged(previous, proposed, note);
    }

    /// @inheritdoc ICrestVault
    function setModule(address module, address payee, bytes calldata note) external {
        _requireTopPrincipal();
        _payees[module] = payee;
        emit ModuleSet(module, payee, note);
    }

    /// @inheritdoc ICrestVault
    function withdraw(address to, uint256 amount, bytes calldata note) external {
        _requireTopPrincipal();
        _requireAboveFee(amount);
        emit Withdrawn(to, amount, note);
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // The tree

    /// @inheritdoc ICrestVault
    function grant(uint256 parentId, address controller, Caps calldata caps, bytes32 salt, bytes calldata note)
        external
        returns (uint256 id)
    {
        return _grant(msg.sender, parentId, controller, caps, salt, note);
    }

    /// @inheritdoc ICrestVault
    function grantBySig(SignedGrant calldata signed, bytes calldata signature) external returns (uint256 id) {
        if (block.timestamp > signed.deadline) revert SignedGrantExpired();
        if (signature.length != 65 || uint256(bytes32(signature[32:64])) > HALF_N) revert BadGrantSignature();
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_GRANT_TYPEHASH,
                signed.parent,
                signed.controller,
                keccak256(abi.encode(CAPS_TYPEHASH, signed.caps)),
                signed.salt,
                signed.deadline,
                keccak256(signed.note)
            )
        );
        address signer = ECDSA.tryRecoverCalldata(_hashTypedData(structHash), signature);
        if (signer == address(0)) revert BadGrantSignature();
        if (grantOf[signed.controller] != 0 || _retired[signed.controller]) revert KeyNotFresh();
        id = _grant(signer, signed.parent, signed.controller, signed.caps, signed.salt, signed.note);
    }

    /// @inheritdoc ICrestVault
    function cancelSignedGrant(uint256 parentId, address controller, bytes32 salt, bytes calldata note) external {
        _requireExists(parentId);
        if (!authorityOver(msg.sender, parentId)) revert NotAuthorized();
        if (controller == address(0)) revert ZeroAddress();
        uint256 id = uint256(keccak256(abi.encode(parentId, controller, salt)));
        Grant storage g = _grants[id];
        if (id <= ROOT || g.controller != address(0)) revert GrantExists();
        (g.parent, g.controller, g.closed) = (parentId, controller, true);
        emit Closed(id, msg.sender, note);
    }

    /// @inheritdoc ICrestVault
    function setCaps(uint256 id, Caps calldata caps, bytes calldata note) external {
        _requireExists(id);
        if (!_above(msg.sender, id)) revert NotAuthorized();
        _requireValid(caps);
        Grant storage g = _grants[id];
        Caps memory previous = g.caps;
        uint256 end = (block.timestamp / caps.period + 1) * caps.period;
        if (g.windowEnd > end) g.windowEnd = uint40(end);
        g.caps = caps;
        emit CapsSet(id, previous, caps, msg.sender, note);
    }

    /// @inheritdoc ICrestVault
    function setPaused(uint256 id, bool paused, bytes calldata note) external {
        Grant storage g = _grants[id];
        _requireExists(id);
        if (!(paused && msg.sender == g.controller) && !_above(msg.sender, id)) revert NotAuthorized();
        g.paused = paused;
        emit PausedSet(id, paused, msg.sender, note);
    }

    /// @inheritdoc ICrestVault
    function close(uint256 id, bytes calldata note) external {
        Grant storage g = _grants[id];
        _requireExists(id);
        if (msg.sender != g.controller && !_above(msg.sender, id)) revert NotAuthorized();
        g.closed = true;
        if (id != ROOT && grantOf[g.controller] == id) {
            delete grantOf[g.controller];
            _retired[g.controller] = true;
        }
        emit Closed(id, msg.sender, note);
    }

    // Child vaults

    /// @inheritdoc ICrestVault
    function createChild(uint256 grantId, bytes32 salt, bytes calldata note) external returns (address child) {
        if (grantId == ROOT && parent == address(0)) revert NoChildFromTheRoot();
        Grant storage g = _grants[grantId];
        if (g.controller == address(0)) revert NoGrant();
        if (!authorityOver(msg.sender, grantId)) revert NotAuthorized();
        _requireDelegable(grantId);
        address childPrincipal = g.controller;
        child = ICrestFactory(factory).childAddressOf(address(this), childPrincipal, grantId, salt);
        if (grantOfChild[child] != 0) return child;
        grantOfChild[child] = grantId;
        emit ChildCreated(child, grantId, childPrincipal, msg.sender, note);
        if (ICrestFactory(factory).createChild(childPrincipal, grantId, salt) != child) revert UnknownChild();
    }

    /// @inheritdoc ICrestVault
    function fundChild(address child, uint256 amount, bytes calldata note) external {
        uint256 id = grantOfChild[child];
        if (id == 0) revert UnknownChild();
        if (!authorityOver(msg.sender, id)) revert NotAuthorized();
        _requireDelegable(id);
        _requireAboveFee(amount);
        uint128 a = _amount(amount);
        for (uint256 g = id; g != 0; g = _grants[g].parent) {
            _chargeOne(g, a, bytes32(0), false);
        }
        emit ChildFunded(child, id, amount, msg.sender, note);
        SafeTransferLib.safeTransfer(token, child, amount);
    }

    /// @inheritdoc ICrestVault
    function takeBackFromChild(address child, uint256 amount, bytes calldata note) external {
        uint256 id = grantOfChild[child];
        if (id == 0) revert UnknownChild();
        if (!authorityOver(msg.sender, id)) revert NotAuthorized();
        emit ChildTakenBack(child, id, amount, msg.sender, note);
        ICrestVault(child).returnToParent(amount, note);
    }

    /// @inheritdoc ICrestVault
    function returnToParent(uint256 amount, bytes calldata note) external {
        address p = parent;
        if (p == address(0)) revert NotChildVault();
        if (msg.sender != p && !authorityOver(msg.sender, ROOT)) revert NotAuthorized();
        _requireAboveFee(amount);
        emit ReturnedToParent(p, amount, msg.sender, note);
        SafeTransferLib.safeTransfer(token, p, amount);
    }

    // Payments

    /// @inheritdoc ICrestVault
    function charge(
        address controller,
        uint256 amount,
        bytes32 counterparty,
        bytes32 commitment,
        uint256 validBefore,
        bytes32 nonce
    ) external {
        address payee = payeeOf(msg.sender);
        if (payee == address(0)) revert ModuleNotEnabled();
        uint256 leaf = grantOf[controller];
        if (leaf == 0) revert NoGrant();
        if (_opens[commitment].module != address(0)) revert CommitmentOpen();
        uint128 a = _amount(amount);
        uint128 total = FEE_BPS == 0 ? a : _withFee(leaf, a, nonce);
        for (uint256 g = leaf; g != 0; g = _grants[g].parent) {
            _chargeOne(g, total, counterparty, true);
        }
        _opens[commitment] = Open({grant: leaf, amount: a, module: msg.sender});
        if (parent != address(0)) ICrestVault(parent).checkPath(parentGrant, total, counterparty);
        if (FEE_BPS != 0) _owe(leaf, a, total - a);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC3009Domain(token).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                        address(this),
                        payee,
                        amount,
                        uint256(0),
                        validBefore,
                        nonce
                    )
                )
            )
        );
        bytes32 slot = _approvalSlot(digest);
        assembly {
            tstore(slot, 1)
        }
        emit Charged(leaf, commitment, msg.sender, amount, counterparty);
    }

    /// @inheritdoc ICrestVault
    function endCommitment(bytes32 commitment) external {
        Open memory o = _opens[commitment];
        if (o.module == address(0) || o.module != msg.sender) revert NotOpen();
        delete _opens[commitment];
        for (uint256 g = o.grant; g != 0; g = _grants[g].parent) {
            _grants[g].open -= 1;
        }
        emit CommitmentEnded(o.grant, commitment, o.amount);
    }

    /// @inheritdoc ICrestVault
    function reclaim(address module, AuthCaptureEscrow.PaymentInfo calldata paymentInfo) external {
        if (payeeOf(module) == address(0)) revert ModuleNotEnabled();
        if (paymentInfo.payer != address(this)) revert NotThePayer();
        address escrow = ICrestEscrowModule(module).escrow();
        uint256 before = SafeTransferLib.balanceOf(token, address(this));
        AuthCaptureEscrow(escrow).reclaim(paymentInfo);
        emit Reclaimed(module, escrow, SafeTransferLib.balanceOf(token, address(this)) - before);
    }

    /// @inheritdoc ICrestVault
    function collectFee() external returns (uint256 owed) {
        owed = feeOwed;
        if (owed == 0) return 0;
        feeOwed = 0;
        emit FeeCollected(FEE_SWEEPER, owed, msg.sender);
        if (owed != 0) SafeTransferLib.safeTransfer(token, FEE_SWEEPER, owed);
    }

    /// @inheritdoc ICrestVault
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (msg.sender == token) {
            uint256 approved;
            bytes32 slot = _approvalSlot(hash);
            assembly {
                approved := tload(slot)
            }
            return approved == 1 ? ERC1271_MAGIC : ERC1271_NO;
        }
        return signature.length > 65 && _signedAsBuyer(hash, signature) ? ERC1271_MAGIC : ERC1271_NO;
    }

    // Views

    /// @inheritdoc ICrestVault
    function authorityOver(address who, uint256 id) public view returns (bool) {
        return who != address(0) && (_grants[id].controller == who || _above(who, id));
    }

    /// @inheritdoc ICrestVault
    function isAbove(address who, uint256 id) external view returns (bool) {
        return _above(who, id);
    }

    /// @inheritdoc ICrestVault
    function checkPath(uint256 id, uint256 amount, bytes32 counterparty) external view {
        _walk(id, true, amount, counterparty);
    }

    /// @inheritdoc ICrestVault
    function checkDelegable(uint256 id) external view {
        _walk(id, false, 0, 0);
    }

    /// @inheritdoc ICrestVault
    function signsFor(address who, uint256 id) public view returns (bool) {
        return who != address(0) && ((_grants[id].controller == who && pathLive(id)) || signsAbove(who, id));
    }

    /// @inheritdoc ICrestVault
    function signsAbove(address who, uint256 id) public view returns (bool) {
        if (who == address(0)) return false;
        if (_isTopPrincipal(who)) return true;
        for (uint256 g = _grants[id].parent; g != 0; g = _grants[g].parent) {
            if (_grants[g].controller == who && pathLive(g)) return true;
        }
        return parent != address(0) && ICrestVault(parent).signsAbove(who, parentGrant);
    }

    /// @inheritdoc ICrestVault
    function pathLive(uint256 id) public view returns (bool) {
        if (_grants[id].controller == address(0)) return false;
        for (uint256 g = id; g != 0; g = _grants[g].parent) {
            Grant storage x = _grants[g];
            uint40 end = x.caps.expiresAt;
            if (x.closed || x.paused || (end != 0 && block.timestamp >= end)) return false;
        }
        return parent == address(0) || ICrestVault(parent).pathLive(parentGrant);
    }

    /// @inheritdoc ICrestVault
    function payeeOf(address module) public view returns (address) {
        return parent == address(0) ? _payees[module] : ICrestVault(parent).payeeOf(module);
    }

    /// @inheritdoc ICrestVault
    function getGrant(uint256 id) external view returns (Grant memory) {
        return _grants[id];
    }

    /// @inheritdoc ICrestVault
    function getOpen(bytes32 commitment) external view returns (Open memory) {
        return _opens[commitment];
    }

    // Internals

    /// `grant`'s checks and effects, for the caller or, for a signed grant, its signer `by`.
    function _grant(
        address by,
        uint256 parentId,
        address controller,
        Caps calldata caps,
        bytes32 salt,
        bytes calldata note
    ) internal returns (uint256 id) {
        Grant storage p = _grants[parentId];
        if (p.controller == address(0)) revert NoGrant();
        if (!authorityOver(by, parentId)) revert NotAuthorized();
        if (!_isTopPrincipal(by)) _requireDelegable(parentId);
        if (p.closed) revert GrantClosed(parentId);
        if (controller == address(0)) revert ZeroAddress();
        _requireValid(caps);
        id = uint256(keccak256(abi.encode(parentId, controller, salt)));
        uint256 held = grantOf[controller];
        if (id <= ROOT || _grants[id].controller != address(0) || held == ROOT) revert GrantExists();
        if (held != 0) {
            if (!_above(by, held)) revert GrantExists();
            _grants[held].closed = true;
            emit Closed(held, by, note);
        }
        Grant storage g = _grants[id];
        (g.parent, g.controller, g.caps) = (parentId, controller, caps);
        grantOf[controller] = id;
        emit Granted(id, parentId, controller, caps, by, note);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Crest", "1");
    }

    function _above(address who, uint256 id) internal view returns (bool) {
        if (who == address(0)) return false;
        if (_isTopPrincipal(who)) return true;
        for (uint256 g = _grants[id].parent; g != 0; g = _grants[g].parent) {
            if (_grants[g].controller == who && !_grants[g].closed) return true;
        }
        return parent != address(0) && ICrestVault(parent).isAbove(who, parentGrant);
    }

    /// A venue's buyer message signed for this vault (`isValidSignature`): `signature` is `abi.encode(module, message,
    /// ecdsa)`, and the module rebuilds the message's digest.
    function _signedAsBuyer(bytes32 hash, bytes calldata signature) internal view returns (bool) {
        (address module, bytes memory message, bytes memory ecdsa) = abi.decode(signature, (address, bytes, bytes));
        if (ecdsa.length != 65 || payeeOf(module) == address(0)) return false;
        ICrestBuyerModule.BuyerMessage memory m = ICrestBuyerModule(module).buyerMessage(message);
        if (m.digest != hash || m.buyer != address(this)) return false;
        address signer = ECDSA.tryRecover(hash, ecdsa);
        if (signer == address(0)) return false;
        Open storage o = _opens[m.commitment];
        if (o.module != address(0)) return o.module == module && signsFor(signer, o.grant);
        uint256 leaf = grantOf[signer];
        if (!m.beforeFunding || m.payer != address(this) || leaf == 0) return false;
        try this.checkPath(leaf, m.amount + m.amount * FEE_BPS / 10_000, m.counterparty) {
            return true;
        } catch {
            return false;
        }
    }

    function _approvalSlot(bytes32 digest) internal pure returns (bytes32) {
        return keccak256(abi.encode(APPROVAL_TAG, digest));
    }

    function _isTopPrincipal(address who) internal view returns (bool) {
        return parent == address(0) && who == principal;
    }

    function _requireTopPrincipal() internal view {
        if (parent != address(0)) revert NotTopVault();
        if (msg.sender != principal) revert NotAuthorized();
    }

    function _chargeOne(uint256 id, uint128 amount, bytes32 counterparty, bool payment) internal {
        Grant storage x = _grants[id];
        Caps memory c = x.caps;
        _requireState(id, x, c);
        if (payment) {
            if (amount > c.perSpend) revert OverPerSpend(id);
            if (c.list != address(0) && !_listAllows(c.list, id, counterparty)) revert CounterpartyNotAllowed(id);
            if (uint256(x.open) + 1 > c.maxOpen) revert TooManyOpen(id);
            x.open += 1;
        }
        uint256 start = block.timestamp / c.period * c.period;
        uint256 inPeriod = x.windowEnd > start ? x.inPeriod : 0;
        if (inPeriod + amount > c.perPeriod) revert OverPerPeriod(id);
        if (uint256(x.spent) + amount > c.lifetime) revert OverLifetime(id);
        (x.inPeriod, x.windowEnd) = (uint128(inPeriod + amount), uint40(start + c.period));
        x.spent += amount;
    }

    function _requireState(uint256 id, Grant storage x, Caps memory c) internal view {
        if (x.closed) revert GrantClosed(id);
        if (x.paused) revert Paused(id);
        if (c.expiresAt != 0 && block.timestamp >= c.expiresAt) revert Expired(id);
    }

    function _requireDelegable(uint256 id) internal view {
        _walk(id, false, 0, 0);
    }

    /// For a payment, the state, per-payment limit and list of every grant on the path; for delegating, the state
    /// and `mayDelegate` of every grant on it. Both continue in every ancestor vault.
    function _walk(uint256 id, bool payment, uint256 amount, bytes32 counterparty) internal view {
        for (uint256 g = id; g != 0; g = _grants[g].parent) {
            Grant storage x = _grants[g];
            Caps memory c = x.caps;
            _requireState(g, x, c);
            if (!payment && !c.mayDelegate) revert MayNotDelegate();
            if (payment && amount > c.perSpend) revert OverPerSpend(g);
            if (payment && c.list != address(0) && !_listAllows(c.list, g, counterparty)) {
                revert CounterpartyNotAllowed(g);
            }
        }
        if (parent == address(0)) return;
        if (payment) ICrestVault(parent).checkPath(parentGrant, amount, counterparty);
        else ICrestVault(parent).checkDelegable(parentGrant);
    }

    /// With a fee, refuses a move that would leave less than the fee owed. At a rate of 0 nothing is ever owed.
    function _requireAboveFee(uint256 amount) internal view {
        if (FEE_BPS == 0) return;
        uint256 owed = feeOwed;
        if (owed != 0 && SafeTransferLib.balanceOf(token, address(this)) < amount + owed) revert BalanceBelowFee();
    }

    /// A payment of `a` with its fee, refused by name when the two would not fit in a `uint128`.
    function _withFee(uint256 leaf, uint128 a, bytes32 nonce) internal returns (uint128) {
        uint256 total = uint256(a) + uint256(a) * FEE_BPS / 10_000;
        if (total > type(uint128).max) revert OverPerSpend(leaf);
        _requireNoPendingApproval(nonce);
        return uint128(total);
    }

    /// Adds a payment's fee to what the vault owes, then refuses the payment if the balance would fall below it.
    function _owe(uint256 leaf, uint128 a, uint128 fee) internal {
        if (fee != 0) {
            feeOwed += fee;
            emit FeeOwed(leaf, fee);
        }
        _requireAboveFee(a);
    }

    /// With a fee, refuses a second approval in one transaction while the token has not yet spent the first, so every
    /// balance check sees every earlier payment's pull. Then records this approval's nonce.
    function _requireNoPendingApproval(bytes32 nonce) internal {
        bytes32 setSlot = PENDING_SET_SLOT;
        bytes32 nonceSlot = PENDING_NONCE_SLOT;
        uint256 set;
        bytes32 last;
        assembly {
            set := tload(setSlot)
            last := tload(nonceSlot)
        }
        if (set != 0 && !IERC3009Domain(token).authorizationState(address(this), last)) revert ApprovalPending();
        assembly {
            tstore(setSlot, 1)
            tstore(nonceSlot, nonce)
        }
    }

    /// Asks `list`, read-only and with `LIST_GAS`, whether grant `id` may pay `counterparty`. Only the exact magic
    /// answer is a yes: a revert, running out of gas, no code, or any other answer is a no, and only 32 bytes of the
    /// answer are ever copied. A call that could not give the list its whole `LIST_GAS` (after the 63/64 rule) is
    /// refused, so the caller's gas never changes the answer.
    function _listAllows(address list, uint256 id, bytes32 counterparty) internal view returns (bool yes) {
        if (gasleft() < LIST_GAS * 64 / 63 + 4000) revert ListGasTooLow();
        bytes memory ask = abi.encodeCall(ICrestList.allows, (address(this), id, counterparty));
        bytes32 want = bytes32(ICrestList.allows.selector);
        assembly ("memory-safe") {
            let ok := staticcall(LIST_GAS, list, add(ask, 0x20), mload(ask), 0x00, 0x20)
            yes := and(and(ok, eq(returndatasize(), 0x20)), eq(mload(0x00), want))
        }
    }

    function _requireExists(uint256 id) internal view {
        if (_grants[id].controller == address(0)) revert NoGrant();
    }

    function _requireValid(Caps calldata caps) internal pure {
        if (caps.period == 0) revert InvalidCaps();
    }

    function _amount(uint256 amount) internal pure returns (uint128) {
        if (amount > type(uint128).max) revert AmountTooLarge();
        return uint128(amount);
    }
}
