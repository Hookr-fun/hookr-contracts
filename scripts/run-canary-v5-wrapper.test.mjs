import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const wrapper = readFileSync(
  new URL("../contracts/run-canary-v5.sh", import.meta.url),
  "utf8",
);
const runbook = readFileSync(
  new URL("../contracts/RELEASE_V5.md", import.meta.url),
  "utf8",
);
const preflightSource = readFileSync(
  new URL("./verify-deployment-preflight.mjs", import.meta.url),
  "utf8",
);

test("wrapper exact-validates every Phase-A stage before a later signer boundary", () => {
  assert.match(wrapper, /phase_a_stage_semantics\(\)/);
  for (const stage of [
    "instant-launch",
    "instant-buy-auction-launch",
    "hookr-launch",
    "hookr-approve-buy",
  ]) {
    assert.ok(
      wrapper.split(`phase_a_stage_semantics ${stage}`).length >= 3,
      `${stage} lacks boundary + bundle gates`,
    );
  }

  const stage1Gate = wrapper.indexOf(
    'phase_a_stage_semantics instant-launch "$PHASE_A_INSTANT_LAUNCH_ABS"',
    wrapper.indexOf('case "$COMMAND" in'),
  );
  const shorten = wrapper.indexOf(
    'send_timing "$CANARY_AUCTION_DURATION"',
    stage1Gate,
  );
  assert.ok(
    stage1Gate >= 0 && shorten > stage1Gate,
    "instant stage is not exact-validated before shorten",
  );

  const stage23Gate = wrapper.indexOf(
    "phase_a_stage_semantics instant-buy-auction-launch",
    shorten,
  );
  const restore = wrapper.indexOf("send_timing 125000", stage23Gate);
  assert.ok(
    stage23Gate > shorten && restore > stage23Gate,
    "auction launch stage is not exact-validated before restore",
  );

  const ownerBidGate = wrapper.indexOf("phase_a_owner_bid_semantics", restore);
  const hookrLaunchSigner = wrapper.indexOf(
    "forge_phase 'launchHookrPair()'",
    ownerBidGate,
  );
  const hookrLaunchGate = wrapper.indexOf(
    'phase_a_stage_semantics hookr-launch "$PHASE_A_HOOKR_LAUNCH_ABS"',
    hookrLaunchSigner,
  );
  const stage67Signer = wrapper.indexOf(
    "forge_phase 'buyHookrPair()'",
    hookrLaunchGate,
  );
  assert.ok(
    ownerBidGate > restore &&
      hookrLaunchSigner > ownerBidGate &&
      hookrLaunchGate > hookrLaunchSigner &&
      stage67Signer > hookrLaunchGate,
    "HOOKR launch is not exact-validated before its buy",
  );
});

test("live recovery authenticates the raw owner bid and never re-submits or fabricates it", () => {
  assert.match(
    wrapper,
    /OWNER_BID_TRANSACTION_HASH="0x718d6a17d804c80f011814bd90c010257aa4b2edabfb517f91ed0e18e08f5063"/,
  );
  assert.match(wrapper, /OWNER_BID_NONCE=712/);
  assert.match(wrapper, /OWNER_BID_ID=3/);
  assert.match(wrapper, /OWNER_BID_WEI=10500000000000000/);
  assert.match(
    wrapper,
    /OWNER_BID_MAX_PRICE_Q96=814814390533794434497901791991308996217/,
  );
  assert.match(wrapper, /owner_bid_receipt_check\(\)/);
  assert.match(wrapper, /--owner-bid-only/);
  assert.match(
    wrapper,
    /PHASE_A_OWNER_BID_TRANSACTION=.*owner-bid-transaction\.json/,
  );
  assert.match(wrapper, /PHASE_A_OWNER_BID_RECEIPT=.*owner-bid-receipt\.json/);
  assert.match(
    wrapper,
    /PHASE_A_HOOKR_LAUNCH_ARTIFACT=.*launchHookrPair-latest\.json/,
  );
  assert.match(wrapper, /forge_phase 'launchHookrPair\(\)'/);
  assert.doesNotMatch(wrapper, /forge_phase 'bidLaunchHookr\(\)'/);
  assert.doesNotMatch(wrapper, /"auction-bid-hookr-launch"/);
  assert.doesNotMatch(wrapper, /PHASE_A_AUCTION_BID_HOOKR_LAUNCH/);
  assert.match(wrapper, /hookr-launch 1 "\$HOOKR_LAUNCH_NONCE"/);
  assert.match(wrapper, /hookr-approve-buy 2 "\$HOOKR_BUY_NONCE"/);
  assert.match(
    wrapper,
    /OWNER_BID_EXPECTED_NONCE="\$\(next_nonce "\$BASE_NONCE" 5\)"/,
  );
  assert.match(
    wrapper,
    /HOOKR_LAUNCH_NONCE="\$\(next_nonce "\$BASE_NONCE" 6\)"/,
  );
  assert.match(wrapper, /HOOKR_BUY_NONCE="\$\(next_nonce "\$BASE_NONCE" 7\)"/);
});

