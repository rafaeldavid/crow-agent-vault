# Crest's deployments

`<chain id>.json` is what `script/Deploy.s.sol`'s `verify()` writes. A later `verify()` rewrites it, so this file keeps each deployment's provenance.

## Sepolia (chain 11155111), since 2026-11-26: the vault as the buyer

**State: deployed, checked on chain and verified on Sourcify.** Test tokens only. `11155111.json` holds this deployment's addresses.

- **Code:** `main` at `8decee3`, built from a fresh recursive clone; the build gave the same CREATE2 addresses as the rehearsal [measured].
  - The module takes only the vault as the buyer (`VAULT_IS_BUYER` true).
  - The build includes the next version's fixes after the stable tag `vault-stable-1`: RT-2 and SF-4 (`docs/design.md`, section 20).
- **Holdback:** the rules contract `0xaAF8A86e54B1Cb867c00BD452c78981664153d56`, from Holdback's record at its tag `contracts-phase-one-2` (`978aa38d`).
- **Deployer:** `0xa27Cd8A0cF6D15559aF9E6Ff9ebd885da57C3E6a`, through the public CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`, with the salt `keccak256("crest v01")`.
- **Fee:** rate 0, and no sweeper (address 0).
- **The deploy:** the maintainer ran `forge script script/Deploy.s.sol:Deploy --broadcast --gas-estimate-multiplier 900 --slow` (2026-11-26). The deploy cost 0.000512 ETH in all, at 0.01055 gwei.

| Contract | Address | Transaction | Block | Gas used |
| --- | --- | --- | --- | --- |
| Factory | `0xF647937227BB866B8dC75C70497DB76EdfB081D1` | `0x3be1e54477d0c7a9f97975f6eff4779ca1c7922980fb1a8dffdb3d86fd399b1c` | 12,214,881 | 31,218,857 |
| Vault implementation | `0xad58B7D323272387827835EdD94B638572d65940` | created by the factory's transaction | 12,214,881 | included above |
| Holdback module | `0xBF9E295d9B9A2991949d6e4775D9a244e5E4Fdd9` | `0x7a9b6335a0237ad408b8abf54e5082fa8804d79e20a468e7f81dc2f2813d77bf` | 12,214,882 | 15,897,722 |
| Default allow list | `0xE505b6369E4E850F068Af40a4D446e180F3bd4Ad` | `0xc1ae50211174ae5c5297654505d98a321b60978906a7b23db7ab83f138ee9f66` | 12,214,883 | 1,403,960 |

[measured, `cast receipt` on a Sepolia RPC, 2026-11-26: each status 1]

- **Rehearsal on the live RPC, before the deploy** [measured, `cast estimate` against two Sepolia RPCs]:
  - Estimates: the factory 31,716,730 gas, the module 16,152,403, the list 1,428,581.
  - They agree with what was used within 2%.
  - The list has a new address because its bytecode changed through its interface import.
- **Checked on chain** [measured]:
  - all four hold code;
  - the factory names the implementation;
  - the implementation's rate is 0, its sweeper is 0, and its principal is the placeholder address 1, so it cannot be initialized;
  - the module names the rules contract, with `VAULT_IS_BUYER` true, and its payee and escrow are the rules contract's ERC-3009 collector and escrow;
  - `verify()` passed and wrote `11155111.json` at block 12,214,888. It was run against Tenderly's gateway, because publicnode could not serve the head block for forge's fork.
- **Source on Sourcify:** an exact match for the runtime and the creation code of all four [measured, `node script/sourcify-verify.mjs --submit`, 2026-11-26].

## Sepolia (chain 11155111), the earlier factory, since 2026-11-19

The 2026-11-19 deployment below stays for the vaults made from it. `11155111.json` no longer holds its addresses; this section does.


**State: deployed, verified on chain and on Sourcify.** Test tokens only.

- **Code:** Crest `main` at `36485df`. Its Holdback module takes the agent's key as a deal's buyer, as well as the vault; it has no `VAULT_IS_BUYER` flag. Later commits deploy the vault as the buyer as a new factory and a new module at new addresses.
- **Holdback:** the rules contract `0xaAF8A86e54B1Cb867c00BD452c78981664153d56`, from Holdback's record at its tag `contracts-phase-one-2` (`978aa38d`).
- **Deployer:** `0xa27Cd8A0cF6D15559aF9E6Ff9ebd885da57C3E6a`, through the public CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
- **Fee:** rate 0, and no sweeper (address 0), so no fee can ever be owed. A factory with a real rate needs the maintainer's sweeper address first.

| Contract | Address | Transaction | Block | Gas used |
| --- | --- | --- | --- | --- |
| Factory | `0x0Ae553d9032096B9804823eb9326Ad1136fef93D` | `0x91e48ee7239e15190e7d94a612bd00ebfe14ff224a2375d76dbab8ad39538265` | 12,170,955 | 28,298,139 |
| Vault implementation | `0x482f42468E14c162A8e474a1d6B4c20c3c0FECC5` | created by the factory's transaction | 12,170,955 | included above |
| Holdback module | `0x02A7149EB6E1895471577925E81A87B11D624320` | `0xf636711398e021658570468f3543bf61329cade6a8ea500c47443036f804e63d` | 12,170,956 | 9,931,223 |
| Default allow list | `0xD328Ae6297902761Bdac990eA55c01a51bDB1F81` | `0xcd34dbc2ec304efb0574e5d7b9f39090d94157dfeb22b6ae33bebb80f72e67d2` | 12,170,957 | 1,403,972 |

[measured, `cast receipt` on a Sepolia RPC, 2026-11-19]

- **Two earlier attempts ran out of gas.**
  - One is `0x52387122535dad92999ba409d7520baefd922711e4f4df49fe861856c5bd8142`, at block 12,170,928, using 5,333,806 gas [measured].
  - The other is inferred from the deployer's nonce, which went from 6 to 7 between blocks 12,170,928 and 12,170,954.
  - Contract creation on Sepolia cost about 7 times forge's local estimate. The deploy that landed passed `--gas-estimate-multiplier 900`.
- **Checked read-only on two RPCs** [measured, block 12,170,980]:
  - all four hold code;
  - the factory names the implementation;
  - the implementation's rate is 0 and its sweeper is 0;
  - the implementation cannot be initialized;
  - the module names the rules contract, its collector and its escrow;
  - the three CREATE2 addresses follow from `36485df`'s build.
- **Source on Sourcify:** an exact match for the runtime and the creation code of all four [measured, 2026-11-20].
  - `script/sourcify-verify.mjs` verified them on 2026-11-19.
  - An independent check from a clean checkout of `36485df`, with every submodule, built the same code, metadata included. Sourcify's lookups then returned `exact_match` for both runtime and creation code.
- **Known limit of this deployment:** while the agent's key is a deal's buyer, it can still accept early a funded hold whose merchant has signed a delivery, after every stop (`test/redteam/FrontRun.t.sol`, `docs/design.md` section 18). The vault-as-buyer build, deployed as a new factory and module, closes it.
