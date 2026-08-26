#!/usr/bin/env bash
# Generation-5 Robinhood canary operator. Each high-level mutating workflow is explicitly
# confirmed. This recovery version authenticates the already-mined owner bid as an ordinary raw
# RPC transaction/receipt pair; it never fabricates a Forge artifact or submits that bid again.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: ./run-canary-v5.sh <command>

Read-only commands:
  preflight       Authenticate the 11-receipt deployment plus reused-library evidence and pin it.
  status          Re-read the pinned target, timing, intent state, and canary artifact progress.
  promote-dry-run Verify deployment + all raw canary artifacts and render without writing.

Explicitly confirmed signing workflows:
  phase-a         Recover Phase A after the mined owner bid; sign only HOOKR launch then approve/buy.
  phase-b         Reconcile six settlement outcomes, signing only transitions still missing.
  restore         Emergency recovery only: setAuctionTiming(125000, 0, 1).

Mutating commands require HOOKR_V5_CONFIRM to exactly equal the command name, for example:
  HOOKR_V5_CONFIRM=phase-a ./run-canary-v5.sh phase-a

Environment:
  HOOKR_RPC_URL / ETH_RPC_URL   Robinhood RPC (defaults to the official public RPC).
  HOOKR_UNLOCKED=1             Local loopback rehearsal only; uses an unlocked sender.
  HOOKR_V5_DEPLOY_ARTIFACT     Override the DeployRobinhoodV5 artifact path.
  HOOKR_V5_LIBRARY_EVIDENCE    Override the reused-library evidence path.
  HOOKR_V5_CANARY_STATE        Override the authenticated target-state path.

Never pass a private key or keystore password in argv or an environment variable. Production uses
the local Foundry account `nodar-deployer` and prompts through Foundry's secure signer flow.
EOF
}

COMMAND="${1:-}"
case "$COMMAND" in
  preflight|status|phase-a|phase-b|restore|promote-dry-run) ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) echo "unknown command: $COMMAND" >&2; usage >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo "unexpected arguments after $COMMAND" >&2; exit 2; }

CONTRACTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CONTRACTS_DIR/.." && pwd)"
cd "$CONTRACTS_DIR"

RPC="${HOOKR_RPC_URL:-${ETH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}}"
# Cast reads ETH_RPC_URL, while Foundry 1.5.1's `forge script` reads FOUNDRY_ETH_RPC_URL. Bind both
# to the same authenticated endpoint and keep it out of child-process argv so an Alchemy key cannot
# be recovered from `ps`; the wrapper never prints this value either.
export ETH_RPC_URL="$RPC"
export FOUNDRY_ETH_RPC_URL="$RPC"
SENDER="0x5a52D4B820Ae7F02880d270562950918ACb14aA2"
HOOKR_TOKEN="0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c"
HOOKR_RUNTIME_CODEHASH="0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d"
POOL_MANAGER="0x8366a39CC670B4001A1121B8F6A443A643e40951"
ARBSYS="0x0000000000000000000000000000000000000064"
ROBINHOOD_ARBSYS_MARKER_RUNTIME_CODEHASH="0xbcc90f2d6dada5b18e155c17a1c0a55920aae94f39857d39d0d8ed07ae8f228b"
ARBSYS_SIMULATION_SHIM_RUNTIME_CODEHASH="0x99ffc66255169307643ea33a4748f6537a4f7fb4b486784e17ed581511bfe9a9"
# Robinhood's finalized head has recently trailed latest by ~10k rollup blocks. Finalize the CCA
# before its direct-value bid and retain at least ~200 seconds after finality.
CANARY_AUCTION_DURATION=20000
CANARY_GUARD_BLOCKS=20000
FINISH_MIN_BLOCK_HEADROOM=2000
GUARD_MIN_BLOCK_HEADROOM=2000
FINALITY_WAIT_MAX_SECONDS=1800
ORIGINAL_CANARY_OPERATOR_COMMIT="5662aaaf479aa42beefbd580fb4e91099651b3ef"
OWNER_BID_TRANSACTION_HASH="0x718d6a17d804c80f011814bd90c010257aa4b2edabfb517f91ed0e18e08f5063"
OWNER_BID_NONCE=712
OWNER_BID_ID=3
OWNER_BID_WEI=10500000000000000
OWNER_BID_MAX_PRICE_Q96=814814390533794434497901791991308996217
DEPLOY_ARTIFACT="${HOOKR_V5_DEPLOY_ARTIFACT:-broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json}"
LIBRARY_EVIDENCE="${HOOKR_V5_LIBRARY_EVIDENCE:-release-evidence/v5/reused-launchpad-library.json}"
CANARY_DIR="broadcast/CanaryRobinhoodV5.s.sol/4663"
STATE_PATH="${HOOKR_V5_CANARY_STATE:-$CANARY_DIR/release-target-v5.json}"
PHASE_A_INSTANT_LAUNCH_ARTIFACT="$CANARY_DIR/openInstant-latest.json"
PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ARTIFACT="$CANARY_DIR/buyInstantLaunchAuction-latest.json"
PHASE_A_OWNER_BID_TRANSACTION="$CANARY_DIR/owner-bid-transaction.json"
PHASE_A_OWNER_BID_RECEIPT="$CANARY_DIR/owner-bid-receipt.json"
PHASE_A_HOOKR_LAUNCH_ARTIFACT="$CANARY_DIR/launchHookrPair-latest.json"
PHASE_A_HOOKR_APPROVE_BUY_ARTIFACT="$CANARY_DIR/buyHookrPair-latest.json"
PHASE_A_INDEX="$CANARY_DIR/phase-a-evidence-v5.json"
PHASE_A_ABANDONED="$CANARY_DIR/phase-a-abandoned-v5.json"
PHASE_B_EVIDENCE_DIR="$CANARY_DIR/phase-b-evidence-v5"
PHASE_B_INDEX="$CANARY_DIR/phase-b-evidence-v5.json"
PHASE_B_JOURNAL_DIR="$CANARY_DIR/phase-b-signing-journal-v5"
SHORTEN_RECEIPT="$CANARY_DIR/timing-shorten-receipt.json"
SHORTEN_TRANSACTION="$CANARY_DIR/timing-shorten-transaction.json"
RESTORE_RECEIPT="$CANARY_DIR/timing-restore-receipt.json"
RESTORE_TRANSACTION="$CANARY_DIR/timing-restore-transaction.json"

# Every command takes one exclusive operator lock before it may inspect or mutate local release
# state. This prevents a second signer process from racing timing/nonces and prevents a read-only
# invocation from deleting an active Forge cache. A SIGKILL/power loss leaves a deliberate stale
# lock that must be inspected and removed manually; it is never guessed stale by PID alone.
mkdir -p "$CANARY_DIR"
OPERATOR_LOCK="$CANARY_DIR/.operator-lock"
OPERATOR_LOCK_HELD=0
release_operator_lock() {
  if [ "$OPERATOR_LOCK_HELD" -eq 1 ]; then
    LOCK_OWNER="$(sed -n '1p' "$OPERATOR_LOCK/pid" 2>/dev/null || true)"
    if [ "$LOCK_OWNER" = "$$" ]; then
      rm -f -- "$OPERATOR_LOCK/pid"
      rmdir -- "$OPERATOR_LOCK" 2>/dev/null || true
    else
      echo "operator lock ownership changed; leaving $OPERATOR_LOCK intact" >&2
    fi
    OPERATOR_LOCK_HELD=0
  fi
}
if ! mkdir "$OPERATOR_LOCK" 2>/dev/null; then
  LOCK_PID="$(sed -n '1p' "$OPERATOR_LOCK/pid" 2>/dev/null || true)"
  echo "another V5 operator invocation holds $OPERATOR_LOCK${LOCK_PID:+ (pid $LOCK_PID)}" >&2
  echo "Do not remove it while that process may be active. After a confirmed crash, inspect timing, nonces, receipts, and the PID before deleting only this lock directory." >&2
  exit 1
fi
printf '%s\n' "$$" >"$OPERATOR_LOCK/pid"
OPERATOR_LOCK_HELD=1
trap release_operator_lock EXIT

# Forge writes the resolved RPC endpoint into its resumable script cache. This operator never
# resumes, so Phase A alone removes exact-prefix remnants from a confirmed prior invocation after
# exclusivity is established. Read-only/status commands never delete local evidence or caches.
if [ "$COMMAND" = "phase-a" ]; then
  for stale_canary_cache in "$CANARY_DIR"/.sensitive-cache.*; do
    [ -d "$stale_canary_cache" ] || continue
    rm -r -- "$stale_canary_cache"
  done
fi

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$CONTRACTS_DIR" "$1" ;;
  esac
}

DEPLOY_ABS="$(absolute_path "$DEPLOY_ARTIFACT")"
LIBRARY_EVIDENCE_ABS="$(absolute_path "$LIBRARY_EVIDENCE")"
STATE_ABS="$(absolute_path "$STATE_PATH")"
PHASE_A_INSTANT_LAUNCH_ABS="$(absolute_path "$PHASE_A_INSTANT_LAUNCH_ARTIFACT")"
PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS="$(absolute_path "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ARTIFACT")"
PHASE_A_OWNER_BID_TRANSACTION_ABS="$(absolute_path "$PHASE_A_OWNER_BID_TRANSACTION")"
PHASE_A_OWNER_BID_RECEIPT_ABS="$(absolute_path "$PHASE_A_OWNER_BID_RECEIPT")"
PHASE_A_HOOKR_LAUNCH_ABS="$(absolute_path "$PHASE_A_HOOKR_LAUNCH_ARTIFACT")"
PHASE_A_HOOKR_APPROVE_BUY_ABS="$(absolute_path "$PHASE_A_HOOKR_APPROVE_BUY_ARTIFACT")"
PHASE_A_INDEX_ABS="$(absolute_path "$PHASE_A_INDEX")"
PHASE_A_ABANDONED_ABS="$(absolute_path "$PHASE_A_ABANDONED")"
PHASE_B_EVIDENCE_DIR_ABS="$(absolute_path "$PHASE_B_EVIDENCE_DIR")"
PHASE_B_INDEX_ABS="$(absolute_path "$PHASE_B_INDEX")"
PHASE_B_JOURNAL_DIR_ABS="$(absolute_path "$PHASE_B_JOURNAL_DIR")"
SHORTEN_RECEIPT_ABS="$(absolute_path "$SHORTEN_RECEIPT")"
SHORTEN_TRANSACTION_ABS="$(absolute_path "$SHORTEN_TRANSACTION")"
RESTORE_RECEIPT_ABS="$(absolute_path "$RESTORE_RECEIPT")"
RESTORE_TRANSACTION_ABS="$(absolute_path "$RESTORE_TRANSACTION")"

for required in cast forge node git shasum; do
  command -v "$required" >/dev/null || { echo "missing required command: $required" >&2; exit 1; }
done

# Foundry transport failures may echo the resolved endpoint. Preserve each child's real exit status
# and stdin/TTY while filtering stderr through an env-only streaming redactor; no secret is placed
# in argv. The redactor also handles URI-encoded and chunk-split endpoint forms.
RPC_STDERR_REDACTOR="$REPO_ROOT/scripts/redact-rpc-stream.mjs"
[ -f "$RPC_STDERR_REDACTOR" ] || { echo "RPC stderr redactor is missing" >&2; exit 1; }
PHASE_B_COLLECTOR="$REPO_ROOT/scripts/collect-v5-phase-b-evidence.mjs"
PHASE_B_BUILDER="$REPO_ROOT/scripts/build-v5-phase-b-evidence.mjs"
[ -f "$PHASE_B_COLLECTOR" ] || { echo "Phase-B evidence collector is missing" >&2; exit 1; }
[ -f "$PHASE_B_BUILDER" ] || { echo "Phase-B evidence builder is missing" >&2; exit 1; }
cast() { command cast "$@" 2> >(node "$RPC_STDERR_REDACTOR" >&2); }
forge() { command forge "$@" 2> >(node "$RPC_STDERR_REDACTOR" >&2); }

RPC_HOST="$(node -e '
  try { const u = new URL(process.env.ETH_RPC_URL); if (!u.hostname) process.exit(1); process.stdout.write(u.hostname); }
  catch { process.exit(1); }
')" || { echo "HOOKR_RPC_URL is not a valid URL" >&2; exit 1; }
case "$RPC_HOST" in
  localhost|::1|\[::1\]|127.*) LOOPBACK=1 ;;
  *) LOOPBACK=0 ;;
esac

CHAIN_ID="$(cast chain-id)"
[ "$CHAIN_ID" = "4663" ] || { echo "configured RPC reports chain $CHAIN_ID, expected 4663" >&2; exit 1; }
echo "Robinhood RPC authenticated: chain $CHAIN_ID"

if [ "${HOOKR_UNLOCKED:-0}" = "1" ]; then
  [ "$LOOPBACK" = "1" ] || { echo "HOOKR_UNLOCKED=1 is refused for a non-loopback RPC" >&2; exit 1; }
  SIGNER_ARGS=(--unlocked)
  CAST_SIGNER_ARGS=(--unlocked --from "$SENDER")
  REHEARSAL_ARGS=(--rehearsal)
  echo "REHEARSAL MODE: unlocked sender on loopback; no production keystore."
else
  [ "$LOOPBACK" = "0" ] || {
    echo "refusing to load the production keystore against loopback; set HOOKR_UNLOCKED=1 for a fork" >&2
    exit 1
  }
  case "$RPC" in
    https://*) ;;
    *) echo "production operation requires an https RPC" >&2; exit 1 ;;
  esac
  SIGNER_ARGS=(--account nodar-deployer)
  CAST_SIGNER_ARGS=(--account nodar-deployer --from "$SENDER")
  REHEARSAL_ARGS=()
  # Do not let a caller-supplied rehearsal exception reach the production script.
  unset HOOKR_CANARY_ALLOW_PREINSTALLED_ARBSYS_SHIM
fi

same_hex() {
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]
}

sha256_path() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_clean_source() {
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]; then
    echo "release source is dirty; commit or remove every change before authenticating or signing" >&2
    git -C "$REPO_ROOT" status --short >&2
    exit 1
  fi
}

read_call() {
  local target="$1" signature="$2"
  shift 2
  cast call "$target" "$signature" "$@" | tr -d '"'
}

runtime_hash() {
  # Hash the runtime bytes returned by eth_getCode directly. Some fork RPCs report the empty-code
  # hash through eth_getProof/codehash even while serving the correct inherited runtime; the
  # production verifiers authenticate this same getCode byte string and must agree with us.
  cast code "$1" | cast keccak
}

timing() {
  printf '%s %s %s\n' \
    "$(read_call "$PAD" 'auctionDurationBlocks()(uint64)' | awk '{print $1}')" \
    "$(read_call "$PAD" 'claimDelayBlocks()(uint64)' | awk '{print $1}')" \
    "$(read_call "$PAD" 'migrationDelayBlocks()(uint64)' | awk '{print $1}')"
}

require_timing() {
  local expected="$1" current
  current="$(timing)"
  [ "$current" = "$expected" ] || {
    echo "auction timing is $current, expected $expected" >&2
    exit 1
  }
}

require_confirmation() {
  [ "${HOOKR_V5_CONFIRM:-}" = "$COMMAND" ] || {
    echo "signing blocked: set HOOKR_V5_CONFIRM=$COMMAND for this one stage" >&2
    exit 1
  }
}

# Prints burner, launchpad, hook, router and the artifact commit. The new deployment deliberately
# contains 11 transactions because the exact reviewed HookrLaunchpadLibV5 is already deployed;
# the read-only verifier binds its separate provenance record as the twelfth logical receipt.
deploy_facts() {
  node - "$DEPLOY_ABS" <<'NODE'
const fs = require("node:fs");
const path = process.argv[2];
const d = JSON.parse(fs.readFileSync(path, "utf8"));
const tx = d.transactions || [];
const rc = d.receipts || [];
const fail = (m) => { throw new Error(`${path}: ${m}`); };
if (tx.length !== 11 || rc.length !== 11) fail(`expected 11/11 transactions/receipts, found ${tx.length}/${rc.length}`);
const names = ["HookrFlywheelBurner", "HookrLaunchpadV5", "HookrHook", "HookrSwapRouter"];
for (let i = 0; i < names.length; i += 1) {
  if (tx[i]?.contractName !== names[i]) fail(`tx #${i} is ${tx[i]?.contractName}, expected ${names[i]}`);
}
const fns = ["setHook", "setHook", "saveBlueprint", "saveBlueprint", "saveBlueprint", "saveBlueprint", "saveBlueprint"];
for (let i = 0; i < fns.length; i += 1) {
  if (!String(tx[i + 4]?.function || "").startsWith(fns[i])) fail(`tx #${i + 4} is not ${fns[i]}()`);
}
if (rc.some((r) => r.status !== "0x1")) fail("a deployment receipt is not successful");
if (!d.commit) fail("artifact has no source commit");
for (const i of [0, 1, 2, 3]) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(tx[i].contractAddress || "")) fail(`tx #${i} has no contract address`);
}
process.stdout.write(`${[tx[0].contractAddress, tx[1].contractAddress, tx[2].contractAddress, tx[3].contractAddress, d.commit].join(" ")}\n`);
NODE
}

load_deploy_facts() {
  [ -f "$DEPLOY_ABS" ] || { echo "missing deployment artifact: $DEPLOY_ABS" >&2; exit 1; }
  [ -f "$LIBRARY_EVIDENCE_ABS" ] || { echo "missing reused-library evidence: $LIBRARY_EVIDENCE_ABS" >&2; exit 1; }
  read -r BURNER PAD HOOK ROUTER ARTIFACT_COMMIT < <(deploy_facts)
  CANARY_OPERATOR_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  DEPLOYMENT_SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse "$ARTIFACT_COMMIT")"
  git -C "$REPO_ROOT" merge-base --is-ancestor "$DEPLOYMENT_SOURCE_COMMIT" "$CANARY_OPERATOR_COMMIT" || {
    echo "deployment source $DEPLOYMENT_SOURCE_COMMIT is not an ancestor of canary operator $CANARY_OPERATOR_COMMIT" >&2
    exit 1
  }
  [ "$DEPLOYMENT_SOURCE_COMMIT" != "$CANARY_OPERATOR_COMMIT" ] || {
    echo "canary operator must be a descendant commit carrying the reviewed ArbSys shim" >&2
    exit 1
  }
  [ "$(git -C "$REPO_ROOT" diff --name-only "$DEPLOYMENT_SOURCE_COMMIT" \
    "$CANARY_OPERATOR_COMMIT" -- contracts/script/CanaryRobinhoodV5.s.sol)" = \
    "contracts/script/CanaryRobinhoodV5.s.sol" ] || {
    echo "canary operator does not carry the reviewed CanaryRobinhoodV5 source update" >&2
    exit 1
  }
  DEPLOYED_SOURCE_DIFF="$(git -C "$REPO_ROOT" diff --name-only \
    "$DEPLOYMENT_SOURCE_COMMIT" "$CANARY_OPERATOR_COMMIT" -- \
    contracts/src contracts/lib contracts/foundry.toml contracts/script/DeployRobinhoodV5.s.sol)"
  [ -z "$DEPLOYED_SOURCE_DIFF" ] || {
    echo "deployed contract/source inputs changed after $DEPLOYMENT_SOURCE_COMMIT:" >&2
    printf '%s\n' "$DEPLOYED_SOURCE_DIFF" >&2
    exit 1
  }
}

