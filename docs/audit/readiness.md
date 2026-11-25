# Readiness for an outside automated scan

**State, 2026-11-25.** Crow Vault's contracts at `main` `821f5f7` were tested end to end, in random sequences and by an adversarial pass before an outside automated scan. No test found money moving past a limit, outside a deal's terms or out of a hold. The red team found one Low (RT-1, a design claim that did not hold for a grant with no merchant list, now corrected) and one Info (RT-2). This pass added one Info (V-I1) and four Info observations, which the maintainer has acknowledged. A second review from another model family added one Info finding and two documentation points (SF-1 to SF-3), and its pass over the next version found one Low in this build too (SF-4, known limit K-20). None needs a change to `src/` before a scan. Three items wait for the maintainer (section 9).

This page is the scan's starting point. It sets the scope, the trust model and the invariants. Each invariant maps to the tests that check it, and the page records what was run, with its settings and results, and what is left untested. Findings and known limits close the page. The vault is not audited, and nothing here says it is secure. It runs on local chains and test networks only.

Labels: **measured** (produced by the named command or test), **documented** (stated in the file cited), **inferred** (concluded from reading), **guessed**.

## 1. Scope

**The code to scan:** `src/` at `821f5f7`, `main` on 2026-11-25. `src/` last changed on 2026-11-19 (`e5af726`), with the vault-as-buyer build. This pull request changes no file in `src/`.