test("recovery preflight authenticates the exact mined prefix before pinning nonce 713", () => {
  const recoveryStart = wrapper.indexOf("recovery_preflight_check()");
  const recoveryCheck = wrapper.slice(
    recoveryStart,
    wrapper.indexOf('\ncase "$COMMAND" in', recoveryStart),
  );
  const preflightCase = wrapper.slice(
    wrapper.indexOf("  preflight)"),
    wrapper.indexOf("  status)"),
  );
  const mutableCheck = wrapper.slice(
    wrapper.indexOf("recovery_mutable_state_check()"),
    wrapper.indexOf("recovery_preflight_check()"),
  );
  assert.match(recoveryCheck, /BASE_NONCE.*= "707"/s);
  assert.match(recoveryCheck, /instant-launch 1 "\$BASE_NONCE"/);
  assert.match(
    recoveryCheck,
    /instant-buy-auction-launch 2 "\$STAGE_23_NONCE"/,
  );
  assert.match(recoveryCheck, /OWNER_BID_EXPECTED_NONCE=.*next_nonce.*5/s);
  assert.match(recoveryCheck, /authenticated_instant/);
  assert.match(recoveryCheck, /authenticated_auction/);
  assert.match(recoveryCheck, /phase_a_owner_bid_semantics/);
  assert.match(
    recoveryCheck,
    /wait_timing_receipt_finalized "\$SHORTEN_RECEIPT_ABS" "\$SHORTEN_TRANSACTION_ABS"/,
  );
  assert.match(
    recoveryCheck,
    /wait_timing_receipt_finalized "\$RESTORE_RECEIPT_ABS" "\$RESTORE_TRANSACTION_ABS"/,
  );
  assert.doesNotMatch(
    recoveryCheck,
    /wait_receipts_finalized "\$(?:SHORTEN|RESTORE)_RECEIPT_ABS"/,
  );
  const timingWait = wrapper.slice(
    wrapper.indexOf("wait_timing_receipt_finalized()"),
    wrapper.indexOf("wait_owner_bid_finalized()"),
  );
  assert.equal((timingWait.match(/timing_receipt_check/g) || []).length, 3);
  assert.equal(
    (recoveryCheck.match(/recovery_mutable_state_check/g) || []).length,
    2,
  );
  assert.match(mutableCheck, /authenticated_auction/);
  assert.match(
    mutableCheck,
    /same_hex "\$current_token" "\$CANARY_AUCTION_TOKEN"/,
  );
  assert.match(mutableCheck, /same_hex "\$current_auction" "\$CANARY_AUCTION"/);
  assert.match(mutableCheck, /"\$current_end" = "\$AUCTION_END"/);
  assert.match(mutableCheck, /require_timing "125000 0 1"/);
  assert.match(mutableCheck, /require_sender_nonce 713/);
  assert.match(recoveryCheck, /bidLaunchHookr-latest\.json/);
  for (const path of [
    "PHASE_A_HOOKR_LAUNCH_ABS",
    "PHASE_A_HOOKR_APPROVE_BUY_ABS",
    "PHASE_A_INDEX_ABS",
  ]) {
    assert.match(recoveryCheck, new RegExp(`\\$${path}`));
  }
  const recoveryIndex = preflightCase.indexOf("recovery_preflight_check");
  const verifierIndex = preflightCase.indexOf(
    "verify-deployment-preflight.mjs",
  );
  const finalMutableIndex = preflightCase.indexOf(
    "recovery_mutable_state_check",
    verifierIndex,
  );
  const writeIndex = preflightCase.indexOf("write_authenticated_state");
  assert.ok(
    recoveryIndex >= 0 &&
      verifierIndex > recoveryIndex &&
      finalMutableIndex > verifierIndex &&
      writeIndex > finalMutableIndex,
  );
  assert.match(preflightCase, /--canary-recovery/);
  assert.match(
    preflightCase,
    /--recovery-instant-token "\$CANARY_INSTANT_TOKEN"/,
  );
  assert.match(
    preflightCase,
    /--recovery-auction-token "\$CANARY_AUCTION_TOKEN"/,
  );
  assert.match(preflightCase, /--recovery-auction "\$CANARY_AUCTION"/);
  assert.match(preflightCase, /--forbid-legacy-artifact/);
});