write_authenticated_state() {
  local state_dir state_tmp
  state_dir="$(dirname "$STATE_ABS")"
  mkdir -p "$state_dir"
  state_tmp="$(mktemp "$state_dir/.release-target-v5.XXXXXX")"
  node - "$state_tmp" "$DEPLOYMENT_SOURCE_COMMIT" "$CANARY_OPERATOR_COMMIT" \
    "$(sha256_path "$DEPLOY_ABS")" \
    "$(sha256_path "$LIBRARY_EVIDENCE_ABS")" "$BURNER" "$PAD" "$HOOK" "$ROUTER" \
    "$(runtime_hash "$BURNER")" "$(runtime_hash "$PAD")" "$(runtime_hash "$HOOK")" \
    "$(runtime_hash "$ROUTER")" <<'NODE'
const fs = require("node:fs");
const [path, deploymentSourceCommit, canaryOperatorCommit, deploySha256, libraryEvidenceSha256,
  burner, launchpad, hook, router,
  burnerRuntimeCodeHash, launchpadRuntimeCodeHash, hookRuntimeCodeHash, routerRuntimeCodeHash] = process.argv.slice(2);
const record = {
  kind: "hookr-v5-canary-target-v2",
  chainId: 4663,
  deploymentSourceCommit,
  canaryOperatorCommit,
  deploySha256,
  libraryEvidenceSha256,
  burner,
  launchpad,
  hook,
  router,
  burnerRuntimeCodeHash,
  launchpadRuntimeCodeHash,
  hookRuntimeCodeHash,
  routerRuntimeCodeHash,
  authenticatedAt: new Date().toISOString(),
};
fs.writeFileSync(path, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
NODE
  mv "$state_tmp" "$STATE_ABS"
  chmod 600 "$STATE_ABS"
}

load_authenticated_state() {
  load_deploy_facts
  [ -f "$STATE_ABS" ] || {
    echo "missing authenticated target state: run ./run-canary-v5.sh preflight first" >&2
    exit 1
  }
  read -r STATE_DEPLOYMENT_COMMIT STATE_OPERATOR_COMMIT STATE_DEPLOY_SHA STATE_LIBRARY_SHA \
    STATE_BURNER STATE_PAD STATE_HOOK STATE_ROUTER \
    BURNER_HASH PAD_HASH HOOK_HASH ROUTER_HASH < <(node - "$STATE_ABS" <<'NODE'
const fs = require("node:fs");
const p = process.argv[2];
const d = JSON.parse(fs.readFileSync(p, "utf8"));
const fail = (m) => { throw new Error(`${p}: ${m}`); };
if (d.kind !== "hookr-v5-canary-target-v2" || d.chainId !== 4663) fail("wrong state kind or chain");
for (const k of ["deploymentSourceCommit", "canaryOperatorCommit"]) {
  if (!/^[0-9a-fA-F]{40}$/.test(d[k] || "")) fail(`${k} is malformed`);
}
for (const k of ["deploySha256", "libraryEvidenceSha256"]) {
  if (!/^[0-9a-fA-F]{64}$/.test(d[k] || "")) fail(`${k} is malformed`);
}
for (const k of ["burnerRuntimeCodeHash", "launchpadRuntimeCodeHash", "hookRuntimeCodeHash",
  "routerRuntimeCodeHash"]) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(d[k] || "")) fail(`${k} is malformed`);
}
for (const k of ["burner", "launchpad", "hook", "router"]) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(d[k] || "")) fail(`${k} is malformed`);
}
process.stdout.write(`${[d.deploymentSourceCommit, d.canaryOperatorCommit, d.deploySha256,
  d.libraryEvidenceSha256, d.burner, d.launchpad,
  d.hook, d.router, d.burnerRuntimeCodeHash, d.launchpadRuntimeCodeHash,
  d.hookRuntimeCodeHash, d.routerRuntimeCodeHash].join(" ")}\n`);
NODE
  )
  [ "$STATE_DEPLOYMENT_COMMIT" = "$DEPLOYMENT_SOURCE_COMMIT" ] || {
    echo "authenticated state belongs to a different deployment source" >&2; exit 1;
  }
  STATE_OPERATOR_RESOLVED="$(git -C "$REPO_ROOT" rev-parse --verify \
    "$STATE_OPERATOR_COMMIT^{commit}" 2>/dev/null)" || {
    echo "authenticated target operator commit is unavailable or ambiguous" >&2; exit 1;
  }
  [ "$STATE_OPERATOR_RESOLVED" = "$STATE_OPERATOR_COMMIT" ] || {
    echo "authenticated target operator commit is unavailable or ambiguous" >&2; exit 1;
  }
  git -C "$REPO_ROOT" merge-base --is-ancestor \
    "$DEPLOYMENT_SOURCE_COMMIT" "$STATE_OPERATOR_COMMIT" || {
    echo "authenticated target operator does not descend from the deployment source" >&2; exit 1;
  }
  git -C "$REPO_ROOT" merge-base --is-ancestor \
    "$STATE_OPERATOR_COMMIT" "$CANARY_OPERATOR_COMMIT" || {
    echo "current tooling head does not descend from the authenticated target operator" >&2; exit 1;
  }
  STATE_DEPLOYED_SOURCE_DIFF="$(git -C "$REPO_ROOT" diff --name-only \
    "$DEPLOYMENT_SOURCE_COMMIT" "$STATE_OPERATOR_COMMIT" -- \
    contracts/src contracts/lib contracts/foundry.toml contracts/script/DeployRobinhoodV5.s.sol)"
  [ -z "$STATE_DEPLOYED_SOURCE_DIFF" ] || {
    echo "authenticated target operator changed deployed contract/source inputs:" >&2
    printf '%s\n' "$STATE_DEPLOYED_SOURCE_DIFF" >&2
    exit 1
  }
  TOOLING_DEPLOYED_SOURCE_DIFF="$(git -C "$REPO_ROOT" diff --name-only \
    "$STATE_OPERATOR_COMMIT" "$CANARY_OPERATOR_COMMIT" -- \
    contracts/src contracts/lib contracts/foundry.toml contracts/script/DeployRobinhoodV5.s.sol)"
  [ -z "$TOOLING_DEPLOYED_SOURCE_DIFF" ] || {
    echo "current tooling head changed deployed inputs after target authentication:" >&2
    printf '%s\n' "$TOOLING_DEPLOYED_SOURCE_DIFF" >&2
    exit 1
  }
  [ "$STATE_DEPLOY_SHA" = "$(sha256_path "$DEPLOY_ABS")" ] || { echo "deployment artifact changed after preflight" >&2; exit 1; }
  [ "$STATE_LIBRARY_SHA" = "$(sha256_path "$LIBRARY_EVIDENCE_ABS")" ] || { echo "library evidence changed after preflight" >&2; exit 1; }
  same_hex "$STATE_BURNER" "$BURNER" && same_hex "$STATE_PAD" "$PAD" && \
    same_hex "$STATE_HOOK" "$HOOK" && same_hex "$STATE_ROUTER" "$ROUTER" || {
      echo "deployment addresses changed after preflight" >&2; exit 1;
    }
  same_hex "$(runtime_hash "$BURNER")" "$BURNER_HASH" || { echo "burner runtime changed after preflight" >&2; exit 1; }
  same_hex "$(runtime_hash "$PAD")" "$PAD_HASH" || { echo "launchpad runtime changed after preflight" >&2; exit 1; }
  same_hex "$(runtime_hash "$HOOK")" "$HOOK_HASH" || { echo "hook runtime changed after preflight" >&2; exit 1; }
  same_hex "$(runtime_hash "$ROUTER")" "$ROUTER_HASH" || { echo "router runtime changed after preflight" >&2; exit 1; }
  same_hex "$(runtime_hash "$HOOKR_TOKEN")" "$HOOKR_RUNTIME_CODEHASH" || { echo "HOOKR runtime is not the reviewed token" >&2; exit 1; }

  [ "$(read_call "$PAD" 'contractVersion()(string)')" = "5.0.1" ] || { echo "launchpad is not V5.0.1" >&2; exit 1; }
  [ "$(read_call "$BURNER" 'contractVersion()(string)')" = "1.0.1" ] || { echo "burner is not the owner-bounded V1.0.1" >&2; exit 1; }
  same_hex "$(read_call "$PAD" 'owner()(address)')" "$SENDER" || { echo "launchpad owner is not the reviewed deployer" >&2; exit 1; }
  same_hex "$(read_call "$BURNER" 'owner()(address)')" "$SENDER" || { echo "burner owner is not the reviewed deployer" >&2; exit 1; }
  same_hex "$(read_call "$PAD" 'hook()(address)')" "$HOOK" || { echo "launchpad/hook wiring changed" >&2; exit 1; }
  same_hex "$(read_call "$HOOK" 'launchpad()(address)')" "$PAD" || { echo "hook/launchpad wiring changed" >&2; exit 1; }
  same_hex "$(read_call "$ROUTER" 'hook()(address)')" "$HOOK" || { echo "router/hook wiring changed" >&2; exit 1; }
  same_hex "$(read_call "$HOOK" 'flywheelRecipient()(address)')" "$BURNER" || { echo "hook/burner wiring changed" >&2; exit 1; }
  same_hex "$(read_call "$BURNER" 'hook()(address)')" "$HOOK" || { echo "burner/hook wiring changed" >&2; exit 1; }
  same_hex "$(read_call "$PAD" 'hookrToken()(address)')" "$HOOKR_TOKEN" || { echo "launchpad HOOKR token changed" >&2; exit 1; }
  same_hex "$(read_call "$BURNER" 'hookrToken()(address)')" "$HOOKR_TOKEN" || { echo "burner HOOKR token changed" >&2; exit 1; }
  same_hex "$(read_call "$BURNER" 'poolManager()(address)')" "$POOL_MANAGER" || { echo "burner PoolManager changed" >&2; exit 1; }
  [ "$(read_call "$BURNER" 'poolFee()(uint24)' | awk '{print $1}')" = "2500" ] || { echo "burner pool fee changed" >&2; exit 1; }
  [ "$(read_call "$BURNER" 'poolTickSpacing()(int24)' | awk '{print $1}')" = "25" ] || { echo "burner pool tick spacing changed" >&2; exit 1; }
}

block_hash() {
  cast block "$1" --field hash | tr -d '"'
}

# Read one launch identity from a single canonical block, then re-authenticate that block hash.
# The following Forge entrypoint independently rechecks the same identity at latest immediately
# before startBroadcast, so neither a mixed-head RPC read nor a reorg can authorize stale calldata.
authenticated_launch_record() {
  local intent="$1" expected_mode="$2" expected_status="$3" expected_quote="$4" label="$5"
  local auth_block auth_hash auth_hash_after token token_code launch_json parsed auction auction_end live_end
  # The creating receipt has already been proven finalized by the caller. Read its immutable
  # identity from one current numeric head (historical-state support is not assumed), hash-pin that
  # head across every call, then let the Forge entrypoint recheck latest before signing.
  auth_block="$(cast block-number)"
  auth_hash="$(block_hash "$auth_block")"
  [ -n "$auth_hash" ] || { echo "$label authentication block has no hash" >&2; return 1; }
  token="$(cast call "$PAD" 'launchedByIntent(address,bytes32)(address)' "$SENDER" "$intent" \
    --block "$auth_block" | tr -d '"')"
  [ "$token" != "0x0000000000000000000000000000000000000000" ] || {
    echo "the authenticated $label intent is not onchain" >&2
    return 1
  }
  token_code="$(cast code "$token" --block "$auth_block")"
  [ "$token_code" != "0x" ] || { echo "$label token $token has no code at block $auth_block" >&2; return 1; }
  launch_json="$(cast call "$PAD" \
    'getLaunch(address)((address,address,uint40,uint32,uint8,uint8,uint96,uint96,uint16,address,uint40,uint40,uint160,bytes32,uint8,(uint32,uint16,uint24,uint24,uint24,uint16,uint16,uint96,uint16,uint16,uint32,uint96)))' \
    "$token" --block "$auth_block" --json)"
  parsed="$(node -e '
    const [raw, token, sender, modeRaw, statusRaw, quoteRaw, label] = process.argv.slice(1);
    const launch = JSON.parse(raw)?.[0];
    const zero = "0x0000000000000000000000000000000000000000";
    const fail = (message) => { throw new Error(`${label}: ${message}`); };
    if (!Array.isArray(launch) || String(launch[0]).toLowerCase() !== token.toLowerCase()) fail("token identity is wrong");
    if (String(launch[1]).toLowerCase() !== sender.toLowerCase()) fail("creator identity is wrong");
    const acceptedStatuses = statusRaw.split(",").map(Number);
    if (Number(launch[4]) !== Number(modeRaw) || !acceptedStatuses.includes(Number(launch[5])) ||
      Number(launch[14]) !== Number(quoteRaw)) fail("mode, status, or quote is wrong");
    const auction = String(launch[9] || zero);
    const auctionEnd = BigInt(launch[10] || 0);
    if (Number(modeRaw) === 0 && (auction.toLowerCase() !== zero || auctionEnd !== 0n)) {
      fail("instant launch unexpectedly carries auction state");
    }
    if (Number(modeRaw) === 1 && (!/^0x[0-9a-fA-F]{40}$/.test(auction) || auction.toLowerCase() === zero)) {
      fail("bonded launch has no CCA");
    }
    process.stdout.write(`${token} ${auction} ${auctionEnd}`);
  ' "$launch_json" "$token" "$SENDER" "$expected_mode" "$expected_status" "$expected_quote" "$label")"
  read -r token auction auction_end <<<"$parsed"
  if [ "$expected_mode" = "1" ]; then
    [ "$(cast code "$auction" --block "$auth_block")" != "0x" ] || {
      echo "$label CCA $auction has no code at block $auth_block" >&2; return 1;
    }
    live_end="$(cast call "$auction" 'endBlock()(uint64)' --block "$auth_block" | awk '{print $1}')"
    [ "$live_end" = "$auction_end" ] || { echo "$label CCA end block differs from launch state" >&2; return 1; }
  fi
  auth_hash_after="$(block_hash "$auth_block")"
  same_hex "$auth_hash_after" "$auth_hash" || {
    echo "$label authentication block reorged during the pinned read" >&2
    return 1
  }
  printf '%s %s %s %s %s\n' "$token" "$auction" "$auction_end" "$auth_block" "$auth_hash"
}

authenticated_instant() {
  authenticated_launch_record \
    0x63ae3076275e7bf7e65f41aa51544acf063c28f2d1b15d0b1e32ea0a0e9aa2fc 0 1 0 "instant canary"
}

authenticated_auction() {
  # Recovery of the independent HOOKR lane remains valid whether a permissionless caller has
  # already migrated the ETH auction. Accept only Auctioning or Live; Failed remains rejected.
  local expected_status="${1:-0,1}"
  authenticated_launch_record \
    0x9c7799db40fdcc5f1cd5a73434b75f784cb5bc1104c6a27cef34d4e7fb1e33ac \
    1 "$expected_status" 0 "auction canary"
}

authenticated_hookr_pair() {
  authenticated_launch_record \
    0x1b07b8b1c7415899dbedbc5591619f7c0996781efbf575f67e5640297c765476 0 1 1 "HOOKR-pair canary"
}

# Phase A is immutable evidence, not a label that follows later tooling. Once its v3 index exists,
# derive the recovery commit from that index and authenticate the exact commit/ancestry/source
# boundary before using it to validate either mined Forge artifact. Phase B continues to record the
# current clean tooling head independently in its own signing plans and evidence.
authenticate_phase_a_recovery_commit() {
  local indexed_commit resolved_commit recovery_deployed_diff tooling_canary_diff tooling_deployed_diff
  [ -f "$PHASE_A_INDEX_ABS" ] && [ ! -L "$PHASE_A_INDEX_ABS" ] || {
    echo "Phase-A v3 index is missing or symlinked: $PHASE_A_INDEX_ABS" >&2
    return 1
  }
  indexed_commit="$(node - "$PHASE_A_INDEX_ABS" "$DEPLOYMENT_SOURCE_COMMIT" \
    "$ORIGINAL_CANARY_OPERATOR_COMMIT" <<'NODE'
const fs = require("node:fs");
const [path, deploymentSourceCommit, originalCanaryOperatorCommit] = process.argv.slice(2);
const d = JSON.parse(fs.readFileSync(path, "utf8"));
const fail = (message) => { throw new Error(`${path}: ${message}`); };
if (d.kind !== "hookr-v5-phase-a-evidence-v3") fail("wrong evidence kind");
if (d.deploymentSourceCommit !== deploymentSourceCommit) fail("deployment source commit differs");
if (d.originalCanaryOperatorCommit !== originalCanaryOperatorCommit) {
  fail("original canary operator commit differs");
}
if (!/^[0-9a-f]{40}$/.test(d.canaryRecoveryCommit || "")) {
  fail("canaryRecoveryCommit is not one full lowercase commit");
}
process.stdout.write(d.canaryRecoveryCommit);
NODE
  )"
  resolved_commit="$(git -C "$REPO_ROOT" rev-parse --verify "$indexed_commit^{commit}" 2>/dev/null)" || {
    echo "Phase-A recovery commit $indexed_commit is unavailable" >&2
    return 1
  }
  [ "$resolved_commit" = "$indexed_commit" ] || {
    echo "Phase-A recovery commit is ambiguous or not canonical" >&2
    return 1
  }
  git -C "$REPO_ROOT" merge-base --is-ancestor \
    "$DEPLOYMENT_SOURCE_COMMIT" "$resolved_commit" || {
    echo "Phase-A recovery commit does not descend from the deployment source" >&2
    return 1
  }
  git -C "$REPO_ROOT" merge-base --is-ancestor \
    "$resolved_commit" "$CANARY_OPERATOR_COMMIT" || {
    echo "current tooling head does not descend from the indexed Phase-A recovery commit" >&2
    return 1
  }
  [ "$STATE_OPERATOR_COMMIT" = "$resolved_commit" ] || {
    echo "authenticated target operator does not equal the indexed Phase-A recovery commit" >&2
    return 1
  }
  [ "$(git -C "$REPO_ROOT" diff --name-only "$DEPLOYMENT_SOURCE_COMMIT" \
    "$resolved_commit" -- contracts/script/CanaryRobinhoodV5.s.sol)" = \
    "contracts/script/CanaryRobinhoodV5.s.sol" ] || {
    echo "indexed Phase-A recovery commit does not carry exactly the reviewed canary script update" >&2
    return 1
  }
  recovery_deployed_diff="$(git -C "$REPO_ROOT" diff --name-only \
    "$DEPLOYMENT_SOURCE_COMMIT" "$resolved_commit" -- \
    contracts/src contracts/lib contracts/foundry.toml contracts/script/DeployRobinhoodV5.s.sol)"
  [ -z "$recovery_deployed_diff" ] || {
    echo "indexed Phase-A recovery commit changed deployed contract/source inputs:" >&2
    printf '%s\n' "$recovery_deployed_diff" >&2
    return 1
  }
  tooling_canary_diff="$(git -C "$REPO_ROOT" diff --name-only \
    "$resolved_commit" "$CANARY_OPERATOR_COMMIT" -- \
    contracts/script/CanaryRobinhoodV5.s.sol)"
  [ -z "$tooling_canary_diff" ] || {
    echo "descendant Phase-B tooling changed the mined canary script:" >&2
    printf '%s\n' "$tooling_canary_diff" >&2
    return 1
  }
  tooling_deployed_diff="$(git -C "$REPO_ROOT" diff --name-only \
    "$resolved_commit" "$CANARY_OPERATOR_COMMIT" -- \
    contracts/src contracts/lib contracts/foundry.toml contracts/script/DeployRobinhoodV5.s.sol)"
  [ -z "$tooling_deployed_diff" ] || {
    echo "descendant Phase-B tooling changed deployed contract/source inputs:" >&2
    printf '%s\n' "$tooling_deployed_diff" >&2
    return 1
  }
  PHASE_A_RECOVERY_COMMIT="$resolved_commit"
}

raw_phase_artifact_check() {
  local path="$1" phase="$2" expected_count="$3" expected_nonce="${4:-}"
  local expected_source_commit
  case "$phase" in
    instant-launch|instant-buy-auction-launch) expected_source_commit="$ORIGINAL_CANARY_OPERATOR_COMMIT" ;;
    hookr-launch|hookr-approve-buy) \
      expected_source_commit="${PHASE_A_RECOVERY_COMMIT:-$CANARY_OPERATOR_COMMIT}" ;;
    *) echo "unknown Phase-A Forge artifact stage: $phase" >&2; return 1 ;;
  esac
  node - "$path" "$phase" "$expected_count" "$SENDER" "$expected_source_commit" \
    "$PAD" "$ROUTER" "$BURNER" "$HOOKR_TOKEN" "$expected_nonce" <<'NODE'
