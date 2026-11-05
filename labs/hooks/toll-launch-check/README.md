# Toll Launch Check

A read-only policy module (`IHookrModuleV1`) that refuses **buys** of a pool's token when the first-block share or the funding-linked share that a detector recorded for that token in an ERC-8470 registry is over the pool's limits. This module never refuses a sell. It takes nothing and adds no fee.

ERC-8470 defines the two shares this way:

- **First-block share:** "Share of total supply acquired in the block of the token's first trade, by accounts other than the pool and the venue."
- **Funding-linked share:** "Share of total supply held at the observed block by accounts that share a funding source, within H transfers of native currency, with the creator or with another holder in the set." The detector this module pins writes it with H = 1 (`param` 1).

Motivation: high values of these two shares are what a bundled launch leaves behind. The module does not decide whether a launch was bundled. It compares two recorded numbers with two limits.

## Why a creator would name it

The module is an opt-in commitment. A creator names it in the pool's stack with limits of their choosing, and the commitment binds the pool. A pool's stack is configured once (`src/HookrStackRegistryV1.sol:724` reverts `StackAlreadyConfigured`), and a configured pool keeps the module snapshots, configs and limits it selected (`src/HookrStackRegistryV1.sol:21-25`); we found no function that changes a configured stack. So if the detector later records a first-block share or a funding-linked share over those limits, buys in that pool stop. It cannot stop a bundle in the launch block itself, because the detector records a launch about 17 to 20 minutes after it. What it does is protect the buyers who come after that.

