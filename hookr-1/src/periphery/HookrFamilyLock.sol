// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrLauncher} from "./HookrLauncher.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrFamilyLock} from "../interfaces/IHookrFamilyLock.sol";
import {HookrFamilyRelease} from "./HookrFamilyRelease.sol";

/// @title HookrFamilyLock
/// @notice A holder for HookrLauncher families that keeps every member's principal in its pool until an unlock block, or
///         for good, while the family's beneficiary collects its fees and arb recapture accruals.
/// @dev The lock is a family owner like any other: it reaches the family only through the launcher's owner entry
///      points, and calls only withdrawWithClaims of zero liquidity, claimRecapture, transferFamily and acceptFamily,
///      so no principal can leave a locked family's pools, nor can liquidity be added. It holds no asset between calls:
///      collections and accrual claims pay the beneficiary directly, and a release takes the family's fees as PoolManager
///      ERC-6909 claims and forwards them within the same call, so every ERC-6909 claim it holds mid-call is the
///      released family's. An ERC-6909 claim sent to it by mistake goes to the next release's beneficiary.
contract HookrFamilyLock is HookrReleased, IHookrFamilyLock {
    /// @dev A locked family: its beneficiary and unlock block, one word.
    struct Lock {
        address beneficiary;
        uint64 unlockBlock;
    }

    HookrLauncher internal immutable _launcher;
    IPoolManager internal immutable _manager;
    mapping(bytes32 familyId => Lock) internal _locks;
    bool private transient _busy;

    modifier nonReentrant() {
        if (_busy) revert Reentered();
        _busy = true;
        _;
        _busy = false;
    }

    /// @param launcher_ The launcher whose families this lock holds.
    constructor(HookrLauncher launcher_) {
        _launcher = launcher_;
        _manager = launcher_.poolManager();
    }

    /// @inheritdoc IHookrFamilyLock
    function launcher() external view returns (address) {
        return address(_launcher);
    }

    /// @inheritdoc IHookrFamilyLock
    function lockOf(bytes32 familyId) external view returns (address beneficiary, uint64 unlockBlock) {
        Lock storage l = _locks[familyId];
        return (l.beneficiary, l.unlockBlock);
    }

    /// @inheritdoc IHookrFamilyLock
    function lock(bytes32 familyId, address beneficiary, uint64 unlockBlock) external nonReentrant {
        (address pending,) = _launcher.pendingFamilyOwner(familyId);
        if (_launcher.familyOwner(familyId) != msg.sender || pending != address(this)) {
            revert NotLockable(familyId, msg.sender);
        }
        if (
            beneficiary == address(0) || beneficiary == address(this) || beneficiary == address(_launcher)
                || beneficiary == address(_manager)
        ) revert InvalidBeneficiary(beneficiary);
        if (unlockBlock <= block.number) revert InvalidUnlockBlock(unlockBlock);
        _locks[familyId] = Lock(beneficiary, unlockBlock);
        _launcher.acceptFamily(familyId);
        emit FamilyLocked(familyId, msg.sender, beneficiary, unlockBlock);
    }

    /// @inheritdoc IHookrFamilyLock
    function collect(bytes32 familyId, uint8 member, uint8 claims)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        address beneficiary = _beneficiary(familyId);
        return _launcher.withdrawWithClaims(familyId, member, 0, 0, 0, beneficiary, claims, block.timestamp);
    }

    /// @inheritdoc IHookrFamilyLock
    function claimRecapture(bytes32 familyId, uint8 member) external nonReentrant returns (uint256 moved) {
        return _launcher.claimRecapture(familyId, member, _beneficiary(familyId));
    }

    /// @inheritdoc IHookrFamilyLock
    function release(bytes32 familyId, address newOwner) external nonReentrant returns (address) {
        address beneficiary = _beneficiary(familyId);
        uint256 unlockBlock = _locks[familyId].unlockBlock;
        if (unlockBlock == type(uint64).max || block.number < unlockBlock) revert StillLocked(familyId, unlockBlock);
        if (newOwner == address(0) || newOwner == address(this) || newOwner == address(_launcher)) {
            revert InvalidNewOwner(newOwner);
        }
        delete _locks[familyId];
        HookrFamilyRelease handover = new HookrFamilyRelease(_launcher, familyId, beneficiary);
        uint8 n = _launcher.memberCount(familyId);
        // Every member's fees reach this lock as ERC-6909 claims when the release accepts the family.
        _launcher.transferFamily(familyId, address(handover), uint16((uint256(1) << (2 * uint256(n))) - 1));
        handover.accept();
        for (uint8 i; i < n; ++i) {
            PoolKey memory key = _launcher.position(familyId, i).key;
            _forward(key.currency0, beneficiary);
            _forward(key.currency1, beneficiary);
        }
        handover.transferTo(newOwner);
        emit FamilyReleased(familyId, beneficiary, newOwner, address(handover));
        return address(handover);
    }

    /// @dev The family's beneficiary, who must be the caller.
    function _beneficiary(bytes32 familyId) private view returns (address beneficiary) {
        beneficiary = _locks[familyId].beneficiary;
        if (beneficiary == address(0) || msg.sender != beneficiary) revert NotBeneficiary(familyId, msg.sender);
    }

    /// @dev Sends this lock's whole ERC-6909 balance of `currency` to `to`.
    function _forward(Currency currency, address to) private {
        uint256 id = currency.toId();
        uint256 amount = _manager.balanceOf(address(this), id);
        if (amount != 0) _manager.transfer(to, id, amount);
    }
}