const fs = require("node:fs");
const [path, phase, expectedRaw, sender, expectedSourceCommit, pad, router, burner, hookrToken, expectedNonce] = process.argv.slice(2);
const expected = Number(expectedRaw);
const d = JSON.parse(fs.readFileSync(path, "utf8"));
const tx = d.transactions || [];
const rc = d.receipts || [];
const fail = (m) => { throw new Error(`${path}: ${m}`); };
const shapes = {
  "instant-launch": {
    functions: ["launchInstant"], targets: [pad], values: ["200000000000000"],
  },
  "instant-buy-auction-launch": {
    functions: ["exactInput", "launchAuction"], targets: [router, pad],
    values: ["1000000000000000", "200000000000000"],
  },
  "hookr-launch": {
    functions: ["launchInstant"], targets: [pad], values: ["200000000000000"],
  },
  "hookr-approve-buy": {
    functions: ["approve", "exactInput"], targets: [hookrToken, router], values: ["0", "0"],
  },
};
const shape = shapes[phase];
if (!shape) fail(`unknown phase ${phase}`);
const expectedFns = shape.functions;
if (tx.length !== expected || expectedFns.length !== expected) fail(`expected ${expected} transactions, found ${tx.length}`);
if (rc.length !== expected) fail(`incomplete receipts: ${rc.length}/${expected}`);
for (let i = 0; i < expected; i += 1) {
  if (!String(tx[i]?.function || "").startsWith(expectedFns[i])) fail(`tx #${i} is not ${expectedFns[i]}()`);
  if (String(tx[i]?.transaction?.from || "").toLowerCase() !== sender.toLowerCase()) fail(`tx #${i} sender is wrong`);
  const target = shape.targets[i];
  if (String(tx[i]?.transaction?.to || "").toLowerCase() !== target.toLowerCase()) {
    fail(`tx #${i} target is not the authenticated ${target}`);
  }
  if (BigInt(tx[i]?.transaction?.value ?? 0) !== BigInt(shape.values[i])) {
    fail(`tx #${i} value is not ${shape.values[i]}`);
  }
}
if (tx.some((item) => String(item?.transaction?.to || "").toLowerCase() ===
  "0x0000000000000000000000000000000000000064")) {
  fail("ArbSys shim must never enter the broadcast transaction list");
}
if (rc.some((r) => r.status !== "0x1")) fail("an existing receipt is not successful");
const txHashes = new Set(tx.map((item, i) => {
  const hash = String(item.hash || "").toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(hash)) fail(`tx #${i} has no valid hash`);
  return hash;
}));
if (txHashes.size !== tx.length) fail("transaction hashes are not unique");
const receiptsByHash = new Map();
for (const [index, receipt] of rc.entries()) {
  const hash = String(receipt.transactionHash || "").toLowerCase();
  if (!txHashes.has(hash)) fail(`receipt #${index} does not bind any artifact transaction`);
  if (receiptsByHash.has(hash)) fail(`receipt #${index} duplicates transaction ${hash}`);
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(receipt.blockHash || ""))) {
    fail(`receipt #${index} has no valid block hash`);
  }
  receiptsByHash.set(hash, receipt);
}
for (const [index, item] of tx.entries()) {
  if (!receiptsByHash.has(String(item.hash).toLowerCase())) fail(`tx #${index} has no matching receipt`);
}
if (!Array.isArray(d.pending)) fail("artifact pending set is missing");
const pending = new Set();
for (const [index, rawHash] of d.pending.entries()) {
  const hash = String(rawHash || "").toLowerCase();
  if (!txHashes.has(hash)) fail(`pending #${index} does not bind any artifact transaction`);
  if (pending.has(hash)) fail(`pending #${index} duplicates transaction ${hash}`);
  if (receiptsByHash.has(hash)) fail(`pending #${index} already has an artifact receipt`);
  pending.add(hash);
}
if (pending.size !== 0) fail("complete artifact still carries pending transaction hashes");
const nonces = tx.map((item, index) => {
  try { return BigInt(item.transaction?.nonce); }
  catch { fail(`tx #${index} has no valid nonce`); }
});
for (let index = 1; index < nonces.length; index += 1) {
  if (nonces[index] !== nonces[0] + BigInt(index)) fail("artifact transaction nonces are not consecutive");
}
if (expectedNonce && nonces[0] !== BigInt(expectedNonce)) {
  fail(`artifact starts at nonce ${nonces[0]}, expected ${expectedNonce}`);
}
const artifactCommit = String(d.commit || "").toLowerCase();
const reviewedCommit = String(expectedSourceCommit || "").toLowerCase();
if (!/^[0-9a-f]{7,40}$/.test(artifactCommit)) fail("artifact has no valid 7-40 hex source commit");
if (!/^[0-9a-f]{40}$/.test(reviewedCommit) || !reviewedCommit.startsWith(artifactCommit)) {
  fail(`artifact commit ${artifactCommit} is not a prefix of reviewed source ${reviewedCommit}`);
}
NODE
  verify_live_forge_artifact "$path"
  verify_live_receipts "$path"
}

# The successful live recovery bid was sent outside Forge after the original two-transaction
# artifact reverted before broadcast. Preserve that fact honestly: authenticate the ordinary raw
# transaction/receipt pair against the live RPC, exact calldata/event, and reviewed chronology.
# This function is read-only and there is deliberately no owner-bid signing path in this wrapper.
owner_bid_receipt_check() {
  local transaction_path="$1" receipt_path="$2" auction="$3" auction_end="$4" expected_nonce="$5"
  local expected_input live_dir
  [ -f "$transaction_path" ] || { echo "owner-bid transaction evidence is missing: $transaction_path" >&2; return 1; }
  [ -f "$receipt_path" ] || { echo "owner-bid receipt evidence is missing: $receipt_path" >&2; return 1; }
  [ "$expected_nonce" = "$OWNER_BID_NONCE" ] || {
    echo "owner-bid chronology expects nonce $OWNER_BID_NONCE, derived $expected_nonce" >&2
    return 1
  }
  expected_input="$(cast calldata 'submitBid(uint256,uint128,address,bytes)' \
    "$OWNER_BID_MAX_PRICE_Q96" "$OWNER_BID_WEI" "$SENDER" 0x)"
  live_dir="$(mktemp -d)"
  if ! cast tx "$OWNER_BID_TRANSACTION_HASH" --json >"$live_dir/transaction.json" || \
    ! cast receipt "$OWNER_BID_TRANSACTION_HASH" --json >"$live_dir/receipt.json"; then
    rm -r -- "$live_dir"
    echo "reviewed owner-bid transaction/receipt is unavailable on this RPC" >&2
    return 1
  fi
  if ! node - "$transaction_path" "$receipt_path" "$live_dir/transaction.json" \
    "$live_dir/receipt.json" "$OWNER_BID_TRANSACTION_HASH" "$expected_nonce" "$SENDER" \
    "$auction" "$auction_end" "$expected_input" "$OWNER_BID_ID" "$OWNER_BID_WEI" \
    "$OWNER_BID_MAX_PRICE_Q96" <<'NODE'
const fs = require("node:fs");
const [txPath, receiptPath, liveTxPath, liveReceiptPath, expectedHash, expectedNonce, sender,
  auction, auctionEnd, expectedInput, expectedBidId, expectedAmount, expectedMaxPrice] = process.argv.slice(2);
const tx = JSON.parse(fs.readFileSync(txPath, "utf8"));
const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
const liveTx = JSON.parse(fs.readFileSync(liveTxPath, "utf8"));
const liveReceipt = JSON.parse(fs.readFileSync(liveReceiptPath, "utf8"));
const fail = (message) => { throw new Error(`${receiptPath}: ${message}`); };
const same = (a, b) => String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();
const sameInt = (a, b, label) => {
  try { if (BigInt(a) !== BigInt(b)) fail(`${label} differs`); }
  catch (error) { if (error.message?.startsWith(`${receiptPath}:`)) throw error; fail(`${label} is not numeric`); }
};
if (!same(tx.hash, expectedHash) || !same(receipt.transactionHash, expectedHash)) fail("hash is not the reviewed owner bid");
if (!same(tx.from, sender) || !same(receipt.from, sender)) fail("sender is wrong");
if (!same(tx.to, auction) || !same(receipt.to, auction)) fail("target is not the authenticated CCA");
if (!same(tx.input, expectedInput)) fail("calldata is not the exact reviewed high-max owner bid");
sameInt(tx.chainId, 4663, "chain id");
sameInt(tx.nonce, expectedNonce, "nonce");
sameInt(tx.value, expectedAmount, "value");
sameInt(receipt.status, 1, "receipt status");
if (!same(tx.blockHash, receipt.blockHash) ||
    BigInt(tx.blockNumber) !== BigInt(receipt.blockNumber) ||
    BigInt(tx.transactionIndex) !== BigInt(receipt.transactionIndex)) {
  fail("raw transaction and receipt canonical coordinates differ");
}
if (BigInt(receipt.blockNumber) >= BigInt(auctionEnd)) fail("owner bid was not mined before auction end");
for (const field of ["hash", "from", "to", "input", "blockHash"]) {
  if (!same(tx[field], liveTx[field])) fail(`raw/live transaction ${field} differs`);
}
for (const field of ["chainId", "nonce", "gas", "value", "blockNumber", "transactionIndex", "type",
  "maxFeePerGas", "maxPriorityFeePerGas", "gasPrice"]) {
  if (tx[field] == null && liveTx[field] == null) continue;
  sameInt(tx[field], liveTx[field], `raw/live transaction ${field}`);
}
for (const field of ["transactionHash", "from", "to", "blockHash", "contractAddress", "logsBloom"]) {
  if (!same(receipt[field], liveReceipt[field])) fail(`raw/live receipt ${field} differs`);
}
for (const field of ["status", "blockNumber", "transactionIndex", "cumulativeGasUsed", "type", "gasUsed",
  "effectiveGasPrice", "gasUsedForL1", "l1BlockNumber"]) {
  if (receipt[field] == null && liveReceipt[field] == null) continue;
  sameInt(receipt[field], liveReceipt[field], `raw/live receipt ${field}`);
}
const rawLogs = receipt.logs || [];
const liveLogs = liveReceipt.logs || [];
if (rawLogs.length !== liveLogs.length) fail("raw/live receipt log count differs");
for (let index = 0; index < rawLogs.length; index += 1) {
  const raw = rawLogs[index];
  const live = liveLogs[index];
  for (const field of ["address", "data", "blockHash", "transactionHash"]) {
    if (!same(raw[field], live[field])) fail(`raw/live log #${index} ${field} differs`);
  }
  for (const field of ["blockNumber", "blockTimestamp", "transactionIndex", "logIndex"]) {
    sameInt(raw[field], live[field], `raw/live log #${index} ${field}`);
  }
  const rawTopics = raw.topics || [];
  const liveTopics = live.topics || [];
  if (rawTopics.length !== liveTopics.length) fail(`raw/live log #${index} topic count differs`);
  rawTopics.forEach((topic, topicIndex) => {
    if (!same(topic, liveTopics[topicIndex])) fail(`raw/live log #${index} topic #${topicIndex} differs`);
  });
  if (raw.removed !== undefined && Boolean(raw.removed) !== Boolean(live.removed)) {
    fail(`raw/live log #${index} removed flag differs`);
  }
}
const bidTopic = "0x650baad5cd8ca09b8f580be220fa04ce2ba905a041f764b6a3fe2c848eb70540";
const ownerTopic = `0x${sender.slice(2).toLowerCase().padStart(64, "0")}`;
const bidLogs = rawLogs.filter((log) => same(log.address, auction) && same(log.topics?.[0], bidTopic));
if (bidLogs.length !== 1) fail(`expected one BidSubmitted event, found ${bidLogs.length}`);
const bidLog = bidLogs[0];
sameInt(bidLog.topics?.[1], expectedBidId, "BidSubmitted id");
if (!same(bidLog.topics?.[2], ownerTopic)) fail("BidSubmitted owner is wrong");
const data = String(bidLog.data || "");
if (!/^0x[0-9a-fA-F]{128}$/.test(data)) fail("BidSubmitted data is malformed");
sameInt(`0x${data.slice(2, 66)}`, expectedMaxPrice, "BidSubmitted max price");
sameInt(`0x${data.slice(66, 130)}`, expectedAmount, "BidSubmitted amount");
NODE
  then
    rm -r -- "$live_dir"
    return 1
  fi
  rm -r -- "$live_dir"
}

# Bind every already-recorded receipt to this RPC's canonical block. This rejects a complete-looking
# local-fork artifact before it can supply a bid id or authorize a later production phase.
verify_live_receipts() {
  local path="$1" hash expected_block expected_number live_block live_status canonical_block receipt_rows failed
  receipt_rows="$(mktemp)"
  if ! node - "$path" >"$receipt_rows" <<'NODE'
const fs = require("node:fs");
const d = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const receipts = Array.isArray(d.receipts) ? d.receipts : [d];
for (const [index, r] of receipts.entries()) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(r.transactionHash || ""))) {
    throw new Error(`artifact receipt #${index} lacks a valid transactionHash`);
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(r.blockHash || ""))) {
    throw new Error(`artifact receipt #${index} lacks a valid blockHash`);
  }
  try { BigInt(r.blockNumber); }
  catch { throw new Error(`artifact receipt #${index} lacks a valid blockNumber`); }
  process.stdout.write(`${r.transactionHash} ${r.blockHash} ${BigInt(r.blockNumber)}\n`);
}
NODE
  then
    rm "$receipt_rows"
    echo "could not materialize authenticated receipt rows from $path" >&2
    return 1
  fi
  failed=0
  while read -r hash expected_block expected_number; do
    [ -n "$hash" ] || continue
    if ! live_block="$(cast receipt "$hash" blockHash)"; then
      echo "receipt $hash is unavailable on this RPC" >&2
      failed=1
      break
    fi
    same_hex "$live_block" "$expected_block" || {
      echo "receipt $hash is not in its recorded canonical block on this RPC" >&2
      failed=1
      break
    }
    if ! canonical_block="$(block_hash "$expected_number")"; then
      echo "canonical block $expected_number is unavailable on this RPC" >&2
      failed=1
      break
    fi
    same_hex "$canonical_block" "$expected_block" || {
      echo "receipt $hash block $expected_number is not canonical on this RPC" >&2
      failed=1
      break
    }
    if ! live_status="$(cast receipt "$hash" status | awk '{print $1}')"; then
      echo "receipt $hash status is unavailable on this RPC" >&2
      failed=1
      break
    fi
    case "$live_status" in
      1|0x1) ;;
      *) echo "receipt $hash is not successful on this RPC" >&2; failed=1; break ;;
    esac
  done <"$receipt_rows"
  rm "$receipt_rows"
  [ "$failed" -eq 0 ] || return 1
}

# Forge broadcast JSON is ignored working state, not authority. Re-fetch every transaction and
# receipt and compare all release-relevant fields and the complete ordered log stream before an
# artifact may supply a dynamic address, bid id, nonce, or continuation boundary.
verify_live_forge_artifact() {
  local path="$1" live_dir rows_file failed index hash
  live_dir="$(mktemp -d)"
  rows_file="$live_dir/rows"
  if ! node - "$path" >"$rows_file" <<'NODE'
const fs = require("node:fs");
const d = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (!Array.isArray(d.transactions) || d.transactions.length === 0) {
  throw new Error("raw Forge artifact has no transactions");
}
for (const [index, tx] of d.transactions.entries()) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(tx.hash || ""))) {
    throw new Error(`raw Forge transaction #${index} has no valid hash`);
  }
  process.stdout.write(`${index} ${tx.hash}\n`);
}
NODE
  then
    rm -r -- "$live_dir"
    echo "could not enumerate raw Forge transactions from $path" >&2
    return 1
  fi
  failed=0
  while read -r index hash; do
    [ -n "$hash" ] || continue
    if ! cast tx "$hash" --json >"$live_dir/tx-$index.json"; then
      echo "live transaction $hash is unavailable" >&2
      failed=1
      break
    fi
    if ! cast receipt "$hash" --json >"$live_dir/receipt-$index.json"; then
      echo "live receipt $hash is unavailable" >&2
      failed=1
      break
    fi
  done <"$rows_file"
  if [ "$failed" -eq 0 ]; then
    if ! node - "$path" "$live_dir" <<'NODE'
const fs = require("node:fs");
const [path, liveDir] = process.argv.slice(2);
const d = JSON.parse(fs.readFileSync(path, "utf8"));
const fail = (message) => { throw new Error(`${path}: ${message}`); };
const sameHex = (a, b) => String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();
const sameInt = (a, b, label) => {
  try { if (BigInt(a) !== BigInt(b)) fail(`${label} differs from live RPC`); }
  catch (error) { if (error.message?.startsWith(`${path}:`)) throw error; fail(`${label} is not numeric`); }
};
const sameOptionalInt = (a, b, label) => {
  if (a == null && b == null) return;
  sameInt(a, b, label);
};
const sameForgeGas = (hasRawGas, raw, live, isFixedGasLimit, label) => {
  if (!hasRawGas) {
    if (isFixedGasLimit === false) return;
    fail(`${label} is missing without an explicit non-fixed gas policy`);
  }
  if (raw == null) fail(`${label} is not numeric`);
  sameInt(raw, live, label);
};
const receipts = new Map((d.receipts || []).map((receipt) =>
  [String(receipt.transactionHash || "").toLowerCase(), receipt]));
const compareHexField = (raw, live, field, label, nullable = false) => {
  if (nullable && raw?.[field] == null && live?.[field] == null) return;
  if (!sameHex(raw?.[field], live?.[field])) fail(`${label} ${field} differs from live RPC`);
};
const compareLog = (raw, live, label) => {
  for (const field of ["address", "data", "blockHash", "transactionHash"]) {
    compareHexField(raw, live, field, label);
  }
  for (const field of ["blockNumber", "blockTimestamp", "transactionIndex", "logIndex"]) {
    sameInt(raw?.[field], live?.[field], `${label} ${field}`);
  }
  const rawTopics = raw?.topics || [];
  const liveTopics = live?.topics || [];
  if (rawTopics.length !== liveTopics.length) fail(`${label} topic count differs from live RPC`);
  for (let i = 0; i < rawTopics.length; i += 1) {
    if (!sameHex(rawTopics[i], liveTopics[i])) fail(`${label} topic #${i} differs from live RPC`);
  }
  if (raw?.removed !== undefined && Boolean(raw.removed) !== Boolean(live?.removed)) {
    fail(`${label} removed flag differs from live RPC`);
  }
};
for (const [index, item] of d.transactions.entries()) {
  const liveTx = JSON.parse(fs.readFileSync(`${liveDir}/tx-${index}.json`, "utf8"));
  const rawTx = item.transaction || {};
  compareHexField(item, liveTx, "hash", `transaction #${index}`);
  for (const field of ["from", "to", "input"]) {
    compareHexField(rawTx, liveTx, field, `transaction #${index}`);
  }
  for (const field of ["nonce", "chainId"]) {
    sameInt(rawTx[field], liveTx[field], `transaction #${index} ${field}`);
  }
  sameForgeGas(
    Object.hasOwn(rawTx, "gas"), rawTx.gas, liveTx.gas, item.isFixedGasLimit,
    `transaction #${index} gas`,
  );
  sameInt(rawTx.value ?? 0, liveTx.value, `transaction #${index} value`);

  const rawReceipt = receipts.get(String(item.hash).toLowerCase());
  if (!rawReceipt) fail(`transaction #${index} has no raw receipt`);
  const liveReceipt = JSON.parse(fs.readFileSync(`${liveDir}/receipt-${index}.json`, "utf8"));
  for (const field of ["transactionHash", "from", "to", "blockHash", "logsBloom"]) {
    compareHexField(rawReceipt, liveReceipt, field, `receipt #${index}`);
  }
  compareHexField(rawReceipt, liveReceipt, "contractAddress", `receipt #${index}`, true);
  for (const field of ["status", "blockNumber", "transactionIndex", "cumulativeGasUsed", "type",
    "gasUsed", "effectiveGasPrice", "gasUsedForL1", "l1BlockNumber"]) {
    sameOptionalInt(rawReceipt[field], liveReceipt[field], `receipt #${index} ${field}`);
  }
  compareHexField(liveTx, liveReceipt, "blockHash", `live transaction/receipt #${index}`);
  sameInt(liveTx.blockNumber, liveReceipt.blockNumber, `live transaction/receipt #${index} blockNumber`);
  sameInt(liveTx.transactionIndex, liveReceipt.transactionIndex,
    `live transaction/receipt #${index} transactionIndex`);
  const rawLogs = rawReceipt.logs || [];
  const liveLogs = liveReceipt.logs || [];
  if (rawLogs.length !== liveLogs.length) fail(`receipt #${index} log count differs from live RPC`);
  for (let i = 0; i < rawLogs.length; i += 1) compareLog(rawLogs[i], liveLogs[i], `receipt #${index} log #${i}`);
}
NODE
    then
      failed=1
    fi
  fi
  rm -r -- "$live_dir"
  [ "$failed" -eq 0 ] || return 1
}

max_receipt_block() {
  node - "$1" <<'NODE'
const fs = require("node:fs");
const d = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const receipts = Array.isArray(d.receipts) ? d.receipts : [d];
if (receipts.length === 0) throw new Error("evidence has no receipts");
const blocks = receipts.map((receipt, index) => {
  try { return BigInt(receipt.blockNumber); }
  catch { throw new Error(`receipt #${index} has no valid block number`); }
});
process.stdout.write(blocks.reduce((a, b) => a > b ? a : b).toString());
NODE
}

wait_receipts_finalized() {
  local path="$1" label="$2" receipt_block finalized_block latest_block now deadline next_notice
  verify_live_receipts "$path"
  receipt_block="$(max_receipt_block "$path")"
  if [ "$LOOPBACK" = "1" ]; then
    latest_block="$(cast block-number)"
    [ "$latest_block" -ge "$receipt_block" ] || {
      echo "$label receipt block $receipt_block is above loopback latest $latest_block" >&2
      return 1
    }
    # Anvil does not advance the `finalized` tag for locally mined fork blocks. A rehearsal has no
    # reorg risk unless the operator explicitly mutates the node, so require exact canonical live
    # receipt/block binding at latest and label this boundary honestly as rehearsal-only.
    verify_live_receipts "$path"
    echo "$label receipts are canonical at loopback latest $latest_block (rehearsal; not production finality)"
    return 0
  fi
  now="$(date +%s)"
  deadline="$((now + FINALITY_WAIT_MAX_SECONDS))"
  next_notice="$now"
  while true; do
    finalized_block="$(cast block finalized --field number)"
    if [ "$finalized_block" -ge "$receipt_block" ]; then
      break
    fi
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || {
      echo "$label receipt block $receipt_block did not finalize within ${FINALITY_WAIT_MAX_SECONDS}s" >&2
      return 1
    }
    if [ "$now" -ge "$next_notice" ]; then
      echo "waiting for $label receipt block $receipt_block to finalize (head $finalized_block)"
      next_notice="$((now + 30))"
    fi
    sleep 2
  done
  # A finalized height is not enough if this RPC changed the receipt's canonical hash while waiting.
  verify_live_receipts "$path"
  echo "$label receipts are canonical at finalized head $finalized_block"
}

