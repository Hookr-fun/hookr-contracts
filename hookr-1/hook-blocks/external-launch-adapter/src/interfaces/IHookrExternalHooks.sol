// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice A hook Hookr did not write, as the Hookr 1 registry would record it.
/// @dev Field set and order copied from the draft `IHookrRegistry.ExternalHookRecord` (hookr-modular-hooks,
///      nodes/hookr-1-architecture, docs/architecture/interfaces/IHookrRegistry.sol).
/// @param hook The hook on this chain; zero for the HOOKLESS protocol
/// @param codeHash `extcodehash` at admission; the launcher re-checks it at every launch
/// @param permissionBits The low fourteen bits of `hook`, mirrored for the hooklist entry
/// @param initProtocolId HOOKLESS, PLAIN_INITIALIZE, DUALPOOL_INITIALIZE_BOOTSTRAP or a later protocol
/// @param launchAdapter The admitted `IHookrLaunchAdapter` for that protocol; zero while LISTED
/// @param capabilities The reviewed capability bitmap (`ExternalHookTypes`)
/// @param listingStatus 0 unset, 1 LISTED, 2 LAUNCHABLE, 3 RETIRED
/// @param auditRef Hash of the audit URL recorded off chain
/// @param ownerOfRecord The account that may call the hook's owner-only entries
struct ExternalHookRecord {
    address hook;
    bytes32 codeHash;
    uint160 permissionBits;
    bytes32 initProtocolId;
    address launchAdapter;
    uint32 capabilities;
    uint8 listingStatus;
    bytes32 auditRef;
    address ownerOfRecord;
}

/// @notice Constants of the external-hook lane: listing statuses, capability bits and protocol ids.
/// @dev Capability bits follow the external-hook design's table, which the draft interface does not yet carry.
///      Protocol ids are keccak256 of the protocol name, the convention the Hookr registry uses for its operation kinds.
library ExternalHookTypes {
    uint8 internal constant UNSET = 0;
    uint8 internal constant LISTED = 1;
    uint8 internal constant LAUNCHABLE = 2;
    uint8 internal constant RETIRED = 3;

    /// @notice The hook rejects `DYNAMIC_FEE_FLAG`
    uint32 internal constant STATIC_FEE_ONLY = 1 << 0;
    /// @notice Native currency is rejected
    uint32 internal constant REJECTS_NATIVE = 1 << 1;
    /// @notice The launcher may hold a v4 position
    uint32 internal constant ALLOWS_EXTERNAL_LP = 1 << 2;
    /// @notice Liquidity lives in hook-internal shares
    uint32 internal constant HOOK_OWNED_LP = 1 << 3;
    /// @notice Empty `hookData` is safe and complete
    uint32 internal constant IGNORES_HOOKDATA = 1 << 4;
    /// @notice The hook interprets `hookData`
    uint32 internal constant READS_HOOKDATA = 1 << 5;
    /// @notice Quotes come from `IALFHook` views, not PoolManager reads
    uint32 internal constant ALF_QUOTE_SURFACE = 1 << 6;
    /// @notice Universal Router swaps work unchanged
    uint32 internal constant VANILLA_SWAP = 1 << 7;
    /// @notice Initialization entries are owner-only
    uint32 internal constant OWNER_INIT = 1 << 8;
    /// @notice Proxy or mutable implementation; such a hook never becomes LAUNCHABLE
    uint32 internal constant UPGRADEABLE = 1 << 9;
    /// @notice Every bit the design defines
    uint32 internal constant KNOWN = (1 << 10) - 1;

    bytes32 internal constant HOOKLESS = keccak256("HOOKLESS");
    bytes32 internal constant PLAIN_INITIALIZE = keccak256("PLAIN_INITIALIZE");
    bytes32 internal constant DUALPOOL_INITIALIZE_BOOTSTRAP = keccak256("DUALPOOL_INITIALIZE_BOOTSTRAP");

    /// @notice The DualPool permission word: beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity,
    ///         beforeSwap, afterSwap (DualPoolHook.sol:686-702; the four 4663 hooklist rows decode to it)
    uint160 internal constant DUALPOOL_PERMISSIONS = 0x2ac0;
}