test("recovery state tolerates only permissionless upward drift and rejects lost baselines", () => {
  assert.match(
    preflightSource,
    /stateEvidenceTag = REHEARSAL \|\| CANARY_RECOVERY \? "latest" : "safe"/,
  );
  assert.match(preflightSource, /if \(tokenCount < 2n\)\s+fail/);
  assert.match(
    preflightSource,
    /if \(protocolFeesWei < RECOVERY_PROTOCOL_FEES_WEI\)/,
  );
  assert.doesNotMatch(
    preflightSource,
    /protocolFeesWei\s*!==\s*RECOVERY_PROTOCOL_FEES_WEI/,
  );
  assert.match(
    preflightSource,
    /claimableToBurner \+ burnerNativeBalance\s*<\s*RECOVERY_MIN_FLYWHEEL_CLAIMABLE_WEI/,
  );
  assert.match(
    preflightSource,
    /BigInt\(latestClaimable\) \+ latestBurnerBalance\s*<\s*RECOVERY_MIN_FLYWHEEL_CLAIMABLE_WEI/,
  );
  assert.match(preflightSource, /tokenCount !== 0n/);
  assert.match(preflightSource, /protocolFeesWei !== 0n/);
  assert.match(preflightSource, /allTokens", \[0n\]/);
  assert.match(preflightSource, /allTokens", \[1n\]/);
  assert.match(preflightSource, /INTENT_HOOKR/);
  assert.match(
    preflightSource,
    /assertLaunch\(\s*auctionLaunch,\s*expectedAuctionToken,\s*1,\s*\[0, 1\],\s*expectedAuction/,
  );
  assert.match(preflightSource, /RECOVERY_SENDER_NONCE = 713n/);
  assert.match(preflightSource, /latestSpent.*latestBurned/s);
});

test("wrapper protects RPC stderr and refuses terminal suspension during Phase A", () => {
  assert.match(wrapper, /RPC_STDERR_REDACTOR=.*redact-rpc-stream\.mjs/);
  assert.match(
    wrapper,
    /export ETH_RPC_URL="\$RPC"\nexport FOUNDRY_ETH_RPC_URL="\$RPC"/,
  );
  assert.match(
    runbook,
    /export HOOKR_RPC_URL="\$ALCHEMY_RPC_URL"\nexport ETH_RPC_URL="\$HOOKR_RPC_URL"\nexport FOUNDRY_ETH_RPC_URL="\$HOOKR_RPC_URL"/,
  );
  assert.doesNotMatch(wrapper, /env "\$\{env_args\[@\]\}" forge script/);
  assert.match(
    wrapper,
    /export "\$\{env_args\[@\]\}"[\s\S]*?forge script script\/CanaryRobinhoodV5\.s\.sol/,
  );
  assert.match(
    wrapper,
    /cast\(\) \{ command cast "\$@" 2> >\(node "\$RPC_STDERR_REDACTOR" >&2\); \}/,
  );
  assert.match(
    wrapper,
    /forge\(\) \{ command forge "\$@" 2> >\(node "\$RPC_STDERR_REDACTOR" >&2\); \}/,
  );
  const forgePhase = wrapper.slice(
    wrapper.indexOf("forge_phase()"),
    wrapper.indexOf("record_phase_a_abandonment()"),
  );
  assert.doesNotMatch(forgePhase, /--rpc-url/);
  assert.match(
    runbook,
    /Foundry 1\.5\.1 does not resolve `forge script` from `ETH_RPC_URL`/,
  );
  assert.doesNotMatch(wrapper, /RPC authenticated: host/);
  assert.match(wrapper, /trap '' TSTP/);
  assert.doesNotMatch(wrapper, /phase_a_signal_guard TSTP/);
  assert.match(runbook, /wrapper ignores `TSTP`/);
});

test("raw Forge gas may be omitted but is exact when present", () => {
  const forgeVerifier = wrapper.indexOf("verify_live_forge_artifact()");
  const helperStart = wrapper.indexOf("const sameInt =", forgeVerifier);
  const helperEnd = wrapper.indexOf("const receipts =", helperStart);
  assert.ok(helperStart >= 0 && helperEnd > helperStart);
  const helpers = wrapper.slice(helperStart, helperEnd);
  const validateGas = new Function(
    "raw",
    "live",
    "hasRawGas",
    "isFixedGasLimit",
    `
    const path = "fixture";
    const fail = (message) => { throw new Error(\`\${path}: \${message}\`); };
    ${helpers}
    sameForgeGas(hasRawGas, raw, live, isFixedGasLimit, "transaction gas");
  `,
  );
  assert.doesNotThrow(() => validateGas(undefined, "0x5208", false, false));
  assert.throws(
    () => validateGas(undefined, "0x5208", false, true),
    /explicit non-fixed gas policy/,
  );
  assert.throws(
    () => validateGas(undefined, "0x5208", false, undefined),
    /explicit non-fixed gas policy/,
  );
  assert.throws(
    () => validateGas(null, "0", true, false),
    /transaction gas is not numeric/,
  );
  assert.throws(
    () => validateGas(undefined, "0", true, false),
    /transaction gas is not numeric/,
  );
  assert.doesNotThrow(() => validateGas("0x5208", "21000", true, false));
  assert.throws(
    () => validateGas("0x5209", "0x5208", true, false),
    /transaction gas differs from live RPC/,
  );

  const txCheck = wrapper.slice(
    wrapper.indexOf("for (const [index, item] of d.transactions.entries())"),
    wrapper.indexOf("const rawReceipt =", helperEnd),
  );
  assert.match(txCheck, /for \(const field of \["nonce", "chainId"\]\)/);
  assert.match(txCheck, /sameInt\(rawTx\[field\], liveTx\[field\]/);
  assert.match(
    txCheck,
    /Object\.hasOwn\(rawTx, "gas"\), rawTx\.gas, liveTx\.gas, item\.isFixedGasLimit/,
  );
});

test("wrapper takes an exclusive operator lock before cleaning any sensitive Forge cache", () => {
  const lock = wrapper.indexOf('if ! mkdir "$OPERATOR_LOCK"');
  const cleanup = wrapper.indexOf(
    'for stale_canary_cache in "$CANARY_DIR"/.sensitive-cache.*',
  );
  assert.ok(lock >= 0 && cleanup > lock);
  assert.match(wrapper, /trap release_operator_lock EXIT/);
  assert.match(wrapper, /phase_a_exit_guard\(\)[\s\S]*?release_operator_lock/);
  assert.match(wrapper, /Do not remove it while that process may be active/);
});

test("guard finality budget is checked before each finalized launch that feeds a guarded buy", () => {
  assert.match(wrapper, /CANARY_GUARD_BLOCKS=20000/);
  assert.match(wrapper, /require_guard_finality_budget\(\)/);
  assert.ok(wrapper.split("require_guard_finality_budget").length >= 4);
  assert.ok(wrapper.split("require_guard_headroom").length >= 4);
  assert.match(
    runbook,
    /old 200-block guard could not truthfully exercise the snipe-tax path/,
  );
});

test("wrapper keeps Hook guard and auction CCA clocks separate", () => {
  const phaseB = wrapper.slice(
    wrapper.indexOf("  phase-b)"),
    wrapper.indexOf("  restore)"),
  );
  const auctionClock = wrapper.slice(
    wrapper.indexOf("current_auction_block()"),
    wrapper.indexOf("require_guard_finality_budget()"),
  );
  assert.match(auctionClock, /rpc_block="\$\(cast block-number\)"/);
  assert.match(
    auctionClock,
    /cast code "\$ARBSYS" --block "\$rpc_block" \| cast keccak/,
  );
  assert.match(
    auctionClock,
    /read_call "\$ARBSYS" 'arbBlockNumber\(\)\(uint256\)' --block "\$rpc_block"/,
  );
  assert.match(auctionClock, /\[ "\$rpc_block" = "\$arbsys_block" \]/);
  assert.equal([...wrapper.matchAll(/\$\(current_auction_block\)/g)].length, 1);
  assert.match(phaseB, /CURRENT_BLOCK="\$\(current_auction_block\)"/);
  assert.doesNotMatch(phaseB, /current_contract_block/);
  assert.equal(
    [...wrapper.matchAll(/\$\(current_contract_block\)/g)].length,
    1,
  );
  assert.match(runbook, /Solidity `block\.number` used by Hook guard windows/);
  assert.match(
    runbook,
    /`eth_blockNumber` must exactly equal the authenticated ArbSys `arbBlockNumber\(\)`/,
  );
  assert.match(runbook, /--slots-in-an-epoch 0/);
  assert.match(
    runbook,
    /: "\$\{REHEARSAL_PORT:\?set REHEARSAL_PORT to a free loopback port\}"/,
  );
  assert.match(runbook, /--fork-block-number "\$FRESH_BASE"/);
  assert.match(runbook, /--prune-history --silent/);
  assert.match(
    runbook,
    /Compile and copy the authenticated deployment inputs before starting the fork/,
  );
  assert.match(
    runbook,
    /Do not combine this rehearsal with `--max-persisted-states`/,
  );
  assert.match(runbook, /`--transaction-block-keeper`/);
  assert.match(runbook, /`--preserve-historical-states`/);
  assert.match(
    runbook,
    /do not pause\s+for manual work after starting the public fork/,
  );
});

test("out-of-band restore either preserves exact N+4 or records abandonment", () => {
  assert.match(wrapper, /record_phase_a_abandonment\(\)/);
  assert.match(wrapper, /PLANNED_RESTORE=0/);
  assert.match(wrapper, /RESTORE_NONCE="\$\(next_nonce "\$BASE_NONCE" 4\)"/);
  assert.match(
    wrapper,
    /out-of-band restore could not occupy the reviewed N\+4 chronology/,
  );
  assert.match(wrapper, /this Phase-A chronology is abandoned/);
});

test("runbook explicitly changes from immutable deployment evidence to the operator worktree", () => {
  assert.match(
    runbook,
    /deployment-worktree path above is historical immutable evidence only/,
  );
  assert.match(runbook, /v5-canary-arbsys-recovery\/hookr/);
  assert.match(runbook, /CANARY_OPERATOR_COMMIT="\$\(git rev-parse HEAD\)"/);
  assert.match(
    runbook,
    /test "\$CANARY_OPERATOR_COMMIT" != "b1ccb017f86d9caffff8bf4277a735d714130972"/,
  );
});

test("descendant Phase-B tooling preserves the indexed Phase-A recovery commit", () => {
  const authenticateRecovery = wrapper.slice(
    wrapper.indexOf("authenticate_phase_a_recovery_commit()"),
    wrapper.indexOf("raw_phase_artifact_check()"),
  );
  const loadState = wrapper.slice(
    wrapper.indexOf("load_authenticated_state()"),
    wrapper.indexOf("block_hash()"),
  );
  const verifyBundle = wrapper.slice(
    wrapper.indexOf("verify_phase_a_bundle()"),
    wrapper.indexOf("recovery_mutable_state_check()"),
  );
  const status = wrapper.slice(
    wrapper.indexOf("show_status()"),
    wrapper.indexOf("send_timing()"),
  );

  assert.match(authenticateRecovery, /hookr-v5-phase-a-evidence-v3/);
  assert.match(authenticateRecovery, /d\.canaryRecoveryCommit/);
  assert.match(
    authenticateRecovery,
    /d\.deploymentSourceCommit !== deploymentSourceCommit/,
  );
  assert.match(
    authenticateRecovery,
    /d\.originalCanaryOperatorCommit !== originalCanaryOperatorCommit/,
  );
  assert.match(
    authenticateRecovery,
    /merge-base --is-ancestor \\\n+    "\$resolved_commit" "\$CANARY_OPERATOR_COMMIT"/,
  );
  assert.match(
    authenticateRecovery,
    /"\$STATE_OPERATOR_COMMIT" = "\$resolved_commit"/,
  );
  assert.match(authenticateRecovery, /recovery_deployed_diff/);
  assert.match(authenticateRecovery, /tooling_canary_diff/);
  assert.match(
    authenticateRecovery,
    /"\$resolved_commit" "\$CANARY_OPERATOR_COMMIT" -- \\\n+    contracts\/script\/CanaryRobinhoodV5\.s\.sol/,
  );
  assert.match(authenticateRecovery, /tooling_deployed_diff/);
  assert.match(
    authenticateRecovery,
    /PHASE_A_RECOVERY_COMMIT="\$resolved_commit"/,
  );

  assert.match(
    loadState,
    /merge-base --is-ancestor \\\n+    "\$STATE_OPERATOR_COMMIT" "\$CANARY_OPERATOR_COMMIT"/,
  );
  assert.match(loadState, /STATE_DEPLOYED_SOURCE_DIFF/);
  assert.match(loadState, /TOOLING_DEPLOYED_SOURCE_DIFF/);
  assert.doesNotMatch(
    loadState,
    /"\$STATE_OPERATOR_COMMIT" = "\$CANARY_OPERATOR_COMMIT"/,
  );

  assert.ok(
    verifyBundle.indexOf("authenticate_phase_a_recovery_commit") >= 0 &&
      verifyBundle.indexOf("authenticate_phase_a_recovery_commit") <
        verifyBundle.indexOf("raw_phase_artifact_check"),
  );
  assert.equal(
    (
      wrapper.match(
        /\$\{PHASE_A_RECOVERY_COMMIT:-\$CANARY_OPERATOR_COMMIT\}/g,
      ) || []
    ).length,
    3,
  );
  assert.match(status, /target operator   \$STATE_OPERATOR_COMMIT/);
  assert.match(status, /current tooling   \$CANARY_OPERATOR_COMMIT/);
  assert.match(wrapper, /"\$CANARY_OPERATOR_COMMIT" <<'NODE'/);
  assert.match(wrapper, /--source-commit "\$PHASE_A_RECOVERY_COMMIT"/);
  assert.doesNotMatch(wrapper, /--source-commit "\$CANARY_OPERATOR_COMMIT"/);
  assert.match(
    runbook,
    /canaryRecoveryCommit = cfb571c16a24842738f9c39ecf4c2ce00f6c05d4/,
  );
  assert.match(
    runbook,
    /Do not edit the index or\s+relabel its Forge artifacts/,
  );
  assert.match(
    runbook,
    /signing plan records the current descendant tooling HEAD,\s+while the Phase-B index's existing `sourceCommit` field remains the authenticated immutable canary\s+source/,
  );
});

test("Phase B reconciles permissionless canonical outcomes and never uses the unsafe settle artifact", () => {
  const phaseB = wrapper.slice(
    wrapper.indexOf("  phase-b)"),
    wrapper.indexOf("  restore)"),
  );
  const phaseBSend = wrapper.slice(
    wrapper.indexOf("phase_b_send_action()"),
    wrapper.indexOf("wait_phase_b_action_finalized()"),
  );
  assert.match(wrapper, /collect-v5-phase-b-evidence\.mjs/);
  assert.match(wrapper, /build-v5-phase-b-evidence\.mjs/);
  assert.match(
    wrapper,
    /for PHASE_B_ACTION in \\\n+      migrateAuction exitBid claimTokens claimAuctionProceeds collect buybackAndBurn/,
  );
  assert.match(wrapper, /phase_b_reconcile_action "\$PHASE_B_ACTION"/);
  assert.match(
    wrapper,
    /phase_b_collect "\$PHASE_B_SUMMARY" --require-complete --require-finalized/,
  );
  assert.match(wrapper, /run_promote_dry_run/);
  assert.match(wrapper, /--canary-phase-b-index "\$PHASE_B_INDEX_ABS"/);
  assert.doesNotMatch(wrapper, /forge_phase 'settle\(\)'/);
  assert.doesNotMatch(wrapper, /settle-latest\.json/);
  assert.doesNotMatch(wrapper, /--canary-settle/);
  assert.match(wrapper, /hookr-v5-phase-b-signing-plan-v1/);
  assert.match(
    wrapper,
    /latest nonce \$latest differs from pending nonce \$pending/,
  );
  assert.match(wrapper, /require_sender_nonce "\$expected_nonce"/);
  assert.match(wrapper, /--nonce "\$expected_nonce" --confirmations 1 --json/);
  assert.equal(
    [
      ...phaseBSend.matchAll(
        /--nonce "\$expected_nonce" --confirmations 1 --json/g,
      ),
    ].length,
    6,
  );
  assert.match(
    wrapper,
    /existing signing-journal evidence.*reconcile that exact nonce\/transaction/,
  );
  assert.match(wrapper, /signing plan remains.*blocks every retry/);
  assert.match(wrapper, /phase_b_migrate_journal_hash\(\)/);
  assert.match(wrapper, /migration signing journal is partial/);
  assert.match(wrapper, /migrate-auction\.plan\.json/);
  assert.match(wrapper, /migrate-auction\.transaction\.json/);
  assert.match(wrapper, /migrate-auction\.receipt\.json/);
  assert.match(wrapper, /cast tx "\$hash" --json/);
  assert.match(wrapper, /cast receipt "\$hash" --json/);
  assert.match(wrapper, /verify_live_receipts "\$receipt"/);
  assert.match(
    wrapper,
    /collector did not select the exact live migration journal transaction .*stop without resubmitting/,
  );
  assert.doesNotMatch(
    wrapper,
    /rm .*migrate-auction\.(plan|transaction|receipt)\.json/,
  );
  assert.match(wrapper, /wait_phase_b_action_finalized\(\)/);
  assert.match(wrapper, /disappeared from the canonical scan before finality/);
  assert.match(
    wrapper,
    /did not finalize within \$\{FINALITY_WAIT_MAX_SECONDS\}s; stop without resubmitting/,
  );
  assert.equal(
    [
      ...phaseBSend.matchAll(
        /cast calldata 'buybackAndBurn\(uint256,uint256\)' 3000000000000 3000000000000000000/g,
      ),
    ].length,
    1,
  );
  assert.equal(
    [
      ...phaseBSend.matchAll(
        /'buybackAndBurn\(uint256,uint256\)\(uint256\)' 3000000000000 3000000000000000000/g,
      ),
    ].length,
    1,
  );
  assert.equal(
    [
      ...phaseBSend.matchAll(
        /cast send "\$BURNER" 'buybackAndBurn\(uint256,uint256\)' 3000000000000 3000000000000000000/g,
      ),
    ].length,
    1,
  );
  assert.doesNotMatch(phaseBSend, /4000000000000000000/);
  assert.match(phaseBSend, /cast call --from "\$SENDER" "\$BURNER"/);
  assert.match(phaseBSend, /if \(!\/\^\[0-9\]\+\$\/\.test\(raw\)\)/);
  assert.match(phaseBSend, /BigInt\(raw\) < 3_000_000_000_000_000_000n/);
  assert.match(phaseBSend, /no signing journal was written/);
  assert.match(wrapper, /phase_b_claim_proceeds_gate\(\)/);
  assert.match(wrapper, /not-applicable-zero-proceeds/);
  assert.match(
    wrapper,
    /zero-proceeds no-op does not alias the exact canonical migration receipt/,
  );
  assert.match(
    wrapper,
    /collector did not provide the explicit not-applicable-zero-proceeds proof; refusing a claim that would revert/,
  );
  assert.match(wrapper, /direct\|helper/);
  assert.match(
    wrapper,
    /claimAuctionProceeds is explicitly not applicable: canonical migration proved zero proceeds; no claim transaction will be signed/,
  );
  assert.match(
    wrapper,
    /five transactions when zero proceeds aliases migration/,
  );
  assert.match(runbook, /3 HOOKR minimum output/);
  assert.match(
    runbook,
    /read-only live `eth_call` from the exact release owner/,
  );
  assert.match(
    runbook,
    /below-floor simulation stops before any signing journal/,
  );
  const buybackSimulation = wrapper.indexOf(
    'cast call --from "$SENDER" "$BURNER"',
  );
  const journalWrite = wrapper.indexOf(
    'kind: "hookr-v5-phase-b-signing-plan-v1"',
  );
  const firstSend = wrapper.indexOf(
    "cast send \"$PAD\" 'migrateAuction(address)'",
    journalWrite,
  );
  assert.ok(
    buybackSimulation >= 0 &&
      journalWrite > buybackSimulation &&
      firstSend > journalWrite,
  );
  assert.match(phaseB, /phase_b_reconcile_action "\$PHASE_B_ACTION"/);
});

test("Phase B parses extensionless collector summaries as JSON data", () => {
  const phaseBIndex = wrapper.slice(
    wrapper.indexOf("phase_b_index()"),
    wrapper.indexOf("run_promote_dry_run()"),
  );
  assert.match(
    phaseBIndex,
    /JSON\.parse\(fs\.readFileSync\(process\.argv\[2\], "utf8"\)\)/,
  );
  assert.doesNotMatch(phaseBIndex, /require\(process\.argv\[2\]\)/);
});