wait_timing_receipt_finalized() {
  local receipt_path="$1" transaction_path="$2" duration="$3" expected_nonce="$4" label="$5"
  local receipt_block finalized_block latest_block now deadline next_notice
  timing_receipt_check "$receipt_path" "$transaction_path" "$duration" "$expected_nonce"
  receipt_block="$(node -e 'process.stdout.write(BigInt(require(process.argv[1]).blockNumber).toString())' "$receipt_path")"
  if [ "$LOOPBACK" = "1" ]; then
    latest_block="$(cast block-number)"
    [ "$latest_block" -ge "$receipt_block" ] || {
      echo "$label receipt block $receipt_block is above loopback latest $latest_block" >&2
      return 1
    }
    timing_receipt_check "$receipt_path" "$transaction_path" "$duration" "$expected_nonce"
    echo "$label receipt is canonical at loopback latest $latest_block (rehearsal; not production finality)"
    return 0
  fi
  now="$(date +%s)"
  deadline="$((now + FINALITY_WAIT_MAX_SECONDS))"
  next_notice="$now"
  while true; do
    finalized_block="$(cast block finalized --field number)"
    if [ "$finalized_block" -ge "$receipt_block" ]; then break; fi
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || {
      echo "$label receipt block $receipt_block did not finalize within ${FINALITY_WAIT_MAX_SECONDS}s" >&2
      return 1
    }
    if [ "$now" -ge "$next_notice" ]; then
      echo "waiting for $label receipt block $receipt_block to finalize (head $finalized_block)"
      next_notice="$((now + 30))"
    fi
    sleep 2
  done
  # Re-fetch and exact-compare both raw timing files and their complete live transaction/receipt
  # after finality. A height-only check can never authorize this recovery chronology.
  timing_receipt_check "$receipt_path" "$transaction_path" "$duration" "$expected_nonce"
  echo "$label receipt is canonical at finalized head $finalized_block"
}

wait_owner_bid_finalized() {
  local transaction_path="$1" receipt_path="$2" auction="$3" auction_end="$4" expected_nonce="$5" label="$6"
  local receipt_block finalized_block latest_block now deadline next_notice
  owner_bid_receipt_check "$transaction_path" "$receipt_path" "$auction" "$auction_end" "$expected_nonce"
  receipt_block="$(node -e 'process.stdout.write(BigInt(require(process.argv[1]).blockNumber).toString())' "$receipt_path")"
  if [ "$LOOPBACK" = "1" ]; then
    latest_block="$(cast block-number)"
    [ "$latest_block" -ge "$receipt_block" ] || {
      echo "$label receipt block $receipt_block is above loopback latest $latest_block" >&2
      return 1
    }
    owner_bid_receipt_check "$transaction_path" "$receipt_path" "$auction" "$auction_end" "$expected_nonce"
    echo "$label receipt is canonical at loopback latest $latest_block (rehearsal; not production finality)"
    return 0
  fi
  now="$(date +%s)"
  deadline="$((now + FINALITY_WAIT_MAX_SECONDS))"
  next_notice="$now"
  while true; do
    finalized_block="$(cast block finalized --field number)"
    if [ "$finalized_block" -ge "$receipt_block" ]; then break; fi
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || {
      echo "$label receipt block $receipt_block did not finalize within ${FINALITY_WAIT_MAX_SECONDS}s" >&2
      return 1
    }
    if [ "$now" -ge "$next_notice" ]; then
      echo "waiting for $label receipt block $receipt_block to finalize (head $finalized_block)"
      next_notice="$((now + 30))"
    fi
    sleep 2
  done
  owner_bid_receipt_check "$transaction_path" "$receipt_path" "$auction" "$auction_end" "$expected_nonce"
  echo "$label receipt is canonical at finalized head $finalized_block"
}

sender_nonce() {
  cast nonce "$SENDER" --block "$1"
}

require_sender_nonce() {
  local expected="$1" latest pending
  latest="$(sender_nonce latest)"
  pending="$(sender_nonce pending)"
  [ "$latest" = "$expected" ] && [ "$pending" = "$expected" ] || {
    echo "sender nonce changed: latest=$latest pending=$pending expected=$expected; stop without rerun" >&2
    return 1
  }
}

artifact_first_nonce() {
  node -e '
    const d = require(process.argv[1]);
    if (!d.transactions?.length) throw new Error("raw Forge artifact has no transactions");
    process.stdout.write(BigInt(d.transactions[0].transaction?.nonce).toString());
  ' "$1"
}

next_nonce() {
  node -e 'process.stdout.write((BigInt(process.argv[1]) + BigInt(process.argv[2])).toString())' "$1" "$2"
}

require_canary_finality_budget() {
  local latest finalized lag
  latest="$(cast block-number)"
  finalized="$(cast block finalized --field number)"
  [ "$latest" -ge "$finalized" ] || {
    echo "RPC returned finalized head $finalized above latest head $latest" >&2
    return 1
  }
  lag="$((latest - finalized))"
  [ "$CANARY_AUCTION_DURATION" -gt "$((lag + FINISH_MIN_BLOCK_HEADROOM))" ] || {
    echo "canary duration $CANARY_AUCTION_DURATION cannot cover finalized lag $lag plus bid headroom $FINISH_MIN_BLOCK_HEADROOM" >&2
    return 1
  }
  echo "finality budget confirmed: latest=$latest finalized=$finalized lag=$lag duration=$CANARY_AUCTION_DURATION"
}

contract_block_at() {
  cast block "$1" --json | node -e '
    let raw = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      const block = JSON.parse(raw);
      const value = block.l1BlockNumber ?? block.number;
      if (value === undefined || value === null) throw new Error("latest block has no contract clock");
      process.stdout.write(BigInt(value).toString());
    });
  '
}

current_contract_block() { contract_block_at latest; }

current_auction_block() {
  local rpc_block arbsys_block arbsys_hash expected_hash
  rpc_block="$(cast block-number)"
  case "$rpc_block" in
    ""|*[!0-9]*) echo "RPC returned a malformed auction block: $rpc_block" >&2; return 1 ;;
  esac

  # The CCA is keyed to Robinhood's rollup clock, not Solidity's hook-guard clock. Authenticate
  # the exact production marker (or the loopback-only nine-byte rehearsal shim) before trusting
  # ArbSys, then require it to agree exactly with eth_blockNumber at the same latest boundary.
  if [ "$LOOPBACK" -eq 1 ]; then
    expected_hash="$ARBSYS_SIMULATION_SHIM_RUNTIME_CODEHASH"
  else
    expected_hash="$ROBINHOOD_ARBSYS_MARKER_RUNTIME_CODEHASH"
  fi
  arbsys_hash="$(cast code "$ARBSYS" --block "$rpc_block" | cast keccak)"
  same_hex "$arbsys_hash" "$expected_hash" || {
    echo "ArbSys runtime is not the authenticated auction-clock runtime" >&2
    return 1
  }
  arbsys_block="$(read_call "$ARBSYS" 'arbBlockNumber()(uint256)' --block "$rpc_block" | awk '{print $1}')"
  case "$arbsys_block" in
    ""|*[!0-9]*) echo "ArbSys returned a malformed auction block: $arbsys_block" >&2; return 1 ;;
  esac
  [ "$rpc_block" = "$arbsys_block" ] || {
    echo "auction clocks disagree: eth_blockNumber=$rpc_block ArbSys=$arbsys_block" >&2
    return 1
  }
  printf '%s\n' "$rpc_block"
}

require_guard_finality_budget() {
  local latest finalized lag
  latest="$(contract_block_at latest)"
  finalized="$(contract_block_at finalized)"
  [ "$latest" -ge "$finalized" ] || {
    echo "RPC returned finalized contract clock $finalized above latest $latest" >&2
    return 1
  }
  lag="$((latest - finalized))"
  [ "$CANARY_GUARD_BLOCKS" -gt "$((lag + GUARD_MIN_BLOCK_HEADROOM))" ] || {
    echo "canary guard $CANARY_GUARD_BLOCKS cannot cover contract-clock finality lag $lag plus buy headroom $GUARD_MIN_BLOCK_HEADROOM" >&2
    return 1
  }
  echo "guard finality budget confirmed: contract-clock lag=$lag guard=$CANARY_GUARD_BLOCKS"
}

launch_contract_block() {
  cast call "$PAD" \
    'getLaunch(address)((address,address,uint40,uint32,uint8,uint8,uint96,uint96,uint16,address,uint40,uint40,uint160,bytes32,uint8,(uint32,uint16,uint24,uint24,uint24,uint16,uint16,uint96,uint16,uint16,uint32,uint96)))' \
    "$1" --json | node -e '
      let raw = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => { raw += chunk; });
      process.stdin.on("end", () => {
        const launch = JSON.parse(raw)?.[0];
        if (!Array.isArray(launch)) throw new Error("launch readback is malformed");
        process.stdout.write(BigInt(launch[2]).toString());
      });
    '
}

require_guard_headroom() {
  local token="$1" label="$2" launch_block current_block remaining
  launch_block="$(launch_contract_block "$token")"
  current_block="$(current_contract_block)"
  remaining="$((launch_block + CANARY_GUARD_BLOCKS - current_block))"
  [ "$remaining" -gt "$GUARD_MIN_BLOCK_HEADROOM" ] || {
    echo "$label has only $remaining contract-clock guard blocks left; expected more than $GUARD_MIN_BLOCK_HEADROOM" >&2
    return 1
  }
  echo "$label guard headroom confirmed: $remaining contract-clock blocks"
}

timing_receipt_check() {
  local path="$1" transaction_path="$2" duration="$3" expected_nonce="$4" hash expected_input live_dir
  [ -f "$transaction_path" ] || { echo "timing transaction evidence is missing: $transaction_path" >&2; return 1; }
  hash="$(node -e '
    const d = require(process.argv[1]);
    if (!/^0x[0-9a-fA-F]{64}$/.test(String(d.transactionHash || ""))) throw new Error("timing receipt hash missing");
    process.stdout.write(d.transactionHash);
  ' "$path")"
  live_dir="$(mktemp -d)"
  if ! cast tx "$hash" --json >"$live_dir/transaction.json" || \
    ! cast receipt "$hash" --json >"$live_dir/receipt.json"; then
    rm -r -- "$live_dir"
    echo "timing transaction/receipt $hash is unavailable on this RPC" >&2
    return 1
  fi
  expected_input="$(cast calldata 'setAuctionTiming(uint64,uint64,uint64)' "$duration" 0 1)"
  if ! node - "$path" "$transaction_path" "$live_dir/transaction.json" "$live_dir/receipt.json" \
    "$hash" "$expected_nonce" "$SENDER" "$PAD" "$expected_input" <<'NODE'
const fs = require("node:fs");
const [path, transactionPath, liveTxPath, liveReceiptPath, hash, nonce, sender, pad, input] = process.argv.slice(2);
const receipt = JSON.parse(fs.readFileSync(path, "utf8"));
const tx = JSON.parse(fs.readFileSync(transactionPath, "utf8"));
const liveTx = JSON.parse(fs.readFileSync(liveTxPath, "utf8"));
const liveReceipt = JSON.parse(fs.readFileSync(liveReceiptPath, "utf8"));
const same = (a, b) => String(a || "").toLowerCase() === String(b || "").toLowerCase();
const fail = (message) => { throw new Error(`${path}: ${message}`); };
if (BigInt(receipt.status) !== 1n || !same(receipt.transactionHash, hash)) fail("receipt is not successful or hash-bound");
if (!same(receipt.from, sender) || !same(receipt.to, pad)) fail("receipt sender/target is wrong");
if (!same(tx.hash, hash) || !same(tx.from, sender) || !same(tx.to, pad)) fail("live transaction identity is wrong");
if (BigInt(tx.nonce) !== BigInt(nonce)) fail(`live transaction nonce ${BigInt(tx.nonce)} is not ${nonce}`);
if (BigInt(tx.value) !== 0n || !same(tx.input, input)) fail("live transaction value/calldata is wrong");
if (!same(tx.blockHash, receipt.blockHash) || BigInt(tx.blockNumber) !== BigInt(receipt.blockNumber)) {
  fail("live transaction and receipt canonical coordinates differ");
}
for (const field of ["hash", "from", "to", "input", "blockHash"]) {
  if (!same(tx[field], liveTx[field])) fail(`raw and live timing transaction ${field} differ`);
}
for (const field of ["nonce", "value", "blockNumber", "transactionIndex", "gas", "chainId"]) {
  if (BigInt(tx[field]) !== BigInt(liveTx[field])) fail(`raw and live timing transaction ${field} differ`);
}
for (const field of ["transactionHash", "from", "to", "blockHash", "contractAddress", "logsBloom"]) {
  if (!same(receipt[field], liveReceipt[field])) fail(`raw and live timing receipt ${field} differ`);
}
for (const field of ["status", "blockNumber", "transactionIndex", "cumulativeGasUsed", "type",
  "gasUsed", "effectiveGasPrice", "gasUsedForL1", "l1BlockNumber"]) {
  if (receipt[field] == null && liveReceipt[field] == null) continue;
  if (BigInt(receipt[field]) !== BigInt(liveReceipt[field])) fail(`raw and live timing receipt ${field} differ`);
}
if (!same(liveTx.blockHash, liveReceipt.blockHash) ||
    BigInt(liveTx.blockNumber) !== BigInt(liveReceipt.blockNumber) ||
    BigInt(liveTx.transactionIndex) !== BigInt(liveReceipt.transactionIndex)) {
  fail("live timing transaction and receipt canonical coordinates differ");
}
const compareLog = (raw, live, index) => {
  for (const field of ["address", "data", "blockHash", "transactionHash"]) {
    if (!same(raw[field], live[field])) fail(`timing log #${index} ${field} differs from live RPC`);
  }
  for (const field of ["blockNumber", "blockTimestamp", "transactionIndex", "logIndex"]) {
    if (BigInt(raw[field]) !== BigInt(live[field])) fail(`timing log #${index} ${field} differs from live RPC`);
  }
  const rawTopics = raw.topics || [];
  const liveTopics = live.topics || [];
  if (rawTopics.length !== liveTopics.length) fail(`timing log #${index} topic count differs from live RPC`);
  for (let topicIndex = 0; topicIndex < rawTopics.length; topicIndex += 1) {
    if (!same(rawTopics[topicIndex], liveTopics[topicIndex])) {
      fail(`timing log #${index} topic #${topicIndex} differs from live RPC`);
    }
  }
  if (raw.removed !== undefined && Boolean(raw.removed) !== Boolean(live.removed)) {
    fail(`timing log #${index} removed flag differs from live RPC`);
  }
};
const rawLogs = receipt.logs || [];
const liveLogs = liveReceipt.logs || [];
if (rawLogs.length !== liveLogs.length) fail("timing receipt log count differs from live RPC");
for (let index = 0; index < rawLogs.length; index += 1) compareLog(rawLogs[index], liveLogs[index], index);
const timingTopic = "0xfcebbff9c47308308470be9ace095ecd389626c60516ffe6bab783effb45773d";
const logs = (receipt.logs || []).filter((log) =>
  same(log.address, pad) && same(log.topics?.[0], timingTopic));
if (logs.length !== 1) fail(`expected one AuctionTimingSet event, found ${logs.length}`);
const data = String(logs[0].data || "");
if (!/^0x[0-9a-fA-F]{192}$/.test(data)) fail("AuctionTimingSet data is malformed");
const words = [0, 1, 2].map((index) => BigInt(`0x${data.slice(2 + index * 64, 66 + index * 64)}`));
const inputDuration = BigInt(`0x${input.slice(10, 74)}`);
if (words[0] !== inputDuration || words[1] !== 0n || words[2] !== 1n) {
  fail("AuctionTimingSet event does not match reviewed timing");
}
NODE
  then
    rm -r -- "$live_dir"
    return 1
  fi
  rm -r -- "$live_dir"
  verify_live_receipts "$path"
}

require_raw_launch_event() {
  local path="$1" tx_index="$2" kind="$3" token="$4"
  local auction="${5:-0x0000000000000000000000000000000000000000}" expected_end="${6:-0}"
  node - "$path" "$tx_index" "$kind" "$PAD" "$token" "$auction" "$expected_end" \
    "$CANARY_AUCTION_DURATION" <<'NODE'
const fs = require("node:fs");
const [path, txIndexRaw, kind, pad, token, auction, expectedEndRaw, durationRaw] = process.argv.slice(2);
const d = JSON.parse(fs.readFileSync(path, "utf8"));
const tx = d.transactions?.[Number(txIndexRaw)];
const receipt = (d.receipts || []).find((candidate) =>
  String(candidate.transactionHash || "").toLowerCase() === String(tx?.hash || "").toLowerCase());
if (!tx || !receipt) throw new Error(`${path}: launch transaction/receipt is missing`);
const topics = {
  instant: "0xe4e68f29538094d634615ce44cb2c723ea42286023b0c489cb9b2b66ea80fc13",
  auction: "0xbc0692e08b687db813691bc9017ad266db62bf06614d2d0f860af04631b2b277",
};
const topic = topics[kind];
if (!topic) throw new Error(`unknown launch event kind ${kind}`);
const indexedAddress = (value) => `0x${String(value || "").slice(-40)}`.toLowerCase();
const matches = (receipt.logs || []).filter((log) =>
  String(log.address || "").toLowerCase() === pad.toLowerCase() &&
  String(log.topics?.[0] || "").toLowerCase() === topic);
if (matches.length !== 1) throw new Error(`${path}: expected one ${kind} launch event, found ${matches.length}`);
if (indexedAddress(matches[0].topics?.[1]) !== token.toLowerCase()) throw new Error(`${path}: launch event token is wrong`);
if (kind === "instant") {
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(matches[0].topics?.[2] || ""))) {
    throw new Error(`${path}: InstantLaunched pool id is missing`);
  }
} else {
  if (indexedAddress(matches[0].topics?.[2]) !== auction.toLowerCase()) {
    throw new Error(`${path}: AuctionStarted CCA is wrong`);
  }
  const data = String(matches[0].data || "");
  if (!/^0x[0-9a-fA-F]{256}$/.test(data)) throw new Error(`${path}: AuctionStarted data is malformed`);
  const eventEnd = BigInt(`0x${data.slice(2, 66)}`);
  const expectedEnd = BigInt(expectedEndRaw);
  const derivedEnd = BigInt(receipt.blockNumber) + BigInt(durationRaw);
  if (eventEnd !== expectedEnd || eventEnd !== derivedEnd) {
    throw new Error(`${path}: AuctionStarted end ${eventEnd} is not authenticated/derived end ${expectedEnd}/${derivedEnd}`);
  }
}
NODE
}

phase_a_outputs() {
  local expected_auction_status="${1:-0}"
  local instant_token auction_token auction bid_id hookr_pair_token instant_auth auction_auth hookr_auth
  instant_auth="$(authenticated_instant)"
  auction_auth="$(authenticated_auction "$expected_auction_status")"
  hookr_auth="$(authenticated_hookr_pair)"
  read -r instant_token _ _ _ _ <<<"$instant_auth"
  read -r auction_token auction _ _ _ <<<"$auction_auth"
  read -r hookr_pair_token _ _ _ _ <<<"$hookr_auth"
  bid_id="$(node - "$PHASE_A_OWNER_BID_RECEIPT_ABS" "$SENDER" "$auction" <<'NODE'
const fs = require("node:fs");
const [path, sender, authenticatedAuction] = process.argv.slice(2);
const bidReceipt = JSON.parse(fs.readFileSync(path, "utf8"));
const auction = String(bidReceipt.to || "").toLowerCase();
if (auction !== authenticatedAuction.toLowerCase()) throw new Error("phase A bid target is not the mined auction");
const topic0 = "0x650baad5cd8ca09b8f580be220fa04ce2ba905a041f764b6a3fe2c848eb70540";
const ownerTopic = `0x${sender.slice(2).toLowerCase().padStart(64, "0")}`;
const matches = (bidReceipt.logs || []).filter((log) =>
  String(log.address || "").toLowerCase() === auction &&
  String(log.topics?.[0] || "").toLowerCase() === topic0 &&
  String(log.topics?.[2] || "").toLowerCase() === ownerTopic);
if (matches.length !== 1 || !matches[0].topics?.[1]) throw new Error(`expected one sender-owned BidSubmitted event, found ${matches.length}`);
process.stdout.write(BigInt(matches[0].topics[1]).toString());
NODE
  )"
  printf '%s %s %s %s %s\n' "$instant_token" "$auction_token" "$auction" "$bid_id" "$hookr_pair_token"
}

