#!/usr/bin/env bash
# Runs the canary against the deployment recorded in the local DeployRobinhood broadcast
# artifact — addresses and runtime code hashes are derived from the artifact and live chain,
# never hand-copied. Safe against deployer-nonce drift from unrelated wallet activity.
set -euo pipefail

RPC="${HOOKR_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
[ "$CHAIN_ID" = "4663" ] || { echo "RPC $RPC reports chain $CHAIN_ID, expected 4663"; exit 1; }
echo "RPC endpoint: $RPC (chain $CHAIN_ID)"
# Signing mode. Production signs from the reviewed keystore; a fork rehearsal must opt in
# explicitly with HOOKR_UNLOCKED=1, which only works against an impersonating local node.
if [ "${HOOKR_UNLOCKED:-0}" = "1" ]; then
  case "$RPC" in
    *127.0.0.1*|*localhost*) ;;
    *) echo "HOOKR_UNLOCKED=1 refused for non-local RPC $RPC"; exit 1 ;;
  esac
  echo "REHEARSAL MODE: impersonated sender, no keystore."
  SIGNER_ARGS=(--unlocked)
else
  case "$RPC" in
    *127.0.0.1*|*localhost*)
      echo "Refusing to sign with the production keystore against a local fork."
      echo "For a fork rehearsal re-run with HOOKR_UNLOCKED=1."
      exit 1
      ;;
  esac
  SIGNER_ARGS=(--account nodar-deployer)
fi
ARTIFACT="broadcast/DeployRobinhood.s.sol/4663/run-latest.json"
SENDER="0x5a52D4B820Ae7F02880d270562950918ACb14aA2"

cd "$(dirname "$0")"
[ -f "$ARTIFACT" ] || { echo "no deploy artifact at contracts/$ARTIFACT — run the deploy first"; exit 1; }

# Authenticate the deployment before Forge can load a signer. This read-only verifier requires all
# ten receipts beneath a finalized head (latest only on an explicit local rehearsal), derives both
# CREATE2 addresses from the live salt+initcode, compares every runtime with its reviewed template,
# and proves the five blueprint calldata/event/readback triples. Live hashes computed below are only
# TOCTOU pins passed into the canary simulation; they are not allowed to authenticate themselves.
PREFLIGHT_ARGS=(
  --deploy "contracts/$ARTIFACT"
  --rpc "$RPC"
)
if [ "${HOOKR_UNLOCKED:-0}" = "1" ]; then
  PREFLIGHT_ARGS+=(--rehearsal)
fi
(cd .. && node scripts/verify-deployment-preflight.mjs "${PREFLIGHT_ARGS[@]}")

# The canary is one-shot: it consumes keccak256("hookr.v4.canary.instant.all-five.1") for this creator
# permanently, so it must refuse anything short of a complete, current deployment. The artifact is
# validated for COMPLETENESS, not just shape. A partial deploy leaves a run-latest.json with every
# transaction listed but only some receipts (that is how `forge script --resume` works), and no
# receipt is marked failed — so "no failed receipts" cannot detect it. Broadcasting the canary
# against a launchpad whose blueprints never landed would burn the intent for nothing: the canary
# launches with blueprintId 0, so it succeeds, and the promotion tool then refuses the artifact.
read -r PAD HOOK ROUTER < <(python3 - "$ARTIFACT" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
head = sys.argv[2]
tx, rc = d["transactions"], d["receipts"]

# Ten, not nine: HookrLaunchpad links HookrLaunchpadLib by DELEGATECALL, and Forge deploys that
# library itself and PREPENDS it, shifting every later index by one.
expect = ["HookrLaunchpadLib", "HookrLaunchpad", "HookrHook", "HookrSwapRouter"]
assert len(tx) == 10 and len(rc) == 10, \
    f"incomplete deploy artifact: {len(tx)} transactions / {len(rc)} receipts, expected 10/10"
for i, name in enumerate(expect):
    assert tx[i].get("contractName") == name, f"tx #{i} is {tx[i].get('contractName')}, expected {name}"
assert (tx[4].get("function") or "").startswith("setHook"), "tx #4 is not setHook()"
for i in range(5, 10):
    assert (tx[i].get("function") or "").startswith("saveBlueprint"), f"tx #{i} is not saveBlueprint()"
assert all(r["status"] == "0x1" for r in rc), "artifact contains failed receipts"

# Reject an artifact from a different commit. contracts/broadcast/ is gitignored, so a stale
# rehearsal artifact can sit on the operator's disk unreviewed and unnoticed — one from an anvil
# fork was found here, complete-looking at 9/9, naming addresses with no code on live 4663.
if head != "unknown" and d.get("commit") and not head.startswith(d["commit"]) \
        and not d["commit"].startswith(head):
    raise AssertionError(
        f"artifact was produced at commit {d['commit']}, but HEAD is {head} — redeploy or check out that commit"
    )
print(tx[1]["contractAddress"], tx[2]["contractAddress"], tx[3]["contractAddress"])
EOF
)

