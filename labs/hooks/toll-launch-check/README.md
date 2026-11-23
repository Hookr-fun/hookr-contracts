# Toll Launch Check

A read-only check that refuses **buys** of a pool's token while the first-block share or the funding-linked share that one detector recorded for that token in an ERC-8470 registry is over the pool's limits, and only for a fixed number of blocks after launch. After that window it allows every buy, for good. It never refuses a sell, takes nothing and adds no fee.

It comes in two forms, with the same decision:

| Form | Where | Interface | Builds with |
| --- | --- | --- | --- |
| Advisory for `HookrRoot` | [`advisory/`](./advisory) | [`IHookrAdvisory`](../../../hookr-1/src/interfaces/IHookrAdvisory.sol), structured like [`TemplateAdvisory`](../../../hookr-1/test/kit/TemplateAdvisory.sol), tested with [`AdvisoryConformance`](../../../hookr-1/test/kit/AdvisoryConformance.sol) | solc 0.8.37 against `hookr-1/`, its own Foundry project |
| Policy module | [`src/`](./src), [`test/`](./test) | `IHookrModuleV1`, from [`labs/templates/module`](../../templates/module) | solc 0.8.26, the `labs/` project |

ERC-8470 defines the two shares this way:

- **First-block share:** "Share of total supply acquired in the block of the token's first trade, by accounts other than the pool and the venue."
- **Funding-linked share:** "Share of total supply held at the observed block by accounts that share a funding source, within H transfers of native currency, with the creator or with another holder in the set." The detector pinned here writes it with H = 1 (`param` 1).

High values of these two shares are what a bundled launch leaves behind. The check does not decide whether a launch was bundled. It compares two recorded numbers with two limits.

## The decision

On a sell: allowed, before anything is read. On a buy at or after the window's end: allowed, before anything is read. On a buy inside the window, the registry is read for the pool's subject token:

| Registry state for the token | Result |
| --- | --- |
| The detector has no observation of it (or, in the advisory, the read failed) | `blockUnread == false`: allowed. `blockUnread == true`: refused, reason `not-observed` |
| First-block share > `maxFirstBlockBps` (limit not 0) | refused, reason `first-block-share` |
| Funding-linked share > `maxFundingLinkedBps` (limit not 0) | refused, reason `funding-linked-share` |
| Otherwise | allowed |

The first-block share is checked first; the funding-linked share is read only when its limit is on. A share equal to its limit is allowed. A finding the detector's latest observation does not carry (`type(uint256).max`) counts neither way. Both forms have a `check` view that returns the decision with its reason and share, without refusing anything.

## The window: `activeForBlocks`

Every pool sets `activeForBlocks`, a `uint32` count of `block.number` blocks. The check applies while `block.number < start + activeForBlocks` and never after; from that block on every buy is allowed without a registry read, and nothing can switch the check back on. **0 is rejected as invalid config**, so every pool's check has an end. The largest value is 4,294,967,295 blocks.

- **Advisory:** `start` is the block in which the pool binds the advisory, which is the block the pool opens in. `bind` stores `activeUntilBlock = block.number + activeForBlocks`.
- **Module:** the module keeps no state, so its config carries `startBlock` next to `activeForBlocks`. `validateStack`, which runs when the pool's stack is created, refuses a `startBlock` after that block and a window already over in it, so the check ends at most `activeForBlocks` blocks after the stack is created. `startBlock` 0 is rejected too.

`block.number` is the chain's `NUMBER` opcode. Hookr's own types note that on Arbitrum-style chains it is the parent chain's height ([`hookr-1/src/types/HookrTypes.sol:77-78`](../../../hookr-1/src/types/HookrTypes.sol)), so a window's length in time depends on the chain. The fork tests below run under forge, whose `block.number` is the fork's block number; the length of a window in time on Robinhood Chain is not measured here.

## What it reads