phase_a_index() {
  local action="$1" instant_token="$2" auction_token="$3" auction="$4" bid_id="$5" hookr_pair_token="$6"
  local write_args=()
  [ "$action" != "write" ] || write_args=(--write)
  (cd "$REPO_ROOT" && node scripts/build-v5-phase-a-index.mjs \
    --instant-launch "$PHASE_A_INSTANT_LAUNCH_ABS" \
    --instant-buy-auction-launch "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
    --owner-bid-transaction "$PHASE_A_OWNER_BID_TRANSACTION_ABS" \
    --owner-bid-receipt "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
    --hookr-launch "$PHASE_A_HOOKR_LAUNCH_ABS" \
    --hookr-approve-buy "$PHASE_A_HOOKR_APPROVE_BUY_ABS" \
    --shorten-transaction "$SHORTEN_TRANSACTION_ABS" --shorten-receipt "$SHORTEN_RECEIPT_ABS" \
    --restore-transaction "$RESTORE_TRANSACTION_ABS" --restore-receipt "$RESTORE_RECEIPT_ABS" \
    --output "$PHASE_A_INDEX_ABS" \
    --deployment-source-commit "$DEPLOYMENT_SOURCE_COMMIT" \
    --original-canary-operator-commit "$ORIGINAL_CANARY_OPERATOR_COMMIT" \
    --canary-recovery-commit "${PHASE_A_RECOVERY_COMMIT:-$CANARY_OPERATOR_COMMIT}" \
    --sender "$SENDER" --launchpad "$PAD" --router "$ROUTER" --hookr-token "$HOOKR_TOKEN" --hook "$HOOK" \
    --instant-token "$instant_token" --auction-token "$auction_token" --auction "$auction" \
    --bid-id "$bid_id" --hookr-pair-token "$hookr_pair_token" "${write_args[@]}")
}

phase_a_owner_bid_semantics() {
  local auction="$1" auction_end="$2"
  (cd "$REPO_ROOT" && node scripts/build-v5-phase-a-index.mjs \
    --owner-bid-only \
    --owner-bid-transaction "$PHASE_A_OWNER_BID_TRANSACTION_ABS" \
    --owner-bid-receipt "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
    --sender "$SENDER" --auction "$auction" --bid-id "$OWNER_BID_ID" \
    --auction-end-block "$auction_end")
}

phase_a_stage_semantics() {
  local stage="$1" artifact="$2"
  local stage_source_commit
  shift 2
  case "$stage" in
    instant-launch|instant-buy-auction-launch) stage_source_commit="$ORIGINAL_CANARY_OPERATOR_COMMIT" ;;
    hookr-launch|hookr-approve-buy) \
      stage_source_commit="${PHASE_A_RECOVERY_COMMIT:-$CANARY_OPERATOR_COMMIT}" ;;
    *) echo "unknown Phase-A semantic stage: $stage" >&2; return 1 ;;
  esac
  (cd "$REPO_ROOT" && node scripts/build-v5-phase-a-index.mjs \
    --stage-only --stage "$stage" --artifact "$artifact" \
    --canary-operator-commit "$stage_source_commit" \
    --sender "$SENDER" --launchpad "$PAD" --router "$ROUTER" \
    --hookr-token "$HOOKR_TOKEN" --hook "$HOOK" "$@")
}

phase_b_slug() {
  case "$1" in
    migrateAuction) printf '%s\n' migrate-auction ;;
    exitBid) printf '%s\n' exit-bid ;;
    claimTokens) printf '%s\n' claim-tokens ;;
    claimAuctionProceeds) printf '%s\n' claim-auction-proceeds ;;
    collect) printf '%s\n' collect ;;
    buybackAndBurn) printf '%s\n' buyback-and-burn ;;
    *) echo "unknown Phase-B action: $1" >&2; return 1 ;;
  esac
}

# A completed signing journal is an immutable stop/reconciliation record, never permission to send
# again. Authenticate the exact saved plan/transaction/receipt against the current canonical RPC,
# then return its transaction hash so the collector result can be required to select that same
# migration. The collector still derives all protocol semantics from the live receipt.
phase_b_migrate_journal_hash() {
  local plan transaction receipt path present=0 facts hash plan_commit resolved_commit live_dir
  plan="$PHASE_B_JOURNAL_DIR_ABS/migrate-auction.plan.json"
  transaction="$PHASE_B_JOURNAL_DIR_ABS/migrate-auction.transaction.json"
  receipt="$PHASE_B_JOURNAL_DIR_ABS/migrate-auction.receipt.json"
  for path in "$plan" "$transaction" "$receipt"; do
    [ ! -e "$path" ] || present="$((present + 1))"
  done
  [ "$present" -ne 0 ] || return 0
  [ "$present" -eq 3 ] || {
    echo "migration signing journal is partial; migration may already have been submitted, so no retry is allowed" >&2
    return 1
  }
  for path in "$plan" "$transaction" "$receipt"; do
    [ -f "$path" ] && [ ! -L "$path" ] || {
      echo "migration signing journal contains a missing, non-regular, or symlinked file: $path" >&2
      return 1
    }
  done
  facts="$(node - "$plan" "$transaction" "$receipt" "$PHASE_A_INDEX_ABS" \
    "$SENDER" "$PAD" <<'NODE'
const fs = require("node:fs");
const [planPath, transactionPath, receiptPath, indexPath, sender, launchpad] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(planPath, "utf8"));
const tx = JSON.parse(fs.readFileSync(transactionPath, "utf8"));
const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
const index = JSON.parse(fs.readFileSync(indexPath, "utf8"));
const fail = (message) => { throw new Error(`migration journal: ${message}`); };
const same = (left, right) => String(left ?? "").toLowerCase() === String(right ?? "").toLowerCase();
const sameInt = (left, right, label) => {
  try { if (BigInt(left) !== BigInt(right)) fail(`${label} differs`); }
  catch (error) { if (String(error.message).startsWith("migration journal:")) throw error; fail(`${label} is not numeric`); }
};
if (plan.kind !== "hookr-v5-phase-b-signing-plan-v1" || plan.action !== "migrateAuction") {
  fail("plan kind/action is wrong");
}
if (plan.chainId !== 4663 || !/^[0-9a-f]{40}$/.test(plan.canaryOperatorCommit || "")) {
  fail("plan chain or operator commit is wrong");
}
const token = index?.identities?.auctionToken;
if (!/^0x[0-9a-fA-F]{40}$/.test(token || "")) fail("Phase-A index has no auction token");
const expectedInput = `0x388fcc3a${token.slice(2).toLowerCase().padStart(64, "0")}`;
if (!same(plan.sender, sender) || !same(plan.target, launchpad) ||
    !same(plan.calldata, expectedInput) || String(plan.value) !== "0") {
  fail("plan does not bind the exact canary migration");
}
if (!/^0x[0-9a-fA-F]{64}$/.test(tx.hash || "") || !same(tx.hash, receipt.transactionHash)) {
  fail("transaction/receipt hash pair is malformed");
}
if (!same(tx.from, plan.sender) || !same(tx.to, plan.target) || !same(tx.input, plan.calldata)) {
  fail("transaction differs from its signing plan");
}
sameInt(tx.nonce, plan.nonce, "transaction nonce");
sameInt(tx.value ?? 0, 0, "transaction value");
sameInt(tx.chainId, 4663, "transaction chain");
sameInt(receipt.status, 1, "receipt status");
if (!same(receipt.from, tx.from) || !same(receipt.to, tx.to) ||
    !same(receipt.blockHash, tx.blockHash)) fail("receipt differs from its transaction");
sameInt(receipt.blockNumber, tx.blockNumber, "receipt block number");
sameInt(receipt.transactionIndex, tx.transactionIndex, "receipt transaction index");
const migratedTopic = "0x924c1eb475addd079107bc371667b4942fe0af2dc458fbb15d61e8889a26a357";
const tokenTopic = `0x${token.slice(2).toLowerCase().padStart(64, "0")}`;
const migrated = (receipt.logs || []).filter((log) => same(log.address, launchpad) &&
  same(log.topics?.[0], migratedTopic) && same(log.topics?.[1], tokenTopic));
if (migrated.length !== 1) fail(`receipt has ${migrated.length} exact canary Migrated logs`);
process.stdout.write(`${tx.hash.toLowerCase()} ${plan.canaryOperatorCommit}`);
NODE
  )" || return 1
  read -r hash plan_commit <<<"$facts"
  resolved_commit="$(git -C "$REPO_ROOT" rev-parse --verify "$plan_commit^{commit}" 2>/dev/null)" || {
    echo "migration signing-plan operator commit is unavailable" >&2
    return 1
  }
  [ "$resolved_commit" = "$plan_commit" ] && \
    git -C "$REPO_ROOT" merge-base --is-ancestor "$STATE_OPERATOR_COMMIT" "$plan_commit" && \
    git -C "$REPO_ROOT" merge-base --is-ancestor "$plan_commit" "$CANARY_OPERATOR_COMMIT" || {
      echo "migration signing-plan operator is not on the authenticated target-to-current ancestry" >&2
      return 1
    }
  live_dir="$(mktemp -d)"
  if ! cast tx "$hash" --json >"$live_dir/transaction.json" || \
    ! cast receipt "$hash" --json >"$live_dir/receipt.json"; then
    rm -r -- "$live_dir"
    echo "migration journal transaction $hash is unavailable; stop without resubmitting" >&2
    return 1
  fi
  if ! node - "$plan" "$transaction" "$receipt" \
    "$live_dir/transaction.json" "$live_dir/receipt.json" <<'NODE'
const fs = require("node:fs");
const [planPath, transactionPath, receiptPath, liveTransactionPath, liveReceiptPath] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(planPath, "utf8"));
const tx = JSON.parse(fs.readFileSync(transactionPath, "utf8"));
const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
const liveTx = JSON.parse(fs.readFileSync(liveTransactionPath, "utf8"));
const liveReceipt = JSON.parse(fs.readFileSync(liveReceiptPath, "utf8"));
const fail = (message) => { throw new Error(`live migration journal: ${message}`); };
const same = (left, right) => String(left ?? "").toLowerCase() === String(right ?? "").toLowerCase();
const sameInt = (left, right, label) => {
  try { if (BigInt(left) !== BigInt(right)) fail(`${label} differs`); }
  catch (error) { if (String(error.message).startsWith("live migration journal:")) throw error; fail(`${label} is not numeric`); }
};
for (const field of ["hash", "from", "to", "input", "blockHash"]) {
  if (!same(tx[field], liveTx[field])) fail(`transaction ${field} differs from live RPC`);
}
for (const field of ["nonce", "value", "chainId", "blockNumber", "transactionIndex"]) {
  sameInt(tx[field] ?? 0, liveTx[field] ?? 0, `transaction ${field}`);
}
if (!same(liveTx.from, plan.sender) || !same(liveTx.to, plan.target) ||
    !same(liveTx.input, plan.calldata)) fail("live transaction differs from signing plan");
sameInt(liveTx.nonce, plan.nonce, "live transaction nonce");
for (const field of ["transactionHash", "from", "to", "blockHash"]) {
  if (!same(receipt[field], liveReceipt[field])) fail(`receipt ${field} differs from live RPC`);
}
for (const field of ["status", "blockNumber", "transactionIndex"]) {
  sameInt(receipt[field], liveReceipt[field], `receipt ${field}`);
}
const rawLogs = receipt.logs || [];
const liveLogs = liveReceipt.logs || [];
if (rawLogs.length !== liveLogs.length) fail("receipt log count differs from live RPC");
for (let index = 0; index < rawLogs.length; index += 1) {
  const raw = rawLogs[index];
  const live = liveLogs[index];
  for (const field of ["address", "data", "blockHash", "transactionHash"]) {
    if (!same(raw[field], live[field])) fail(`log #${index} ${field} differs from live RPC`);
  }
  for (const field of ["blockNumber", "blockTimestamp", "transactionIndex", "logIndex"]) {
    sameInt(raw[field], live[field], `log #${index} ${field}`);
  }
  if ((raw.topics || []).length !== (live.topics || []).length) fail(`log #${index} topic count differs`);
  for (let topic = 0; topic < (raw.topics || []).length; topic += 1) {
    if (!same(raw.topics[topic], live.topics[topic])) fail(`log #${index} topic #${topic} differs`);
  }
  if (raw.removed !== undefined && Boolean(raw.removed) !== Boolean(live.removed)) {
    fail(`log #${index} removed flag differs`);
  }
}
NODE
  then
    rm -r -- "$live_dir"
    return 1
  fi
  rm -r -- "$live_dir"
  verify_live_receipts "$receipt" || return 1
  printf '%s\n' "$hash"
}

phase_b_collect() {
  local summary_path="$1" migrate_journal_hash selected_migration_hash
  shift
  local rehearsal_args=()
  [ "$LOOPBACK" -ne 1 ] || rehearsal_args=(--rehearsal)
  migrate_journal_hash="$(phase_b_migrate_journal_hash)" || return 1
  if ! (cd "$REPO_ROOT" && node "$PHASE_B_COLLECTOR" \
    --phase-a-index "$PHASE_A_INDEX_ABS" \
    --output-dir "$PHASE_B_EVIDENCE_DIR_ABS" \
    "${rehearsal_args[@]}" "$@") >"$summary_path"; then
    [ -z "$migrate_journal_hash" ] || \
      echo "migration $migrate_journal_hash is already journaled; collector reconciliation failed, so no migration retry is allowed" >&2
    return 1
  fi
  if [ -n "$migrate_journal_hash" ]; then
    selected_migration_hash="$(phase_b_summary_value \
      "$summary_path" action-transaction-hash migrateAuction)"
    same_hex "$selected_migration_hash" "$migrate_journal_hash" || {
      echo "collector did not select the exact live migration journal transaction $migrate_journal_hash; stop without resubmitting" >&2
      return 1
    }
  fi
}

phase_b_summary_value() {
  local summary_path="$1" mode="$2" action="${3:-}"
  node - "$summary_path" "$mode" "$action" <<'NODE'
const fs = require("node:fs");
const [path, mode, action] = process.argv.slice(2);
const d = JSON.parse(fs.readFileSync(path, "utf8"));
const value = (() => {
  if (mode === "launch-status") return d.stateReadbacks?.launch?.status;
  if (mode === "complete") return Boolean(d.complete);
  if (mode === "promotion-ready") return Boolean(d.promotionReady);
  if (mode === "action-present") return Boolean(d.actions?.[action]);
  if (mode === "action-finalized") return Boolean(d.actions?.[action]?.finalized);
  if (mode === "action-receipt") return d.actions?.[action]?.receiptPath ?? "";
  if (mode === "action-transaction-hash") return d.actions?.[action]?.transactionHash ?? "";
  if (mode === "action-mode") {
    return d.actions?.[action]?.semantics?.mode ??
      d.actions?.[action]?.semantics?.executionMode ?? "";
  }
  if (mode === "action-proof-transaction-hash") {
    return d.actions?.[action]?.semantics?.proofTransactionHash ?? "";
  }
  if (mode === "creator-proceeds") return d.stateReadbacks?.creatorProceedsWei ?? "";
  if (mode === "action-blockers") {
    const item = (d.missingActions ?? []).find((candidate) => candidate.action === action);
    return (item?.blockedBy ?? []).join(",");
  }
  throw new Error(`unknown Phase-B summary query ${mode}`);
})();
process.stdout.write(typeof value === "boolean" ? (value ? "true" : "false") : String(value ?? ""));
NODE
}

phase_b_claim_proceeds_gate() {
  local summary="$1" quiet="${2:-0}" present mode proceeds claim_hash proof_hash migration_hash
  present="$(phase_b_summary_value "$summary" action-present claimAuctionProceeds)"
  mode="$(phase_b_summary_value "$summary" action-mode claimAuctionProceeds)"
  proceeds="$(phase_b_summary_value "$summary" creator-proceeds)"
  if [ "$present" = "true" ]; then
    case "$mode" in
      not-applicable-zero-proceeds)
        node -e '
          if (BigInt(process.argv[1]) !== 0n) {
            throw new Error("zero-proceeds no-op conflicts with the live creator-proceeds ledger");
          }
        ' "$proceeds" || return 1
        claim_hash="$(phase_b_summary_value "$summary" action-transaction-hash claimAuctionProceeds)"
        proof_hash="$(phase_b_summary_value "$summary" action-proof-transaction-hash claimAuctionProceeds)"
        migration_hash="$(phase_b_summary_value "$summary" action-transaction-hash migrateAuction)"
        same_hex "$claim_hash" "$migration_hash" && same_hex "$proof_hash" "$migration_hash" || {
          echo "zero-proceeds no-op does not alias the exact canonical migration receipt" >&2
          return 1
        }
        [ "$quiet" = "1" ] || \
          echo "Phase-B claimAuctionProceeds is explicitly not applicable: canonical migration proved zero proceeds; no claim transaction will be signed"
        ;;
      direct|helper) ;;
      *)
        echo "Phase-B claimAuctionProceeds has unrecognized authenticated mode '$mode'; refusing to sign or skip" >&2
        return 1
        ;;
    esac
  else
    node -e '
      if (BigInt(process.argv[1]) <= 0n) {
        throw new Error("claimAuctionProceeds is missing but creator proceeds are not positive");
      }
    ' "$proceeds" || {
      echo "collector did not provide the explicit not-applicable-zero-proceeds proof; refusing a claim that would revert" >&2
      return 1
    }
  fi
}

phase_b_send_action() {
  local action="$1" slug journal plan_receipt plan_transaction target calldata
  local latest pending expected_nonce send_status=0 transaction_hash burner_balance simulated_burn
  slug="$(phase_b_slug "$action")"
  journal="$PHASE_B_JOURNAL_DIR_ABS/$slug.plan.json"
  plan_receipt="$PHASE_B_JOURNAL_DIR_ABS/$slug.receipt.json"
  plan_transaction="$PHASE_B_JOURNAL_DIR_ABS/$slug.transaction.json"
  if [ -e "$journal" ] || [ -e "$plan_receipt" ] || [ -e "$plan_transaction" ]; then
    echo "Phase-B $action has existing signing-journal evidence under $PHASE_B_JOURNAL_DIR_ABS; reconcile that exact nonce/transaction before any new signature" >&2
    return 1
  fi
  latest="$(sender_nonce latest)"
  pending="$(sender_nonce pending)"
  [ "$latest" = "$pending" ] || {
    echo "Phase-B $action blocked: sender latest nonce $latest differs from pending nonce $pending; reconcile the pending transaction first" >&2
    return 1
  }
  expected_nonce="$latest"
  require_sender_nonce "$expected_nonce"
  case "$action" in
    migrateAuction)
      target="$PAD"; calldata="$(cast calldata 'migrateAuction(address)' "$CANARY_AUCTION_TOKEN")" ;;
    exitBid)
      target="$CANARY_AUCTION"; calldata="$(cast calldata 'exitBid(uint256)' "$CANARY_BID_ID")" ;;
    claimTokens)
      target="$CANARY_AUCTION"; calldata="$(cast calldata 'claimTokens(uint256)' "$CANARY_BID_ID")" ;;
    claimAuctionProceeds)
      target="$PAD"; calldata="$(cast calldata 'claimAuctionProceeds(address)' "$CANARY_AUCTION_TOKEN")" ;;
    collect)
      target="$BURNER"; calldata="$(cast calldata 'collect()')" ;;
    buybackAndBurn)
      target="$BURNER"; calldata="$(cast calldata 'buybackAndBurn(uint256,uint256)' 3000000000000 3000000000000000000)"
      burner_balance="$(cast balance "$BURNER")"
      node -e '
        if (BigInt(process.argv[1]) < 3_000_000_000_000n) {
          throw new Error("burner balance is below the exact canary buyback input");
        }
      ' "$burner_balance"
      if ! simulated_burn="$(
        cast call --from "$SENDER" "$BURNER" \
          'buybackAndBurn(uint256,uint256)(uint256)' 3000000000000 3000000000000000000 |
          awk 'NR == 1 { print $1 }'
      )"; then
        echo "Phase-B buybackAndBurn pre-sign simulation reverted or was unavailable; no signing journal was written" >&2
        return 1
      fi
      if ! node -e '
        const raw = process.argv[1];
        if (!/^[0-9]+$/.test(raw)) throw new Error("buyback simulation returned a non-numeric burn");
        if (BigInt(raw) < 3_000_000_000_000_000_000n) {
          throw new Error("buyback simulation returned less than the reviewed 3 HOOKR minimum");
        }
      ' "$simulated_burn"; then
        echo "Phase-B buybackAndBurn pre-sign simulation was invalid or below minimum; no signing journal was written" >&2
        return 1
      fi
      echo "Phase-B buybackAndBurn pre-sign simulation passed: $simulated_burn HOOKR wei"
      ;;
    *) echo "unknown Phase-B action: $action" >&2; return 1 ;;
  esac
  mkdir -p "$PHASE_B_JOURNAL_DIR_ABS"
  node - "$journal" "$action" "$expected_nonce" "$SENDER" "$target" "$calldata" \
    "$CANARY_OPERATOR_COMMIT" <<'NODE'
