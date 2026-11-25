// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";

/// @title ICrestVault
/// @notice A principal's vault: it holds one token and a tree of grants, and pays only through modules the principal
///         enabled, each to the one payee the principal pinned for it. The principal is the person or company behind
///         the agents, as in Holdback's mandates.
///
///         The tree. The principal controls the root grant. Each grant names a parent, one controller key and its
///         limits. A payment charges the grant of the key that asks and every grant above it: each checks its state,
///         its expiry, its limits and the merchant list it names, and adds to its own counters. One refusal reverts the whole
///         payment and nothing is counted. A child granted wider limits than its parent is still bound by the parent at
///         payment time, so limits are never compared when a grant is made.
///
///         Who may do what. A top vault's principal withdraws, enables modules, hands the vault over and acts on any
///         grant. A controller above a grant, at any level, may pause, resume, close or set the limits and the list of
///         that grant; a closed grant's controller loses that authority, though in a child vault it
///         made it still manages grants that cannot pay. A grant's own controller may pause or close itself and, while
///         every grant on its path is open and may delegate, grant children and create and fill child vaults. It never
///         widens, resumes or reopens its own grant. Anyone above a paused grant can lift the pause, so pause or close
///         an agent's own grant to stop all below it. Closing frees the key, not the grant; any granter may reuse it.
///
///         Child vaults. A grant's controller may create a child vault through this vault, be its principal for good,
///         and fill it from this vault within the grant's period and total limits. The child's root extends that grant:
///         only authority strictly above the grant can widen, resume or reopen it. Every payment from the child is also
///         checked against the parent grant's path, and the paths above it in every ancestor vault, for state, expiry,
///         per-payment limit and lists. A child pays only through modules enabled at the top vault, to the payees
///         pinned there, and sends money only back to its parent. A child cannot be handed over, and a top vault's root
///         creates no child, so a handover never leaves a child with the previous principal.
///
///         Payments. An enabled module asks the vault to `charge` a key's grant. After the charge the vault approves
///         exactly one ERC-3009 `ReceiveWithAuthorization`: from the vault, to the module's pinned payee, for exactly
///         the charged amount, with the module's deadline and nonce, for the rest of the transaction. It answers the
///         token through ERC-1271 for that digest only, so no key's own signature ever moves the vault's money. To
///         anyone else it answers only for a buyer message, below, and that moves nothing by itself.
///
///         The vault as the buyer. A deal may name the vault itself as its buyer as well as its payer, so that a
///         stop reaches the agent's signature on funded deals. The vault then answers ERC-1271 for the venue's buyer
///         messages, through a module it enabled that rebuilds each message's digest (`ICrestBuyerModule`). Its
///         signature is `abi.encode(module, message, ecdsa)`: `message` is the calldata of one of that module's message
///         views, and `ecdsa` a key's 65-byte signature of the digest. For a deal this vault paid through that module,
///         the key must sign for the grant that paid it (`signsFor`). Before the deal is paid, for the terms and the
///         agreement, the deal must name this vault as buyer and payer and the key's own grant must pass `checkPath`
///         for it: a dry run, since only `charge` lets the vault's money move.
///
///         Signed grants. Whoever may grant under a parent may instead sign a `SignedGrant` under this vault's EIP-712
///         domain, which names the vault and the chain, and anyone may submit it with `grantBySig`. The vault checks it
///         as `grant` checks its caller, at submission, and it lands as an ordinary grant for the key it names, so the
///         submitter gains nothing and only that key can pay through it. It is used once: its grant ID stays taken.
///         Before use, `cancelSignedGrant` voids it and its deadline ends it; after use, close the grant.
///
///         Notes. Every change a principal or a controller makes takes a `note`, carried in its event as given: a
///         reason, a ticket, or the hash of a document kept elsewhere. It is public, so a principal that wants the
///         reason private puts a hash there.
///
///         Fees. The factory fixes a rate (`FEE_BPS`, basis points) and a sweeper (`FEE_SWEEPER`) in every vault it
///         creates, and nothing changes either afterwards. A payment owes `floor(amount × FEE_BPS / 10,000)` on top of
///         itself; the fee counts with the payment against every limit on the path, so a payment that exactly meets a
///         limit is refused once its fee is counted. The vault keeps what it owes (`feeOwed`), moves only the balance
///         above it, and pays it to the sweeper on `collectFee`. It never calls the sweeper. At a rate of 0 nothing
///         is owed. No fee on a deposit, a withdrawal, money coming back, or a move to or from a child vault. With a
///         fee, while a payment approved in a transaction is not yet pulled, the vault refuses another payment, a
///         withdrawal, a fill and a return in that transaction (`ApprovalPending`), so none can take the fee owed.
///
///         Money already committed. A vault has no function that can move money a venue holds. Its only call into a
///         venue is a Commerce Payments escrow's payer-only `reclaim`, after that escrow's expiry, which returns money to
///         the vault.
/// @dev No upgrade, no delegatecall, no selfdestruct. Every vault is a minimal clone of one implementation, created and
///      initialized in one transaction by `CrestFactory`.
interface ICrestVault {
    /// @notice What a grant allows. The largest value of a type means no limit of that kind.
    /// @param perSpend The most one payment and its fee may be, in the token's base units.
    /// @param perPeriod The most the payments of one period may add up to.
    /// @param lifetime The most this grant may ever pay, fees and child-vault funding included.
    /// @param maxOpen How many commitments may be open at once.
    /// @param period A period's length in seconds; a period is `floor(block.timestamp / period)`, so 86,400 is a UTC
    ///        day. Must not be 0. A new length keeps the spend of the last window paid in if it overlaps the new one.
    /// @param expiresAt No payment from this instant on (unix seconds); 0 for no expiry.
    /// @param mayDelegate False: no one delegates at or below it, except the top vault's principal granting.
    /// @param list The contract that says whom this grant may pay (`ICrestList`), asked at every payment; 0 for anyone,
    ///        bounded still by every list above. Whoever controls the list controls whom the grant can pay.
    struct Caps {
        uint128 perSpend;
        uint128 perPeriod;
        uint128 lifetime;
        uint32 maxOpen;
        uint32 period;
        uint40 expiresAt;
        bool mayDelegate;
        address list;
    }

