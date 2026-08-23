#!/usr/bin/env bash
# One-time workspace setup: init every dependency, then apply the single tracked
# pragma widening that lets the pinned solc 0.8.28 satisfy the whole import graph.
# foundry.toml documents why PoolManager.sol needs ^0.8.26 instead of its exact pin;
# re-apply after any submodule bump.
set -euo pipefail

cd "$(dirname "$0")"

git submodule update --init --recursive

PM=lib/v4-core/src/PoolManager.sol
if grep -q '^pragma solidity 0\.8\.26;$' "$PM"; then
  perl -pi -e 's/^pragma solidity 0\.8\.26;$/pragma solidity ^0.8.26;/' "$PM"
  echo "widened $PM pragma to ^0.8.26"
fi

echo "workspace ready — run: forge fmt --check && forge build --sizes && forge test -vv"
