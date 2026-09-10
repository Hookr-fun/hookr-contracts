#!/usr/bin/env bash
# Deterministic local V2 bootstrap lifecycle. It never loads a signer, forks a network, or broadcasts.
set -euo pipefail

cd "$(dirname "$0")"
forge test --match-contract HookrUtilityV2CanaryScriptsTest -vvvv
