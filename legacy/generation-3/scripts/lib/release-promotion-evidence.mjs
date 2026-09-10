import { concatHex, getAddress, keccak256 } from "viem";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const frozenParams = (params) => Object.freeze(params);

/**
 * The five production house blueprints seeded by DeployRobinhood. These values deliberately live
 * outside the Forge artifact: promotion must prove the live calldata and the live readback against
 * a reviewed specification, not merely prove that five transactions happened to call
 * `saveBlueprint`.
 */
export const HOUSE_BLUEPRINTS = Object.freeze([
  Object.freeze({
    id: 1,
    name: "Nth-buy Pot",
    royaltyBps: 500,
    params: frozenParams({
      guardBlocks: 0,
      maxBuyBps: 0,
      snipeTaxPips: 0,
      baseFeePips: 3_000,
      maxFeePips: 0,
      surgeSens: 0,
      burnBps: 0,
      burnTriggerWei: 0n,
      lpBps: 0,
      potBps: 50,
      potEveryNBuys: 500,
      potMinBuyWei: 10_000_000_000_000_000n,
    }),
  }),
  Object.freeze({
    id: 2,
    name: "Sniper Slayer",
    royaltyBps: 0,
    params: frozenParams({
      guardBlocks: 100,
      maxBuyBps: 50,
      snipeTaxPips: 400_000,
      baseFeePips: 3_000,
      maxFeePips: 0,
      surgeSens: 0,
      burnBps: 0,
      burnTriggerWei: 0n,
      lpBps: 0,
      potBps: 0,
      potEveryNBuys: 0,
      potMinBuyWei: 0n,
    }),
  }),
  Object.freeze({
    id: 3,
    name: "Auto Burn",
    royaltyBps: 0,
    params: frozenParams({
      guardBlocks: 0,
      maxBuyBps: 0,
      snipeTaxPips: 0,
      baseFeePips: 3_000,
      maxFeePips: 0,
      surgeSens: 0,
      burnBps: 100,
      burnTriggerWei: 0n,
      lpBps: 0,
      potBps: 0,
      potEveryNBuys: 0,
      potMinBuyWei: 0n,
    }),
  }),
  Object.freeze({
    id: 4,
    name: "Surge Fees",
    royaltyBps: 0,
    params: frozenParams({
      guardBlocks: 0,
      maxBuyBps: 0,
      snipeTaxPips: 0,
      baseFeePips: 3_000,
      maxFeePips: 30_000,
      surgeSens: 5,
      burnBps: 0,
      burnTriggerWei: 0n,
      lpBps: 0,
      potBps: 0,
      potEveryNBuys: 0,
      potMinBuyWei: 0n,
    }),
  }),
  Object.freeze({
    id: 5,
    name: "LP Loyalty",
    royaltyBps: 400,
    params: frozenParams({
      guardBlocks: 0,
      maxBuyBps: 0,
      snipeTaxPips: 0,
      baseFeePips: 3_000,
      maxFeePips: 0,
      surgeSens: 0,
      burnBps: 0,
      burnTriggerWei: 0n,
      lpBps: 25,
      potBps: 0,
      potEveryNBuys: 0,
      potMinBuyWei: 0n,
    }),
  }),
]);

export const HOOK_PARAM_FIELDS = Object.freeze([
  "guardBlocks",
  "maxBuyBps",
  "snipeTaxPips",
  "baseFeePips",
  "maxFeePips",
  "surgeSens",
  "burnBps",
  "burnTriggerWei",
  "lpBps",
  "potBps",
  "potEveryNBuys",
  "potMinBuyWei",
]);

const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();

const completeAddress = (value) =>
  typeof value === "string" &&
  /^0x[0-9a-fA-F]{40}$/.test(value) &&
  !sameHex(value, ZERO_ADDRESS);

const check = (condition, message) => {
  if (!condition) throw new Error(message);
};

const asBigInt = (value, label) => {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`${label} is not an integer`);
  }
};

/**
 * The canonical deterministic-deployment proxy accepts raw `salt || initCode` calldata. Merely
 * proving that a transaction called the proxy does not prove which address it created: derive the
 * CREATE2 result from the live transaction bytes and bind that receipt to the claimed contract.
 */
