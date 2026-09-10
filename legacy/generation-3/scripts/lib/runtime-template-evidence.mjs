import { getAddress, keccak256, toHex } from "viem";

export const REVIEWED_COMPILER_SETTINGS = Object.freeze({
  compilerVersion: "0.8.26+commit.8a97fa7a",
  optimizerRuns: 200,
  evmVersion: "cancun",
});

/**
 * Review anchors for runtime templates with only solc-declared address immutable/link slots zeroed.
 * Re-derive and review these after an intentional contract-source change; do not derive them from
 * live code during promotion.
 */
export const REVIEWED_NORMALIZED_RUNTIME_HASHES = Object.freeze({
  launchpad: "0xd331e42e132f7d6907e5b2bce39a35d9dc776cdb1b2fee1c0d0bce402c2e3ed1",
  hook: "0x6e3c932352b1fe5d5033e26e342b776544301298b3fc0a41a889a530563464ab",
  router: "0xb73b3147d5d096916c25989789e3dea9b0c6778f1cd582c19f874b66ef8ebfd2",
  launchpadLib: "0x64fb218ddce6f33077749e3a750b04461b2f9b9929d3d4a6baaf5711c05ba5c6",
});

/** Pin the exact solc-declared ranges so an edited artifact cannot widen what promotion masks. */
export const REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES = Object.freeze({
  launchpad: "0x9927dd4dbd5666b0e783daf5c63c639f832d5d5bdc53f1be3bbd1eea51beb4fe",
  hook: "0xa1203eda2e0df9323b6f8e0a71780c998f5ae1307ca1557f18417f0aa8eb5e25",
  router: "0x0435c7cacba198223bcbdaa78774867a126dd67911dda37ec4c54d99f789bb1c",
  launchpadLib: "0x75765f00a5d68c4c25ba2df8c18c5fd0060f3cee6edff20fb88bd0e987521ce5",
});

const check = (condition, message) => {
  if (!condition) throw new Error(message);
};

const strip0x = (value) => String(value ?? "").replace(/^0x/, "");
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();

const hashBytes = (value) => {
  const bytes =
    typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value);
  return keccak256(toHex(bytes));
};

const compilationTargetOf = (artifact) => {
  const entries = Object.entries(artifact?.metadata?.settings?.compilationTarget ?? {});
  check(entries.length === 1, "artifact must contain exactly one compilation target");
  return entries[0];
};

/** Prove that the artifact was compiled from the exact local source bytes it claims. */
export function assertArtifactSourceHashes(artifact, readSource, label = "runtime artifact") {
  const sources = artifact?.metadata?.sources;
  check(sources && typeof sources === "object", `${label} has no metadata source hashes`);
  const entries = Object.entries(sources);
  check(entries.length > 0, `${label} metadata source list is empty`);
  for (const [sourcePath, source] of entries) {
    let contents;
    try {
      contents = readSource(sourcePath);
    } catch (error) {
      throw new Error(`${label} source ${sourcePath} cannot be read: ${error.message}`);
    }
    const actual = hashBytes(contents);
    check(
      sameHex(actual, source?.keccak256),
      `${label} source hash mismatch for ${sourcePath}`,
    );
  }
  return entries.length;
}

const assertCompilerSettings = (artifact, expectedTarget, label) => {
  const metadata = artifact?.metadata;
  check(
    metadata?.compiler?.version === REVIEWED_COMPILER_SETTINGS.compilerVersion,
    `${label} compiler version is not reviewed`,
  );
  const settings = metadata?.settings;
  check(settings?.optimizer?.enabled === true, `${label} optimizer is disabled`);
  check(
    settings?.optimizer?.runs === REVIEWED_COMPILER_SETTINGS.optimizerRuns,
    `${label} optimizer runs are not reviewed`,
  );
  check(settings?.viaIR === true, `${label} was not compiled via IR`);
  check(
    settings?.evmVersion === REVIEWED_COMPILER_SETTINGS.evmVersion,
    `${label} EVM version is not reviewed`,
  );
  check(settings?.metadata?.bytecodeHash === "none", `${label} embeds an unreviewed metadata hash`);
  check(
    settings?.libraries && Object.keys(settings.libraries).length === 0,
    `${label} metadata contains prelinked libraries`,
  );
  const [sourcePath, contractName] = compilationTargetOf(artifact);
  check(
    sourcePath === expectedTarget.sourcePath && contractName === expectedTarget.contractName,
    `${label} compilation target is ${sourcePath}:${contractName}`,
  );
};

