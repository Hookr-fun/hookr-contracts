import { encodeAbiParameters, keccak256 } from "viem";

export const INSTANT_CANARY_SPEC = Object.freeze({
  intentId: "0xaeff879d7bb7c1ca78eba49ba3936b2845bb1d9bc90e44743b3c4ae5f1310e26",
  name: "Hookr Instant Five-Block Canary",
  symbol: "HICAN",
  tagline: "release proof: instant pool and all five Hookr blocks",
  depositWei: 10_000_000_000_000_000n,
  creationFeeWei: 200_000_000_000_000n,
  poolSupplyBps: 5_000,
  poolTokens: 500_000_000n * 10n ** 18n,
  openPriceWei: 20_000_000n,
  openFdvWei: 20_000_000_000_000_000n,
  buyWei: 1_000_000_000_000_000n,
  buyMinTokensOut: 20_000_000n * 10n ** 18n,
  sellMinWeiOut: 2_000_000_000_000n,
  minSqrtPriceLimitX96: 4_295_128_740n,
  maxSqrtPriceLimitX96: 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341n,
  dynamicFee: 0x800000,
  tickSpacing: 60,
  hookParams: Object.freeze({
    // Long enough to recover the separately-mined buy after an operational interruption without
    // weakening the proof that it actually executed inside the anti-snipe window.
    guardBlocks: 200,
    maxBuyBps: 1_000,
    snipeTaxPips: 200_000,
    baseFeePips: 3_000,
    maxFeePips: 30_000,
    surgeSens: 5,
    burnBps: 100,
    burnTriggerWei: 0n,
    lpBps: 25,
    potBps: 50,
    potEveryNBuys: 10,
    potMinBuyWei: 1_000_000_000_000_000n,
  }),
});

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const DEAD = "0x000000000000000000000000000000000000dead";
const PIPS = 1_000_000n;
const MAX_PROTOCOL_FEE_PIPS = 1_000n;

const sameHex = (a, b) =>
  typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

const check = (condition, message) => {
  if (!condition) throw new Error(message);
};

const asBigInt = (value) => BigInt(value);

/** Strictly order mined transactions by (block number, transaction index), never by artifact order. */
export function assertStrictReceiptOrder(records) {
  check(Array.isArray(records) && records.length > 0, "receipt evidence is empty");
  const hashes = new Set();
  for (let i = 0; i < records.length; i += 1) {
    const current = records[i];
    check(current?.label && current?.hash, `receipt #${i} is malformed`);
    const hash = String(current.hash).toLowerCase();
    check(!hashes.has(hash), `receipt order contains duplicate hash ${current.hash}`);
    hashes.add(hash);
    if (i === 0) continue;
    const previous = records[i - 1];
    const later =
      asBigInt(current.blockNumber) > asBigInt(previous.blockNumber) ||
      (asBigInt(current.blockNumber) === asBigInt(previous.blockNumber) &&
        Number(current.transactionIndex) > Number(previous.transactionIndex));
    check(later, `${current.label} was not mined strictly after ${previous.label}`);
  }
}

/** `PoolIdLibrary.toId`: keccak256(abi.encode(PoolKey)). */
export function poolIdForKey(key) {
  return keccak256(
    encodeAbiParameters(
      [
        {
          name: "key",
          type: "tuple",
          components: [
            { name: "currency0", type: "address" },
            { name: "currency1", type: "address" },
            { name: "fee", type: "uint24" },
            { name: "tickSpacing", type: "int24" },
            { name: "hooks", type: "address" },
          ],
        },
      ],
      [key],
    ),
  );
}

const checkPoolKey = (key, evidence, label) => {
  check(sameHex(key.currency0, ZERO_ADDRESS), `${label} currency0 is not native`);
  check(sameHex(key.currency1, evidence.launch.event.token), `${label} token does not match instant launch`);
  check(Number(key.fee) === INSTANT_CANARY_SPEC.dynamicFee, `${label} fee is not dynamic`);
  check(Number(key.tickSpacing) === INSTANT_CANARY_SPEC.tickSpacing, `${label} tick spacing is wrong`);
  check(sameHex(key.hooks, evidence.identities.hook), `${label} hook does not match the release`);
  check(sameHex(poolIdForKey(key), evidence.launch.event.poolId), `${label} pool key does not match instant pool id`);
};