export function canonicalCreate2Address(factory, calldata) {
  check(completeAddress(factory), "CREATE2 factory is missing or zero");
  check(
    typeof calldata === "string" && /^0x[0-9a-fA-F]+$/.test(calldata),
    "CREATE2 calldata is malformed",
  );
  const body = calldata.slice(2);
  check(body.length > 64 && body.length % 2 === 0, "CREATE2 calldata has no init code");
  const salt = `0x${body.slice(0, 64)}`;
  const initCode = `0x${body.slice(64)}`;
  const digest = keccak256(
    concatHex(["0xff", getAddress(factory), salt, keccak256(initCode)]),
  );
  return getAddress(`0x${digest.slice(-40)}`);
}

/**
 * Every release receipt must already be below the authenticated finalized evidence head. The
 * caller obtains that head with the RPC's `finalized` tag; this pure seam makes the ordering/floor
 * rule independently testable. Local non-writing rehearsals deliberately pass their latest head.
 */
export function assertReceiptsWithinEvidenceBlock(records, evidenceBlock) {
  const blockNumber = asBigInt(evidenceBlock?.number, "evidence block number");
  check(blockNumber > 0n, "evidence block number is zero");
  check(
    typeof evidenceBlock?.hash === "string" && /^0x[0-9a-fA-F]{64}$/.test(evidenceBlock.hash),
    "evidence block hash is missing",
  );
  check(Array.isArray(records) && records.length > 0, "receipt evidence is empty");
  for (const record of records) {
    const receiptBlock = asBigInt(record?.blockNumber, `${record?.label ?? "receipt"} block`);
    check(
      receiptBlock <= blockNumber,
      `${record?.label ?? "receipt"} is not finalized at the evidence block`,
    );
  }
  return blockNumber;
}

/**
 * Robinhood's default RPC exposes finalized block headers but cannot execute historical state
 * methods at those blocks. State evidence is therefore pinned by a separately authenticated safe
 * (latest only for a local rehearsal) block hash, which must be at least as new as the finalized
 * receipt head.
 */
export function assertStateEvidenceAfterFinality(finalizedBlock, stateBlock) {
  const finalizedNumber = asBigInt(finalizedBlock?.number, "finalized evidence block number");
  const stateNumber = asBigInt(stateBlock?.number, "state evidence block number");
  for (const [label, block] of [
    ["finalized", finalizedBlock],
    ["state", stateBlock],
  ]) {
    check(
      typeof block?.hash === "string" && /^0x[0-9a-fA-F]{64}$/.test(block.hash),
      `${label} evidence block hash is missing`,
    );
  }
  check(finalizedNumber > 0n, "finalized evidence block number is zero");
  check(stateNumber >= finalizedNumber, "state evidence block precedes finalized receipt evidence");
  return stateNumber;
}

/**
 * Before a state-evidence hash is persisted in a production manifest, the finalized head must have
 * advanced through its height and the canonical header at that height must still carry the exact
 * hash used for every earlier EIP-1898 state read. Reading first and finalizing second is necessary
 * because Robinhood stops serving historical state at finalized heights even though it continues
 * serving their headers.
 */
export function assertStateEvidenceFinalized(finalizedBlock, stateBlock, canonicalStateBlock) {
  const finalizedNumber = asBigInt(finalizedBlock?.number, "finalized confirmation block number");
  const stateNumber = asBigInt(stateBlock?.number, "state evidence block number");
  const canonicalNumber = asBigInt(
    canonicalStateBlock?.number,
    "canonical state evidence block number",
  );
  for (const [label, block] of [
    ["finalized confirmation", finalizedBlock],
    ["state", stateBlock],
    ["canonical state", canonicalStateBlock],
  ]) {
    check(
      typeof block?.hash === "string" && /^0x[0-9a-fA-F]{64}$/.test(block.hash),
      `${label} block hash is missing`,
    );
  }
  check(stateNumber > 0n, "state evidence block number is zero");
  check(
    finalizedNumber >= stateNumber,
    "finalized confirmation head has not reached the state evidence block",
  );
  check(canonicalNumber === stateNumber, "canonical state header is for the wrong block number");
  check(
    sameHex(canonicalStateBlock.hash, stateBlock.hash),
    "state evidence block is not canonical after finalization",
  );
  return stateNumber;
}

const checkParams = (actual, expected, label) => {
  check(actual && typeof actual === "object", `${label} hook params are missing`);
  for (const field of HOOK_PARAM_FIELDS) {
    check(
      asBigInt(actual[field], `${label} ${field}`) ===
        asBigInt(expected[field], `${label} expected ${field}`),
      `${label} hook parameter ${field} is wrong`,
    );
  }
};