const immutableGroups = (artifact) =>
  Object.entries(artifact?.deployedBytecode?.immutableReferences ?? {}).map(
    ([id, references]) => ({ kind: "immutable", id, references }),
  );

const linkGroups = (artifact) => {
  const groups = [];
  for (const [sourcePath, libraries] of Object.entries(
    artifact?.deployedBytecode?.linkReferences ?? {},
  )) {
    for (const [libraryName, references] of Object.entries(libraries)) {
      groups.push({
        kind: "link",
        id: `${sourcePath}:${libraryName}`,
        references,
      });
    }
  }
  return groups;
};

const canonicalReferences = (references) =>
  [...references]
    .sort((left, right) => left.start - right.start || left.length - right.length)
    .map(({ start, length }) => ({ start, length }));

const canonicalReferenceLayout = (artifact) => {
  // solc keys immutable groups by an internal AST id. That number is not semantic: Foundry can
  // recompile the identical target/source/runtime in a larger compilation unit and renumber every
  // AST node. Pin the exact ranges and their group boundaries, sorted deterministically, without
  // pinning those unstable ids. Merging, splitting, moving, or widening any group still changes the
  // hash. Linked-library names are semantic compiler inputs and remain pinned verbatim.
  const immutables = immutableGroups(artifact)
    .map(({ references }) => ({
      kind: "immutable",
      references: canonicalReferences(references),
    }))
    .sort((left, right) =>
      JSON.stringify(left.references).localeCompare(JSON.stringify(right.references)),
    );
  const links = linkGroups(artifact)
    .map(({ id, references }) => ({
      kind: "link",
      id,
      references: canonicalReferences(references),
    }))
    .sort((left, right) => left.id.localeCompare(right.id));
  return [...immutables, ...links];
};

export const deriveRuntimeReferenceLayoutHash = (artifact) =>
  hashBytes(JSON.stringify(canonicalReferenceLayout(artifact)));

const canonicalAddresses = (addresses) =>
  addresses.map((address) => getAddress(address).toLowerCase()).sort();

/**
 * Compare live runtime byte-for-byte with a locally reviewed Foundry runtime template. Only slots
 * declared by solc as immutable or link references are masked, and every masked slot is first
 * required to contain its exact verified constructor/link value.
 */
