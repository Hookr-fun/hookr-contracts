#!/usr/bin/env bash
# Mutation gate: hand-written one-edit mutants of the value-moving contracts (the catalog is test/invariant/mutants.py),
# each of which the suites it names must fail on. The runner is test/invariant/mutate.py; this script runs it.
#
#   test/invariant/mutations.sh                         every mutant (long: hours; CI runs one job per contract)
#   test/invariant/mutations.sh --only HookrRoot        the mutants of one contract (repeatable)
#   test/invariant/mutations.sh --id RT-3 --id RT-4     named mutants
#   test/invariant/mutations.sh --jobs 4                four workers, each on its own copy of the tree
#   test/invariant/mutations.sh --list                  print the catalog
#   test/invariant/mutations.sh --check                 confirm every anchor matches once (no build)
#   SEED=0x1 test/invariant/mutations.sh                another fuzz seed (default 0x7e57a11)
#
# The first four mutants (SYS-1 to SYS-4, in HookrRules) are the original gate on the whole-system invariant campaign:
# one edit each that breaks a guard feature, which the default profile (128 runs x 64 calls) must fail on:
#   SYS-1  the launch buy no longer closes its parent block      (DB2, G2)
#   SYS-2  the Snipe decays quadratically, same start and floor  (S1)
#   SYS-3  the dynamic fee is halved                             (DF-02)
#   SYS-4  the per-parent-block buy cap is doubled               (G1)
#
# src must be unmodified before the run. The original text is restored after every mutant and on exit, so an
# interrupted run leaves no mutation behind. Exit 0 when every mutant is killed, 1 when one survives, 2 when a mutant is
# invalid (does not compile, or its suites select no test) or the build fails.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.."
trap 'git checkout -- src 2>/dev/null || true' INT TERM HUP
exec python3 "$here/mutate.py" "$@"