    /// @notice A grant and its counters. `paused` can be lifted from above; `closed` is permanent. `inPeriod` counts the
    ///         window that ends at `windowEnd` (unix seconds) and counts while that end is after the current window's
    ///         start; a new period length only moves `windowEnd` back to the end of the new current window.
    struct Grant {
        uint256 parent;
        address controller;
        bool paused;
        bool closed;
        Caps caps;
        uint128 inPeriod;
        uint128 spent;
        uint40 windowEnd;
        uint32 open;
    }

    /// @notice A grant signed off chain: `grant`'s arguments and the last instant (unix seconds) it may be submitted. A
    ///         slip fixes its list's address, not that list's answers: whoever controls the list decides whom the grant
    ///         may pay, always within every limit and list above it. A list someone else controls is the signer's risk.
    struct SignedGrant {
        uint256 parent;
        address controller;
        Caps caps;
        bytes32 salt;
        uint40 deadline;
        bytes note;
    }

    /// @notice A commitment a module opened: which grant paid, how much, and which module may end it.
    struct Open {
        uint256 grant;
        uint128 amount;
        address module;
    }

    // Events. Every state change emits one; every change a principal or a controller makes carries who made it and
    // its note.

    event Initialized(address indexed principal, address indexed token, address indexed parent, uint256 parentGrant);
    event PrincipalProposed(address indexed principal, address indexed proposed, bytes note);
    event PrincipalChanged(address indexed previous, address indexed principal, bytes note);
    event ModuleSet(address indexed module, address indexed payee, bytes note);
    event Withdrawn(address indexed to, uint256 amount, bytes note);
    event Granted(
        uint256 indexed id, uint256 indexed parent, address indexed controller, Caps caps, address by, bytes note
    );
    event CapsSet(uint256 indexed id, Caps previous, Caps caps, address indexed by, bytes note);
    event PausedSet(uint256 indexed id, bool paused, address indexed by, bytes note);
    event Closed(uint256 indexed id, address indexed by, bytes note);
    event Charged(
        uint256 indexed grant, bytes32 indexed commitment, address indexed module, uint256 amount, bytes32 counterparty
    );
    event CommitmentEnded(uint256 indexed grant, bytes32 indexed commitment, uint256 amount);
    event ChildCreated(address indexed child, uint256 indexed grant, address indexed principal, address by, bytes note);
    event ChildFunded(address indexed child, uint256 indexed grant, uint256 amount, address indexed by, bytes note);
    event ChildTakenBack(address indexed child, uint256 indexed grant, uint256 amount, address indexed by, bytes note);
    event ReturnedToParent(address indexed parent, uint256 amount, address indexed by, bytes note);
    event Reclaimed(address indexed module, address indexed escrow, uint256 amount);
    event FeeOwed(uint256 indexed grant, uint256 fee);
    event FeeCollected(address indexed sweeper, uint256 amount, address indexed by);