const fs = require("node:fs");
const [path, action, nonce, sender, target, calldata, canaryOperatorCommit] = process.argv.slice(2);
fs.writeFileSync(path, `${JSON.stringify({
  kind: "hookr-v5-phase-b-signing-plan-v1",
  chainId: 4663,
  canaryOperatorCommit,
  action,
  nonce,
  sender,
  target,
  calldata,
  value: "0",
  createdAt: new Date().toISOString(),
}, null, 2)}\n`, { flag: "wx", mode: 0o600 });
NODE
  echo "Phase B: signing exact missing transition $action at explicit owner nonce $expected_nonce"
  case "$action" in
    migrateAuction)
      cast send "$PAD" 'migrateAuction(address)' "$CANARY_AUCTION_TOKEN" \
        "${CAST_SIGNER_ARGS[@]}" --nonce "$expected_nonce" --confirmations 1 --json | tee "$plan_receipt" || send_status=$?
      ;;
    exitBid)
      cast send "$CANARY_AUCTION" 'exitBid(uint256)' "$CANARY_BID_ID" \
        "${CAST_SIGNER_ARGS[@]}" --nonce "$expected_nonce" --confirmations 1 --json | tee "$plan_receipt" || send_status=$?
      ;;
    claimTokens)
      cast send "$CANARY_AUCTION" 'claimTokens(uint256)' "$CANARY_BID_ID" \
        "${CAST_SIGNER_ARGS[@]}" --nonce "$expected_nonce" --confirmations 1 --json | tee "$plan_receipt" || send_status=$?
      ;;
    claimAuctionProceeds)
      cast send "$PAD" 'claimAuctionProceeds(address)' "$CANARY_AUCTION_TOKEN" \
        "${CAST_SIGNER_ARGS[@]}" --nonce "$expected_nonce" --confirmations 1 --json | tee "$plan_receipt" || send_status=$?
      ;;
    collect)
      cast send "$BURNER" 'collect()' \
        "${CAST_SIGNER_ARGS[@]}" --nonce "$expected_nonce" --confirmations 1 --json | tee "$plan_receipt" || send_status=$?
      ;;
    buybackAndBurn)
      cast send "$BURNER" 'buybackAndBurn(uint256,uint256)' 3000000000000 3000000000000000000 \
        "${CAST_SIGNER_ARGS[@]}" --nonce "$expected_nonce" --confirmations 1 --json | tee "$plan_receipt" || send_status=$?
      ;;
    *) echo "unknown Phase-B action: $action" >&2; return 1 ;;
  esac
  [ "$send_status" -eq 0 ] || {
    echo "Phase-B $action send failed or became ambiguous; signing plan remains at $journal and blocks every retry until manual nonce/mempool/receipt reconciliation" >&2
    return "$send_status"
  }
  transaction_hash="$(node -e '
    const fs = require("node:fs");
    const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!/^0x[0-9a-fA-F]{64}$/.test(String(d.transactionHash || ""))) process.exit(1);
    process.stdout.write(d.transactionHash);
  ' "$plan_receipt")" || {
    echo "Phase-B $action response has no authenticated transaction hash; signing plan remains blocked" >&2
    return 1
  }
  cast tx "$transaction_hash" --json >"$plan_transaction"
  node - "$journal" "$plan_transaction" "$plan_receipt" <<'NODE'
const fs = require("node:fs");
const [journalPath, transactionPath, receiptPath] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(journalPath, "utf8"));
const tx = JSON.parse(fs.readFileSync(transactionPath, "utf8"));
const receipt = JSON.parse(fs.readFileSync(receiptPath, "utf8"));
const same = (a, b) => String(a || "").toLowerCase() === String(b || "").toLowerCase();
if (!same(tx.hash, receipt.transactionHash) || BigInt(receipt.status) !== 1n) {
  throw new Error("Phase-B journal transaction/receipt is not one successful hash-bound pair");
}
if (!same(tx.from, plan.sender) || !same(tx.to, plan.target) || !same(tx.input, plan.calldata) ||
    BigInt(tx.nonce) !== BigInt(plan.nonce) || BigInt(tx.value || 0) !== 0n || BigInt(tx.chainId) !== 4663n) {
  throw new Error("Phase-B journal transaction differs from its pre-signing plan");
}
NODE
}

wait_phase_b_action_finalized() {
  local action="$1" summary now deadline next_notice finalized receipt_path
  deadline="$(( $(date +%s) + FINALITY_WAIT_MAX_SECONDS ))"
  next_notice=0
  while true; do
    summary="$(mktemp)"
    if ! phase_b_collect "$summary"; then
      rm "$summary"
      echo "Phase-B $action could not be re-authenticated while waiting for finality" >&2
      return 1
    fi
    [ "$(phase_b_summary_value "$summary" action-present "$action")" = "true" ] || {
      rm "$summary"
      echo "Phase-B $action disappeared from the canonical scan before finality; stop for journal/reorg reconciliation" >&2
      return 1
    }
    finalized="$(phase_b_summary_value "$summary" action-finalized "$action")"
    receipt_path="$(phase_b_summary_value "$summary" action-receipt "$action")"
    if [ "$finalized" = "true" ]; then
      [ -f "$receipt_path" ] || {
        rm "$summary"
        echo "Phase-B $action finalized but its immutable canonical receipt was not installed" >&2
        return 1
      }
      PHASE_B_FINALIZED_RECEIPT_PATH="$receipt_path"
      rm "$summary"
      return 0
    fi
    rm "$summary"
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || {
      echo "Phase-B $action did not finalize within ${FINALITY_WAIT_MAX_SECONDS}s; stop without resubmitting" >&2
      return 1
    }
    if [ "$now" -ge "$next_notice" ]; then
      echo "waiting for Phase-B $action canonical outcome to finalize"
      next_notice="$((now + 30))"
    fi
    sleep 10
  done
}

phase_b_reconcile_action() {
  local action="$1" summary receipt_path blockers send_status scan_deadline journal finalized
  journal="$PHASE_B_JOURNAL_DIR_ABS/$(phase_b_slug "$action").plan.json"
  summary="$(mktemp)"
  phase_b_collect "$summary"
  if [ "$action" = "claimAuctionProceeds" ]; then
    phase_b_claim_proceeds_gate "$summary" || { rm "$summary"; return 1; }
  fi
  if [ "$(phase_b_summary_value "$summary" action-present "$action")" != "true" ]; then
    blockers="$(phase_b_summary_value "$summary" action-blockers "$action")"
    [ -z "$blockers" ] || {
      rm "$summary"
      echo "Phase-B $action is blocked by missing canonical evidence: $blockers" >&2
      return 1
    }
    if [ -e "$journal" ] || [ -e "$PHASE_B_JOURNAL_DIR_ABS/$(phase_b_slug "$action").receipt.json" ] || \
      [ -e "$PHASE_B_JOURNAL_DIR_ABS/$(phase_b_slug "$action").transaction.json" ]; then
      rm "$summary"
      echo "Phase-B $action still lacks a canonical outcome but has signing-journal evidence under $PHASE_B_JOURNAL_DIR_ABS; reconcile its exact nonce/transaction before any retry" >&2
      return 1
    fi
    rm "$summary"
    refresh_release_guard
    require_timing "125000 0 1"
    send_status=0
    phase_b_send_action "$action" || send_status=$?
    # A permissionless caller may win the race, or the RPC may lose the response after submission.
    # Never retry blindly. Reconcile canonical events for up to one minute, then hard-stop if the
    # exact transition remains absent. Re-running this command later is safe because it rescans first.
    scan_deadline="$(( $(date +%s) + 60 ))"
    while true; do
      summary="$(mktemp)"
      if phase_b_collect "$summary" && \
        [ "$(phase_b_summary_value "$summary" action-present "$action")" = "true" ]; then
        if [ "$action" != "claimAuctionProceeds" ] || \
          phase_b_claim_proceeds_gate "$summary" 1; then
          break
        fi
      fi
      rm "$summary"
      [ "$(date +%s)" -lt "$scan_deadline" ] || {
        if [ "$send_status" -ne 0 ]; then
          echo "Phase-B $action send failed or was ambiguous and no canonical outcome was found; signing journal remains and no retry is allowed" >&2
        else
          echo "Phase-B $action was submitted but no canonical outcome was found; signing journal remains and no retry is allowed" >&2
        fi
        return 1
      }
      sleep 2
    done
  fi
  if [ "$action" = "claimAuctionProceeds" ]; then
    phase_b_claim_proceeds_gate "$summary" 1 || { rm "$summary"; return 1; }
  fi
  receipt_path="$(phase_b_summary_value "$summary" action-receipt "$action")"
  finalized="$(phase_b_summary_value "$summary" action-finalized "$action")"
  rm "$summary"
  if [ "$finalized" != "true" ]; then
    PHASE_B_FINALIZED_RECEIPT_PATH=""
    wait_phase_b_action_finalized "$action"
    receipt_path="$PHASE_B_FINALIZED_RECEIPT_PATH"
  fi
  [ -f "$receipt_path" ] || {
    echo "Phase-B $action canonical receipt path is missing" >&2
    return 1
  }
  wait_receipts_finalized "$receipt_path" "Phase B $action"
  summary="$(mktemp)"
  phase_b_collect "$summary"
  if [ "$action" = "claimAuctionProceeds" ]; then
    phase_b_claim_proceeds_gate "$summary" 1 || { rm "$summary"; return 1; }
  fi
  [ "$(phase_b_summary_value "$summary" action-finalized "$action")" = "true" ] || {
    rm "$summary"
    echo "Phase-B $action is not finalized after its canonical wait" >&2
    return 1
  }
  rm "$summary"
}

phase_b_index() {
  local action="$1" summary="$2" write_args=() identities
  [ "$action" != "write" ] || write_args=(--write)
  identities="$(node - "$summary" <<'NODE'
const fs = require("node:fs");
const d = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const i = d.identities;
const a = d.phaseAAccrual;
for (const value of [
  i.auctionToken, i.auction, i.bidId, i.launchpad, i.burner, i.owner, i.poolManager,
  i.auctionPoolId, i.hook, i.hookrToken, a.transactionHash, a.blockNumber, a.transactionIndex,
  a.logIndex, a.poolId, a.amountWei,
]) process.stdout.write(`${value}\n`);
NODE
  )"
  local auction_token auction bid_id launchpad burner owner pool_manager auction_pool_id hook hookr_token
  local accrual_hash accrual_block accrual_tx_index accrual_log_index accrual_pool_id accrual_amount
  {
    read -r auction_token
    read -r auction
    read -r bid_id
    read -r launchpad
    read -r burner
    read -r owner
    read -r pool_manager
    read -r auction_pool_id
    read -r hook
    read -r hookr_token
    read -r accrual_hash
    read -r accrual_block
    read -r accrual_tx_index
    read -r accrual_log_index
    read -r accrual_pool_id
    read -r accrual_amount
  } <<<"$identities"
  (cd "$REPO_ROOT" && node "$PHASE_B_BUILDER" \
    --migrate-auction-transaction "$PHASE_B_EVIDENCE_DIR_ABS/migrate-auction/transaction.json" \
    --migrate-auction-receipt "$PHASE_B_EVIDENCE_DIR_ABS/migrate-auction/receipt.json" \
    --exit-bid-transaction "$PHASE_B_EVIDENCE_DIR_ABS/exit-bid/transaction.json" \
    --exit-bid-receipt "$PHASE_B_EVIDENCE_DIR_ABS/exit-bid/receipt.json" \
    --claim-tokens-transaction "$PHASE_B_EVIDENCE_DIR_ABS/claim-tokens/transaction.json" \
    --claim-tokens-receipt "$PHASE_B_EVIDENCE_DIR_ABS/claim-tokens/receipt.json" \
    --claim-auction-proceeds-transaction "$PHASE_B_EVIDENCE_DIR_ABS/claim-auction-proceeds/transaction.json" \
    --claim-auction-proceeds-receipt "$PHASE_B_EVIDENCE_DIR_ABS/claim-auction-proceeds/receipt.json" \
    --collect-transaction "$PHASE_B_EVIDENCE_DIR_ABS/collect/transaction.json" \
    --collect-receipt "$PHASE_B_EVIDENCE_DIR_ABS/collect/receipt.json" \
    --buyback-and-burn-transaction "$PHASE_B_EVIDENCE_DIR_ABS/buyback-and-burn/transaction.json" \
    --buyback-and-burn-receipt "$PHASE_B_EVIDENCE_DIR_ABS/buyback-and-burn/receipt.json" \
    --source-commit "$PHASE_A_RECOVERY_COMMIT" --token "$auction_token" --auction "$auction" \
    --bid-id "$bid_id" --launchpad "$launchpad" --burner "$burner" --owner "$owner" \
    --pool-manager "$pool_manager" --pool-id "$auction_pool_id" --hook "$hook" \
    --hookr-token "$hookr_token" \
    --phase-a-accrual-transaction-hash "$accrual_hash" \
    --phase-a-accrual-block-number "$accrual_block" \
    --phase-a-accrual-transaction-index "$accrual_tx_index" \
    --phase-a-accrual-log-index "$accrual_log_index" \
    --phase-a-accrual-pool-id "$accrual_pool_id" \
    --phase-a-accrual-amount-wei "$accrual_amount" \
    --output "$PHASE_B_INDEX_ABS" "${write_args[@]}")
}

run_promote_dry_run() {
  (cd "$REPO_ROOT" && node scripts/promote-release-manifest.mjs \
    --deploy "$DEPLOY_ABS" --library-evidence "$LIBRARY_EVIDENCE_ABS" \
    --canary-instant-launch "$PHASE_A_INSTANT_LAUNCH_ABS" \
    --canary-instant-buy-auction-launch "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
    --canary-owner-bid-transaction "$PHASE_A_OWNER_BID_TRANSACTION_ABS" \
    --canary-owner-bid-receipt "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
    --canary-hookr-launch "$PHASE_A_HOOKR_LAUNCH_ABS" \
    --canary-hookr-approve-buy "$PHASE_A_HOOKR_APPROVE_BUY_ABS" \
    --canary-timing-shorten-transaction "$SHORTEN_TRANSACTION_ABS" \
    --canary-timing-shorten-receipt "$SHORTEN_RECEIPT_ABS" \
    --canary-timing-restore-transaction "$RESTORE_TRANSACTION_ABS" \
    --canary-timing-restore-receipt "$RESTORE_RECEIPT_ABS" \
    --canary-phase-a-index "$PHASE_A_INDEX_ABS" \
    --canary-phase-b-index "$PHASE_B_INDEX_ABS" \
    --dry-run)
}

show_status() {
  local instant auction hookr pair_1 pair_23 owner_bid pair_6 pair_78 pair_index pair_b abandoned_state
  local timing_shorten timing_restore finalized phase_b_journals
  instant="$(read_call "$PAD" 'launchedByIntent(address,bytes32)(address)' "$SENDER" \
    0x63ae3076275e7bf7e65f41aa51544acf063c28f2d1b15d0b1e32ea0a0e9aa2fc)"
  auction="$(read_call "$PAD" 'launchedByIntent(address,bytes32)(address)' "$SENDER" \
    0x9c7799db40fdcc5f1cd5a73434b75f784cb5bc1104c6a27cef34d4e7fb1e33ac)"
  hookr="$(read_call "$PAD" 'launchedByIntent(address,bytes32)(address)' "$SENDER" \
    0x1b07b8b1c7415899dbedbc5591619f7c0996781efbf575f67e5640297c765476)"
  pair_1="absent"; pair_23="absent"; owner_bid="absent"; pair_6="absent"; pair_78="absent"
  pair_index="absent"; pair_b="absent"
  abandoned_state="no"; phase_b_journals="0"
  timing_shorten="absent"; timing_restore="absent"
  [ ! -f "$PHASE_A_INSTANT_LAUNCH_ABS" ] || pair_1="$(node -e 'const d=require(process.argv[1]); process.stdout.write(`${d.receipts?.length||0}/${d.transactions?.length||0}`)' "$PHASE_A_INSTANT_LAUNCH_ABS")"
  [ ! -f "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" ] || pair_23="$(node -e 'const d=require(process.argv[1]); process.stdout.write(`${d.receipts?.length||0}/${d.transactions?.length||0}`)' "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS")"
  if [ -f "$PHASE_A_OWNER_BID_TRANSACTION_ABS" ] && [ -f "$PHASE_A_OWNER_BID_RECEIPT_ABS" ]; then owner_bid="pair-present";
  elif [ -e "$PHASE_A_OWNER_BID_TRANSACTION_ABS" ] || [ -e "$PHASE_A_OWNER_BID_RECEIPT_ABS" ]; then owner_bid="PARTIAL"; fi
  [ ! -f "$PHASE_A_HOOKR_LAUNCH_ABS" ] || pair_6="$(node -e 'const d=require(process.argv[1]); process.stdout.write(`${d.receipts?.length||0}/${d.transactions?.length||0}`)' "$PHASE_A_HOOKR_LAUNCH_ABS")"
  [ ! -f "$PHASE_A_HOOKR_APPROVE_BUY_ABS" ] || pair_78="$(node -e 'const d=require(process.argv[1]); process.stdout.write(`${d.receipts?.length||0}/${d.transactions?.length||0}`)' "$PHASE_A_HOOKR_APPROVE_BUY_ABS")"
  [ ! -f "$PHASE_A_INDEX_ABS" ] || pair_index="present"
  if [ -f "$PHASE_B_INDEX_ABS" ]; then
    pair_b="index-present"
  elif [ -d "$PHASE_B_EVIDENCE_DIR_ABS" ]; then
    pair_b="$(node - "$PHASE_B_EVIDENCE_DIR_ABS" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const slugs = ["migrate-auction", "exit-bid", "claim-tokens", "claim-auction-proceeds", "collect", "buyback-and-burn"];
const count = slugs.filter((slug) =>
  fs.existsSync(path.join(root, slug, "transaction.json")) &&
  fs.existsSync(path.join(root, slug, "receipt.json"))).length;
process.stdout.write(`${count}/6-canonical-action-references`);
NODE
    )"
  fi
  if [ -d "$PHASE_B_JOURNAL_DIR_ABS" ]; then
    phase_b_journals="$(node - "$PHASE_B_JOURNAL_DIR_ABS" <<'NODE'
const fs = require("node:fs");
const root = process.argv[2];
process.stdout.write(String(fs.readdirSync(root).filter((name) => name.endsWith(".plan.json")).length));
NODE
    )"
  fi
  [ ! -f "$PHASE_A_ABANDONED_ABS" ] || abandoned_state="YES"
  if [ -f "$SHORTEN_RECEIPT_ABS" ] && [ -f "$SHORTEN_TRANSACTION_ABS" ]; then
    timing_shorten="present"
  elif [ -e "$SHORTEN_RECEIPT_ABS" ] || [ -e "$SHORTEN_TRANSACTION_ABS" ]; then
    timing_shorten="PARTIAL"
  fi
  if [ -f "$RESTORE_RECEIPT_ABS" ] && [ -f "$RESTORE_TRANSACTION_ABS" ]; then
    timing_restore="present"
  elif [ -e "$RESTORE_RECEIPT_ABS" ] || [ -e "$RESTORE_TRANSACTION_ABS" ]; then
    timing_restore="PARTIAL"
  fi
  finalized="$(cast block finalized --field number)"
  echo "authenticated V5.0.1 target:"
  echo "  deployment source $DEPLOYMENT_SOURCE_COMMIT"
  echo "  target operator   $STATE_OPERATOR_COMMIT"
  echo "  current tooling   $CANARY_OPERATOR_COMMIT"
  echo "  launchpad $PAD  $PAD_HASH"
  echo "  hook      $HOOK  $HOOK_HASH"
  echo "  router    $ROUTER  $ROUTER_HASH"
  echo "  burner    $BURNER  $BURNER_HASH"
  echo "  timing    $(timing)"
  echo "  finalized head $finalized; timing evidence shorten=$timing_shorten restore=$timing_restore"
  echo "  intents   instant=$instant auction=$auction hookr=$hookr"
  echo "  evidence A1=$pair_1 A2-3=$pair_23 owner-bid=$owner_bid A6=$pair_6 A7-8=$pair_78 index=$pair_index phase-b=$pair_b journals=$phase_b_journals"
  echo "  phase A abandoned=$abandoned_state"
}

send_timing() {
  local duration="$1" receipt_path="$2" transaction_path="$3" expected_nonce="${4:-}" latest pending hash
  [ ! -e "$receipt_path" ] && [ ! -e "$transaction_path" ] || {
    echo "timing evidence already exists at $receipt_path or $transaction_path" >&2; return 1;
  }
  if [ -z "$expected_nonce" ]; then
    latest="$(sender_nonce latest)"
    pending="$(sender_nonce pending)"
    [ "$latest" = "$pending" ] || { echo "sender has a pending nonce; timing transaction blocked" >&2; return 1; }
    expected_nonce="$latest"
  fi
  require_sender_nonce "$expected_nonce"
  mkdir -p "$(dirname "$receipt_path")"
  cast send "$PAD" 'setAuctionTiming(uint64,uint64,uint64)' "$duration" 0 1 \
    "${CAST_SIGNER_ARGS[@]}" --nonce "$expected_nonce" --confirmations 1 --json | tee "$receipt_path"
  hash="$(node -e 'process.stdout.write(require(process.argv[1]).transactionHash)' "$receipt_path")"
  cast tx "$hash" --json | tee "$transaction_path" >/dev/null
  timing_receipt_check "$receipt_path" "$transaction_path" "$duration" "$expected_nonce"
}