const checkSwapEvent = (event, calldata, evidence, label) => {
  check(sameHex(event.payer, evidence.identities.deployer), `${label} event payer is wrong`);
  check(sameHex(event.recipient, evidence.identities.deployer), `${label} event recipient is wrong`);
  check(sameHex(event.token, evidence.launch.event.token), `${label} event token does not match instant token`);
  check(event.zeroForOne === calldata.zeroForOne, `${label} event direction does not match calldata`);
  check(event.exactInput === true, `${label} event is not exact input`);
  check(asBigInt(event.amountIn) === asBigInt(calldata.amountIn), `${label} event input does not match calldata`);
  check(asBigInt(event.amountOut) >= asBigInt(calldata.amountOutMinimum), `${label} output missed its bound`);
};

/**
 * Validate the decoded, pinned evidence for one production instant canary. This routine is pure so
 * malformed hand-built artifacts can be covered with negative fixtures without an RPC.
 */
export function validateInstantCanaryEvidence(evidence) {
  const spec = INSTANT_CANARY_SPEC;
  assertStrictReceiptOrder(evidence.receiptOrder);

  const { deployer, launchpad, router, poolManager } = evidence.identities;
  const { launch, buy, approval, sell, postconditions } = evidence;
  for (const [label, tx, target] of [
    ["instant launch", launch.transaction, launchpad],
    ["router buy", buy.transaction, router],
    ["token approval", approval.transaction, launch.event.token],
    ["router sell", sell.transaction, router],
  ]) {
    check(sameHex(tx.from, deployer), `${label} sender is not the release deployer`);
    check(sameHex(tx.to, target), `${label} target is wrong`);
  }

  const args = launch.calldata.args;
  check(args.name === spec.name, "instant launch name is wrong");
  check(args.symbol === spec.symbol, "instant launch symbol is wrong");
  check(args.tagline === spec.tagline, "instant launch tagline is wrong");
  check(args.logoURI === "", "instant launch logo must be empty");
  check(sameHex(args.expectedCreator, deployer), "instant launch expected creator is wrong");
  check(asBigInt(args.targetRaiseWei) === 0n, "instant launch targetRaiseWei is not zero");
  check(Number(args.blueprintId) === 0, "instant launch is not the custom all-five stack");
  check(asBigInt(args.creatorBuyWei) === spec.depositWei, "instant launch deposit is not 0.01 ETH");
  check(asBigInt(args.minTokensOut) === 0n, "instant launch minTokensOut is not zero");
  check(Number(args.creatorFeeBps) === 0, "instant launch creator fee override is nonzero");
  check(args.feeRecipients.length === 0, "instant launch has unexpected fee recipients");
  check(args.lpTranches.length === 0, "instant launch has unexpected LP tranches");
  check(Number(launch.calldata.poolSupplyBps) === spec.poolSupplyBps, "instant launch pool supply is not 5000 bps");
  check(sameHex(launch.calldata.intentId, spec.intentId), "instant launch intent is wrong");
  check(asBigInt(launch.transaction.value) === spec.creationFeeWei + spec.depositWei, "instant launch value is wrong");

  for (const [field, expected] of Object.entries(spec.hookParams)) {
    const actual = args.custom[field];
    check(asBigInt(actual) === asBigInt(expected), `instant launch hook parameter ${field} is wrong`);
  }

  check(!sameHex(launch.event.token, ZERO_ADDRESS), "instant launch event token is zero");
  check(!sameHex(launch.event.poolId, `0x${"00".repeat(32)}`), "instant launch event pool id is zero");
  check(Number(launch.event.poolSupplyBps) === spec.poolSupplyBps, "instant launch event pool supply is wrong");
  check(asBigInt(launch.event.openPriceWei) === spec.openPriceWei, "instant launch event price is wrong");
  check(asBigInt(launch.event.ethInPool) > 0n, "instant launch event has no ETH liquidity");
  check(asBigInt(launch.event.ethInPool) <= spec.depositWei, "instant launch event exceeds the deposit");
  check(
    spec.depositWei - asBigInt(launch.event.ethInPool) <= spec.depositWei / 1_000_000n,
    "instant launch event ETH differs materially from the deposit",
  );
  check(sameHex(launch.tokenEvent.token, launch.event.token), "TokenLaunched names a different token");
  check(sameHex(launch.tokenEvent.creator, deployer), "TokenLaunched creator is wrong");
  check(Number(launch.tokenEvent.blueprintId) === 0, "TokenLaunched blueprint is not custom");
  check(launch.tokenEvent.name === spec.name && launch.tokenEvent.symbol === spec.symbol, "TokenLaunched metadata is wrong");
  check(launch.tokenEvent.tagline === spec.tagline && launch.tokenEvent.logoURI === "", "TokenLaunched presentation is wrong");
  check(asBigInt(launch.tokenEvent.targetWei) === spec.depositWei, "TokenLaunched target does not equal the deposit");
  check(asBigInt(launch.tokenEvent.basePriceWei) === spec.openPriceWei, "TokenLaunched opening price is wrong");
  check(sameHex(launch.graduatedEvent.token, launch.event.token), "Graduated names a different token");
  check(sameHex(launch.graduatedEvent.poolId, launch.event.poolId), "Graduated names a different pool");
  check(asBigInt(launch.graduatedEvent.ethLiquidity) === asBigInt(launch.event.ethInPool), "Graduated ETH differs from InstantLaunched");
  check(asBigInt(launch.graduatedEvent.tokenLiquidity) > 0n, "Graduated has no token liquidity");
  check(asBigInt(launch.graduatedEvent.tokenLiquidity) <= spec.poolTokens, "Graduated token liquidity exceeds the chosen float");
  check(asBigInt(launch.graduatedEvent.tokensBurned) > 0n, "Graduated burned no unused supply");
  check(sameHex(launch.intentEvent.creator, deployer), "LaunchIntentConsumed creator is wrong");
  check(sameHex(launch.intentEvent.intentId, spec.intentId), "LaunchIntentConsumed intent is wrong");
  check(sameHex(launch.intentEvent.token, launch.event.token), "LaunchIntentConsumed names a different token");

  checkPoolKey(buy.calldata.key, evidence, "router buy");
  check(buy.calldata.zeroForOne === true, "router buy direction is wrong");
  check(asBigInt(buy.calldata.amountIn) === spec.buyWei, "router buy input is wrong");
  check(asBigInt(buy.transaction.value) === spec.buyWei, "router buy native value is wrong");
  check(asBigInt(buy.calldata.amountOutMinimum) === spec.buyMinTokensOut, "router buy bound is wrong");
  check(asBigInt(buy.calldata.sqrtPriceLimitX96) === spec.minSqrtPriceLimitX96, "router buy price limit is wrong");
  check(sameHex(buy.calldata.recipient, deployer), "router buy recipient is wrong");
  check(asBigInt(buy.calldata.deadline) > 0n, "router buy deadline is missing");
  checkSwapEvent(buy.event, buy.calldata, evidence, "router buy");

  // Permissionless activity after the canary may legitimately change every cumulative hook
  // ledger. Bind the five-block proof to logs emitted by this exact buy receipt, then treat pinned
  // cumulative state only as monotonic backing evidence.
  const poolSwap = buy.poolManagerEvent;
  check(poolSwap && typeof poolSwap === "object", "canary buy has no PoolManager Swap evidence");
  check(sameHex(poolSwap.id, launch.event.poolId), "canary buy PoolManager event names the wrong pool");
  check(sameHex(poolSwap.sender, router), "canary buy PoolManager event sender is not the router");
  check(asBigInt(poolSwap.sqrtPriceX96) > 0n, "canary buy PoolManager event has no price");
  check(asBigInt(poolSwap.liquidity) > 0n, "canary buy PoolManager event has no liquidity");
  const scopedFeePips = asBigInt(poolSwap.fee);
  const combinedFeePips = (protocolFeePips, lpFeePips) =>
    protocolFeePips + lpFeePips - (protocolFeePips * lpFeePips) / PIPS;
  const noSurgeLpFeePips = BigInt(
    spec.hookParams.baseFeePips + spec.hookParams.snipeTaxPips,
  );
  // PoolManager's Swap event emits the combined protocol + LP fee. The controller may set up to
  // 1000 protocol pips, so prove surge only above the largest combined fee that no-surge LP config
  // could emit; comparing directly with the LP rate would misclassify protocol fee as surge.
  const maximumNoSurgeCombinedFeePips = combinedFeePips(
    MAX_PROTOCOL_FEE_PIPS,
    noSurgeLpFeePips,
  );
  check(
    scopedFeePips > maximumNoSurgeCombinedFeePips,
    "canary buy receipt did not prove a surge fee",
  );
  const maximumLpFeePips = BigInt(
    spec.hookParams.maxFeePips + spec.hookParams.snipeTaxPips,
  );
  check(
    scopedFeePips <= combinedFeePips(MAX_PROTOCOL_FEE_PIPS, maximumLpFeePips),
    "canary buy receipt fee exceeds the configured maximum",
  );

  const fees = buy.hookEvents?.feesAccrued;
  const donation = buy.hookEvents?.lpDonation;
  const burn = buy.hookEvents?.autoBurn;
  for (const [label, event] of [
    ["HookFeesAccrued", fees],
    ["LpRewardsDonated", donation],
    ["AutoBurn", burn],
  ]) {
    check(event && sameHex(event.poolId, launch.event.poolId), `${label} names the wrong canary pool`);
  }
  const totalCutBps = BigInt(spec.hookParams.lpBps + spec.hookParams.potBps);
  const expectedHookFeeWei = (spec.buyWei * totalCutBps) / 10_000n;
  const expectedLpDonationWei =
    (expectedHookFeeWei * BigInt(spec.hookParams.lpBps)) / totalCutBps;
  const expectedPotAddedWei = expectedHookFeeWei - expectedLpDonationWei;
  check(asBigInt(fees.burnWei) === 0n, "canary buy accrued a legacy burn cut");
  check(asBigInt(fees.lpWei) === expectedLpDonationWei, "canary buy LP cut is wrong");
  check(asBigInt(fees.potWeiAdded) === expectedPotAddedWei, "canary buy pot cut is wrong");
  check(asBigInt(fees.royaltyWei) === 0n, "custom canary accrued a royalty");
  check(sameHex(fees.royaltyTo, ZERO_ADDRESS), "custom canary named a royalty recipient");
  check(asBigInt(donation.amountWei) === expectedLpDonationWei, "canary buy LP donation event is wrong");
  check(asBigInt(burn.tokensBurned) > 0n, "canary buy AutoBurn event is empty");

  check(sameHex(approval.calldata.spender, router), "approval spender is not the release router");
  check(asBigInt(approval.calldata.amount) > 0n, "approval amount is zero");
  check(asBigInt(approval.transaction.value) === 0n, "approval sent native value");
  check(sameHex(approval.event.owner, deployer), "approval event owner is wrong");
  check(sameHex(approval.event.spender, router), "approval event spender is wrong");
  check(asBigInt(approval.event.value) === asBigInt(approval.calldata.amount), "approval event amount is wrong");

  checkPoolKey(sell.calldata.key, evidence, "router sell");
  check(sell.calldata.zeroForOne === false, "router sell direction is wrong");
  check(asBigInt(sell.transaction.value) === 0n, "router sell sent native value");
  check(asBigInt(sell.calldata.amountIn) === asBigInt(approval.calldata.amount), "sell does not consume the approved slice");
  check(asBigInt(sell.calldata.amountOutMinimum) === spec.sellMinWeiOut, "router sell bound is wrong");
  check(asBigInt(sell.calldata.sqrtPriceLimitX96) === spec.maxSqrtPriceLimitX96, "router sell price limit is wrong");
  check(sameHex(sell.calldata.recipient, deployer), "router sell recipient is wrong");
  check(asBigInt(sell.calldata.deadline) > 0n, "router sell deadline is missing");
  checkSwapEvent(sell.event, sell.calldata, evidence, "router sell");

  check(sameHex(postconditions.intentToken, launch.event.token), "intent mapping does not resolve to the instant token");
  const record = postconditions.launch;
  check(sameHex(record.token, launch.event.token), "launch record token is wrong");
  check(sameHex(record.creator, deployer), "launch record creator is wrong");
  check(record.graduated === true, "instant launch record is not graduated");
  check(asBigInt(record.launchBlock) === asBigInt(record.graduatedAtBlock), "instant launch did not graduate in its launch block");
  check(
    asBigInt(record.launchBlock) === asBigInt(launch.transaction.contractBlockNumber),
    "launch record block does not match the receipt block l1BlockNumber",
  );
  check(asBigInt(record.soldTokens) === 0n, "instant launch record sold curve tokens");
  check(asBigInt(record.reserveWei) === 0n, "instant launch record has curve reserve");
  check(asBigInt(record.targetWei) === spec.depositWei, "instant launch record target does not equal the deposit");
  check(asBigInt(record.basePriceWei) === spec.openPriceWei, "instant launch record opening price is wrong");
  check(sameHex(record.poolId, launch.event.poolId), "launch record pool does not match the event");
  check(Number(record.blueprintId) === 0, "instant launch record is not custom");
  for (const [field, expected] of Object.entries(spec.hookParams)) {
    check(asBigInt(record.hookParams[field]) === asBigInt(expected), `launch record hook parameter ${field} is wrong`);
  }

  const preview = postconditions.preview;
  check(asBigInt(preview.tokensInPool) === spec.poolTokens, "pinned instant preview pool supply is wrong");
  check(asBigInt(preview.openPriceWei) === spec.openPriceWei, "pinned instant preview price is wrong");
  check(asBigInt(preview.openFdvWei) === spec.openFdvWei, "pinned instant preview FDV is wrong");
  check(Number(preview.err) === 0, "pinned instant preview rejects the canary parameters");
  check(asBigInt(preview.sqrtPriceX96) > 0n, "pinned instant preview has no sqrt price");
  check(asBigInt(record.sqrtPriceX96AtGraduation) === asBigInt(preview.sqrtPriceX96), "launch record opening sqrt price is wrong");
  check(asBigInt(launch.graduatedEvent.sqrtPriceX96) === asBigInt(preview.sqrtPriceX96), "Graduated opening sqrt price is wrong");
  check(asBigInt(postconditions.creationFeeWei) === spec.creationFeeWei, "pinned creation fee is wrong");

  const config = postconditions.hook.config;
  check(config.initialized === true, "instant pool hook config is not initialized");
  check(sameHex(config.token, launch.event.token), "hook config token does not match the instant token");
  check(asBigInt(config.guardEndBlock) > asBigInt(record.graduatedAtBlock), "anti-snipe guard was not active");
  for (const field of ["baseFeePips", "maxFeePips", "snipeTaxPips", "surgeSens", "burnBps", "lpBps", "potBps", "potEveryNBuys", "potMinBuyWei", "burnTriggerWei"]) {
    check(asBigInt(config[field]) === asBigInt(spec.hookParams[field]), `hook config ${field} is wrong`);
  }
  check(asBigInt(config.maxBuyWei) >= spec.buyWei, "hook guard cap did not admit the canary buy");
  check(asBigInt(config.royaltyBps) === 0n, "custom canary unexpectedly has a blueprint royalty");
  check(sameHex(config.royaltyTo, ZERO_ADDRESS), "custom canary unexpectedly has a royalty recipient");

  const ledgers = postconditions.hook.ledgers;
  check(
    asBigInt(ledgers.totalHookFeesWei) >= expectedHookFeeWei,
    "cumulative hook fees are below the canary receipt",
  );
  check(
    asBigInt(ledgers.totalBurnedTokens) >= asBigInt(burn.tokensBurned),
    "cumulative burns are below the canary receipt",
  );
  check(
    asBigInt(ledgers.totalLpDonatedWei) >= expectedLpDonationWei,
    "cumulative LP donations are below the canary receipt",
  );
  check(asBigInt(ledgers.potBuyCount) >= 1n, "pot buy count is below the canary receipt");
  check(asBigInt(ledgers.burnVaultWei) === 0n, "legacy burn vault is nonzero");
  check(
    asBigInt(ledgers.nativeClaimBalance) >= asBigInt(ledgers.potWei),
    "global native claims do not back the canary pool's current pot",
  );
  const guardedSwapInWei = spec.buyWei - expectedHookFeeWei;
  const combinedFeeWei = (guardedSwapInWei * scopedFeePips + PIPS - 1n) / PIPS;
  // The event does not expose the protocol component. Subtract the maximum permitted protocol
  // amount to obtain a conservative receipt-scoped lower bound on LP income. Hookr's ledger may
  // be larger (actual protocol fee can be lower) but must never be below this buy plus its exact
  // in-receipt LP donation.
  const maximumProtocolFeeWei =
    (guardedSwapInWei * MAX_PROTOCOL_FEE_PIPS) / PIPS;
  const scopedGuardEarnings =
    combinedFeeWei - maximumProtocolFeeWei + expectedLpDonationWei;
  check(
    asBigInt(ledgers.guardLpEarnedWei) >= scopedGuardEarnings,
    "guard earnings are below this canary buy receipt",
  );

  const pool = postconditions.pool;
  check(asBigInt(pool.sqrtPriceX96) > 0n, "PoolManager slot0 is uninitialized");
  check(asBigInt(pool.liquidity) > 0n, "PoolManager has no canary liquidity");
  check(Number(pool.lpFee) === spec.hookParams.baseFeePips, "PoolManager LP fee is wrong");

  const balances = postconditions.tokenBalances;
  check(asBigInt(balances.creator) > 0n, "creator holds no canary tokens");
  check(asBigInt(balances.poolManager) > 0n, "PoolManager holds no canary supply");
  check(asBigInt(balances.dead) > 0n, "dead address holds no burned canary tokens");
  check(asBigInt(balances.router) === 0n, "router retained canary tokens");
  check(asBigInt(balances.launchpad) === 0n, "launchpad retained canary tokens");
  check(sameHex(postconditions.deadAddress, DEAD), "burn evidence used the wrong dead address");

  const tokenIdentity = postconditions.tokenIdentity;
  check(sameHex(tokenIdentity.creator, deployer), "token immutable creator is wrong");
  check(sameHex(tokenIdentity.launchpad, launchpad), "token immutable launchpad is wrong");
  check(asBigInt(tokenIdentity.totalSupply) === spec.poolTokens * 2n, "token fixed supply is wrong");
  check(tokenIdentity.name === spec.name && tokenIdentity.symbol === spec.symbol, "token metadata does not match launch calldata");
  check(tokenIdentity.tagline === spec.tagline, "token tagline does not match launch calldata");

  check(asBigInt(postconditions.nativeBalances.hook) === 0n, "hook retained physical ETH");
  check(asBigInt(postconditions.nativeBalances.router) === 0n, "router retained physical ETH");
  check(sameHex(postconditions.poolManagerAddress, poolManager), "pool evidence used the wrong PoolManager");

  return { token: launch.event.token, poolId: launch.event.poolId, intentId: launch.calldata.intentId };
}