export function validateReviewedRuntime({
  artifact,
  liveCode,
  expectedTarget,
  expectedImmutableAddresses,
  expectedLinks = {},
  expectedNormalizedTemplateHash,
  expectedReferenceLayoutHash,
  label = expectedTarget.contractName,
}) {
  assertCompilerSettings(artifact, expectedTarget, label);
  const template = strip0x(artifact?.deployedBytecode?.object);
  const live = strip0x(liveCode);
  check(template.length > 0 && template.length % 2 === 0, `${label} runtime template is malformed`);
  check(/^[0-9a-fA-F_$]+$/.test(template), `${label} runtime template has unexpected placeholders`);
  check(/^([0-9a-fA-F]{2})+$/.test(live), `${label} live runtime is malformed`);
  check(live.length === template.length, `${label} live runtime length differs from the reviewed template`);

  const byteLength = template.length / 2;
  const masked = new Uint8Array(byteLength);
  const templateChars = template.split("");
  const liveChars = live.split("");
  const immutableValues = [];
  const groups = [...immutableGroups(artifact), ...linkGroups(artifact)];
  const referenceLayoutHash = deriveRuntimeReferenceLayoutHash(artifact);
  check(
    sameHex(referenceLayoutHash, expectedReferenceLayoutHash),
    `${label} compiler reference layout is not the reviewed anchor (candidate ${referenceLayoutHash}, reviewed ${expectedReferenceLayoutHash})`,
  );

  for (const group of groups) {
    check(
      Array.isArray(group.references) && group.references.length > 0,
      `${label} ${group.kind} ${group.id} has no references`,
    );
    let groupValue = null;
    for (const reference of group.references) {
      const { start, length } = reference ?? {};
      check(
        Number.isInteger(start) && Number.isInteger(length) && start >= 0 && length > 0,
        `${label} ${group.kind} ${group.id} has a malformed reference`,
      );
      check(start + length <= byteLength, `${label} ${group.kind} ${group.id} is out of bounds`);
      for (let offset = start; offset < start + length; offset += 1) {
        check(masked[offset] === 0, `${label} compiler reference ranges overlap at byte ${offset}`);
        masked[offset] = 1;
      }
      const value = live.slice(start * 2, (start + length) * 2).toLowerCase();
      if (groupValue === null) groupValue = value;
      check(value === groupValue, `${label} ${group.kind} ${group.id} has inconsistent live values`);

      if (group.kind === "immutable") {
        check(length === 32, `${label} immutable ${group.id} is not an address word`);
        const artifactValue = template.slice(start * 2, (start + length) * 2);
        check(/^0+$/.test(artifactValue), `${label} immutable ${group.id} template is not zero-filled`);
      } else {
        check(length === 20, `${label} link ${group.id} is not an address`);
      }
      templateChars.splice(start * 2, length * 2, ..."0".repeat(length * 2));
      liveChars.splice(start * 2, length * 2, ..."0".repeat(length * 2));
    }

    if (group.kind === "immutable") {
      check(/^0{24}[0-9a-f]{40}$/.test(groupValue), `${label} immutable ${group.id} is not an encoded address`);
      immutableValues.push(getAddress(`0x${groupValue.slice(24)}`).toLowerCase());
    } else {
      const expected = expectedLinks[group.id];
      check(expected, `${label} has unexpected linked library ${group.id}`);
      check(
        groupValue === getAddress(expected).slice(2).toLowerCase(),
        `${label} linked library ${group.id} has the wrong address`,
      );
    }
  }

  const expectedLinkNames = Object.keys(expectedLinks).sort();
  const actualLinkNames = linkGroups(artifact).map(({ id }) => id).sort();
  check(
    JSON.stringify(actualLinkNames) === JSON.stringify(expectedLinkNames),
    `${label} linked-library set differs from the reviewed template`,
  );
  check(
    JSON.stringify(immutableValues.sort()) ===
      JSON.stringify(canonicalAddresses(expectedImmutableAddresses)),
    `${label} immutable address set differs from constructor evidence`,
  );

  const normalizedTemplate = templateChars.join("").toLowerCase();
  const normalizedLive = liveChars.join("").toLowerCase();
  check(/^[0-9a-f]+$/.test(normalizedTemplate), `${label} has an unmasked template placeholder`);
  const normalizedTemplateHash = keccak256(`0x${normalizedTemplate}`);
  check(
    sameHex(normalizedTemplateHash, expectedNormalizedTemplateHash),
    `${label} normalized template hash is not the reviewed anchor (candidate ${normalizedTemplateHash}, reviewed ${expectedNormalizedTemplateHash})`,
  );
  if (normalizedTemplate !== normalizedLive) {
    let firstDifference = 0;
    while (
      firstDifference < byteLength &&
      normalizedTemplate.slice(firstDifference * 2, firstDifference * 2 + 2) ===
        normalizedLive.slice(firstDifference * 2, firstDifference * 2 + 2)
    ) {
      firstDifference += 1;
    }
    throw new Error(`${label} live runtime differs from reviewed source at byte ${firstDifference}`);
  }

  return Object.freeze({
    runtimeCodeHash: keccak256(`0x${live}`),
    normalizedTemplateHash,
    referenceLayoutHash,
    byteLength,
  });
}