One function of an [ERC-8470 Token Launch Observations](https://github.com/ethereum/ERCs/pull/2121) registry, `latestFinding(chainId, token, detector, kind, param)`, once or twice per buy inside the window:

| Read | `kind` | `param` |
| --- | --- | --- |
| First-block share | `keccak256("erc.launch-observations.first-block-share")` | 0 |
| Funding-linked share (only when that limit is on) | `keccak256("erc.launch-observations.funding-linked-share")` | 1 |

Both shares are basis points of total supply. The registry and the detector are constructor immutables, so they are part of the runtime code that is pinned by code hash. On Robinhood Chain (4663):

| | Address |
| --- | --- |
| ERC-8470 registry | `0x730E3C356299c9203cB042F6C0A9274aeABf9AF3` |
| Detector (Toll) | `0x02593AbFf31f4E8eC1D5c2F297a347C51ef06E5c` |

The registry is open, and it keys every observation by the address that recorded it. Toll's detector is an off-chain process that reads launches from the chain and records observations of them, each with the block it read at; it can record a token again later, and the newest observation is the one read here. Only the pinned detector's findings count; both test suites show that another writer's findings are ignored.

## The advisory

Source: [`advisory/src/TollLaunchCheckAdvisory.sol`](./advisory/src/TollLaunchCheckAdvisory.sol). Copied from `TemplateAdvisory`'s structure: no owner, no storage other than the bindings, no upgrade path, no DELEGATECALL (the conformance suite scans the runtime for it). Bindings are keyed by the calling root.

**Bind data:** `abi.encode(Config)`, exactly 128 bytes, canonical:

```solidity
struct Config {
    uint16 maxFirstBlockBps;    // 0 = off, otherwise 1..9,999
    uint16 maxFundingLinkedBps; // 0 = off, otherwise 1..9,999
    bool blockUnread;           // refuse buys while the detector has not observed the token
    uint32 activeForBlocks;     // not 0
}
```

The subject is not in the bind data: the root passes it in every `SwapContext`. `bind` refuses (`InvalidConfig`) a caller that is not the pool's hook (`key.hooks != msg.sender`), a pool config that names another advisory, phases other than `BEFORE_SWAP` alone, an advisory gas limit under `MIN_ADVISORY_GAS`, a caller whose registry does not hold an `ADVISORY` admission of this contract, and bind data that is not canonical, has a limit of 10,000 or more, can never refuse anything, or has a window of 0. A second bind of the same pool reverts `AlreadyBound`.

**On each swap:** `beforeSwap` returns zero surcharge, zero take and no recipient, always. It sets `reject` on a buy inside the window that the decision above refuses. `beforeAddLiquidity` returns true. `afterSwap` is never called (the advisory binds with `BEFORE_SWAP` only) and returns zero advice. A pool the caller has not bound gets zero advice; `check(binder, id, token)` reverts `UnknownPool` for it.

### Fail-open and fail-closed bindings

A pool binds an advisory fail-open or fail-closed (`PoolConfig.advisoryFailOpen`). What `HookrRoot` does with each, from its source:

- It calls `beforeSwap` through `HookrRootStorage.bounded`, a STATICCALL with exactly the pool's `advisoryGasLimit` that is ok only when exactly 128 bytes come back ([`hookr-1/src/core/HookrRoot.sol:790-791`](../../../hookr-1/src/core/HookrRoot.sol), [`hookr-1/src/libraries/HookrRootStorage.sol:103-115`](../../../hookr-1/src/libraries/HookrRootStorage.sol)).
- If the call reverts, runs out of gas or answers in the wrong shape, a **fail-closed** pool reverts the swap with `ModuleCallReverted` or `ModuleCallFailed` (`HookrRoot.sol:805-806`, `HookrRootStorage.sol:123`); a **fail-open** pool goes on and charges the advisory's admitted LP-fee cap, up to the pool's room (`HookrRoot.sol:807-811`).
- If the call answers, a **fail-open** advisory that returns `reject` or a quote take makes the root revert `InvalidModuleResult` (`HookrRoot.sol:814-818`: "A fail-open advisory may neither reject nor take", as `IHookrAdvisory.beforeSwap` says). On a **fail-closed** pool, `reject` reverts the swap with `SwapRejected` (`HookrRoot.sol:432`, and `:381` on the fee-only path).
- `beforeAddLiquidity` is called only on fail-closed pools (`HookrRoot.sol:299`).

So the advisory can refuse a buy only on a **fail-closed** binding, and on a fail-closed binding anything that makes `beforeSwap` revert or run out of gas would stop every swap, sells included. The advisory is built for that:

- Nothing on its swap path reverts. Each registry read is a STATICCALL that keeps `READ_RESERVE` (5,000) gas back and copies at most five words. A read that reverts, runs out of the gas it is given, or answers fewer than five words counts as "not observed", so it refuses only when the pool set `blockUnread`. A second read that fails counts neither way.
- `MIN_ADVISORY_GAS` is 250,000. The most expensive buy is an observation with the registry's maximum of 32 findings, 30 of them funding-linked shares under other params, then the first-block share, then the funding-linked share; the registry compares the kind first and reads the param only on a kind match, so both reads scan everything. Against the live registry, cold, that costs 188,079 gas (fork test). Below the minimum, a read could run out of gas on a real observation and let a buy through that should be refused; the fork test `test_fork_worstCaseRefusedOnTheSecondRead` refuses it at 250,000.
- On a **fail-open** binding the advisory accepts the bind (the conformance suite opens a fail-open pool) and returns zero advice on every swap: it can never refuse there. `binding(...).failOpen` and `check` (reason `fail-open`) show it.

The advisory serves `HookrRoot` pools only. A pair root (`IHookrPairAdvisory`) takes a surcharge from its advisory and has no way to refuse a swap, so the advisory does not implement it and the suite's pair checks are skipped.

**Admission it would need:** kind `ADVISORY`, `phaseMask` = `BEFORE_SWAP`, all caps 0 (it charges nothing), `gasLimit` at least 250,000 (a pool's `advisoryGasLimit` must equal the admitted one, `hookr-1/src/core/HookrLane.sol:943`). `failOpen` and `feeOnly` in the admission decide only whether a pool may bind it fail-open (`hookr-1/src/libraries/HookrRegistryChecks.sol:453`); a pool that wants the check binds it fail-closed.

### Where it lives and how it builds

`advisory/` is a Foundry project of its own ([`advisory/foundry.toml`](./advisory/foundry.toml)): solc 0.8.37 for its sources and hookr-1's compiler settings, the `hookr-1/` remapping to the repository's `hookr-1/` (read-only) for the interfaces and the conformance kit, and the root submodules for v4-core and forge-std. The kit deploys the PoolManager by artifact, so [`advisory/test/PoolManagerArtifact.sol`](./advisory/test/PoolManagerArtifact.sol) compiles it with 0.8.26, as `hookr-1/test/fixtures/PoolManagerArtifact.sol` does. `labs/foundry.toml` skips `hooks/toll-launch-check/advisory/**`, so `forge build --root labs` and `forge test --root labs` do not compile it. The labs CI job therefore does not build or test the advisory; it is built from its own root:

```sh
forge fmt --check --root labs/hooks/toll-launch-check/advisory
forge test --root labs/hooks/toll-launch-check/advisory -vv
forge test --root labs/hooks/toll-launch-check/advisory --fork-url <robinhood chain rpc> --match-path 'test/*.fork.t.sol' -vv
```

### Advisory tests

[`advisory/test/TollLaunchCheckAdvisory.t.sol`](./advisory/test/TollLaunchCheckAdvisory.t.sol) inherits `AdvisoryConformance`. The suite deploys a real `HookrRoot` with `HookrRules`, the launcher, router and quoter, admits the advisory with an LP-fee cap of 0 and a gas limit of 250,000, and opens one fail-closed and one fail-open pool bound to it. 44 tests: 36 pass, 8 skip (the suite's pair-root checks and its pair fuzz).

- **Conformance (root):** binds once, return sizes, advice within the cap over fuzzed swaps, gas at the limit in the worst case with the advisory and the registry cold and a fill both ways, fail-open charge and fail-closed revert when the advisory reverts, declarations and plain code, the launch's dev buy. The kit's tokens have no observation and the kit binds `blockUnread = false`, so its checks that an advisory never rejects run on the unread branch; the worst case records a 32-finding observation under the limits.
- **Behaviour, through the real root and router:** a buy over the first-block or the funding-linked limit is rejected and the router's swap reverts with `SwapRejected` (exact input and exact output); a buy at or under the limits fills; a finding not carried counts neither way; another detector's findings are ignored; the decision follows the limits (fuzzed); a sell over the limits fills on both kinds of pool, and sells are never rejected over fuzzed registry state and a reverting registry; an unread coin fills unless `blockUnread`; a registry that reverts, runs out of gas or answers short counts as unread, and with the out-of-gas registry the root-style call still answers 128 bytes within 250,000 gas and the fail-closed pool's buy fills; at `activeUntilBlock - 1` a buy is rejected and from `activeUntilBlock` it fills, also 50,000,000 blocks later; `blockUnread` ends with the window; the window decides over fuzzed lengths; a fail-open binding never rejects and its buy fills; a caller that bound nothing gets zero advice; bind refuses a caller that is not the pool's hook, a hook without an admission, wrong pool settings and invalid data, and a second bind reverts `AlreadyBound`.

[`advisory/test/TollLaunchCheckAdvisory.fork.t.sol`](./advisory/test/TollLaunchCheckAdvisory.fork.t.sol): 10 tests against the live registry, which take the RPC from `--fork-url` only and skip on any other chain. They bind through a stand-in root (it reports an `ADVISORY` admission and calls `beforeSwap` with `HookrRootStorage.bounded`'s assembly at exactly 250,000 gas); it is not `HookrRoot`. The worst-case tests record, on the fork only, an observation by the detector of a fresh token.

### Advisory gas

The root-style call at 250,000 gas, with the advisory and the registry cold (`vm.cool`), forked at the head of Robinhood Chain on 2026-11-23, forge 1.8.6:

| Case | Gas |
| --- | --- |
| Buy, both shares read (observation 77), allowed | 40,987 |
| Buy refused on the first-block share (observation 114) | 26,187 |
| Buy of a coin the detector never observed (one read) | 12,705 |
| Sell (no read) | 3,417 |
| Buy after the window (no read) | 6,058 |
| 32 findings of other kinds, both reads, allowed | 123,783 |
| Worst case (30 funding-linked findings first), both reads | 188,079 to 188,103 |

## The module

Source: [`src/TollLaunchCheckModule.sol`](./src/TollLaunchCheckModule.sol), for the `IHookrModuleV1` interface in `src/` that [PREVIOUS_RELEASES.md](../../../PREVIOUS_RELEASES.md) describes. It is the logic of [soli0x/toll-launch-check](https://github.com/soli0x/toll-launch-check) (MIT) recast in the module template's shape.

The config is the ABI-encoded `Config` struct in the source: the pool id and the three addresses `validateStack` checks it against, then the same limits and `blockUnread` as the advisory, then `uint64 startBlock` (not 0, not after the stack's block) and `uint32 activeForBlocks` (not 0).

`MODULE_VERSION` is 2 and the schema string is `labs.toll-launch-check.config.v2`. A refusal is a revert from `beforeSwap` with `LaunchCheckRefused(token, reason, value)`. A sell returns an all-zero result before the config is decoded or the registry is read. A buy at or after the window's end returns before the registry is read. Unlike the advisory, a registry that reverts makes a buy inside the window revert. `validateStack` returns every cap as zero, and also refuses a config bound to another pool or address. Registration it would need: read-only, `PHASE_BEFORE_SWAP`, all caps 0, a callback gas limit of 150,000.

[`test/TollLaunchCheckModule.t.sol`](./test/TollLaunchCheckModule.t.sol): 35 tests (4 fuzz) against a mock registry, including the window: a zero window or zero start is rejected; `validateStack` refuses a start after its block and a window already over; a buy is refused at the window's last block and allowed from its end, also 10,000,000 blocks later, where `check` says `expired`; an unread coin with `blockUnread` is allowed after the window; after the window a reverting registry is not read; the window decides over fuzzed lengths and blocks; sells are never refused. [`test/TollLaunchCheckModule.fork.t.sol`](./test/TollLaunchCheckModule.fork.t.sol): 12 tests against the live registry.

Module gas: a STATICCALL into `beforeSwap` with 150,000 gas, one case per test, forked at the head of Robinhood Chain on 2026-11-23, forge 1.8.6:

| Case | Gas |
| --- | --- |
| Buy, both shares under the limits (two reads) | 42,525 |
| Buy refused on the first-block share (one read) | 27,376 |
| Buy of a coin the detector never observed (one read) | 13,902 |
| Sell (no read) | 4,035 |
| Buy after the window (no read) | 7,042 |

```sh
forge test --root labs --match-path 'hooks/toll-launch-check/*' -vv
forge test --root labs --fork-url <robinhood chain rpc> --match-path 'hooks/toll-launch-check/*' -vv
```

## Pinned observations

Both fork suites pin two of the detector's observations by id; a recorded observation does not change:

- Observation 114, token `0x4Ad0…091C`: first-block share 3,356 bps, funding-linked share 0. A buy is refused at a 2,500 limit and its sell passes.
- Observation 77, token `0x4EC6…5Eae`: first-block share 209 bps, funding-linked share 0. A buy passes.

The token `0xdead` has no observation, so its buys follow `blockUnread`. The module's suite also checks that 114 and 77 are still each token's latest observation.

## What is unproven

- **No pool can use either form today.** The advisory needs an admission on `HookrRoot`, behind the registry's timelock, at its exact code hash; the module needs a catalog registration and a sealed profile that names it.
- **The advisory's fork tests use a stand-in root.** The real `HookrRoot` runs it only in the unit suite, against a mock registry with the reference implementation's storage shape.
- **Early buys are unread.** In Toll's operation the detector records a launch about 17 to 20 minutes after it, so earlier buys take the `not-observed` branch and `blockUnread` alone decides them. With `blockUnread = true` a pool's launch dev buy is refused. The tests show the branch, not the latency.
- **The window in time.** `activeForBlocks` counts `block.number` blocks; how long that is on Robinhood Chain is not measured here.
- **Coverage and trust.** A token the detector never records stays unread forever. The check believes the pinned detector's numbers; the registry stores the block each was read at so anyone can recompute them, but nothing on chain does.
- **Latest observation only.** The decision uses the detector's latest observation of the token.
- **Gas headroom.** `MIN_ADVISORY_GAS` leaves about 62,000 gas over the worst case measured against the live registry. A future registry is not covered: the registry address is an immutable.