Source: [`src/TollLaunchCheckModule.sol`](./src/TollLaunchCheckModule.sol). It is the logic of [soli0x/toll-launch-check](https://github.com/soli0x/toll-launch-check) (MIT) recast in the module template's shape.

## What it does on a swap

`beforeSwap` only. The other two phases are no-ops: `beforeAddLiquidity` returns true and `afterSwap` returns an empty result.

- **A sell** (`context.isBuy == false`) returns an all-zero `ModuleResult` straight away. It does not decode the config and does not read the registry, so no config and no registry state can make a sell revert in this module.
- **A buy** reads the registry for the pool's subject token and decides:

| Registry state for the token | Result |
| --- | --- |
| The detector has no observation of it | `blockUnread == false`: passes. `blockUnread == true`: refused, reason `not-observed` |
| First-block share > `maxFirstBlockBps` (limit not 0) | refused, reason `first-block-share`, value = the share |
| Funding-linked share > `maxFundingLinkedBps` (limit not 0) | refused, reason `funding-linked-share`, value = the share |
| Otherwise | passes, all-zero result |

The first-block share is checked first. A limit equal to the share passes (the comparison is strictly greater). A finding the detector's latest observation does not carry (`type(uint256).max`, "not read") counts neither way.

A refusal is a revert from `beforeSwap` with `LaunchCheckRefused(token, reason, value)`, 100 bytes of revert data. The accounting kernel turns a failed module call into `ModuleCallFailed(moduleId, PHASE_BEFORE_SWAP, keccak256(revertData))`, so the swap does not happen and the reason reaches the caller only as that hash. `check(token, config)` is a view that returns the same decision as `(allowed, reason, value)` without reverting, for a front end or an agent that wants the reason before it sends the swap.

## What it reads

One function of an [ERC-8470 Token Launch Observations](https://github.com/ethereum/ERCs/pull/2121) registry, `latestFinding(chainId, token, detector, kind, param)`, once or twice per buy:

| Read | `kind` | `param` |
| --- | --- | --- |
| First-block share | `keccak256("erc.launch-observations.first-block-share")` | 0 |
| Funding-linked share (only when that limit is on) | `keccak256("erc.launch-observations.funding-linked-share")` | 1 |

Both shares are basis points of total supply. The registry and the detector are constructor immutables, so they are part of the runtime code a registration would pin. On Robinhood Chain (4663):

| | Address |
| --- | --- |
| ERC-8470 registry | `0x730E3C356299c9203cB042F6C0A9274aeABf9AF3` |
| Detector (Toll) | `0x02593AbFf31f4E8eC1D5c2F297a347C51ef06E5c` |

Who writes: the registry is open, and it keys every observation by the address that recorded it (`msg.sender`). Toll's detector is an off-chain process that reads launches from the chain and records observations of them, each with the block it read at; it can record a token again later, and the newest observation is the one read here. This module reads only the pinned detector's findings, so another writer cannot change its decision; the test `test_anotherDetectorsFindingsAreIgnored` shows that against the mock registry.

## What it takes

Nothing. `validateStack` returns every cap as zero (`maxLpFeeSurchargePips`, `maxSpecifiedQuoteTakeBps`, `maxUnspecifiedQuoteTakeBps`, `maxSubjectTakeBps`), every result it returns is all zeros, and it holds no state and no funds.

## Config

ABI-encoded `Config`, validated at stack creation by `validateStack` (and by `validateConfig`) with the template's canonical-encoding rule:

```solidity
struct Config {
    bytes32 poolId;
    address kernel;
    address subject;
    address quote;
    uint16 maxFirstBlockBps;    // 0 = off, otherwise 1..9,999
    uint16 maxFundingLinkedBps; // 0 = off, otherwise 1..9,999
    bool blockUnread;           // refuse buys while the detector has not observed the token
}
```

`blockUnread = true` means no buys at all for the roughly 17 to 20 minutes before the detector records the token, and no buys ever for a token the detector never covers. A pool configured with `blockUnread = true` cannot be opened with a creator initial buy. We read this from `HookrMarketCoordinatorV5`, which runs the initial buy only when `initialBuy.quoteAmountIn != 0`; it is not tested. Pass `quoteAmountIn = 0`. The module has no exemption for the creator.

Rejected: bytes that do not re-encode to themselves, a zero pool id, kernel or subject, a subject equal to the quote, a limit of 10,000 or more (a share cannot exceed 10,000, so it could never trip), and a config with both limits off and `blockUnread` false (it could never refuse anything). `validateStack` also rejects a config bound to another pool, kernel, subject or quote.

## Registration it would need

`executionMode` READ_ONLY, `phaseMask` = `PHASE_BEFORE_SWAP`, all four caps 0, and a `callbackGasLimit` of 150,000 (the tests check it sits between the catalog's `MIN_CALLBACK_GAS` of 25,000 and the native block's 2,000,000). We have not worked out `requiredHookFlags`, an `exclusiveGroup` or relations to other modules.

## Gas

Measured by the fork test against the live registry, forked at the head of Robinhood Chain on 2026-11-05. "Kernel-style call" means a STATICCALL using the kernel's `_staticcallExact` assembly ([`test/KernelCallHarness.sol`](./test/KernelCallHarness.sol)). Each case runs in its own test. Measured with forge 1.8.6, which starts each top-level call from the test with cold accounts and storage; a `code.length` read of the registry just before the measured call leaves the figure unchanged, so the numbers include the cold registry access. Whether the module's own account access is cold was not separated.

| Case | Kernel-style call, gas |
| --- | --- |
| Buy, both shares under the limits (two reads) | 41,978 |
| Buy refused on the first-block share (one read) | 26,829 |
| Buy of a token the detector never observed (one read) | 13,356 |
| Sell (no read) | 4,022 |

`forge test --gas-report` on the same fork run reports `beforeSwap` at 1,206 min / 39,162 max called directly. The registry finds a finding by scanning the observation's findings in order; the two observations used here carry 7 findings each. An observation can carry up to 32, and the cost of that worst case is not measured; the 150,000 limit is chosen to leave room for it, not proven to cover it.

## Tests

From the repository root:

```sh
forge test --root labs --match-path 'hooks/toll-launch-check/*' -vv
forge test --root labs --fork-url <robinhood chain rpc> --match-path 'hooks/toll-launch-check/*' -vv
```

[`test/TollLaunchCheckModule.t.sol`](./test/TollLaunchCheckModule.t.sol), 29 tests against a mock registry with the same read semantics: identity; caps all zero and under the catalog's registration maxima; config validation (range edges, out-of-range limits fuzzed, all-off config, non-canonical bytes, zero bindings, subject equal to quote, a config for another stack); a buy under both limits passes; first-block over the limit refused with the exact revert; at the limit passes; funding-linked over the limit refused; first-block reported before funding-linked; a zero limit is off; unread follows `blockUnread`; another detector's findings ignored; a finding the observation does not carry counts neither way; a registry that reverts refuses buys; sells never refused (fuzzed over registry state, arbitrary config bytes and a reverting registry); the buy decision follows the limits (fuzzed); the kernel-style call sees a 128-byte zero result for a pass and the 100-byte refusal for a refusal.

[`test/TollLaunchCheckModule.fork.t.sol`](./test/TollLaunchCheckModule.fork.t.sol) has 11 tests against the live registry. They take the RPC from `--fork-url` only and skip when the chain id is not 4663.

They pin two of the detector's observations by id with `getObservation`; a recorded observation does not change:

- Observation 114, token `0x4Ad0…091C`: first-block share 3,356 bps, funding-linked share 0. A buy is refused at a 2,500 limit, its sell passes, and a 3,356 limit or a 0 limit lets the buy through.
- Observation 77, token `0x4EC6…5Eae`: first-block share 209 bps, funding-linked share 0. A buy passes.

The token `0xdead` has no observation, so its buys follow `blockUnread`.

The module reads the latest observation of each token. `test_fork_thePinnedObservationsAreTheLatest` fails if the detector has since recorded a newer observation of either token.

The prototype this comes from pinned block 103,924,809. The public RPCs we tried do not serve state that old, so these tests run at the fork head instead.

## What is unproven

- **No end-to-end swap.** Nothing here runs a swap through `HookrSwapAccountingKernelV3` with this module in a stack. That the kernel reverts the swap with `ModuleCallFailed` when the module reverts is read from the kernel's source and shown only against a copy of its call assembly.
- **No pool can use it today.** The live roots' sealed profiles admit the native rules only. A module serves pools once it is registered in the catalog and a newly sealed profile names it. Hookr 1 (`hookr-1/`), where hookr.fun opens new pools, runs a different hook (`HookrRoot` with Hook Blocks); this module follows the labs template's `IHookrModuleV1` and has not been ported to a Hook Block.
- **Early buys are unread.** In Toll's operation the detector records a launch about 17 to 20 minutes after it. Every buy before then takes the `not-observed` branch, and `blockUnread` alone decides it. The tests show the branch, not the latency. The initial-buy interaction is described under Config and is not tested.
- **Coverage.** A token the detector never records stays `not-observed` forever. Which launches the detector covers is not shown here.
- **Trust in the detector.** The module believes the pinned detector's numbers. Nothing on chain checks how a share was computed; the registry stores the block it was read at so anyone can recompute it, but this module does not. If the detector stops writing, new tokens stay unread; if it writes a wrong number, buys are refused or let through on it.
- **Latest observation only.** The decision uses the detector's latest observation of the token. A later observation that leaves a share unread makes that limit count neither way.
- **Worst-case gas.** Measured for 7-finding observations only (see Gas).
- **Quoter.** Whether `HookrKernelQuoterV1` reports a refused buy as a failed quote has not been checked.