hash_of() { cast keccak "$(cast code "$1" --rpc-url "$RPC")"; }
PAD_HASH=$(hash_of "$PAD"); HOOK_HASH=$(hash_of "$HOOK"); ROUTER_HASH=$(hash_of "$ROUTER")

# The deploy-only preflight above already authenticated all four runtimes against reviewed compiler
# templates, including exact immutables and library links. Re-read their raw hashes here so the
# canary simulation fails if any target changes between that evidence snapshot and execution.
#
# Read from the deploy script rather than duplicated here. The previous copy drifted two contract
# revisions behind its twin in RELEASE.md, and because this check runs only after the deploy has
# already been broadcast, the drift would have surfaced as an abort with the ETH already spent.
# DeployRobinhood.s.sol now asserts the same constant during simulation, so a mismatch stops the
# release before any transaction is signed; this stays as the second, on-chain-sourced check.
REVIEWED_PAD_HASH=$(
  grep -A1 'bytes32 constant REVIEWED_PAD_RUNTIME_HASH' script/DeployRobinhood.s.sol \
    | grep -oE '0x[0-9a-fA-F]{64}' | head -1
)
[ -n "$REVIEWED_PAD_HASH" ] || {
  echo "could not read REVIEWED_PAD_RUNTIME_HASH from script/DeployRobinhood.s.sol"
  exit 1
}
[ "$PAD_HASH" = "$REVIEWED_PAD_HASH" ] || {
  echo "launchpad runtime hash $PAD_HASH does not match the reviewed build $REVIEWED_PAD_HASH"
  exit 1
}

echo "canary target (from artifact + live chain):"
echo "  launchpad $PAD  $PAD_HASH"
echo "  hook      $HOOK  $HOOK_HASH"
echo "  router    $ROUTER  $ROUTER_HASH"

# Bounds are deliberately below the fork-rehearsed outputs while remaining nonzero execution-time
# slippage checks. See RELEASE.md for the measured generation-4 instant-canary amounts.
HOOKR_LAUNCHPAD_ADDRESS="$PAD" \
HOOKR_HOOK_ADDRESS="$HOOK" \
HOOKR_SWAP_ROUTER_ADDRESS="$ROUTER" \
HOOKR_LAUNCHPAD_RUNTIME_CODEHASH="$PAD_HASH" \
HOOKR_HOOK_RUNTIME_CODEHASH="$HOOK_HASH" \
HOOKR_SWAP_ROUTER_RUNTIME_CODEHASH="$ROUTER_HASH" \
CANARY_BUY_MIN_TOKENS_OUT=20000000000000000000000000 \
CANARY_SELL_MIN_WEI_OUT=2000000000000 \
forge script script/CanaryRobinhood.s.sol \
  --rpc-url "$RPC" \
  "${SIGNER_ARGS[@]}" \
  --sender "$SENDER" \
  --broadcast --slow "$@"
