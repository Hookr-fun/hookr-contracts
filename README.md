# Hookr contracts and integrations

Public contracts, release evidence, integration standards, and the typed SDK for
[Hookr](https://hookr.fun), the programmable-market launchpad on Robinhood Chain.

Generation 5 is the promoted write target. It supports zero-seed instant launches quoted in ETH or
HOOKR and bonded ETH launches through Uniswap's Continuous Clearing Auction. Retained generations
remain immutable and readable; publishing this repository does not rewrite their pools or state.

## Current generation 5 release

| Contract | Address |
| --- | --- |
| `HookrLaunchpadV5` 5.0.1 | [`0xa043caBE645636899dDe91Cce4693C00a015e660`](https://robinhoodchain.blockscout.com/address/0xa043caBE645636899dDe91Cce4693C00a015e660) |
| `HookrHook` 1.0.0 | [`0xe7c3461A4c762fF9dB4F91BeE3Cf8deAaFc2E8CC`](https://robinhoodchain.blockscout.com/address/0xe7c3461A4c762fF9dB4F91BeE3Cf8deAaFc2E8CC) |
| `HookrSwapRouter` 1.0.0 | [`0x644ac2e784059e1C01F24f99DF7795aE2be06ca0`](https://robinhoodchain.blockscout.com/address/0x644ac2e784059e1C01F24f99DF7795aE2be06ca0) |
| `HookrFlywheelBurner` 1.0.1 | [`0x8Cee20FA000aF3266AC2cD2cBeEFbcD19D98FD89`](https://robinhoodchain.blockscout.com/address/0x8Cee20FA000aF3266AC2cD2cBeEFbcD19D98FD89) |
| Uniswap v4 `PoolManager` | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |
| HOOKR quote token | [`0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`](https://robinhoodchain.blockscout.com/address/0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c) |

The exact runtime hashes, fixed release block, source commit, and a recent one-block live
verification are exported by [`@hookr/sdk`](packages/sdk/src/release.ts). Runtime identity and
immutable wiring remain the authority; an address table alone is not release proof.

## Five composable market rules

| Block | V5 behavior |
| --- | --- |
| Anti-Snipe | Applies a finite opening guard, buy cap, and extra LP fee. |
| Surge Fees | Scales the LP fee with trade size relative to in-range depth. |
| Auto Burn | Sends a configured share of actual buy output to the dead address. |
| LP Rewards | Donates a configured ETH-side share to in-range liquidity. |
| Nth-buy Pot | Funds a deterministic scheduled pot with bounded per-block progression. |

The hook and its configuration are fixed in a pool's `PoolKey`. An existing v4 pool cannot adopt a
new hook. Existing-token integrations therefore create a separate reviewed pool and leave the old
market unchanged.

## Developer surface

- [`integrations/`](integrations/README.md) — six PR #119-aligned partner tracks, public schemas,
  external-hook manifests, and explicit capability states.
- [`packages/sdk/`](packages/sdk/README.md) — `@hookr/sdk` release candidate with ESM, CommonJS,
  types, examples, tests, and package verification.
- [`contracts/`](contracts/README.md) — V5 and retained Solidity source, Foundry tests, deployment
  scripts, and evidence.
- [`contracts/RELEASE_V5.md`](contracts/RELEASE_V5.md) — ordered V5 simulation, signature,
  broadcast, receipt, readback, and promotion protocol.
- [`integrations/ARB_RECAPTURE.md`](integrations/ARB_RECAPTURE.md) — the source-review V6 Arb
  Recapture boundary. It is not deployed protection and is not exposed by the SDK.

`@hookr/sdk` is not yet published to npm. The package returns typed requests and verification
results; it never stores keys, signs, broadcasts, or calls a partner's callback URL.

## Build and verify

```bash
npm ci
npm test
npm run sdk:pack

cd contracts
forge fmt --check
forge build --sizes
forge test
```

The contract job checks EIP-170 sizes and the complete suite. The public developer job validates
all integration manifests, builds both SDK module formats and declarations, typechecks examples,
runs package and V5 release-tooling tests, and inspects the npm tarball.

## Evidence and authority boundary

Source, a passing test, a deployment transaction, a successful receipt, runtime verification,
source verification, release promotion, npm publication, and partner adoption are separate states.
Nothing in this repository authorizes a wallet action, deployment, registry submission, package
publication, or public partnership announcement.

The contracts and release process have not received an independent audit. The adversarial suites
and retained evidence are review material, not a substitute for one.

## License

MIT
