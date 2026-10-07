// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrAdmissions
/// @notice The registry's per-module brake and its part scopes. Every admission is a queued `ADMIT` operation for one
///         scope: a root, a root factory (pair advisories) or a part scope. A part scope is a Rules module that holds a
///         live RULES admission on the active root it reports from `trustedRoot()`, with its runtime codehash
///         unchanged, so a module that composes other contracts (a rule chain) can have its parts admitted under its
///         own address: `abi.encode(module, admission)`. A part is of kind RULES with a gas limit from 25,000 to
///         2,000,000, a nonzero phase mask, never fail-open and never the module itself. The module reads
///         `admission(module, part)` when a pool binds; a root never reads part admissions, so a part cannot be bound
///         as a pool's Rules on its own. Freezing the root seals its part scopes, retiring it closes them, and revoking
///         the module on the root ends its part scope.
///         A queued `SET_ADMISSION_BOND` (`keccak256("SET_ADMISSION_BOND")`, arguments `abi.encode(address scope,
///         address implementation, address bondRef)`) attaches a bond (IHookrModuleBond) to a live admission for good,
///         and `admission(scope, implementation)` then reads as empty whenever the bond does not cover it.
/// @dev Kept apart from `IHookrRegistry`, which every root and module imports, so adding it changes no other contract.
///      Bonds: the day-one consumer is a module market's IHookrModuleBond. Invariants: a bond is inert until a
///      queued `SET_ADMISSION_BOND` executes, so every unbonded admission reads exactly as before; a bond attaches only
///      to a live admission that has none, only while it covers that admission, and never changes or leaves it; a bond
///      that stops covering, like a revoke, refuses new binds only and never reaches a live pool, since no path of an
///      open pool reads an admission; the registry asks the bond with a bounded static call and reads any failure as
///      not covering; the Admission struct is unchanged.
interface IHookrAdmissions {
    /// @notice The admission already has a bond, which is permanent.
    error AlreadyBonded(address scope, address implementation);

    /// @notice The bond does not cover the admission now, so attaching it would withdraw the admission.
    error BondNotCovering(address bondRef);

    /// @notice A queued `SET_ADMISSION_BOND` attached `bondRef` to `implementation`'s admission for `scope`, for good.
    /// @param scope The root, root factory or part scope of the admission.
    /// @param implementation The admitted implementation.
    /// @param bondRef The bond that now stands behind the admission.
    event AdmissionBondSet(address indexed scope, address indexed implementation, address indexed bondRef);

    /// @notice Brake: withdraws `implementation`'s admission for `scope` (a root, a root factory or a part scope) at
    ///         once and for good. A revoke blocks new binds only and never silently disables a live pool.
    /// @dev Callable by the owner or the guardian, also on a closed or retired root. On a frozen root, and on a part
    ///      scope of a frozen root, only the owner can call it: those scopes take no replacement admission, so a
    ///      revocation there could not be undone, and the guardian's instant answer is `closeRoot`, which the owner can
    ///      lift; it also stops the root's GATE admissions, which every gated swap reads, from vouching
    ///      (HookrRouter.swapGated) until the root reopens. A module is a part scope of a frozen root here while that
    ///      root stores its RULES admission, whatever the module's bond, its codehash or the root's lifecycle, so none
    ///      of them lapsing opens the guardian a way in. Reverts unless the admission is live. New pools that name the
    ///      implementation for `scope` are refused from then on: a root refuses the module as a pool's Rules or
    ///      advisory, a root factory refuses new pair roots naming the advisory, and a Rules module reading its part
    ///      admissions refuses the part. Pools already open keep what they bound, since a pool's modules are frozen at
    ///      its initialization and never re-read the registry. The address can never be admitted for `scope` again, so
    ///      no queued admission lifts the brake; a replacement is a new deployment admitted through the timelock. Emits
    ///      `AdmissionRevoked(scope, implementation, caller)`.
    /// @param scope The root, root factory or part scope the admission was made for.
    /// @param implementation The admitted implementation.
    function revokeModuleAdmission(address scope, address implementation) external;

    /// @notice Returns whether `module` is a part scope that can take a new admission now, and its root.
    /// @dev `root` is the root `module` reports from `trustedRoot()` while that root is active and holds a live RULES
    ///      admission of `module` with its current runtime codehash, zero otherwise. `eligible` also needs that root
    ///      not to be frozen.
    /// @param module The Rules module to check.
    /// @return eligible Whether an `ADMIT` for `module` can be queued and executed now, subject to the part's bounds.
    /// @return root The module's root, or zero when `module` is not a part scope.
    function partScopeEligible(address module) external view returns (bool eligible, address root);

    /// @notice Executes a queued `SET_ADMISSION_BOND`: from now on `implementation`'s admission for `scope` reads as
    ///         admitted only while `bondRef` covers it. A bond that stops covering blocks new binds only and never
    ///         silently disables a live pool.
    /// @dev Owner only. Checked when queued and again when executed: the admission is live and has no bond; `bondRef`
    ///      holds code that is not an EIP-7702 delegation and answers `covers(scope, implementation)` with a clean
    ///      32-byte true. The bond is permanent: no operation changes or removes it. A part scope's module that its bond
    ///      no longer covers takes no new part admission.
    /// @param scope The root, root factory or part scope of the admission.
    /// @param implementation The admitted implementation.
    /// @param bondRef The bond that stands behind the admission.
    function pinModuleBondFor(address scope, address implementation, address bondRef) external;

    /// @notice Returns the bond that stands behind `implementation`'s admission for `scope` (zero for none) and whether
    ///         it covers the admission now; `admission(scope, implementation)` reads as empty while a bond does not.
    ///         The bond stays readable after a brake revokes the admission, which then reads as not covered.
    /// @param scope The root, root factory or part scope of the admission.
    /// @param implementation The admitted implementation.
    /// @return bondRef The bond, or zero.
    /// @return covering Whether there is a bond, the admission is live (not revoked) and the bond covers it now.
    function findBondForAdmission(address scope, address implementation)
        external
        view
        returns (address bondRef, bool covering);
}
