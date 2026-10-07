# Builder Attribution

Registered integration partners, one-time market vouchers and the permanent attribution record of every pool opened through the attribution launcher, which deploys the pool's revenue vault and initializes the pool with a partner tax advisory paying that vault. The launcher links the release's `HookrTokenDeployer` at `0x1B23D6d7beBcB61E39317E9F0Bc02AEB91aFCcAe`.

Deployed in production wave 3 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrAttributionLauncher` | [`0x4aa429Bcc4A92e7F8601D1387E72e325a920b2C8`](https://robin.etherscan.io/address/0x4aa429Bcc4A92e7F8601D1387E72e325a920b2C8#code) | [Sourcify](https://repo.sourcify.dev/4663/0x4aa429Bcc4A92e7F8601D1387E72e325a920b2C8) | links `HookrTokenDeployer` |
| `HookrDirectionalTax` | [`0x99012422e1acBdf53C42BB378eb2f4e468005d3c`](https://robin.etherscan.io/address/0x99012422e1acBdf53C42BB378eb2f4e468005d3c#code) | [Sourcify](https://repo.sourcify.dev/4663/0x99012422e1acBdf53C42BB378eb2f4e468005d3c) |  |
| `HookrPartnerRegistry` | [`0x48FE32A6a1b1507D6981A51f907d53595C16e862`](https://robin.etherscan.io/address/0x48FE32A6a1b1507D6981A51f907d53595C16e862#code) | [Sourcify](https://repo.sourcify.dev/4663/0x48FE32A6a1b1507D6981A51f907d53595C16e862) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...` or `src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x4aa429Bcc4A92e7F8601D1387E72e325a920b2C8 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
