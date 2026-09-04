/**
 * Replace only the write-facing release assignment. Historical catalog records are deliberately
 * outside this pattern: a new generation must not erase the addresses needed to read old tokens.
 *
 * The alias shape is the only writable promotion boundary in this generation. Once CURRENT is an
 * expanded object, only a byte-identical no-op is accepted: a future generation must first add the
 * outgoing object as an exact retained declaration and registry entry in one reviewed change.
 */
const CURRENT_RELEASE_PATTERN =
  /export const CURRENT_RELEASE_MANIFEST = (?:[A-Z][A-Z0-9_]*|\{[\s\S]*?\} as const satisfies HookrReleaseManifest);/g;

const RETAINED_RELEASE_PATTERN =
  /export const RETAINED_GENERATION_\d+_MANIFEST = \{[\s\S]*?\} as const satisfies HookrReleaseManifest;/g;

const READ_RELEASES_PATTERN =
  /export const READ_RELEASES = validateReleaseRegistry\(\s*CURRENT_RELEASE_MANIFEST,\s*createReleaseRegistry\(\[[\s\S]*?\]\),\s*\);/g;

/** Capture the exact historical declarations and their exact read-catalog registration. */
export function retainedReleaseHistory(source) {
  const retained = [...source.matchAll(RETAINED_RELEASE_PATTERN)].map((match) => match[0]);
  const registries = [...source.matchAll(READ_RELEASES_PATTERN)].map((match) => match[0]);
  if (retained.length === 0) {
    throw new Error("release manifest contains no retained release history");
  }
  if (registries.length !== 1) {
    throw new Error(`expected exactly one READ_RELEASES registry, found ${registries.length}`);
  }
  return Object.freeze({ retained: Object.freeze(retained), registry: registries[0] });
}

/** Fail if promotion changed, removed, reordered, or silently unregistered any retained release. */
export function assertRetainedReleaseHistoryPreserved(before, after) {
  const expected = retainedReleaseHistory(before);
  const actual = retainedReleaseHistory(after);
  if (
    expected.registry !== actual.registry ||
    expected.retained.length !== actual.retained.length ||
    expected.retained.some((entry, index) => entry !== actual.retained[index])
  ) {
    throw new Error("promotion changed the exact retained release history");
  }
}

const assignmentVersion = (assignment) => {
  const alias = assignment.match(
    /^export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_(\d+)_MANIFEST;$/,
  );
  if (alias) return Number(alias[1]);
  const versions = [...assignment.matchAll(/^\s*version:\s*(\d+),?\s*$/gm)];
  if (versions.length !== 1) {
    throw new Error(`expected exactly one release version in CURRENT_RELEASE_MANIFEST, found ${versions.length}`);
  }
  return Number(versions[0][1]);
};

/**
 * Promote past an EXPANDED current release: retain the outgoing CURRENT object byte-for-byte as
 * RETAINED_GENERATION_<n>_MANIFEST, register that retained name in READ_RELEASES directly after
 * CURRENT (the registry stays newest-first), and only then replace CURRENT with the next
 * generation — one atomic text rewrite, so the outgoing addresses needed to read old tokens can
 * never be dropped by a promotion. A byte-identical re-run (crash recovery after a successful
 * write) is accepted as a no-op; anything else that would touch existing history fails closed.
 */
export function retireAndReplaceCurrentReleaseManifest(source, manifest) {
  const currentAssignments = [...source.matchAll(CURRENT_RELEASE_PATTERN)];
  if (currentAssignments.length !== 1) {
    throw new Error(`expected exactly one CURRENT_RELEASE_MANIFEST assignment, found ${currentAssignments.length}`);
  }
  const currentAssignment = currentAssignments[0][0];
  if (currentAssignment === manifest) return source; // exact recovery no-op
  if (!currentAssignment.startsWith("export const CURRENT_RELEASE_MANIFEST = {")) {
    throw new Error(
      "current release is a retained alias; use replaceCurrentReleaseManifest for the initial alias promotion",
    );
  }
  const currentVersion = assignmentVersion(currentAssignment);
  const nextVersion = assignmentVersion(manifest);
  if (nextVersion !== currentVersion + 1) {
    throw new Error(
      `retiring promotion must advance exactly one generation (v${currentVersion} to v${currentVersion + 1})`,
    );
  }
  const retainedName = `RETAINED_GENERATION_${currentVersion}_MANIFEST`;
  if (source.includes(`export const ${retainedName} `)) {
    throw new Error(`${retainedName} already exists; refusing to retain the current release twice`);
  }
  const retainedLiteral = `export const ${retainedName} = ${currentAssignment.slice(
    "export const CURRENT_RELEASE_MANIFEST = ".length,
  )}`;

  const { registry } = retainedReleaseHistory(source);
  const registryAnchor = "createReleaseRegistry([\n    CURRENT_RELEASE_MANIFEST,\n";
  if (!registry.includes(registryAnchor)) {
    throw new Error("READ_RELEASES registry does not list CURRENT_RELEASE_MANIFEST first");
  }
  const patchedRegistry = registry.replace(
    registryAnchor,
    `${registryAnchor}    ${retainedName},\n`,
  );

  const patched = source
    .replace(currentAssignment, () => `${retainedLiteral}\n\n${manifest}`)
    .replace(registry, () => patchedRegistry);

  const patchedCurrent = [...patched.matchAll(CURRENT_RELEASE_PATTERN)];
  if (patchedCurrent.length !== 1 || patchedCurrent[0][0] !== manifest) {
    throw new Error("retiring promotion did not produce exactly the next CURRENT_RELEASE_MANIFEST");
  }
  const before = retainedReleaseHistory(source);
  const after = retainedReleaseHistory(patched);
  if (
    after.registry !== patchedRegistry ||
    after.retained.length !== before.retained.length + 1 ||
    before.retained.some((entry) => !after.retained.includes(entry)) ||
    !after.retained.includes(retainedLiteral)
  ) {
    throw new Error("retiring promotion failed to preserve and extend the retained release history");
  }
  return patched;
}

export function replaceCurrentReleaseManifest(source, manifest) {
  const currentAssignments = [...source.matchAll(CURRENT_RELEASE_PATTERN)];
  if (currentAssignments.length !== 1) {
    throw new Error(`expected exactly one CURRENT_RELEASE_MANIFEST assignment, found ${currentAssignments.length}`);
  }
  const currentAssignment = currentAssignments[0][0];
  const currentVersion = assignmentVersion(currentAssignment);
  const nextVersion = assignmentVersion(manifest);
  if (currentAssignment.startsWith("export const CURRENT_RELEASE_MANIFEST = {")) {
    if (currentAssignment === manifest) return source;
    throw new Error(
      `refusing to replace expanded current release v${currentVersion}; retain it atomically before any future generation`,
    );
  }
  if (nextVersion !== currentVersion + 1) {
    throw new Error(
      `initial alias promotion must advance exactly one generation (v${currentVersion} to v${currentVersion + 1})`,
    );
  }
  const patched = source.replace(CURRENT_RELEASE_PATTERN, manifest);
  assertRetainedReleaseHistoryPreserved(source, patched);
  return patched;
}
