#!/usr/bin/env bash
# Deterministic local lifecycle canary. It never loads a signer, forks a network, or broadcasts.
set -euo pipefail

cd "$(dirname "$0")"
forge test \
  --match-contract HookrLockRewardsV1Test \
  --match-test test_canary_localFullUtilityLifecyclePreservesExactSolvency \
  -vvvv
