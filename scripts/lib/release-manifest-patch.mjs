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