forge_phase() {
  local signature="$1" forge_cache_dir forge_status
  local env_args=(
    "HOOKR_LAUNCHPAD_V5_ADDRESS=$PAD"
    "HOOKR_HOOK_V5_ADDRESS=$HOOK"
    "HOOKR_SWAP_ROUTER_V5_ADDRESS=$ROUTER"
    "HOOKR_FLYWHEEL_BURNER_ADDRESS=$BURNER"
    "HOOKR_LAUNCHPAD_V5_RUNTIME_CODEHASH=$PAD_HASH"
    "HOOKR_HOOK_V5_RUNTIME_CODEHASH=$HOOK_HASH"
    "HOOKR_SWAP_ROUTER_V5_RUNTIME_CODEHASH=$ROUTER_HASH"
    "HOOKR_FLYWHEEL_BURNER_RUNTIME_CODEHASH=$BURNER_HASH"
    "HOOKR_CANARY_SENDER=$SENDER"
  )
  if [ "${HOOKR_UNLOCKED:-0}" = "1" ]; then
    env_args+=("HOOKR_CANARY_ALLOW_PREINSTALLED_ARBSYS_SHIM=true")
  fi
  [ -z "${CANARY_INSTANT_TOKEN:-}" ] || env_args+=("CANARY_INSTANT_TOKEN=$CANARY_INSTANT_TOKEN")
  [ -z "${CANARY_AUCTION_TOKEN:-}" ] || env_args+=("CANARY_AUCTION_TOKEN=$CANARY_AUCTION_TOKEN")
  [ -z "${CANARY_AUCTION:-}" ] || env_args+=("CANARY_AUCTION=$CANARY_AUCTION")
  [ -z "${CANARY_HOOKR_PAIR_TOKEN:-}" ] || env_args+=("CANARY_HOOKR_PAIR_TOKEN=$CANARY_HOOKR_PAIR_TOKEN")
  [ -z "${CANARY_BID_ID:-}" ] || env_args+=("CANARY_BID_ID=$CANARY_BID_ID")
  forge_cache_dir="$(mktemp -d "$CANARY_DIR/.sensitive-cache.XXXXXX")"
  chmod 700 "$forge_cache_dir"
  # Export the per-stage inputs in a subshell so the `forge` shell wrapper above remains in the
  # call path. `/usr/bin/env ... forge` would bypass that function and could leak a secret-bearing
  # RPC URL through unredacted transport stderr.
  if (
    export "${env_args[@]}"
    forge script script/CanaryRobinhoodV5.s.sol \
      --sig "$signature" --sender "$SENDER" "${SIGNER_ARGS[@]}" \
      --broadcast --slow --skip-simulation --cache-path "$forge_cache_dir"
  ); then
    forge_status=0
  else
    forge_status=$?
  fi
  rm -r -- "$forge_cache_dir"
  return "$forge_status"
}

record_phase_a_abandonment() {
  local status="$1" emergency_stamp="$2" reason="$3"
  if [ ! -e "$PHASE_A_ABANDONED_ABS" ]; then
    node - "$PHASE_A_ABANDONED_ABS" "$status" "$emergency_stamp" "$reason" <<'NODE'
const fs = require("node:fs");
const [path, status, emergencyStamp, reason] = process.argv.slice(2);
fs.writeFileSync(path, `${JSON.stringify({
  kind: "hookr-v5-phase-a-abandoned-v1",
  status: Number(status),
  emergencyStamp,
  reason,
  recordedAt: new Date().toISOString(),
}, null, 2)}\n`, { flag: "wx", mode: 0o600 });
NODE
  fi
}

phase_a_exit_guard() {
  local status="$?" emergency_stamp="" abandoned=0
  trap - EXIT INT TERM HUP TSTP
  set +e
  if [ "$status" -ne 0 ]; then
    echo "PHASE A STOPPED after signing could have started." >&2
    if [ "$(timing 2>/dev/null)" != "125000 0 1" ]; then
      abandoned=1
      emergency_stamp="$(date +%s)"
      echo "URGENT: timing is still short. Starting a visible emergency restore now; enter the Foundry account password when prompted." >&2
      send_timing 125000 \
        "$CANARY_DIR/timing-emergency-restore-$emergency_stamp-receipt.json" \
        "$CANARY_DIR/timing-emergency-restore-$emergency_stamp-transaction.json"
    fi
    if [ "$(timing 2>/dev/null)" != "125000 0 1" ]; then
      echo "IMMEDIATE RESTORE REQUIRED: with the same authenticated RPC environment, run:" >&2
      echo "  HOOKR_V5_CONFIRM=restore ./run-canary-v5.sh restore" >&2
    else
      echo "production timing is restored" >&2
    fi
    allowance="$(read_call "$HOOKR_TOKEN" 'allowance(address,address)(uint256)' "$SENDER" "$ROUTER" 2>/dev/null | awk '{print $1}')"
    if [ -n "$allowance" ] && [ "$allowance" != "0" ]; then
      echo "HOOKR router allowance remains $allowance; revoke it before any continuation:" >&2
      echo "  ETH_RPC_URL=\"\$HOOKR_RPC_URL\" cast send $HOOKR_TOKEN 'approve(address,uint256)' $ROUTER 0 --account nodar-deployer --from $SENDER" >&2
    fi
    if [ "$abandoned" -eq 1 ]; then
      record_phase_a_abandonment "$status" "$emergency_stamp" "automatic emergency restore consumed an interstitial nonce"
      echo "This canary chronology is ABANDONED because an emergency restore consumed an interstitial nonce. Do not rerun phase-a; archive and reconcile every receipt manually." >&2
    else
      echo "Continuation is allowed only through this wrapper after it revalidates every complete artifact. Partial/pending evidence is a manual hard stop." >&2
    fi
    echo "Never use forge --resume. SIGKILL, power loss, or terminal loss cannot run this guard; check timing immediately and use the restore command if needed." >&2
  fi
  release_operator_lock
  return "$status"
}

phase_a_signal_guard() {
  local signal="$1" status="$2"
  echo "phase A received $signal; exiting through the restore guard" >&2
  exit "$status"
}

refresh_release_guard() {
  require_clean_source
  load_authenticated_state
}

require_timing_evidence_pair() {
  local receipt="$1" transaction="$2" label="$3"
  if { [ -e "$receipt" ] && [ ! -e "$transaction" ]; } || \
    { [ ! -e "$receipt" ] && [ -e "$transaction" ]; }; then
    echo "$label timing evidence is partial; stop for manual reconciliation" >&2
    return 1
  fi
}

require_hookr_allowance_zero() {
  local allowance
  allowance="$(read_call "$HOOKR_TOKEN" 'allowance(address,address)(uint256)' "$SENDER" "$ROUTER" | awk '{print $1}')"
  [ "$allowance" = "0" ] || {
    echo "HOOKR router allowance is $allowance, expected zero; revoke it before continuing" >&2
    return 1
  }
}

require_phase_a_files() {
  local required
  for required in \
    "$PHASE_A_INSTANT_LAUNCH_ABS" \
    "$SHORTEN_TRANSACTION_ABS" "$SHORTEN_RECEIPT_ABS" \
    "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
    "$RESTORE_TRANSACTION_ABS" "$RESTORE_RECEIPT_ABS" \
    "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
    "$PHASE_A_HOOKR_LAUNCH_ABS" \
    "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "$PHASE_A_INDEX_ABS"; do
    [ -f "$required" ] || { echo "phase A evidence is missing: $required" >&2; return 1; }
  done
}

verify_phase_a_bundle() {
  local expected_auction_status="${1:-0}"
  require_phase_a_files
  authenticate_phase_a_recovery_commit
  BASE_NONCE="$(artifact_first_nonce "$PHASE_A_INSTANT_LAUNCH_ABS")"
  SHORTEN_NONCE="$(next_nonce "$BASE_NONCE" 1)"
  STAGE_23_NONCE="$(next_nonce "$BASE_NONCE" 2)"
  RESTORE_NONCE="$(next_nonce "$BASE_NONCE" 4)"
  OWNER_BID_EXPECTED_NONCE="$(next_nonce "$BASE_NONCE" 5)"
  HOOKR_LAUNCH_NONCE="$(next_nonce "$BASE_NONCE" 6)"
  HOOKR_BUY_NONCE="$(next_nonce "$BASE_NONCE" 7)"

  raw_phase_artifact_check "$PHASE_A_INSTANT_LAUNCH_ABS" instant-launch 1 "$BASE_NONCE"
  timing_receipt_check "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
    "$CANARY_AUCTION_DURATION" "$SHORTEN_NONCE"
  raw_phase_artifact_check "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
    instant-buy-auction-launch 2 "$STAGE_23_NONCE"
  timing_receipt_check "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" 125000 "$RESTORE_NONCE"
  AUCTION_AUTH="$(authenticated_auction "$expected_auction_status")"
  read -r _ CANARY_AUCTION AUCTION_END _ _ <<<"$AUCTION_AUTH"
  owner_bid_receipt_check "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
    "$CANARY_AUCTION" "$AUCTION_END" "$OWNER_BID_EXPECTED_NONCE"
  phase_a_owner_bid_semantics "$CANARY_AUCTION" "$AUCTION_END"
  raw_phase_artifact_check "$PHASE_A_HOOKR_LAUNCH_ABS" hookr-launch 1 "$HOOKR_LAUNCH_NONCE"
  raw_phase_artifact_check "$PHASE_A_HOOKR_APPROVE_BUY_ABS" hookr-approve-buy 2 "$HOOKR_BUY_NONCE"
  wait_receipts_finalized "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "phase A final stage"

  PHASE_A_OUTPUTS="$(phase_a_outputs "$expected_auction_status")"
  read -r CANARY_INSTANT_TOKEN CANARY_AUCTION_TOKEN CANARY_AUCTION CANARY_BID_ID \
    CANARY_HOOKR_PAIR_TOKEN <<<"$PHASE_A_OUTPUTS"
  AUCTION_AUTH="$(authenticated_auction "$expected_auction_status")"
  read -r _ _ AUCTION_END _ _ <<<"$AUCTION_AUTH"
  phase_a_stage_semantics instant-launch "$PHASE_A_INSTANT_LAUNCH_ABS" \
    --instant-token "$CANARY_INSTANT_TOKEN"
  phase_a_stage_semantics instant-buy-auction-launch \
    "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" --instant-token "$CANARY_INSTANT_TOKEN"
  phase_a_stage_semantics hookr-launch "$PHASE_A_HOOKR_LAUNCH_ABS"
  phase_a_stage_semantics hookr-approve-buy "$PHASE_A_HOOKR_APPROVE_BUY_ABS" \
    --hookr-pair-token "$CANARY_HOOKR_PAIR_TOKEN"
  require_raw_launch_event "$PHASE_A_INSTANT_LAUNCH_ABS" 0 instant "$CANARY_INSTANT_TOKEN"
  require_raw_launch_event "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" 1 auction \
    "$CANARY_AUCTION_TOKEN" "$CANARY_AUCTION" "$AUCTION_END"
  require_raw_launch_event "$PHASE_A_HOOKR_LAUNCH_ABS" 0 instant "$CANARY_HOOKR_PAIR_TOKEN"
  phase_a_index verify "$CANARY_INSTANT_TOKEN" "$CANARY_AUCTION_TOKEN" "$CANARY_AUCTION" \
    "$CANARY_BID_ID" "$CANARY_HOOKR_PAIR_TOKEN"
  require_timing "125000 0 1"
  require_hookr_allowance_zero
}

# Recovery preflight is intentionally narrower than a fresh-canary preflight. Nonces 707-712 are
# already mined, so authenticate that exact immutable/canonical prefix before pinning a target that
# may authorize nonce 713. Ambient permissionless launches, fee collection, or auction migration
# may coexist; they cannot replace the reviewed intents, evidence, chronology, or unused HOOKR lane.
recovery_mutable_state_check() {
  local auction_auth current_token current_auction current_end hookr_intent
  auction_auth="$(authenticated_auction)"
  read -r current_token current_auction current_end _ _ <<<"$auction_auth"
  same_hex "$current_token" "$CANARY_AUCTION_TOKEN" && \
    same_hex "$current_auction" "$CANARY_AUCTION" && [ "$current_end" = "$AUCTION_END" ] || {
    echo "auction recovery identity changed during preflight" >&2
    return 1
  }
  hookr_intent="$(read_call "$PAD" 'launchedByIntent(address,bytes32)(address)' "$SENDER" \
    0x1b07b8b1c7415899dbedbc5591619f7c0996781efbf575f67e5640297c765476)"
  same_hex "$hookr_intent" "0x0000000000000000000000000000000000000000" || {
    echo "HOOKR-pair recovery intent is already used" >&2
    return 1
  }
  require_timing "125000 0 1"
  require_sender_nonce 713
}

recovery_preflight_check() {
  local required later instant_auth auction_auth
  for required in \
    "$PHASE_A_INSTANT_LAUNCH_ABS" \
    "$SHORTEN_TRANSACTION_ABS" "$SHORTEN_RECEIPT_ABS" \
    "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
    "$RESTORE_TRANSACTION_ABS" "$RESTORE_RECEIPT_ABS" \
    "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS"; do
    [ -f "$required" ] || { echo "recovery preflight evidence is missing: $required" >&2; return 1; }
  done
  for later in "$PHASE_A_HOOKR_LAUNCH_ABS" "$PHASE_A_HOOKR_APPROVE_BUY_ABS" \
    "$PHASE_A_INDEX_ABS" "$PHASE_A_ABANDONED_ABS" "$PHASE_B_INDEX_ABS"; do
    [ ! -e "$later" ] || { echo "recovery preflight found later/abandoned evidence: $later" >&2; return 1; }
  done
  [ ! -e "$CANARY_DIR/bidLaunchHookr-latest.json" ] || {
    echo "legacy combined bidLaunchHookr artifact is forbidden; preserve the owner bid only as its raw transaction/receipt pair" >&2
    return 1
  }

  BASE_NONCE="$(artifact_first_nonce "$PHASE_A_INSTANT_LAUNCH_ABS")"
  [ "$BASE_NONCE" = "707" ] || {
    echo "recovery evidence starts at nonce $BASE_NONCE, expected reviewed nonce 707" >&2
    return 1
  }
  SHORTEN_NONCE="$(next_nonce "$BASE_NONCE" 1)"
  STAGE_23_NONCE="$(next_nonce "$BASE_NONCE" 2)"
  RESTORE_NONCE="$(next_nonce "$BASE_NONCE" 4)"
  OWNER_BID_EXPECTED_NONCE="$(next_nonce "$BASE_NONCE" 5)"

  raw_phase_artifact_check "$PHASE_A_INSTANT_LAUNCH_ABS" instant-launch 1 "$BASE_NONCE"
  timing_receipt_check "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
    "$CANARY_AUCTION_DURATION" "$SHORTEN_NONCE"
  raw_phase_artifact_check "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
    instant-buy-auction-launch 2 "$STAGE_23_NONCE"
  timing_receipt_check "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" 125000 "$RESTORE_NONCE"

  instant_auth="$(authenticated_instant)"
  read -r CANARY_INSTANT_TOKEN _ _ _ _ <<<"$instant_auth"
  auction_auth="$(authenticated_auction)"
  read -r CANARY_AUCTION_TOKEN CANARY_AUCTION AUCTION_END _ _ <<<"$auction_auth"
  require_raw_launch_event "$PHASE_A_INSTANT_LAUNCH_ABS" 0 instant "$CANARY_INSTANT_TOKEN"
  require_raw_launch_event "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" 1 auction \
    "$CANARY_AUCTION_TOKEN" "$CANARY_AUCTION" "$AUCTION_END"
  phase_a_stage_semantics instant-launch "$PHASE_A_INSTANT_LAUNCH_ABS" \
    --instant-token "$CANARY_INSTANT_TOKEN"
  phase_a_stage_semantics instant-buy-auction-launch \
    "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" --instant-token "$CANARY_INSTANT_TOKEN"
  owner_bid_receipt_check "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
    "$CANARY_AUCTION" "$AUCTION_END" "$OWNER_BID_EXPECTED_NONCE"
  phase_a_owner_bid_semantics "$CANARY_AUCTION" "$AUCTION_END"

  recovery_mutable_state_check

  # Finality is part of the recovery checkpoint, not inferred from file presence. Reauthenticate
  # each live receipt after the finalized head advances before allowing the target-state write.
  wait_receipts_finalized "$PHASE_A_INSTANT_LAUNCH_ABS" "recovery instant launch"
  wait_timing_receipt_finalized "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
    "$CANARY_AUCTION_DURATION" "$SHORTEN_NONCE" "recovery timing shorten"
  wait_receipts_finalized "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" "recovery instant buy/auction launch"
  wait_timing_receipt_finalized "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" \
    125000 "$RESTORE_NONCE" "recovery timing restore"
  wait_owner_bid_finalized "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
    "$CANARY_AUCTION" "$AUCTION_END" "$OWNER_BID_EXPECTED_NONCE" "recovery owner bid"
  recovery_mutable_state_check
}

