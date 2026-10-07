# External Launch

Opens a pool on a hook Hookr did not write, through that hook's admitted launch adapter, in one transaction, and records it for discovery. The two adapters cover hookless pools and hooks that allow a plain initialize. The launcher links its own deployment of the release's `HookrTokenDeployer` library.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HooklessLaunchAdapter` | [`0x524Ae074223711ee9BC6FC425E7e359aca30151E`](https://robin.etherscan.io/address/0x524Ae074223711ee9BC6FC425E7e359aca30151E#code) | [Sourcify](https://repo.sourcify.dev/4663/0x524Ae074223711ee9BC6FC425E7e359aca30151E) |  |
| `HookrExternalHookBook` | [`0x96D01E30cd4980D16e757f0Ab2a1d24caFf02f86`](https://robin.etherscan.io/address/0x96D01E30cd4980D16e757f0Ab2a1d24caFf02f86#code) | [Sourcify](https://repo.sourcify.dev/4663/0x96D01E30cd4980D16e757f0Ab2a1d24caFf02f86) |  |
| `HookrExternalLauncher` | [`0x4F121366e6F44f219dC87Ce382e6054c66fA860e`](https://robin.etherscan.io/address/0x4F121366e6F44f219dC87Ce382e6054c66fA860e#code) | [Sourcify](https://repo.sourcify.dev/4663/0x4F121366e6F44f219dC87Ce382e6054c66fA860e) | links `HookrTokenDeployer` |
| `HookrTokenDeployer` | [`0xA3B750366F3Bc54dE57C3A455E25C212cC176ac6`](https://robin.etherscan.io/address/0xA3B750366F3Bc54dE57C3A455E25C212cC176ac6#code) | [Sourcify](https://repo.sourcify.dev/4663/0xA3B750366F3Bc54dE57C3A455E25C212cC176ac6) |  |
| `PlainInitializeLaunchAdapter` | [`0xa5Db222fe6B144Fe43b20fEfD6a14bc81896222d`](https://robin.etherscan.io/address/0xa5Db222fe6B144Fe43b20fEfD6a14bc81896222d#code) | [Sourcify](https://repo.sourcify.dev/4663/0xa5Db222fe6B144Fe43b20fEfD6a14bc81896222d) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x524Ae074223711ee9BC6FC425E7e359aca30151E > input.json
solc-0.8.37 --standard-json input.json > output.json
```
