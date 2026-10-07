// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrFamilyLock
/// @notice Holds HookrLauncher families whose principal must stay in their pools: until an unlock block, or for good.
///         A family's owner starts a transfer of the family to the lock (HookrLauncher.transferFamily) and then calls
///         `lock`, which accepts it. While locked, the family's beneficiary collects its LP fees and arb recapture
///         accruals; nobody can withdraw principal, add liquidity or move the family. From the unlock block the
///         beneficiary releases the family to an owner it chooses. An unlock block of type(uint64).max locks for good.
/// @dev The lock holds no asset between calls: fees and accruals go from the PoolManager and the Rules straight to the
///      beneficiary, and a release hands the family over through its own HookrFamilyRelease, which receives the fees
///      the family earns until its new owner accepts it.
interface IHookrFamilyLock {
    /// @notice `familyId` was locked by `locker`, its owner until now, for `beneficiary` until `unlockBlock`.
    /// @param familyId The family.
    /// @param locker The family's owner before the lock, paid the fees the family had earned.
    /// @param beneficiary The account that collects the family's fees and accruals and releases it.
    /// @param unlockBlock The parent block from which the family can be released; type(uint64).max never.
    event FamilyLocked(
        bytes32 indexed familyId, address indexed locker, address indexed beneficiary, uint64 unlockBlock
    );
    /// @notice `beneficiary` released `familyId` to `newOwner`, who accepts it from `release`.
    /// @param familyId The family.
    /// @param beneficiary The beneficiary that released it.
    /// @param newOwner The owner the transfer names; the beneficiary may re-target it until acceptance.
    /// @param release The HookrFamilyRelease that owns the family until `newOwner` accepts it.
    event FamilyReleased(
        bytes32 indexed familyId, address indexed beneficiary, address indexed newOwner, address release
    );

    /// @notice `caller` is not the family's owner, or the family's pending owner is not this lock.
    error NotLockable(bytes32 familyId, address caller);
    /// @notice A beneficiary of zero, this lock, the launcher or the PoolManager: none can be paid a collection.
    error InvalidBeneficiary(address beneficiary);
    /// @notice An unlock block at or before the current block.
    error InvalidUnlockBlock(uint256 unlockBlock);
    /// @notice `caller` is not the family's beneficiary (an unlocked family has none).
    error NotBeneficiary(bytes32 familyId, address caller);
    /// @notice The family stays locked until `unlockBlock` (type(uint64).max: for good).
    error StillLocked(bytes32 familyId, uint256 unlockBlock);
    /// @notice A new owner of zero, this lock or the launcher.
    error InvalidNewOwner(address newOwner);
    /// @notice A call into the lock while it runs.
    error Reentered();

    /// @notice The launcher whose families this lock holds.
    /// @return The launcher.
    function launcher() external view returns (address);

    /// @notice A locked family's beneficiary and unlock block; zeros for a family this lock does not hold.
    /// @param familyId The family.
    /// @return beneficiary The account that collects the family's fees and accruals and releases it.
    /// @return unlockBlock The parent block from which the family can be released; type(uint64).max never.
    function lockOf(bytes32 familyId) external view returns (address beneficiary, uint64 unlockBlock);

    /// @notice Accepts the family's pending transfer to this lock and locks it for `beneficiary` until `unlockBlock`.
    /// @dev Only the family's current owner may call, after HookrLauncher.transferFamily(familyId, this lock, claims):
    ///      the acceptance first pays it the fees its family earned so far, in the form `claims` chose.
    /// @param familyId The family.
    /// @param beneficiary The account that collects the family's fees and accruals and releases it.
    /// @param unlockBlock The parent block (block.number) from which the family can be released; type(uint64).max
    ///        never.
    function lock(bytes32 familyId, address beneficiary, uint64 unlockBlock) external;

    /// @notice The beneficiary collects member `member`'s LP fees, and on a member launched with arb recapture its
    ///         accrual, with no principal: HookrLauncher.withdrawWithClaims of zero liquidity to the beneficiary.
    /// @param familyId The family.
    /// @param member The member, from 0.
    /// @param claims Bit 0 and bit 1 deliver currency0 and currency1 as PoolManager ERC-6909 claims.
    /// @return amount0 The currency0 fees collected.
    /// @return amount1 The currency1 fees collected.
    function collect(bytes32 familyId, uint8 member, uint8 claims) external returns (uint256 amount0, uint256 amount1);

    /// @notice The beneficiary moves member `member`'s arb recapture accrual into its own claims in the member's Rules
    ///         (HookrLauncher.claimRecapture).
    /// @param familyId The family.
    /// @param member The member, from 0.
    /// @return moved How many currencies moved.
    function claimRecapture(bytes32 familyId, uint8 member) external returns (uint256 moved);

    /// @notice From the unlock block, the beneficiary releases the family to `newOwner`, who accepts it with
    ///         HookrLauncher.acceptFamily.
    /// @dev The lock hands the family to a new HookrFamilyRelease, which accepts it at once: the fees the family earned
    ///      until then reach this lock as PoolManager ERC-6909 claims and go on to the beneficiary in the same call. The
    ///      release then starts the transfer to `newOwner`; the fees the family earns until `newOwner` accepts reach
    ///      the release, as ERC-6909 claims, and the release's `sweep` sends them to the beneficiary. Arb recapture
    ///      accruals left unclaimed follow the family to its new owner.
    /// @param familyId The family.
    /// @param newOwner The owner the transfer names: not zero, this lock or the launcher.
    /// @return handover The HookrFamilyRelease handing the family over.
    function release(bytes32 familyId, address newOwner) external returns (address handover);
}
