// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrModuleBond
/// @notice A contract that stands behind a module admission, such as a module market holding a module's stake. Once a
///         queued `SET_ADMISSION_BOND` names it for an admission, the registry reports that admission only while the
///         bond covers it, so roots, root factories and Rules modules refuse new pools for a module its bond no longer
///         backs. Pools already open never read the admission again.
/// @dev Day-one consumer: a module market's bond. The registry asks `covers` with a bounded static call each
///      time it reports a bonded admission, and counts only a clean 32-byte true.
interface IHookrModuleBond {
    /// @notice Whether the bond covers `implementation`'s admission for `scope` (a root, a root factory or a part
    ///         scope).
    /// @dev A revert, a return shorter or longer than one word, any word other than 1, or running out of the
    ///      registry's probe gas reads as not covering.
    /// @param scope The root, root factory or part scope of the admission.
    /// @param implementation The admitted implementation.
    /// @return Whether the bond covers the admission.
    function covers(address scope, address implementation) external view returns (bool);
}
