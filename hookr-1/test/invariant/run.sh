#!/usr/bin/env bash
# Runs the whole-system invariant campaign.
#
#   test/invariant/run.sh             default profile: 128 runs x 64 calls, plus the seeded smoke drive
#   test/invariant/run.sh deep        deep profile: 512 runs x 256 calls (131,072 calls)
#   test/invariant/run.sh lane        the lane campaign (test/lane/invariant), isolated: 64 runs x 32 calls
#   test/invariant/run.sh lane-deep   the deep lane campaign, isolated: 256 runs x 128 calls
#   test/invariant/run.sh deep -vv    any further arguments go to forge test
#   test/invariant/mutations.sh       the mutation gate (test/invariant/mutants.py): one-edit mutants of the value-moving
#                                     contracts, each of which the suites named for it must fail on. Its first four
#                                     mutants are the gate on this campaign itself (HookrRules: launch-buy block closure,
#                                     Snipe decay shape, dynamic fee, buy cap)
#
# Environment:
#   RECAPTURE=1                  after the default or deep campaign, also run the lane campaign under lane or lane-deep
#   ALL_INVARIANTS=1             run every invariant test the profile selects, not only its invariant folder
#   HOOKR_INVARIANT_COVERAGE=1   print each run's handler coverage before its liveness checks
#   FOUNDRY_INVARIANT_RUNS / FOUNDRY_INVARIANT_DEPTH override the profile, for example to fit a time budget.
# The lane campaign also runs KothInvariant and KothFuzz (test/lane/invariant), so it takes longer than the lane
# invariants alone.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${1:-default}"
if [ $# -gt 0 ]; then shift; fi
if [ "${HOOKR_INVARIANT_COVERAGE:-}" = 1 ]; then export HOOKR_INVARIANT_COVERAGE=true; fi

campaign() {
  local profile=$1 folder=$2
  shift 2
  local select=(--match-path "$folder/*")
  if [ "${ALL_INVARIANTS:-0}" = 1 ]; then select=(--match-test 'invariant'); fi
  echo "FOUNDRY_PROFILE=$profile forge test ${select[*]} $*"
  FOUNDRY_PROFILE="$profile" forge test "${select[@]}" "$@"
}

cd "$here/../.."
case "$profile" in
  lane | lane-deep) campaign "$profile" test/lane/invariant "$@" ;;
  *)
    campaign "$profile" test/invariant "$@"
    if [ "${RECAPTURE:-0}" = 1 ]; then
      if [ "$profile" = deep ]; then lane=lane-deep; else lane=lane; fi
      campaign "$lane" test/lane/invariant "$@"
    fi
    ;;
esac
