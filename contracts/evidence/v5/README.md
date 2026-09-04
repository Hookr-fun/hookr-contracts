# Hookr v5 Robinhood release evidence

This directory archives the exact production deployment and canary records used to promote Hookr
generation 5 on Robinhood Chain (chain ID 4663). The authenticated provenance chain is:

- deployed-contract source commit `b1ccb017f86d9caffff8bf4277a735d714130972`;
- original canary operator commit `5662aaaf479aa42beefbd580fb4e91099651b3ef`;
- owner-bid recovery commit `cfb571c16a24842738f9c39ecf4c2ce00f6c05d4`.

The deployment record contains 11 successful receipts for the reviewed library, launchpad, hook,
router, flywheel burner, immutable wiring, and house blueprints. Phase A contains the exact four
Forge artifacts (1 + 2 + 1 + 2 receipts), the separately authenticated owner bid, and the
shorten/restore timing pairs. Its nine-receipt index is
`2a91d091ae429a8ef08cb248cc7498a035f13990faa76f6a14e459336f5525fe`.

Phase B records five successful transactions proving six reviewed outcomes: migration, owner bid
exit, token claim, zero creator proceeds, flywheel collection, and buyback-and-burn. The
zero-proceeds claim outcome is intentionally represented by a byte-identical alias of the migration
transaction and receipt under `claim-auction-proceeds/`; it proves that no claim transaction was
applicable or sent. Its index is
`a5eab2f9030f6cac8dca71ad5cac6fe15401bc45bff9feff12c6f19827ee046f`.

The files under `contracts/broadcast/` remain ignored operator artifacts. These 25 copied records
are the immutable review archive. Verify every byte from this directory with:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Signing journals, temporary release targets, failed rehearsals, and fork artifacts are
intentionally excluded.