/**
 * Derive the release's read floor from the receipt that actually created HookrLaunchpad. The
 * linked-library transaction is necessarily earlier and must never become the manifest floor.
 */
export function deriveLiveLaunchpadDeployBlock(receipt, expectedLaunchpad) {
  check(receipt?.status === "success", "live launchpad deployment receipt did not succeed");
  check(
    sameHex(receipt.contractAddress, expectedLaunchpad),
    "live launchpad deployment receipt created the wrong address",
  );
  const blockNumber = asBigInt(receipt.blockNumber, "live launchpad deployment block");
  check(blockNumber > 0n, "live launchpad deployment block is zero");
  return blockNumber;
}

/**
 * Validate all three independent views of every seeded blueprint: decoded live transaction
 * calldata, the BlueprintSaved log from that receipt, and getBlueprint() at the pinned evidence
 * block. `uses` is intentionally not pinned to zero: it is a legitimate mutable counter on this
 * permissionless launchpad. `savedAtBlock` uses Solidity's parent-chain clock and is therefore
 * compared with the receipt block header's `l1BlockNumber`, never the rollup receipt height.
 */
export function validateHouseBlueprintEvidence(evidence) {
  check(evidence && typeof evidence === "object", "house blueprint evidence is missing");
  check(completeAddress(evidence.identities?.deployer), "blueprint deployer is missing or zero");
  check(completeAddress(evidence.identities?.launchpad), "blueprint launchpad is missing or zero");
  check(
    Array.isArray(evidence.blueprints) && evidence.blueprints.length === HOUSE_BLUEPRINTS.length,
    `house blueprint evidence must contain exactly ${HOUSE_BLUEPRINTS.length} records`,
  );

  for (let index = 0; index < HOUSE_BLUEPRINTS.length; index += 1) {
    const expected = HOUSE_BLUEPRINTS[index];
    const actual = evidence.blueprints[index];
    const label = `blueprint #${expected.id} (${expected.name})`;
    check(actual && typeof actual === "object", `${label} evidence is missing`);
    check(Number(actual.id) === expected.id, `${label} evidence id is wrong`);

    const transaction = actual.transaction;
    check(sameHex(transaction?.from, evidence.identities.deployer), `${label} sender is wrong`);
    check(sameHex(transaction?.to, evidence.identities.launchpad), `${label} target is wrong`);
    check(asBigInt(transaction?.value, `${label} transaction value`) === 0n, `${label} sent native value`);
    const receiptBlock = asBigInt(transaction?.blockNumber, `${label} receipt block`);
    check(receiptBlock > 0n, `${label} receipt block is zero`);
    const contractBlock = asBigInt(
      transaction?.contractBlockNumber,
      `${label} contract-visible block`,
    );
    check(contractBlock > 0n, `${label} contract-visible block is zero`);

    const calldata = actual.calldata;
    check(calldata?.name === expected.name, `${label} calldata name is wrong`);
    check(Number(calldata?.royaltyBps) === expected.royaltyBps, `${label} calldata royalty is wrong`);
    checkParams(calldata?.params, expected.params, `${label} calldata`);

    const event = actual.event;
    check(Number(event?.id) === expected.id, `${label} event id is wrong`);
    check(sameHex(event?.author, evidence.identities.deployer), `${label} event author is wrong`);
    check(event?.name === expected.name, `${label} event name is wrong`);
    check(Number(event?.royaltyBps) === expected.royaltyBps, `${label} event royalty is wrong`);

    const readback = actual.readback;
    check(sameHex(readback?.author, evidence.identities.deployer), `${label} readback author is wrong`);
    check(Number(readback?.royaltyBps) === expected.royaltyBps, `${label} readback royalty is wrong`);
    const uses = asBigInt(readback?.uses, `${label} readback uses`);
    check(uses >= 0n && uses <= 0xffff_ffffn, `${label} readback uses is outside uint32`);
    check(
      asBigInt(readback?.savedAtBlock, `${label} savedAtBlock`) === contractBlock,
      `${label} savedAtBlock does not match its receipt block l1BlockNumber`,
    );
    check(readback?.name === expected.name, `${label} readback name is wrong`);
    checkParams(readback?.params, expected.params, `${label} readback`);
  }

  return HOUSE_BLUEPRINTS.map(({ id, name }) => ({ id, name }));
}