    // Errors. A refusal by a limit names the grant that refused.

    error AlreadyInitialized();
    error NotAuthorized();
    error ZeroAddress();
    error NotTopVault();
    error NotChildVault();
    error InvalidCaps();
    error NoGrant();
    error GrantExists();
    error MayNotDelegate();
    error UnknownChild();
    error NoChildFromTheRoot();
    error ModuleNotEnabled();
    error CommitmentOpen();
    error NotOpen();
    error AmountTooLarge();
    error NotThePayer();
    error Paused(uint256 grant);
    error GrantClosed(uint256 grant);
    error Expired(uint256 grant);
    error OverPerSpend(uint256 grant);
    error OverPerPeriod(uint256 grant);
    error OverLifetime(uint256 grant);
    error TooManyOpen(uint256 grant);
    error CounterpartyNotAllowed(uint256 grant);
    error ListGasTooLow();
    error BadGrantSignature();
    error KeyNotFresh();
    error InvalidFee();
    error BalanceBelowFee();
    error ApprovalPending();
    error SignedGrantExpired();

    // Setup

    /// @notice Sets the principal, the token and, for a child, its parent vault and parent grant. Once, by the factory
    ///         that created the clone, in the same transaction. The root grant goes to the principal with no limits.
    function initialize(address principal, address token, address parent, uint256 parentGrant) external;

    // The principal

    /// @notice A top vault's principal proposes a new principal; the proposed key takes over with `acceptPrincipal`.
    ///         A child vault cannot be handed over.
    function proposePrincipal(address proposed, bytes calldata note) external;

    /// @notice The proposed key becomes the top vault's principal and the controller of its root grant. A grant the key
    ///         held is closed, so no agent can block a handover by giving the key a grant first.
    function acceptPrincipal(bytes calldata note) external;

    /// @notice A top vault's principal enables `module` to have this vault pay `payee`, or disables it with payee 0.
    ///         Child vaults inherit the top vault's modules and cannot set their own. An enabled module decides what a
    ///         deal it pays may look like, such as whether an agent's key may be its buyer, and one that is also an
    ///         `ICrestBuyerModule` decides which buyer messages the vault signs: enable only modules whose rules are
    ///         reviewed, and only the ones wanted.
    function setModule(address module, address payee, bytes calldata note) external;

    /// @notice A top vault's principal sends `amount` of the vault's balance to `to`. Money a venue holds is not the
    ///         vault's balance and cannot be reached.
    function withdraw(address to, uint256 amount, bytes calldata note) external;

    // The tree

    /// @notice Grants `controller` a child of `parentId` with `caps`, by `parentId`'s controller or authority above it
    ///         while its path may delegate; the top principal needs only authority. A grant the key holds closes if the
    ///         caller is above it. The ID is `keccak256(parentId, controller, salt)`.
    /// @return id The new grant's ID.
    function grant(uint256 parentId, address controller, Caps calldata caps, bytes32 salt, bytes calldata note)
        external
        returns (uint256 id);

    /// @notice Lands `signed` as `grant` would for its signer, by anyone until its deadline, for a fresh key: one that
    ///         has never held a grant here, nor been this vault's principal. A key that held one is granted again, or
    ///         moved, by transaction. `signature` is a 65-byte ECDSA signature with a low `s`: a contract controller
    ///         grants by transaction.
    /// @return id The new grant's ID.
    function grantBySig(SignedGrant calldata signed, bytes calldata signature) external returns (uint256 id);