case "$COMMAND" in
  preflight)
    require_clean_source
    load_deploy_facts
    recovery_preflight_check
    (cd "$REPO_ROOT" && node scripts/verify-deployment-preflight.mjs \
      --deploy "$DEPLOY_ABS" --library-evidence "$LIBRARY_EVIDENCE_ABS" \
      --canary-recovery \
      --recovery-instant-token "$CANARY_INSTANT_TOKEN" \
      --recovery-auction-token "$CANARY_AUCTION_TOKEN" \
      --recovery-auction "$CANARY_AUCTION" \
      --forbid-legacy-artifact "$CONTRACTS_DIR/$CANARY_DIR/bidLaunchHookr-latest.json" \
      "${REHEARSAL_ARGS[@]}")
    recovery_mutable_state_check
    write_authenticated_state
    echo "authenticated target pinned at $STATE_ABS"
    ;;

  status)
    require_clean_source
    load_authenticated_state
    show_status
    ;;

  phase-a)
    refresh_release_guard
    require_confirmation
    [ ! -e "$PHASE_A_ABANDONED_ABS" ] || {
      echo "phase A is marked abandoned at $PHASE_A_ABANDONED_ABS; do not rerun it" >&2
      exit 1
    }
    trap phase_a_exit_guard EXIT
    trap 'phase_a_signal_guard INT 130' INT
    trap 'phase_a_signal_guard TERM 143' TERM
    trap 'phase_a_signal_guard HUP 129' HUP
    # Bash defers a trapped TSTP while waiting for a foreground signer. Ignore it instead; the
    # ignored disposition is inherited by child processes, so Ctrl-Z cannot suspend a password
    # prompt while the launchpad is temporarily on canary auction timing.
    trap '' TSTP

    require_timing_evidence_pair "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" shorten
    require_timing_evidence_pair "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" restore

    # Recovery-only boundary: nonces 707-712 are already mined. Refuse to recreate any of them,
    # and refuse the abandoned combined Forge-artifact name so raw owner-bid evidence cannot be
    # laundered into a synthetic `bidLaunchHookr` run.
    for recovered in \
      "$PHASE_A_INSTANT_LAUNCH_ABS" "$SHORTEN_TRANSACTION_ABS" "$SHORTEN_RECEIPT_ABS" \
      "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" "$RESTORE_TRANSACTION_ABS" "$RESTORE_RECEIPT_ABS" \
      "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS"; do
      [ -f "$recovered" ] || {
        echo "live Phase-A recovery evidence is missing: $recovered; this wrapper will not recreate it" >&2
        exit 1
      }
    done
    [ ! -e "$CANARY_DIR/bidLaunchHookr-latest.json" ] || {
      echo "legacy combined bidLaunchHookr artifact is forbidden; preserve the owner bid only as its raw transaction/receipt pair" >&2
      exit 1
    }

    # Stage 1: the plain-CREATE ETH token must mine and finalize before it enters router calldata.
    if [ -f "$PHASE_A_INSTANT_LAUNCH_ABS" ]; then
      BASE_NONCE="$(artifact_first_nonce "$PHASE_A_INSTANT_LAUNCH_ABS")"
      raw_phase_artifact_check "$PHASE_A_INSTANT_LAUNCH_ABS" instant-launch 1 "$BASE_NONCE"
    else
      for later in \
        "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
        "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
        "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" \
        "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
        "$PHASE_A_HOOKR_LAUNCH_ABS" "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "$PHASE_A_INDEX_ABS"; do
        [ ! -e "$later" ] || { echo "later phase A evidence exists before stage 1: $later" >&2; exit 1; }
      done
      require_timing "125000 0 1"
      for intent in \
        0x63ae3076275e7bf7e65f41aa51544acf063c28f2d1b15d0b1e32ea0a0e9aa2fc \
        0x9c7799db40fdcc5f1cd5a73434b75f784cb5bc1104c6a27cef34d4e7fb1e33ac \
        0x1b07b8b1c7415899dbedbc5591619f7c0996781efbf575f67e5640297c765476; do
        used="$(read_call "$PAD" 'launchedByIntent(address,bytes32)(address)' "$SENDER" "$intent")"
        [ "$used" = "0x0000000000000000000000000000000000000000" ] || {
          echo "phase A intent is already consumed by $used without its raw stage evidence" >&2; exit 1;
        }
      done
      ETH_BALANCE="$(cast balance "$SENDER")"
      HOOKR_BALANCE="$(read_call "$HOOKR_TOKEN" 'balanceOf(address)(uint256)' "$SENDER" | awk '{print $1}')"
      node -e '
        if (BigInt(process.argv[1]) < 20_000_000_000_000_000n) throw new Error("canary sender needs at least 0.02 ETH plus gas");
        if (BigInt(process.argv[2]) < 25_000n * 10n ** 18n) throw new Error("canary sender needs at least 25,000 HOOKR");
      ' "$ETH_BALANCE" "$HOOKR_BALANCE"
      require_guard_finality_budget
      BASE_NONCE="$(sender_nonce latest)"
      require_sender_nonce "$BASE_NONCE"
      refresh_release_guard
      require_timing "125000 0 1"
      require_sender_nonce "$BASE_NONCE"
      forge_phase 'openInstant()'
      raw_phase_artifact_check "$PHASE_A_INSTANT_LAUNCH_ABS" instant-launch 1 "$BASE_NONCE"
      require_sender_nonce "$(next_nonce "$BASE_NONCE" 1)"
    fi
    wait_receipts_finalized "$PHASE_A_INSTANT_LAUNCH_ABS" "phase A stage 1"
    INSTANT_AUTH="$(authenticated_instant)"
    read -r CANARY_INSTANT_TOKEN _ _ _ _ <<<"$INSTANT_AUTH"
    require_raw_launch_event "$PHASE_A_INSTANT_LAUNCH_ABS" 0 instant "$CANARY_INSTANT_TOKEN"
    phase_a_stage_semantics instant-launch "$PHASE_A_INSTANT_LAUNCH_ABS" \
      --instant-token "$CANARY_INSTANT_TOKEN"

    # Shorten only after stage 1 is finalized. This timing is exposed globally for the shortest
    # possible interval and is itself raw, hash-bound release evidence.
    SHORTEN_NONCE="$(next_nonce "$BASE_NONCE" 1)"
    if [ -f "$SHORTEN_RECEIPT_ABS" ] && [ -f "$SHORTEN_TRANSACTION_ABS" ]; then
      timing_receipt_check "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
        "$CANARY_AUCTION_DURATION" "$SHORTEN_NONCE"
    else
      for later in "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" "$RESTORE_RECEIPT_ABS" \
        "$RESTORE_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_TRANSACTION_ABS" \
        "$PHASE_A_OWNER_BID_RECEIPT_ABS" "$PHASE_A_HOOKR_LAUNCH_ABS" \
        "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "$PHASE_A_INDEX_ABS"; do
        [ ! -e "$later" ] || { echo "later phase A evidence exists before shorten: $later" >&2; exit 1; }
      done
      refresh_release_guard
      require_timing "125000 0 1"
      require_canary_finality_budget
      require_sender_nonce "$SHORTEN_NONCE"
      send_timing "$CANARY_AUCTION_DURATION" "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" "$SHORTEN_NONCE"
      require_timing "$CANARY_AUCTION_DURATION 0 1"
      require_sender_nonce "$(next_nonce "$BASE_NONCE" 2)"
    fi

    # Stages 2-3: consume the finalized instant token, then create (but do not consume) the CCA.
    STAGE_23_NONCE="$(next_nonce "$BASE_NONCE" 2)"
    if [ -f "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" ]; then
      raw_phase_artifact_check "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
        instant-buy-auction-launch 2 "$STAGE_23_NONCE"
    else
      for later in "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" \
        "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
        "$PHASE_A_HOOKR_LAUNCH_ABS" "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "$PHASE_A_INDEX_ABS"; do
        [ ! -e "$later" ] || { echo "later phase A evidence exists before stages 2-3: $later" >&2; exit 1; }
      done
      refresh_release_guard
      require_timing "$CANARY_AUCTION_DURATION 0 1"
      require_canary_finality_budget
      require_sender_nonce "$STAGE_23_NONCE"
      INSTANT_AUTH="$(authenticated_instant)"
      read -r CANARY_INSTANT_TOKEN _ _ _ _ <<<"$INSTANT_AUTH"
      require_guard_headroom "$CANARY_INSTANT_TOKEN" "instant canary"
      forge_phase 'buyInstantLaunchAuction()'
      raw_phase_artifact_check "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
        instant-buy-auction-launch 2 "$STAGE_23_NONCE"
      require_sender_nonce "$(next_nonce "$BASE_NONCE" 4)"
    fi
    phase_a_stage_semantics instant-buy-auction-launch \
      "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" --instant-token "$CANARY_INSTANT_TOKEN"

    # Restore immediately after the auction-launch receipt. Do not wait for finality while the
    # public launchpad remains on canary timing.
    RESTORE_NONCE="$(next_nonce "$BASE_NONCE" 4)"
    if [ -f "$RESTORE_RECEIPT_ABS" ] && [ -f "$RESTORE_TRANSACTION_ABS" ]; then
      timing_receipt_check "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" 125000 "$RESTORE_NONCE"
    else
      for later in "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
        "$PHASE_A_HOOKR_LAUNCH_ABS" "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "$PHASE_A_INDEX_ABS"; do
        [ ! -e "$later" ] || { echo "later phase A evidence exists before restore: $later" >&2; exit 1; }
      done
      refresh_release_guard
      require_timing "$CANARY_AUCTION_DURATION 0 1"
      require_sender_nonce "$RESTORE_NONCE"
      send_timing 125000 "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" "$RESTORE_NONCE"
      require_sender_nonce "$(next_nonce "$BASE_NONCE" 5)"
    fi
    require_timing "125000 0 1"
    wait_receipts_finalized "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" "phase A stages 2-3"
    wait_receipts_finalized "$RESTORE_RECEIPT_ABS" "phase A production restore"
    AUCTION_AUTH="$(authenticated_auction)"
    read -r CANARY_AUCTION_TOKEN CANARY_AUCTION AUCTION_END _ _ <<<"$AUCTION_AUTH"
    require_raw_launch_event "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" 1 auction \
      "$CANARY_AUCTION_TOKEN" "$CANARY_AUCTION" "$AUCTION_END"

    # The owner bid at N+5 (live nonce 712) is already mined outside Forge. Bind its raw pair to
    # canonical RPC truth and finality before the next signature; there is no bid send/retry path.
    OWNER_BID_EXPECTED_NONCE="$(next_nonce "$BASE_NONCE" 5)"
    owner_bid_receipt_check "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
      "$CANARY_AUCTION" "$AUCTION_END" "$OWNER_BID_EXPECTED_NONCE"
    phase_a_owner_bid_semantics "$CANARY_AUCTION" "$AUCTION_END"
    wait_owner_bid_finalized "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
      "$CANARY_AUCTION" "$AUCTION_END" "$OWNER_BID_EXPECTED_NONCE" "phase A owner bid"

    # Stage 6: launch only the HOOKR pair at N+6 (live nonce 713). Permissionless migration of the
    # independent ETH auction may move it from Auctioning to Live and must not brick this lane.
    HOOKR_LAUNCH_NONCE="$(next_nonce "$BASE_NONCE" 6)"
    if [ -f "$PHASE_A_HOOKR_LAUNCH_ABS" ]; then
      raw_phase_artifact_check "$PHASE_A_HOOKR_LAUNCH_ABS" hookr-launch 1 "$HOOKR_LAUNCH_NONCE"
    else
      for later in "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "$PHASE_A_INDEX_ABS"; do
        [ ! -e "$later" ] || { echo "later phase A evidence exists before HOOKR launch: $later" >&2; exit 1; }
      done
      refresh_release_guard
      require_timing "125000 0 1"
      require_guard_finality_budget
      require_sender_nonce "$HOOKR_LAUNCH_NONCE"
      AUCTION_AUTH="$(authenticated_auction)"
      read -r CANARY_AUCTION_TOKEN CANARY_AUCTION AUCTION_END _ _ <<<"$AUCTION_AUTH"
      owner_bid_receipt_check "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
        "$CANARY_AUCTION" "$AUCTION_END" "$OWNER_BID_EXPECTED_NONCE"
      forge_phase 'launchHookrPair()'
      raw_phase_artifact_check "$PHASE_A_HOOKR_LAUNCH_ABS" hookr-launch 1 "$HOOKR_LAUNCH_NONCE"
      require_sender_nonce "$(next_nonce "$BASE_NONCE" 7)"
    fi
    phase_a_stage_semantics hookr-launch "$PHASE_A_HOOKR_LAUNCH_ABS"
    wait_receipts_finalized "$PHASE_A_HOOKR_LAUNCH_ABS" "phase A HOOKR launch"
    HOOKR_AUTH="$(authenticated_hookr_pair)"
    read -r CANARY_HOOKR_PAIR_TOKEN _ _ _ _ <<<"$HOOKR_AUTH"
    require_raw_launch_event "$PHASE_A_HOOKR_LAUNCH_ABS" 0 instant "$CANARY_HOOKR_PAIR_TOKEN"

    # Stages 7-8: keep the exact HOOKR approval beside its buy. Any partial artifact is a hard
    # stop, and the final readback proves no reusable router allowance remains.
    HOOKR_BUY_NONCE="$(next_nonce "$BASE_NONCE" 7)"
    if [ -f "$PHASE_A_HOOKR_APPROVE_BUY_ABS" ]; then
      raw_phase_artifact_check "$PHASE_A_HOOKR_APPROVE_BUY_ABS" hookr-approve-buy 2 "$HOOKR_BUY_NONCE"
    else
      [ ! -e "$PHASE_A_INDEX_ABS" ] || { echo "phase A index exists before stages 7-8" >&2; exit 1; }
      refresh_release_guard
      require_timing "125000 0 1"
      require_hookr_allowance_zero
      require_sender_nonce "$HOOKR_BUY_NONCE"
      HOOKR_AUTH="$(authenticated_hookr_pair)"
      read -r CANARY_HOOKR_PAIR_TOKEN _ _ _ _ <<<"$HOOKR_AUTH"
      require_guard_headroom "$CANARY_HOOKR_PAIR_TOKEN" "HOOKR-pair canary"
      forge_phase 'buyHookrPair()'
      raw_phase_artifact_check "$PHASE_A_HOOKR_APPROVE_BUY_ABS" hookr-approve-buy 2 "$HOOKR_BUY_NONCE"
      require_sender_nonce "$(next_nonce "$BASE_NONCE" 9)"
    fi
    phase_a_stage_semantics hookr-approve-buy "$PHASE_A_HOOKR_APPROVE_BUY_ABS" \
      --hookr-pair-token "$CANARY_HOOKR_PAIR_TOKEN"
    wait_receipts_finalized "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "phase A stages 7-8"
    require_hookr_allowance_zero

    # Freeze the aggregate only after every raw source is complete, finalized, re-read, and the
    # source tree still matches the authenticated operator commit.
    refresh_release_guard
    require_timing "125000 0 1"
    raw_phase_artifact_check "$PHASE_A_INSTANT_LAUNCH_ABS" instant-launch 1 "$BASE_NONCE"
    timing_receipt_check "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
      "$CANARY_AUCTION_DURATION" "$SHORTEN_NONCE"
    raw_phase_artifact_check "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
      instant-buy-auction-launch 2 "$STAGE_23_NONCE"
    timing_receipt_check "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" 125000 "$RESTORE_NONCE"
    owner_bid_receipt_check "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS" \
      "$CANARY_AUCTION" "$AUCTION_END" "$OWNER_BID_EXPECTED_NONCE"
    phase_a_owner_bid_semantics "$CANARY_AUCTION" "$AUCTION_END"
    raw_phase_artifact_check "$PHASE_A_HOOKR_LAUNCH_ABS" hookr-launch 1 "$HOOKR_LAUNCH_NONCE"
    raw_phase_artifact_check "$PHASE_A_HOOKR_APPROVE_BUY_ABS" hookr-approve-buy 2 "$HOOKR_BUY_NONCE"
    PHASE_A_OUTPUTS="$(phase_a_outputs)"
    read -r CANARY_INSTANT_TOKEN CANARY_AUCTION_TOKEN CANARY_AUCTION CANARY_BID_ID \
      CANARY_HOOKR_PAIR_TOKEN <<<"$PHASE_A_OUTPUTS"
    if [ -f "$PHASE_A_INDEX_ABS" ]; then
      phase_a_index verify "$CANARY_INSTANT_TOKEN" "$CANARY_AUCTION_TOKEN" "$CANARY_AUCTION" \
        "$CANARY_BID_ID" "$CANARY_HOOKR_PAIR_TOKEN"
    else
      phase_a_index write "$CANARY_INSTANT_TOKEN" "$CANARY_AUCTION_TOKEN" "$CANARY_AUCTION" \
        "$CANARY_BID_ID" "$CANARY_HOOKR_PAIR_TOKEN"
    fi
    phase_a_index verify "$CANARY_INSTANT_TOKEN" "$CANARY_AUCTION_TOKEN" "$CANARY_AUCTION" \
      "$CANARY_BID_ID" "$CANARY_HOOKR_PAIR_TOKEN"
    trap - EXIT INT TERM HUP TSTP
    echo "phase A confirmed: raw Forge 1+2+1+2, raw owner bid, and shorten/restore; nine receipts finalized"
    echo "  CANARY_INSTANT_TOKEN=$CANARY_INSTANT_TOKEN"
    echo "  CANARY_AUCTION_TOKEN=$CANARY_AUCTION_TOKEN"
    echo "  CANARY_AUCTION=$CANARY_AUCTION"
    echo "  CANARY_BID_ID=$CANARY_BID_ID"
    echo "  CANARY_HOOKR_PAIR_TOKEN=$CANARY_HOOKR_PAIR_TOKEN"
    echo "production timing is restored; phase B remains a separately approved command"
    release_operator_lock
    ;;

  phase-b)
    refresh_release_guard
    require_timing "125000 0 1"
    require_confirmation
    require_phase_a_files
    PHASE_B_SUMMARY="$(mktemp)"
    phase_b_collect "$PHASE_B_SUMMARY"
    AUCTION_STATUS="$(phase_b_summary_value "$PHASE_B_SUMMARY" launch-status)"
    case "$AUCTION_STATUS" in
      0|1) ;;
      *) rm "$PHASE_B_SUMMARY"; echo "auction is in terminal/non-promotable status $AUCTION_STATUS" >&2; exit 1 ;;
    esac
    rm "$PHASE_B_SUMMARY"
    verify_phase_a_bundle "$AUCTION_STATUS"
    CURRENT_BLOCK="$(current_auction_block)"
    node -e '
      if (BigInt(process.argv[1]) <= BigInt(process.argv[2])) {
        throw new Error("auction window has not closed on the auction/CCA clock");
      }
    ' "$CURRENT_BLOCK" "$AUCTION_END"

    # The first five transitions are permissionless. Reconcile canonical events before every
    # signer prompt, send only a genuinely missing transition, and accept a keeper/front-run receipt
    # when it proves the same exact outcome. Only the final bounded buyback is owner-only.
    for PHASE_B_ACTION in \
      migrateAuction exitBid claimTokens claimAuctionProceeds collect buybackAndBurn; do
      phase_b_reconcile_action "$PHASE_B_ACTION"
    done

    PHASE_B_SUMMARY="$(mktemp)"
    phase_b_collect "$PHASE_B_SUMMARY" --require-complete --require-finalized
    if [ -f "$PHASE_B_INDEX_ABS" ]; then
      phase_b_index verify "$PHASE_B_SUMMARY"
    else
      phase_b_index write "$PHASE_B_SUMMARY"
    fi
    phase_b_index verify "$PHASE_B_SUMMARY"
    rm "$PHASE_B_SUMMARY"
    verify_phase_a_bundle 1
    require_hookr_allowance_zero
    run_promote_dry_run
    echo "phase B confirmed from six finalized canonical outcomes (five transactions when zero proceeds aliases migration); promotion dry-run passed"
    ;;

  restore)
    refresh_release_guard
    if [ "$(timing)" = "125000 0 1" ]; then
      echo "production timing is already restored; no transaction sent"
      exit 0
    fi
    require_confirmation
    PHASE_A_ACTIVITY=0
    for phase_path in \
      "$PHASE_A_INSTANT_LAUNCH_ABS" "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
      "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" "$PHASE_A_OWNER_BID_TRANSACTION_ABS" \
      "$PHASE_A_OWNER_BID_RECEIPT_ABS" "$PHASE_A_HOOKR_LAUNCH_ABS" \
      "$PHASE_A_HOOKR_APPROVE_BUY_ABS" "$PHASE_A_INDEX_ABS"; do
      [ ! -e "$phase_path" ] || PHASE_A_ACTIVITY=1
    done
    PLANNED_RESTORE=0
    if [ -f "$PHASE_A_INSTANT_LAUNCH_ABS" ] && [ -f "$SHORTEN_RECEIPT_ABS" ] && \
      [ -f "$SHORTEN_TRANSACTION_ABS" ] && [ -f "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" ] && \
      [ ! -e "$RESTORE_RECEIPT_ABS" ] && [ ! -e "$RESTORE_TRANSACTION_ABS" ] && \
      [ ! -e "$PHASE_A_OWNER_BID_TRANSACTION_ABS" ] && [ ! -e "$PHASE_A_OWNER_BID_RECEIPT_ABS" ] && \
      [ ! -e "$PHASE_A_HOOKR_LAUNCH_ABS" ] && \
      [ ! -e "$PHASE_A_HOOKR_APPROVE_BUY_ABS" ] && [ ! -e "$PHASE_A_INDEX_ABS" ]; then
      BASE_NONCE="$(artifact_first_nonce "$PHASE_A_INSTANT_LAUNCH_ABS")"
      RESTORE_NONCE="$(next_nonce "$BASE_NONCE" 4)"
      raw_phase_artifact_check "$PHASE_A_INSTANT_LAUNCH_ABS" instant-launch 1 "$BASE_NONCE"
      timing_receipt_check "$SHORTEN_RECEIPT_ABS" "$SHORTEN_TRANSACTION_ABS" \
        "$CANARY_AUCTION_DURATION" "$(next_nonce "$BASE_NONCE" 1)"
      raw_phase_artifact_check "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" \
        instant-buy-auction-launch 2 "$(next_nonce "$BASE_NONCE" 2)"
      INSTANT_AUTH="$(authenticated_instant)"
      read -r CANARY_INSTANT_TOKEN _ _ _ _ <<<"$INSTANT_AUTH"
      phase_a_stage_semantics instant-launch "$PHASE_A_INSTANT_LAUNCH_ABS" \
        --instant-token "$CANARY_INSTANT_TOKEN"
      phase_a_stage_semantics instant-buy-auction-launch \
        "$PHASE_A_INSTANT_BUY_AUCTION_LAUNCH_ABS" --instant-token "$CANARY_INSTANT_TOKEN"
      require_sender_nonce "$RESTORE_NONCE"
      PLANNED_RESTORE=1
    fi
    if [ "$PLANNED_RESTORE" -eq 1 ]; then
      send_timing 125000 "$RESTORE_RECEIPT_ABS" "$RESTORE_TRANSACTION_ABS" "$RESTORE_NONCE"
    else
      EMERGENCY_STAMP="$(date +%s)"
      send_timing 125000 "$CANARY_DIR/timing-emergency-restore-$EMERGENCY_STAMP-receipt.json" \
        "$CANARY_DIR/timing-emergency-restore-$EMERGENCY_STAMP-transaction.json"
      if [ "$PHASE_A_ACTIVITY" -eq 1 ]; then
        record_phase_a_abandonment 1 "$EMERGENCY_STAMP" \
          "out-of-band restore could not occupy the reviewed N+4 chronology"
      fi
    fi
    require_timing "125000 0 1"
    if [ "$PLANNED_RESTORE" -eq 1 ]; then
      echo "production timing restored at the reviewed N+4 boundary; rerun phase-a for full validation"
    elif [ "$PHASE_A_ACTIVITY" -eq 1 ]; then
      echo "production timing restored, but this Phase-A chronology is abandoned; reconcile manually"
    else
      echo "production timing restored and read back"
    fi
    ;;

  promote-dry-run)
    refresh_release_guard
    require_timing "125000 0 1"
    verify_phase_a_bundle 1
    PHASE_B_SUMMARY="$(mktemp)"
    phase_b_collect "$PHASE_B_SUMMARY" --require-complete --require-finalized
    phase_b_index verify "$PHASE_B_SUMMARY"
    rm "$PHASE_B_SUMMARY"
    run_promote_dry_run
    ;;
esac
