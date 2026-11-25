# Crow Vault

Spend controls for AI agents, enforced on chain.

This repository is Crow Vault, formerly `crest`, at `github.com/rafaeldavid/crow-agent-vault`. It was renamed on 2026-11-21.

A principal's vault holds the money. Each agent, and each agent's short-lived sub-agents, gets a grant with limits no wider than its parent's: the most per deal and per period, a total, how many deals may be open at once, approved merchants tied to their payout addresses, an expiry and a stop. Every payment is checked and counted at every level up to the principal, in the transaction that commits the money, so no agent can spend past any level above it. The principal takes back any money not yet committed and stops any agent at once.

Crow Vault knows how to pay; it knows nothing of what it pays for. A module per venue says what a payment is. The first module pays a hold in Holdback, the escrow behind Crow, whose contracts Crow Vault uses unchanged.

**State:** design and first build, on test networks only. No real money. Not audited: unreviewed.

**Deployed on Sepolia, a test network, since 2026-11-19.** The addresses are in `deployments/11155111.json`. Its Holdback module pays holds in the Holdback rules contract that record names. Nowhere else.
- **Source verified on Sourcify:** an exact match for the runtime and the creation code of all four contracts [measured, 2026-11-19]. `node script/sourcify-verify.mjs` checks the chain against this checkout's build, and with `--submit` sends the sources through Sourcify's API v2, with no key.
- **No fee.** The factory charges a rate of 0 and names no sweeper (address 0), so no fee can ever be owed. A factory with a real rate needs the maintainer's sweeper address first, and is a new factory at a new address. `verify()` for this one runs from commit `36485df`, the deployed code, with `CREST_FEE_BPS` and `CREST_FEE_SWEEPER` unset. Later commits deploy the vault as the buyer: a new factory and a new module at new addresses.
- **A known limit of this version.** The agent's key is the deal's buyer, and the vault only pays. So after every stop (a pause, a close, an empty vault), that key can still accept early a funded hold whose merchant has signed a delivery. A stop prevents new payments; it does not reach a deal already funded. The vault-as-buyer build closes this limit. It ships as a new factory.

- `docs/design.md`: the design record and the decisions still open.
- `docs/audit/readiness.md`: the scope, trust model and invariants for an outside scan, each invariant mapped to its tests, with the recorded runs, the static analysis and the known limits.
- `docs/research/`: the research behind it.
- `src/`: the vault, its factory and the Holdback module, with descriptions in their interface files.
- `test/`: the tests, attack tests included: each limit is proven by an attempt to break it that fails.
- `script/Deploy.s.sol`: deploys the factory and the Holdback module on Sepolia or a local chain, and refuses any other chain. It asks the RPC which chain it is on, and on Sepolia it takes the rules contract from Holdback's pinned record. `run` deploys whatever is missing and checks it; `verify`, run without `--broadcast` after the deploy, checks the chain and writes `deployments/<chain id>.json`. Deploys wait for the maintainer.
  - **Gas on Sepolia.** Contract creation costs about seven times what forge's local simulation estimates, and a fork rehearsal does not show it. The first deploy needed `--gas-estimate-multiplier 900` [measured, 2026-11-19].

```sh
git submodule update --init --recursive
forge test
CREST_FORK_URL=<sepolia-rpc-url> CREST_FORK_BLOCK=<a block behind the head> forge test --match-path 'test/fork/*'   # the deploy rehearsal on a fork of Sepolia
CREST_CHAIN1_URL=<rpc-url-of-anvil---chain-id-1> forge test --match-contract DeployOnChainOneTest   # the mainnet refusal
```
