# audit-poc — archived pre-fix proofs of concept

These suites were written by the adversarial audit against the **v1** contracts. Each one
*asserts that a vulnerability is present*, so by construction they cannot pass against the
fixed v2 sources — a green `Audit.t.sol` would mean the fix had been reverted.

They live outside `contracts/test/` so `forge test` does not compile them (Foundry only
compiles `src`, `test` and `script`). They are kept verbatim as the evidence trail for the
findings.

Every finding they proved now has an inverted regression test in
`contracts/test/Regression.t.sol`, which fails on the v1 code and passes on v2.

To re-run one against the v1 code, check out commit `6d3ad6b` and copy the file back into
`contracts/test/`.