/// @notice An adapter's admission: the code hash it was admitted under and the protocol it speaks.
/// @param codeHash `extcodehash` of the adapter at admission
/// @param initProtocolId The protocol the adapter answers from `initProtocolId()`
/// @param active False once revoked; a revoked adapter cannot be re-admitted at the same address
struct AdapterAdmission {
    bytes32 codeHash;
    bytes32 initProtocolId;
    bool active;
}

/// @title IHookrExternalHookBook
/// @notice Read surface of the external-hook records the launcher and the adapters consult at open.
/// @dev The draft places these in `HookrRegistry` (`recordExternalHook`, `externalHook`); the Hookr 1 registry has
///      no such section, so they are kept in a sidecar with the same timelock discipline. Never read during a
///      swap.
interface IHookrExternalHookBook {
    /// @notice The current record of `hook`; an unknown hook returns an all-zero record (status UNSET)
    function externalHook(address hook) external view returns (ExternalHookRecord memory);

    /// @notice The admission of `adapter`; an unknown adapter returns an all-zero admission
    function adapterAdmission(address adapter) external view returns (AdapterAdmission memory);

    /// @notice True while the owner or guardian has stopped new external launches
    function launchesPaused() external view returns (bool);
}

/// @title IHookrLaunchAdapterBound
/// @notice The extension every adapter implements: the one launcher it serves, fixed at construction.
interface IHookrLaunchAdapterBound {
    /// @notice The only caller of `prepare`, `initialize` and `seed`
    function launcher() external view returns (address);
}

/// @title IHookrSeedHost
/// @notice The launcher's typed seed primitive for protocols with `ALLOWS_EXTERNAL_LP`.
/// @dev A v4 position belongs to the address that calls `modifyLiquidity`. The draft wants the launcher to own the
///      founding band while the adapter places it, so the adapter names a range and a liquidity and the launcher
///      adds it under its own unlock, from the launch's own funds. Callable once per launch, only by that launch's
///      adapter, only while its `seed` step runs. The adapter never touches a token on this path.
interface IHookrSeedHost {
    /// @notice Adds the launch's founding position, owned by the launcher
    /// @param tickLower The lower tick of the band
    /// @param tickUpper The upper tick of the band
    /// @param liquidity The liquidity to add
    /// @return subjectUsed The subject the position consumed
    /// @return quoteUsed The quote the position consumed
    /// @return positionId The PoolManager position key: keccak256(launcher, tickLower, tickUpper, salt)
    function seedPosition(int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (uint256 subjectUsed, uint256 quoteUsed, bytes32 positionId);
}

/// @title IHookrShareEscrow
/// @notice An owner-initialized protocol's adapter that holds hook-internal shares for the
///         launcher. The shares are the launcher's in the ledger; only the launcher can release them.
interface IHookrShareEscrow {
    /// @notice Shares escrowed for the launcher in pool `id`
    function escrowOf(PoolId id) external view returns (uint256);

    /// @notice Burns `shares` of pool `key` in the hook and pays the proceeds to `to`
    /// @dev Launcher only; the launcher checks the launch owner and the principal lock first
    /// @param key The pool
    /// @param shares The shares to burn
    /// @param min0 The minimum currency0 out
    /// @param min1 The minimum currency1 out
    /// @param to The recipient of both currencies
    /// @return amount0 The currency0 `to` received (less than paid only when the token taxes the transfer)
    /// @return amount1 The currency1 `to` received (less than paid only when the token taxes the transfer)
    function release(PoolKey calldata key, uint256 shares, uint256 min0, uint256 min1, address to)
        external
        returns (uint256 amount0, uint256 amount1);
}