    /// @notice Voids an unused signed grant by taking its ID, which then holds a closed grant, emitting `Closed` with no
    ///         `Granted` before it. By anyone with authority over the existing grant `parentId`, even while paused or
    ///         unable to delegate, so a signer can always void its own slips; another salt avoids an ID it takes.
    function cancelSignedGrant(uint256 parentId, address controller, bytes32 salt, bytes calldata note) external;

    /// @notice Sets the limits of grant `id`. By anyone with authority above it.
    function setCaps(uint256 id, Caps calldata caps, bytes calldata note) external;

    /// @notice Pauses or resumes grant `id`, and with it every payment through it. Its own controller may pause it;
    ///         only authority above may resume it.
    function setPaused(uint256 id, bool paused, bytes calldata note) external;

    /// @notice Closes grant `id` for good and frees its key. By its own controller or by authority above it.
    function close(uint256 id, bytes calldata note) external;

    // Child vaults

    /// @notice Creates a child vault whose principal is grant `grantId`'s controller, through the factory, or returns
    ///         it when it exists. By that controller or authority above it, while every grant on its path here and in
    ///         ancestor vaults is open, unexpired and may delegate. A top vault's root creates no child.
    /// @return child The child vault's address.
    function createChild(uint256 grantId, bytes32 salt, bytes calldata note) external returns (address child);

    /// @notice Moves `amount` into `child`, charged to the period and total limits of the path of the grant that
    ///         created it. By that grant's controller or authority above it, on the same terms as `createChild`.
    function fundChild(address child, uint256 amount, bytes calldata note) external;

    /// @notice Has `child` send `amount` back to this vault. By the grant's controller or authority above it.
    function takeBackFromChild(address child, uint256 amount, bytes calldata note) external;

    /// @notice A child vault sends `amount` to its parent vault: by its principal, by anyone with authority over its
    ///         root, or by its parent vault.
    function returnToParent(uint256 amount, bytes calldata note) external;

    // Payments

    /// @notice An enabled module charges `controller`'s grant and every grant above it with `amount` and its fee for
    ///         `counterparty`, opens `commitment` (the venue's own ID for this payment: for Holdback, the deal's
    ///         commitment ID), and has the vault approve one ERC-3009 authorization of exactly
    ///         `amount` to the module's pinned payee, valid before `validBefore`, with `nonce`.
    function charge(
        address controller,
        uint256 amount,
        bytes32 counterparty,
        bytes32 commitment,
        uint256 validBefore,
        bytes32 nonce
    ) external;

    /// @notice The module that opened `commitment` says it has ended: the open counts fall at every level. What was
    ///         spent stays counted.
    function endCommitment(bytes32 commitment) external;

    /// @notice Anyone has the vault call `reclaim` on the Commerce Payments escrow an enabled `module` names, for a
    ///         payment this vault paid. The escrow allows it only to the payer and only after its own expiry, and
    ///         returns the money to the vault.
    function reclaim(address module, AuthCaptureEscrow.PaymentInfo calldata paymentInfo) external;

    /// @notice Anyone has the vault pay `feeOwed` to `FEE_SWEEPER`, zeroing it first.
    /// @return owed What was paid.
    function collectFee() external returns (uint256 owed);

    /// @notice ERC-1271. To the token: yes only for a digest `charge` approved in this transaction, whatever the
    ///         signature. To anyone else: yes for a buyer message, as "The vault as the buyer" above describes, when
    ///         - the module named is enabled at the top vault and rebuilds exactly `hash` from `message`, naming this
    ///           vault as the buyer;
    ///         - for a deal this vault paid through that module, the key that signed `hash` signs for the grant that paid
    ///           it (`signsFor`);
    ///         - for a deal not yet paid, the message comes before funding, names this vault as the payer, and the key's
    ///           own grant passes `checkPath` for the amount, its fee included, and the counterparty.
    ///         A signature of 65 bytes or fewer is a no. One that does not decode, or a message the module refuses,
    ///         makes the call revert, which a caller reads as a no.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);

    // Views

    /// @notice Whether `who` controls grant `id` or has authority above it.
    function authorityOver(address who, uint256 id) external view returns (bool);

    /// @notice Whether `who` has authority strictly above grant `id`: it controls an open grant above `id` here, or has
    ///         authority strictly above this vault's parent grant in the parent vault, or it is this top vault's
    ///         principal.
    function isAbove(address who, uint256 id) external view returns (bool);