| File | Lines (`wc -l`) | nSLOC (Aderyn) | What it is |
| --- | --- | --- | --- |
| `src/CrestVault.sol` | 602 | 480 | The vault: grants, limits and counters, child vaults, payments, the fee, ERC-1271 answers |
| `src/ICrestVault.sol` | 396 | 159 | Its interface: every function, event and error, with the descriptions |
| `src/modules/holdback/HoldbackModule.sol` | 176 | 143 | The Holdback venue: funds a hold from a vault, rebuilds buyer messages |
| `src/modules/holdback/IHoldbackModule.sol` | 105 | 38 | Its interface |
| `src/CrestFactory.sol` | 62 | 45 | Creates vaults and child vaults as minimal clones |
| `src/ICrestFactory.sol` | 40 | 17 | Its interface |
| `src/CrestFeeSweeper.sol` | 28 | 19 | Collects fees to a fixed destination |
| `src/ICrestFeeSweeper.sol` | 22 | 8 | Its interface |
| `src/CrestAllowList.sol` | 23 | 14 | The default merchant list |
| `src/ICrestAllowList.sol` | 23 | 10 | Its interface |
| **Total** | **1,477** | **933** | [measured: `wc -l src/*.sol src/modules/holdback/*.sol`; Aderyn 0.6.8's file summary] |

**Build.** Solidity 0.8.28, via-IR, optimizer 200 runs, EVM `prague` (`foundry.toml`). Foundry 1.0.0, the version CI installs (`.github/workflows/ci.yml`).

**Out of scope, relied on unchanged:**
- Holdback's rules contract, at Holdback's tag `contracts-phase-one-2` (`978aa38d`), the submodule `lib/holdback`. It had its own outside automated scan and fix review (Holdback's `docs/audit/outside-scan.md`). Its known issues are in its `docs/audit/known-issues.md`.
- Coinbase Commerce Payments (`AuthCaptureEscrow`, `ERC3009PaymentCollector`), and Solady (`LibClone`, `ECDSA`, `EIP712`, `SafeTransferLib`), through Holdback's submodules.
- `script/Deploy.s.sol` and `script/sourcify-verify.mjs`: the deploy and its checks. `test/Deploy.t.sol` and the fork suites test them. They hold no funds. A scan may read them second.
- `client/`: the off-chain thin client.

**Which build is deployed.** Sepolia runs an earlier build, from commit `36485df`, since 2026-11-19 (`deployments/11155111.json`, `deployments/README.md`). It takes the agent's key as the buyer. The scan reads `main`, whose module takes only the vault as the buyer (`VAULT_IS_BUYER`). That build is not deployed, and its deploy waits for the maintainer [documented: `README.md`; `docs/design.md`, section 19, "What waits"].

## 2. Trust model and roles

No function grants power to whoever deploys, creates or relays. No contract has an owner, a pause of its own, an upgrade path, `selfdestruct` or `delegatecall` [measured: `test_defense_noSelfdestructCallcodeOrDelegatecall_inTheVaultFactoryOrModule`, the selector allowlists in `test/Selectors.t.sol`].

| Role | Who | Can | Cannot | Trusted for |
| --- | --- | --- | --- | --- |
| Top principal | The key named at creation, or the key it handed over to | Withdraw anything not in a hold; enable modules and pin their payees; act on every grant; hand the vault over in two steps; sign for the vault on any deal it paid | Reach money in a hold | Everything in its own vault: it is the owner's wallet |
| Controller (agent) | The key of one grant | Pay through an enabled module within its path's limits; pause or close its own grant; when its path may delegate, grant sub-agents, land and cancel slips, create and fill child vaults; manage grants below it; sign for the vault on deals its grant paid while its path is live | Widen, resume or reopen its own grant; withdraw; enable a module; write its own grant's list | Nothing |
| Controller above | The key of a grant higher on the path | What a controller can do, on every grant below it | The same as a controller, for its own grant | Nothing |
| Child vault principal | The controller of the parent grant when the child was created | Manage grants inside the child; return money to the parent | Withdraw; enable modules; hand the child over; widen the child's root | Nothing |
| Enabled module | A contract the top principal enabled, with its pinned payee | Ask the vault to charge a named controller's grant; end commitments it opened; rebuild buyer messages | Move money anywhere but its pinned payee | Naming the right controller (the Holdback module recovers it from the agreement signature) |
| Merchant list | A contract a grant names | Say yes or no for that grant, read-only, within 30,000 gas | Write anything during the call | Whom that grant pays, within every list above it |
| Token | The vault's token | Hold the balances; ask the vault through ERC-1271 | Be approved for anything but the one digest `charge` approved | Being a plain ERC-20 with ERC-3009: no fee on transfer, no rebasing, no hooks, an honest `balanceOf` |
| Factory, deployer | The factory contract and whoever deployed it | Create vaults and child vaults; fix the fee rate and sweeper at deployment | Keep any role in a vault; change the fee | Nothing after deployment |
| Fee sweeper | A contract fixed in the factory | Collect a vault's fee owed and forward it to its fixed destination | Take more than the fee owed; block a payment | Forwarding the fee |
| Anyone | Any address | Create a vault for anyone; relay a signed grant; end a commitment whose deal ended; reclaim a hold after the escrow's expiry, only to the vault; sweep a fee | Anything that moves money elsewhere | Nothing |
| Holdback | The rules contract and its escrow, out of scope | Hold, release and refund holds by the deal's signed terms; ask the vault as the buyer through ERC-1271 | Take money from a vault without a charge | Its own audit's claims |
| Seller, adjudicators | Named in a deal's terms | Act in the deal as Holdback allows | Reach the vault | Nothing (the principal lists them as one counterparty) |

## 3. Invariants and the tests that check them

`test/` already held 479 tests before this pass [measured, `forge test --no-match-path 'test/fork/*'`]. This pass adds:
- 5 end-to-end journeys (`test/e2e/Journeys.t.sol`);
- a stateful campaign through the whole vault system, at a fee of 0 and of 1% (`test/invariant/SystemInvariants.t.sol`, handler `test/invariant/SystemHandler.sol`, 16 invariant tests);
- seeded long simulations through the same handler (`test/invariant/SystemSimulation.t.sol`, 4 tests);
- a campaign and simulations through Holdback's real contracts with the vault as the buyer (`test/invariant/HoldbackInvariants.t.sol`, handler `test/invariant/HoldbackHandler.sol`, 6 tests);
- 6 stateless fuzz and boundary tests on the arithmetic (`test/fuzz/Arithmetic.fuzz.t.sol`);
- 13 tests from this pass's red team (`test/redteam/ReadinessRedTeam.t.sol`);
- 3 tests that pin the second-family review's points (`test/review/SecondFamily.t.sol`), added after the runs of section 4.

The handlers decide beforehand, from the design record and not from the code, whether each call must be refused, and count every call that lands against the model (`violations`) and every allowed call that is refused (`unexpectedRefusals`). Independent ghost counters record what each grant should have counted.

In the tables, "Campaign" names the invariant tests, "Simulation" the seeded runs, and "Unit and attack" a selection of the existing tests by file and name.

### V1. Money conservation and the routes out

No token unit is created or lost. Money leaves a vault only in five ways: the principal's withdrawal, a fill of a child vault, a child's return to its parent, the one ERC-3009 approval to an enabled module's pinned payee for exactly the charged amount, and the fee to the fixed sweeper. No agent or stranger key receives the vault's money while a merchant list on the payment's path names only others. A grant with no list on its path pays whatever counterparty the agent's terms name, its own key included (RT-1).

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariants*.invariant_conservation`, `invariant_moneyLeavesOnlyByItsRoutes`; `HoldbackInvariantsTest.invariant_conservation`; `TreeInvariantsTest.invariant_moneyGoesOnlyToThePinnedPayee` |
| Simulation | `SystemSimulation*` and `HoldbackSimulationTest`, every checkpoint |
| End to end | every journey's `_assertConserved` after each step, and `test_journey_theWholeLifeOfABudget`'s closing ledger |
| Red team, this pass | `redteam/ReadinessRedTeam.t.sol` `test_attack_aHijackedAgentRoutesThePriceToItsOwnKey_refusedAtEveryRoute`, `test_finding_RT1_anUnlistedGrant_paysTheAgentsOwnKey` |
| Unit and attack | `redteam/Approval.t.sol` (`test_attack_agentsOwnOperatorPaysTheAgentFromTheVaultInTheSameTransaction_refused`, `test_attack_spendTheLingeringApprovalASecondTime_refused`, `test_attack_oneVaultsApprovalAnswersForAnotherVault_refused`); `crosscheck/Coverage.t.sol` `test_defense_duringACharge_noTransferCancelOrPermitDigestIsApproved`; `HoldbackModule.t.sol` `test_attack_agentSignsARawAuthorizationForTheVaultsMoney_refused`; `ChildVault.t.sol` `test_moneyGoesBackUpOnly_byTheAgentOrThePrincipal`; `review/Coverage.t.sol` `test_attack_childReturnsToTheCaller_notTheParent_refused` |

### V2. Limits hold across the hierarchy

No payment passes a grant's per-payment, per-period, lifetime or open-commitment limit at its own level. No payment passes the state (paused, closed, expired), the per-payment limit or the merchant list of any grant above it, in this vault or in any ancestor vault. A fill counts against the period and lifetime limits at every level of the vault that fills. A child vault's payments do not count against an ancestor vault's open limit, by design.

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariants*.invariant_noRefusedCallLanded` (each payment and fill against the model), `invariant_everyAllowedCallLanded`; `TreeInvariantsTest.invariant_noGrantPassesItsTotalOrItsPeriod`, `invariant_everyPaymentThatPassedWasInsideItsLimits`, `invariant_aChildNeverPassesItsParent` |
| Fuzz | `Arithmetic.fuzz.t.sol` `testFuzz_perPaymentAndLifetime_atTheExactBoundary`; `redteam/ListRedTeam.t.sol` `testFuzz_attack_everyListOnThePathMustSayYes`; `redteam/FeeAttacks.t.sol` `testFuzz_attack_noLimitIsPassedThroughTheFee` |
| End to end | `test_journey_theWholeLifeOfABudget` (open and daily limits across two venues, a child bound by its parent's list); `test_journey_everyRefusedMove_countsNothing` |
| Unit and attack | `HoldbackModule.t.sol` `test_attack_overPerDeal_refused`, `test_attack_overPerDay_refused`, `test_attack_overLifetime_refused`, `test_attack_tooManyOpen_refused_untilOneCloses`, `test_attack_unlistedPayoutAddress_refused`, `test_attack_listedPayoutWithAnotherAdjudicator_refused`; `Hierarchy.t.sol` `test_attack_aWiderSubAgent_isBoundByTheAgentsPerDeal`, `test_attack_siblingsTogetherPassTheirParent_refused`; `ChildVault.t.sol` `test_attack_childPaymentOverTheParentsPerDeal_refused`, `test_aGrandchildIsBoundByTheTop`; `review/Coverage.t.sol` `test_attack_overTheAgentsLifetime_bySubAgent_refused`, `test_attack_overTheAgentsOpenCount_bySubAgent_refused`; `crosscheck/Coverage.t.sol` `test_observe_aParentGrantsOpenLimit_doesNotBoundItsChildVault` |

### V3. Every level counts exactly what passes through it

`spent` and the open count of every grant equal the sum of the charges and open commitments at or below it. Ending a commitment frees exactly its slot at every level, once, and only through the module that opened it.

| Kind | Tests |
| --- | --- |
| Red team, this pass | `redteam/ReadinessRedTeam.t.sol` `test_observe_aFillAndReturnLoop_burnsTheRootsLifetime_withoutPayingAnyone` |
| Campaign | `SystemInvariants*.invariant_everyLevelCountsWhatPassesThroughIt`; `HoldbackInvariantsTest.invariant_openCommitmentsMatchTheDeals`; `TreeInvariantsTest.invariant_everyLevelCountsWhatPassesThroughIt` |
| Unit and attack | `review/Coverage.t.sol` `test_attack_releaseTwice_refused`; `redteam/Tree.t.sol` `test_attack_closeADealTwiceOrOneTheVaultNeverOpened_refused`; `HoldbackModule.t.sol` `test_attack_releaseByAnotherModule_refused`, `test_closeBeforeTheDealEnds_refused`; `crosscheck/Verify.t.sol` `test_aMovedKeysOpenCommitments_endOnTheOldPath` |

### V4. The delegation switch

With `mayDelegate` false on any grant of a path, here or in an ancestor vault, nobody at or below it grants, creates or fills a child vault, or lands a signed grant. The one exception is the top vault's principal granting, by transaction or by a signed grant (design, open item 13; `review/SecondFamily.t.sol` `test_observe_SF2_theTopPrincipalsSlips_landBelowAGrantWhoseDelegationIsOff`).

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariants*.invariant_noRefusedCallLanded` (every grant, slip, child creation and fill against the model) |
| End to end | `test_journey_theWholeLifeOfABudget`, the switch-off step |
| Unit and attack | `DelegationSwitch.t.sol` (18 tests); `crosscheck/Gaps.t.sol` `test_attack_delegationOff_*` (4 tests); `review/Observations.t.sol` `test_attack_mayDelegateOff_stopsFillingAnExistingChild`; `review/Rereview.t.sol` `test_attack_mayDelegateOffAtTheParent_stillGrantsInsideTheChild_refused`; `crosscheck/Verify.t.sol` `test_attack_delegationOff_agentMovesItsSubAgentsKey_refused` |

### V5. Stops: pause, close, narrowing, unlisting, module switch-off

A stop by authority always lands, whatever came first. A closed grant never reopens, and a slip never gives its key fresh counters. A paused, closed or expired path silences its controller's signature for the vault. Nobody below a grant resumes, widens or reopens it.

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariants*.invariant_everyAllowedCallLanded` (every pause, resume, close and limits change by authority lands), `invariant_closedIsForever_andThePrincipalHoldsTheRoot`, `invariant_noRefusedCallLanded` (no stop or resume without authority); `HoldbackInvariantsTest.invariant_onlyLiveAuthoritySignsForTheVault` |
| End to end | `test_journey_theWholeLifeOfABudget` (pause, owner accepts in the agent's place, switch-off, close); `test_journey_holdsEndByTheirTerms_withoutTheAgent` |
| Red team, this pass | `redteam/ReadinessRedTeam.t.sol` `test_attack_aMovedAgentKey_silencesItsChildVaultsSigners_andMoneyOnlyGoesUp_refused`, `test_attack_aKeyMovedInTheMiddleVault_silencesTheGrandchild_andOnlyAuthorityAboveSigns_refused` |
| Unit and attack | `redteam/FrontRun.t.sol` (17 tests); `HoldbackModule.t.sol` `test_attack_afterPause_refused_andTheAgentCannotResume`, `test_attack_afterClose_refusedForGood_andTheKeyIsFreed`; `VaultBuyer.t.sol` `test_afterAPause_theAgentIsRefused_andThePrincipalAcceptsEarlyInItsPlace` and its close and root-pause twins; `redteam/VaultBuyer.t.sol` `test_attack_theAgentSignsAfterAStopOnItsPath_refused`, `test_attack_aPauseOnAChildVaultsRoot_silencesItsPrincipal`; `redteam/SignedGrant.t.sol` `test_attack_subAgentReturnsAfterThePrincipalClosedItsGrant_refused`; `review/Findings.t.sol` (5 tests) |

### V6. Period accounting

A period is a fixed window, `floor(t / period)`. A payment lands exactly when its window's earlier charges plus itself fit the limit. No change of the period's length hands out a fresh window. A refund gives no period back.

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariants*.invariant_periodCountsItsWindow` (exactly the window's charges while the period is unchanged; at least every charge since the last change otherwise) |
| Fuzz | `Arithmetic.fuzz.t.sol` `testFuzz_aFixedPeriodCountsExactlyItsWindow` (any period up to 2^32 − 1 s, 12 payments and waits), `testFuzz_theWindowBoundary_isExact`; `crosscheck/Verify.t.sol` `testFuzz_oneChange_neverUndercountsTheLastPaymentInTheNewWindow`, `testFuzz_twoChanges_neverUndercountTheLastPaymentInTheNewWindow`, `testFuzz_setCapsNeverOverflows` |
| Unit and attack | `HoldbackModule.t.sol` `test_dayBoundary_oneSecondBeforeRefused_atTheBoundaryFunds`, `test_refundReturnsToTheVault_andDoesNotGiveTheDayBack`; `redteam/Tree.t.sol` `test_attack_ownerChangesThePeriod_agentGetsAFreshWindowAtOnce_refused`; `crosscheck/Gaps.t.sol` `test_attack_lengthenThePeriodTheDayAfter_agentPassesTheNewWeeklyLimit_refused`, `test_observe_lengthenThePeriodAfterTwoDaysOfSpend_countsOnlyTheLastDay` (open item 12); `Arithmetic.fuzz.t.sol` `test_observe_theWindowEndWrapsOnlyNearTheYear36812` (V-I1) |

### V7. Factory and clone safety

A vault is exactly the library's minimal proxy for one implementation, at an address fixed by the principal, the token and a salt. Nobody can initialize the implementation or a vault twice. A second creation returns the existing vault. Only a vault of the factory creates a child. A child vault's parent and parent grant are fixed. Whoever creates a vault gets no power.

| Kind | Tests |
| --- | --- |
| End to end | `JourneyBase._openOwnersVault`: a stranger creates the owner's vault at its predicted address and holds no grant |
| Red team, this pass | `redteam/ReadinessRedTeam.t.sol` `test_attack_aCloneOutsideTheFactory_movesNothingOfTheRealVault_refused` |
| Unit and attack | `CrestFactory.t.sol` (5 tests); `crosscheck/Coverage.t.sol` `test_defense_aVaultIsExactlyTheMinimalProxyForTheImplementation`, `test_defense_zeroPrincipalTokenOrControllerRefused`; `redteam/Tree.t.sol` `test_attack_anotherVaultTakesTheAgentsChildAddressFirst_refused`, `test_attack_aVaultTheFactoryDidNotMakeClaimsThePrincipalsRootAsItsParent`, `test_attack_createTheAgentsChildAgain_resetsNothing`; `ChildVault.t.sol` `test_attack_aChildMadeOutsideAVault_refused`; `Selectors.t.sol` (4 tests); `Deploy.t.sol` (8 tests) |

### V8. Signatures and replay

A signed grant lands exactly where its signer's `grant` would. It lands once, for a fresh key, before its deadline, and only on this vault and chain. The vault answers the token through ERC-1271 only for the one digest `charge` approved in the same transaction. It answers anyone else only for a Holdback buyer message, rebuilt by an enabled module, for a deal this vault paid or will pay, and signed by live authority over the grant that paid. Nothing replays across deals, vaults, chains or domains.

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariants*.invariant_noRefusedCallLanded` (each slip against `grant`'s rule and freshness, then replayed, which must fail); `HoldbackInvariantsTest.invariant_onlyLiveAuthoritySignsForTheVault` |
| Fuzz | `redteam/SignedGrant.t.sol` `testFuzz_attack_aSlipLandsExactlyWhereItsSignersGrantWould` and its child-vault twin; `redteam/ListRedTeam.t.sol` `testFuzz_attack_aSlipPaysOnlyWhatItsSignerCouldPayNow`; `fuzz/HoldbackDigest.fuzz.t.sol` `testFuzz_theVaultsDigestMatchesTheCollectors` |
| End to end | `test_journey_signedGrantsThenAHandover` |
| Red team, this pass | `redteam/ReadinessRedTeam.t.sol` `test_attack_RT2_theFeesPendingFlags_getANoFromTheToken_refused` (named `test_finding_RT2_theTokenGetsAYesForTheFeesPendingFlag` at `vault-stable-1`, where it asserted the yes), `testFuzz_attack_afterAFeePayment_theTokenGetsANoForEveryOtherHash`, `test_attack_aSecondRulesDeployment_sharesNoSlotNoEndAndNoSignature_refused`, `test_attack_anEndedDealsTermsSignedAgainByASibling_fundNothing_refused`, `test_attack_aKeyNamedInATombstone_gainsNoPowerToPayDelegateOrSign_refused` |
| Unit and attack | `SignedGrant.t.sol` (38 tests); `redteam/SignedGrant.t.sol` (37); `VaultBuyer.t.sol` (22) and `redteam/VaultBuyer.t.sol` (27), which hold the nine attacks of design section 12; `review/Coverage.t.sol` `test_attack_anApprovedDigestAskedByANonToken_answersNo`, `test_attack_theApprovalUsedTwiceOrForMore_refused` |

### V9. External calls, reentrancy and gas

No token, list, sweeper, module, child vault or venue callback can re-enter to move money, count twice or skip a check. A transient approval cannot be reused for another payment or by another vault. Starving a call of gas cannot turn a list's answer or a buyer answer into a yes.

| Kind | Tests |
| --- | --- |
| Unit and attack | `Fee.t.sol` `test_attack_aHostileSweeperTakesMoreOrTwice_orReenters`; `redteam/FeeAttacks.t.sol` `test_attack_aDestinationThatReentersTheSweep_getsOnlyTheFeeOwed`, `test_attack_twoApprovalsBeforeAnyPull_leaveTheVaultShortOfItsFee`; `review/Fee.t.sol` `test_attack_twoChargesBeforeEitherPull_refused`; `redteam/ListRedTeam.t.sol` `test_attack_aListThatCallsBackIntoTheVaultAndTheDefaultList_onlyReads`, `test_attack_aReturnDataBombAboveAChild_onlyRefuses`, the starving tests (8); `review/List.t.sol` `test_review_aListThatWrites_isRefusedByTheStaticcall`; `redteam/VaultBuyer.t.sol` `test_attack_aStarvedBuyerAnswer_isANo_andHoldbackRefuses`; `redteam/Approval.t.sol` the ERC-6492 and Multicall3 hook attacks (3) |
| Not in a campaign | The campaigns use the default list and a plain mock token, so hostile lists and tokens are covered by the unit and attack tests only |

### V10. Token edge cases, within the stated assumption

A token that returns false or reverts, or a sweeper or destination the token refuses, blocks no payment, withdrawal or stop and moves nothing it should not.

| Kind | Tests |
| --- | --- |
| Unit and attack | `review/Fee.t.sol` `test_aForwardTheTokenAnswersFalse_leavesPaymentsUntouched`, `test_attack_aSweeperTheTokenRefuses_blocksNoPaymentWithdrawalOrStop`; `Fee.t.sol` `test_aForwardTheTokenRefuses_leavesPaymentsUntouched`; `redteam/FeeAttacks.t.sol` `test_attack_aBalanceOfThatSaysZero_blocksNoWithdrawalWhileNothingIsOwed`, `test_observe_aBalanceOfThatSaysMore_isTheTokensRisk` |
| Fork, not run in this pass | `fork/UsdcFork.t.sol` runs through Circle's USDC on a fork of Sepolia and needs an RPC. This pass touched no RPC |
| Not tested | Tokens with a fee on transfer, rebasing or hooks: outside the stated assumption |

### V11. The hold

Nothing the vault, its principal, its agents or its fee does moves or shrinks money already in a Holdback hold. Every funded hold ends by the deal's terms: a decision, an early accept, a settlement, a refund at the delivery deadline, or the escrow's own reclaim after its expiry, which returns money only to the vault. A hold receives exactly its terms at any fee.

| Kind | Tests |
| --- | --- |
| Campaign | `HoldbackInvariantsTest.invariant_theEscrowHoldsExactlyTheOpenHolds`, `invariant_onlyLiveAuthoritySignsForTheVault` |
| Simulation | `HoldbackSimulationTest.test_simulation_fixedSeed_reachesEveryOutcome`, `testFuzz_simulation_anySeed` |
| Red team, this pass | `redteam/ReadinessRedTeam.t.sol` `test_attack_aChildDealAtExpiry_freesItsSlotsOnce_andTheReclaimReturnsOnlyToTheChild_refused` |
| End to end | `test_journey_theWholeLifeOfABudget` (deal E refunds after the owner empties the vault); `test_journey_holdsEndByTheirTerms_withoutTheAgent` |
| Unit and attack | `HoldbackModule.t.sol` `test_neutrality_ownerEmptiesTheVaultAfterFunding_dealStillReleased`, `test_reclaimAfterTheEscrowsExpiry_returnsTheHoldToTheVault`, `test_attack_reclaimForAnotherPayer_refused`; `redteam/Neutrality.t.sol` (5 tests); `redteam/FeeAttacks.t.sol` `testFuzz_attack_theHoldReceivesExactlyItsTerms_atAnyRate` |

### V12. Authority

Only the top principal withdraws, enables modules and hands the vault over, in two steps, and a handover takes every power from the previous key. Only authority strictly above a grant changes its limits, lifts its pause or writes its list. A grant's own controller may only pause or close it.

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariants*.invariant_noRefusedCallLanded` (withdrawals, pauses, closes, limits changes, list writes, take-backs, returns and cancels against the model; a key that was not proposed accepting), `invariant_closedIsForever_andThePrincipalHoldsTheRoot` |
| End to end | `test_journey_signedGrantsThenAHandover`; `test_journey_everyRefusedMove_countsNothing` |
| Unit and attack | `Hierarchy.t.sol` `test_thePrincipalRoleMovesInTwoSteps_andTheOldPrincipalLosesTheRoot`; `HoldbackModule.t.sol` `test_attack_agentWithdraws_widens_listsOrEnables_refused`, `test_attack_strangerGrantsOrPauses_refused`; `review/Rereview.t.sol` `test_attack_aSelfHandoverClosesTheRoot_refused`; `redteam/Tree.t.sol` `test_attack_agentTakesTheProposedPrincipalsKeySlot_blocksTheHandover`; `List.t.sol` `test_theDefaultList_isWrittenOnlyByAuthorityAboveTheGrant` |

### V13. The fee

The rate and the sweeper are fixed in the factory. The fee is `floor(amount × rate / 10,000)`. It counts against every limit on the path, is owed and not moved at payment time, is collected exactly and only to the fixed sweeper, and can never be taken by a withdrawal, fill or return.

| Kind | Tests |
| --- | --- |
| Campaign | `SystemInvariantsFeeTest.invariant_feesOwedAreCovered`, `invariant_moneyLeavesOnlyByItsRoutes` (at 1%); `SystemInvariantsNoFeeTest.invariant_feesOwedAreCovered` (at 0, nothing is ever owed) |
| Fuzz | `Arithmetic.fuzz.t.sol` `testFuzz_theFeeAtItsExactBoundary` (any rate from 1 to 10,000), `testFuzz_theLargestAmounts_areRefusedByName`; `Fee.t.sol` `testFuzz_theFeeRoundsDown_andNeverPassesTheRate`; `redteam/FeeAttacks.t.sol` (4 fuzz tests) |
| End to end | `test_journey_aFactoryWithAFee` |
| Unit and attack | `Fee.t.sol` (21 tests), `redteam/FeeAttacks.t.sol` (29), `review/Fee.t.sol` (13) |

## 4. What was run

All runs were on Foundry's in-process chain (chain ID 31337), with no RPC and no key, on 2026-11-25 [measured].

**The whole suite:** `forge test --no-match-path 'test/fork/*'` passed 529 of 529 in 77 s: the 479 earlier tests and this pass's 50. Plain `forge test`, as CI runs it, passed 529 and skipped the 4 fork tests, which need an RPC.

**In-file settings (CI's).**

| Suite | Settings | Calls per invariant |
| --- | --- | --- |
| `SystemInvariantsNoFeeTest`, `SystemInvariantsFeeTest` | 64 runs, depth 100 | 6,400 |
| `HoldbackInvariantsTest` | 32 runs, depth 60 | 1,920 |
| `SystemSimulation*`, `HoldbackSimulationTest` | the fixed seed (3,000 and 1,200 moves), and 4 random seeds (1,500 and 600 moves each) | every invariant checked every 25 and 20 moves |
| `TreeInvariantsTest` (earlier) | 256 runs, depth 500 | 128,000 |
| Fuzz tests | 256 runs (`foundry.toml`) | |

**The deep campaign:** `FOUNDRY_PROFILE=deep forge test --match-path 'test/{invariant,fuzz}/*'` passed 38 of 38 in 965 s (20 minutes on a laptop), 0 failed.

| Suite | Runs | Depth | Calls per invariant | Result |
| --- | --- | --- | --- | --- |
| `SystemInvariantsNoFeeTest` (8 invariants) | 500 | 200 | 100,000 | pass |
| `SystemInvariantsFeeTest` (8 invariants) | 500 | 200 | 100,000 | pass |
| `HoldbackInvariantsTest` (4 invariants) | 250 | 100 | 25,000 | pass |
| `TreeInvariantsTest` (5 invariants, earlier) | 1,000 | 200 | 200,000 | pass |
| `SystemSimulation*.testFuzz_simulation_anySeed` | 49 seeds each | 1,500 moves | every invariant every 25 moves | pass |
| `HoldbackSimulationTest.testFuzz_simulation_anySeed` | 49 seeds | 600 moves | every check every 20 moves | pass |
| `Arithmetic.fuzz.t.sol` (5 fuzz tests), `HoldbackDigest.fuzz.t.sol` | 20,000 each | | | pass |

The deep campaign ran before the handler's slips began trying retired keys (M6 below). With that change, the CI settings and both fixed-seed simulations pass [measured].

`reverts: 0` in the campaign lines means no handler call reverted: the handlers catch every refusal and judge it against the model.

**What the campaigns reach.** A campaign that never pays proves nothing, so the fixed-seed simulations assert that they reach every kind of move. At seed `0xC0FFEE`, 3,000 moves landed about 145 payments, 38 fills of a child vault, 11 grants and 5 slips. They also landed 30 stops, 118 handovers and changes of the period's length, and at a fee of 1% they charged and collected fees. At seed `0xBEEF`, 1,200 moves funded 61 deals: 3 released, 28 refunded, 5 settled, and 1 settled or released by authority signing in a stopped grant's place [measured: the tests' logs and assertions].

**The first deep pass found a defect in a test, not in the vault.** `testFuzz_theWindowBoundary_isExact` warped to time 0 for a period longer than the current time, where the mock token refuses any authorization. The test now enters such a window one second in [measured].

**Do the new suites catch defects?** 12 one-line mutants of `src/CrestVault.sol` were planted one at a time in a copy of the repository. For each, the new suites ran: the journeys, the arithmetic fuzz and the four simulations at their fixed seeds. A mutant is killed when at least one of them fails.

| Mutant | What it plants | Killed by |
| --- | --- | --- |
| M1 | the open count is not incremented | 7 tests, the journeys and both fixed-seed simulations among them |
| M2 | the window's end is written as its start, so every payment opens a fresh window | 6, among them the arithmetic period fuzz and the whole-life journey |
| M3 | a child vault's payment skips the parent vault's path | 3 |
| M4 | a fill skips the delegation switch | 1, the whole-life journey |
| M5 | a controller may resume its own grant | 3 |
| M6 | a slip lands for a key whose grant was closed | at first none of the new suites. 6 earlier signed-grant tests kill it (`test/SignedGrant.t.sol`, `test/redteam/SignedGrant.t.sol`). The campaign's slips now try retired keys one time in three, and both fixed-seed simulations kill it since |
| M7 | the fee is not added to the fee owed | 3, among them the fee journey |
| M8 | a withdrawal may take the fee owed | 1, the fee journey |
| M9 | any key with a grant signs for the vault | 4, among them the Holdback simulation |
| M10 | an ended commitment is not deleted | 2 |
| M11 | a path walk ignores a pause | 3 |
| M12 | a payment skips the merchant list | 3 |

12 of 12 killed [measured: `forge test` with each mutant, then without it; the copy was restored and compared with `src/` after each]. The runner and the trimmed copy stayed outside the repository.

## 5. What is not tested

[inferred, from the handlers and the test list]
- **Holdback's fallback, escalation and default paths with the vault as the buyer** are not driven by a campaign. The Holdback handler drives fundings, deliveries, the primary's accept and reject, early accepts, settlements, the refund at the delivery deadline and the escrow's reclaim after its expiry. Holdback asks the buyer for no signature on the other paths, so the vault is not consulted there [inferred from `HoldbackRules.sol`]. One unit test reaches an escalation (`review/Coverage.t.sol` `test_closeWhileEscalated_refused`).
- **Child vaults deeper than one level** appear in the campaign only as created and empty. Grandchild vaults are covered by unit and attack tests: `ChildVault.t.sol` `test_aGrandchildIsBoundByTheTop`, `redteam/Tree.t.sol`, `redteam/FeeAttacks.t.sol` `test_attack_aGrandchildPays_oneFee_countedAtEveryLevelAbove`, `DelegationSwitch.t.sol`, and the gas tests at depth 4 in `VaultBuyer.t.sol`.
- **Hostile lists, tokens, sweepers and modules** are not in a campaign. They are covered by unit and attack tests only (V9, V10). A module the principal enables is trusted by design.
- **More than one enabled module at once** is not in a campaign. A module without `VAULT_IS_BUYER` beside the vault-buyer module reopens the agent's own-key route (section 8).
- **Real USDC and live Holdback contracts.** The fork suites (`test/fork/`) need a Sepolia RPC and were not run in this pass. They last passed on 2026-11-19 at block 12,171,150 [documented: `docs/design.md`, section 19].
- **Formal verification** and **systematic mutation testing**: none. This pass ran 12 hand-picked mutants (section 4). A re-review on 2026-11-19 ran 13 one-line mutants [documented: `docs/design.md`, section 8].
- **A second review by a model from another family**, recommended for sections 18 and 19 of the design, has not run [documented].
- **Gas limits at depth.** The vault's buyer answer and `checkPath` walk every ancestor vault, with no depth limit (parametrize, don't restrict). Measured up to depth 4 [documented: `docs/design.md`, section 19, point 3]. A very deep tree costs its own caller more gas.

## 6. Static analysis

Both tools ran on `src/` at `821f5f7` with the dependencies, `test/` and `script/` filtered out, on a copy of the repository [measured, 2026-11-25]. No finding holds on reading: each is either intended or unreachable [inferred, reading each location].

**Slither 0.11.6**: 50 results, none of High impact.

| Detector | Impact | Count | Reading |
| --- | --- | --- | --- |
| `divide-before-multiply` | Medium | 1 | `_chargeOne`'s `block.timestamp / c.period * c.period` is the window's start, a floor by design (V6) |
| `unused-return` | Medium | 1 | `CrestFeeSweeper.sweep` ignores `collectFee()`'s return on purpose and reads its own balance, so it forwards what it holds (design, section 14) |
| `timestamp` | Low | 17 | Expiries and windows are time by design; the comparisons are not randomness |
| `shadowing-local` | Low | 4 | Interface parameter names `principal`, `token` and `parent` shadow getters; no effect |
| `missing-zero-check` | Low | 3 | `feeSweeper` may be 0 at a rate of 0; `parent_` is 0 for a top vault; a zero `proposed` principal can never accept |
| `calls-loop` | Low | 1 | `pathLive` asks the parent vault, a vault of the same factory |
| `reentrancy-events` | Low | 2 | `reclaim` and `sweep` emit after a call to the escrow or the vault; no state follows the call |
| `assembly`, `low-level-calls`, `naming-convention` | Info | 21 | Transient storage, the gas-capped list call, the module's self-`staticcall`, and immutables in capitals |

**Aderyn 0.6.8**: 1 High and 7 Low detectors.

| Detector | Locations | Reading |
| --- | --- | --- |
| H-1, state change after an external call | `CrestAllowList.set`; `CrestFactory.createChild`; `CrestVault.createChild`; the module's constructor | False positives. `set` writes only under the calling vault's own address after asking it. The factory reads `token()` from a vault it made (`isVault` is checked first). `createChild` calls only the factory. A constructor cannot be re-entered |
| L-1, L-5: costly operations and reverts in loops | the path walks | By design: every level is charged and checked |
| L-2: division before multiplication | the window's start | As Slither's |
| L-3, L-4: literals | constants inline | Style |
| L-6: address set without a check | `initialize`, `proposePrincipal` | As Slither's `missing-zero-check` |
| L-7: unchecked return | `sweep` | As Slither's `unused-return` |

## 7. Findings from this pass

This pass changed nothing in `src/`. No test showed money moving past a limit, outside a deal's terms or out of a hold, so no test is kept failing or skipped. Severity follows the usual scale: Critical, High, Medium, Low, Info.

| ID | Finding | Severity | Status | Test |
| --- | --- | --- | --- | --- |
| RT-1 | A grant with no merchant list anywhere on its path pays whatever counterparty the agent's terms name, the agent's own key included. The agent writes the terms, signs as seller, adjudicator and buyer, delivers and accepts early; the price reaches its key. The design record's section 18 said no path sends money to the agent's key. The limits still bound it; with the default list on the grant the same terms are refused (`CounterpartyNotAllowed`). | Low (red team): within the limits and the terms, but it contradicted a stated claim a principal could rely on | Documented: section 18 of `docs/design.md` is corrected in this pull request. Decided: a list stays optional, with no default (Rafa, 2026-11-25); known limit K-17 | `test_finding_RT1_anUnlistedGrant_paysTheAgentsOwnKey` (asserts the behaviour) |
| RT-2 | The vault's ERC-1271 answer to the token reads any transient slot that holds 1, and the fee's pending flag sits in the same transient space at the fixed slot `keccak256("crest.vault.pending.set")`. After a payment with a fee, the token gets a yes for that one hash. An honest token asks only for digests it builds from typed data, so reaching the slot needs a keccak preimage | Info: moves nothing; every other hash gets a no (fuzzed, 256 runs) | Decided: fixed in the next contract version, not in the build this page scopes (Rafa, 2026-11-25). The branch `next-version` keys each approval as `keccak256(abi.encode(APPROVAL_TAG, digest))` (design, section 20); it ships in a new factory | `test_attack_RT2_theFeesPendingFlags_getANoFromTheToken_refused` (named `test_finding_RT2_theTokenGetsAYesForTheFeesPendingFlag` at `vault-stable-1`, where it asserted the yes), `testFuzz_attack_afterAFeePayment_theTokenGetsANoForEveryOtherHash` |
| V-I1 | `windowEnd` is 40 bits. Within one period of 2^40 s (the year 36,812) a window's end no longer fits, the stored end wraps, and every payment starts a fresh window | Info: unreachable on any chain for about 34,000 years | Decided: not fixed; a known Info item (Rafa, 2026-11-25) | `test_observe_theWindowEndWrapsOnlyNearTheYear36812` |
| RT-O1 | Filling a child vault and returning the money, day after day, spends the root's and every ancestor grant's lifetime with no money leaving: fills count, returns give nothing back. A sibling agent is then refused until the principal raises the limit | Info: the agent's own limits bound it; one line for the owner's guide | Acknowledged by the maintainer (Rafa, 2026-11-25); no change | `test_observe_aFillAndReturnLoop_burnsTheRootsLifetime_withoutPayingAnyone` |
| RT-O2 | Once a deal's commitment ends, the vault forgets it, and a live grant's yes on that deal's terms or agreement passes the dry run again. Holdback never funds a deal twice (`WrongStage`) | Info | Acknowledged by the maintainer (Rafa, 2026-11-25); no change | `test_attack_anEndedDealsTermsSignedAgainByASibling_fundNothing_refused` |
| RT-O3 | A key named in a `cancelSignedGrant` record has `authorityOver` that closed record and can nest further records under it: `Closed` events, and IDs no grant can ever use. It cannot pay, grant, widen, resume or sign | Info: off-chain indexers should expect it | Acknowledged by the maintainer (Rafa, 2026-11-25); no change | `test_attack_aKeyNamedInATombstone_gainsNoPowerToPayDelegateOrSign_refused` |
| RT-O4 | A note is carried byte for byte, hidden Unicode tag characters included, and grants nothing. Off-chain tools that show notes to a model must treat them as untrusted text | Info | Acknowledged by the maintainer (Rafa, 2026-11-25); no change | `test_attack_aNoteWithHiddenUnicodeTags_isCarriedVerbatim_andGrantsNothing_refused` |

**What the red team tried that held** [measured, 13 tests]: every route a hijacked agent has to its own key with a list on its grant; a clone of the implementation made outside the factory, naming the real vault as its parent; a second Holdback rules deployment whose commitment IDs collide with the first's; a key moved mid-flight, with deals open in a child and in a grandchild vault; a child vault's deal at the escrow's expiry; and the token's answer for every other hash after a fee payment. It found by reading [inferred] that every external call made during `charge`, `fundChild` and `isValidSignature` goes to a view function and compiles to `STATICCALL`, so nothing re-enters between a charge and its pull.

**A second review from another model family** (DeepSeek, 2026-11-25) read `src/` at `main` `7fbeed4`. The coordinator verified each of its 194 claims against the code; the verification table is kept privately. One claim stands as an Info finding and two as documentation points. None moves money outside a deal's terms, past a limit or out of a hold [documented: the verification; measured: the tests below].

| ID | Finding | Severity | Status | Test |
| --- | --- | --- | --- | --- |
| SF-1 | `reclaim` asks for an enabled module (`CrestVault.reclaim`, line 322 at `vault-stable-1`), so switching a module off while it has funded holds also shuts the vault's own escrow reclaim through it until the principal enables it again. Holdback's own timeouts still return every hold to the vault (`reclaim` at the delivery deadline, the fallback turn and the default), and the module still ends its commitments | Info | Documented: known limit K-18, and one line for the owner's guide | `review/SecondFamily.t.sol` `test_observe_SF1_aDisabledModule_shutsTheVaultsOwnReclaim_andHoldbacksTimeoutsStillReturnTheHolds` |
| SF-2 | This page's V4 said the top principal's exemption from the delegation switch applies to grants by transaction. It applies to its signed grants too, as `ICrestVault.sol` and design section 2 say | Documentation | Corrected here and in the design record (section 2, open item 13) | `test_observe_SF2_theTopPrincipalsSlips_landBelowAGrantWhoseDelegationIsOff` |
| SF-3 | Design section 18 said a narrowing binds every grant below from the next payment. A child vault keeps spending money filled before the narrowing; a pause on the parent grant stops it and a take-back returns the rest | Documentation | Corrected in design section 18; known limit K-19 | `test_observe_SF3_aChildSpendsAFillMadeBeforeANarrowing_untilAPauseOrATakeBack` |

A second pass by the same model family read the branch `next-version` at `f06063c` (2026-11-25, 59 claims; the verification is kept privately). It confirmed one more item, which is in this page's build too:

| ID | Finding | Severity | Status | Test |
| --- | --- | --- | --- | --- |
| SF-4 | With a fee, an enabled module that charges without pulling in the same call, and that also holds authority to move money, can withdraw, fill a child or return to the parent before the token pulls. The vault is then left short of its fee owed | Low: an enabled module is trusted; the Holdback module pulls in the same call; at the deployed rate of 0 nothing is owed | Known limit K-20 in this build; fixed on `next-version` (design, section 20) | `review/Pr21SecondFamily.t.sol` (on `next-version`) |

One claim was corrected by the verification and needs no change: the Holdback module's `uint120` cast of a hold's amount truncates rather than reverts, and Holdback then refuses the hold (`Unrepresentable`), so it fails safely (`redteam/Approval.t.sol` `test_attack_termsWhoseHoldTheModuleTruncates_failClosed`).

## 8. Known limits: do not report these as new

Each is documented with its reason and its bound. A scan finding that only restates one of them is a known limit.

| ID | Limit | Where it is recorded | Bound |
| --- | --- | --- | --- |
| K-1 | With a module deployed without `VAULT_IS_BUYER` (the Sepolia build at `36485df`), the agent's key is the deal's buyer and can still accept early a delivered hold after every stop | `README.md`, "A known limit"; design, sections 18 and 19 | The deal's price, to a listed merchant. The scanned build's module refuses such terms (`BuyerNotTheVault`); enable only that module |
| K-2 | Lengthening a period counts only the last short window paid in (open item 12) | design, Open 12; `test_observe_lengthenThePeriodAfterTwoDaysOfSpend_countsOnlyTheLastDay` | Only authority above the grant changes a period; the lifetime limit and every grant above keep their own counters |
| K-3 | The top principal cannot create or fill a child below a grant whose delegation is off (open item 13) | design, Open 13 | Fail-closed; `withdraw` to the child works |
| K-4 | An agent can lift a principal's pause on the agent's own sub-agent, or regrant its key (open item 14) | design, Open 14; `review/Observations.t.sol` `test_observe_theAgentLiftsThePrincipalsStopOnItsSubAgent` | The agent's own limits; the principal pauses the agent, or switches its delegation off and closes the sub-agent |
| K-5 | The open-commitment limit does not count a child vault's commitments in the parent | design, section 2; `test_observe_aParentGrantsOpenLimit_doesNotBoundItsChildVault` | The period and lifetime limits |
| K-6 | The vault's buyer answer accepts a high-`s` twin of a valid ECDSA signature | design, section 19; `test_observe_aHighSTwinOfAValidSignature_isAlsoAYes` | No identity is keyed on signature bytes |
| K-7 | The module field inside the vault's buyer signature is not signed | design, section 19 | The other module must rebuild the same digest and, for a funded deal, be the one that paid |
| K-8 | A settlement digest names no buyer | design, section 19 | The vault answers only for deals it paid |
| K-9 | Any agent with a grant in a vault can fund terms another agent of the same vault negotiated, charged to its own grant | design, section 19, red team Low | Its own limits; give agents separate child vaults where that matters |
| K-10 | Contract principals cannot sign for the vault; signers are ECDSA keys | design, section 19 | A multisig acts by transaction |
| K-11 | A list entry outlives its writer's authority; a list with no code refuses until it has code; a slip naming the default list pays no one until listed | design, section 15 | Fail-closed |
| K-12 | A refunded hold keeps its fee owed; a payment too small for the rate owes 0; `collectFee` pays all or nothing | design, Open 1 | At most the stated rate; the deployed rate is 0 |
| K-13 | A token whose `balanceOf` lies can let a withdrawal take the fee owed; a token issuer's freeze or pause | design, section 14 | The principal chooses the token; out of scope |
| K-14 | The delegation switch is on the chain only: a contract controller with its own session keys, or a shared private key, still lets new keys act | design, Open 13, "The delegation switch" | The controller's own limits |
| K-15 | A slip's holder can land it before a cancel lands | design, section 17 | Short deadlines; a close still stops the landed grant |
| K-16 | Holdback's own known issues | Holdback's `docs/audit/known-issues.md` | As recorded there |
| K-17 | A grant with no merchant list anywhere on its path pays whatever counterparty the agent's terms name, the agent's own key included (RT-1). A list is optional, with no default (Rafa, 2026-11-25) | section 7, RT-1; design, section 18 | The grant's period and lifetime limits, and every limit above it; a principal who wants the agent's own keys excluded sets a list |
| K-18 | With a module switched off, the vault's own escrow `reclaim` through it is refused (`ModuleNotEnabled`) until the principal enables it again (SF-1) | section 7, SF-1 | None lost: Holdback's own timeouts return every hold to the vault, and the module ends its commitments |
| K-19 | A narrowing does not bind a child vault spending money filled before it: a child's payment checks the parent path's state, expiry, per-payment limit and lists, not its period or lifetime counters (SF-3) | section 7, SF-3; design, section 18 | What was filled; a pause on the parent grant stops the child at once, and a take-back returns the rest |
| K-20 | With a fee, V13's "never taken by a withdrawal, fill or return" holds when the module pulls in the same call as its charge. A module that charges and pulls later, and holds authority to move money, can leave the vault short of its fee owed (SF-4) | section 7, SF-4 | The fee, at the stated rate; the Holdback module pulls in the same call; the deployed rate is 0; fixed on `next-version` |
| K-21 | At a rate above 0, the fee is owed when the vault approves a payment, not when the token pulls it. An enabled module that charges with a nonce the token has already spent, or abandons a charge, leaves the vault owing the fee for a payment that never left (design, section 20, O-4) | design, section 20; `test/redteam/Sf4RedTeam.t.sol` | At most the rate times that amount; it needs an enabled module, which is trusted; the Holdback module's nonces come from unique deals; nothing is owed at the deployed rate of 0. Smallest fix: refuse in `charge` a nonce the token reports as used. Take it with the next contract version, or before any factory with a rate above 0 (coordinator's call, 2026-11-25) |

## 9. Before submission

**Ready for the scan** [inferred from the sections above]:
- The scope, the trust model and 13 invariants, each mapped to the tests that check it.
- 529 tests pass, 50 of them new, and the deep campaign passes 38 of 38. The new suites catch all 12 planted mutants.
- Static analysis is triaged, and the known limits are listed so the scan can tell them from new findings.

**Decided:**
- RT-1's default. A merchant list on an agent's grant stays optional, and neither onboarding nor the deploy script sets one by default (Rafa, 2026-11-25). The behaviour is by design ("no list means anyone"); the claim that contradicted it is corrected, and K-17 records the limit.
- RT-2 and V-I1 (Rafa, 2026-11-25). RT-2 is fixed in the next contract version, on its own branch, after this build is tagged as the stable one; V-I1 stays a known Info item. The scan reads this build with both recorded here.
- The second review from another model family ran on 2026-11-25 (section 7, SF-1 to SF-3), and its documentation points are corrected. Its pass over `next-version` found SF-4, recorded here as K-20 and fixed in the next version.

**Not ready, or the maintainer's to decide:**

1. **Open items 12, 13 and 14** carry recommendations from 2026-11-24 (document, no change) that the maintainer has not yet confirmed.
2. **Which build the scan reads.** `main` (this page's scope) is not the build deployed on Sepolia (`36485df`). Scanning `main` matches Holdback's practice of having the scan read the next build.
3. **The fork suites** were not rerun in this pass, because it touched no RPC. Run them once against a Sepolia fork before the submission.