    /// @notice Reverts as `charge` would for `amount`, its fee included, and `counterparty` on grant `id`'s path,
    ///         here and in every ancestor vault, for state, expiry, per-payment limit and lists. Counts nothing.
    function checkPath(uint256 id, uint256 amount, bytes32 counterparty) external view;

    /// @notice Reverts when any grant on `id`'s path, here or in an ancestor vault, is closed, paused or expired, or may
    ///         not delegate.
    function checkDelegable(uint256 id) external view;

    /// @notice Whether `who` signs for the deals of grant `id` when the vault is the buyer: it controls `id` while
    ///         `id`'s path is live (`pathLive`), or it signs above `id` (`signsAbove`). So a stop on a grant, or anywhere
    ///         above it, silences that grant's controller and everyone below it, and authority above the stop signs
    ///         instead.
    function signsFor(address who, uint256 id) external view returns (bool);

    /// @notice Whether `who` signs strictly above grant `id`: it is this top vault's principal, or it controls a grant
    ///         strictly above `id` whose own path is live, here or, strictly above this vault's parent grant, in an
    ///         ancestor vault. A child vault's root extends its parent grant, so a stop on that root silences the
    ///         parent grant's controller too.
    function signsAbove(address who, uint256 id) external view returns (bool);

    /// @notice Whether grant `id` exists and every grant on its path, here and in every ancestor vault, is open,
    ///         unpaused and unexpired.
    function pathLive(uint256 id) external view returns (bool);

    /// @notice The payee pinned for `module` at the top vault; 0 when it is not enabled.
    function payeeOf(address module) external view returns (address);

    function principal() external view returns (address);
    function FEE_BPS() external view returns (uint256);
    function FEE_SWEEPER() external view returns (address);
    function feeOwed() external view returns (uint256);
    function pendingPrincipal() external view returns (address);
    function token() external view returns (address);
    function factory() external view returns (address);
    function parent() external view returns (address);
    function parentGrant() external view returns (uint256);
    function grantOf(address controller) external view returns (uint256);
    function grantOfChild(address child) external view returns (uint256);
    function getGrant(uint256 id) external view returns (Grant memory);
    function getOpen(bytes32 commitment) external view returns (Open memory);
}

/// @notice The merchant list a grant names. The vault asks it read-only, under a fixed gas cap, at every payment.
interface ICrestList {
    /// @notice Whether `vault`'s grant `grant` may pay `counterparty`. Only this function's selector is a yes; a
    ///         revert, running out of gas, an address with no code or any other answer is a no. The vault gives the list
    ///         30,000 gas and reads 32 bytes of its answer; a payment sent with too little gas to give the list its
    ///         whole cap is refused with `ListGasTooLow`.
    function allows(address vault, uint256 grant, bytes32 counterparty) external view returns (bytes4);
}

/// @notice A module that pays through a Commerce Payments escrow names it, so the vault can call that escrow's
///         payer-only `reclaim` after the escrow's expiry.
interface ICrestEscrowModule {
    function escrow() external view returns (address);
}

/// @notice A module that lets a vault be its venue's buyer: it rebuilds the digest of a buyer message from the message's
///         fields, so the vault checks a signature without knowing the venue.
interface ICrestBuyerModule {
    /// @notice What a buyer message names.
    /// @param digest The EIP-712 digest the venue asks its buyer to sign.
    /// @param commitment The venue's ID for the deal, the one `charge` records.
    /// @param buyer The buyer the message names.
    /// @param beforeFunding True for a message the buyer signs before the deal is paid: the terms and the agreement.
    /// @param payer Before funding: the address that pays the deal. Otherwise 0.
    /// @param amount Before funding: what the deal charges its payer, before Crest's fee. Otherwise 0.
    /// @param counterparty Before funding: the counterparty `charge` checks the lists against. Otherwise 0.
    struct BuyerMessage {
        bytes32 digest;
        bytes32 commitment;
        address buyer;
        bool beforeFunding;
        address payer;
        uint256 amount;
        bytes32 counterparty;
    }

    /// @notice Rebuilds the buyer message `message`, the calldata of one of the module's message views. Reverts for any
    ///         other call, or for fields that do not decode.
    function buyerMessage(bytes calldata message) external view returns (BuyerMessage memory);
}
