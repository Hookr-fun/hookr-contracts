// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrModuleTypesV1} from "./HookrModuleTypesV1.sol";

interface IHookrNativeMechanicsModuleReadV1 {
    function requiresLockedFoundingPosition(bytes calldata config) external pure returns (bool required);
    function guardLpEarnedQuote(bytes32 poolId) external view returns (uint256 amount);
}

interface IHookrNativeMechanicsCatalogReadV1 {
    function module(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot);
}

interface IHookrNativeMechanicsTreasuryReadV1 {
    function treasuryBeneficiary() external view returns (address);
}

/// @title Hookr Native Mechanics Coordinator Library V1
/// @notice Bounded coordinator-side admission and guard-fee read boundary for the native block.
library HookrNativeMechanicsCoordinatorLibV1 {
    bytes32 internal constant MODULE_KEY = keccak256("HOOKR_NATIVE_MECHANICS");
    bytes32 internal constant CONFIG_SCHEMA_HASH = keccak256(
        "HookrNativeMechanicsBlockV1.Config(bytes32 poolId,address kernel,address subject,address quote,address lockedLiquidityProvider,uint40 guardEndBlock,uint24 baseFeePips,uint24 maxFeePips,uint24 snipeTaxPips,uint16 surgeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint32 potEveryNBuys,uint96 maxBuyQuoteAmount,uint96 potMinBuyWei,address royaltyTo,address flywheelRecipient,uint24 flywheelFeePips)"
    );
    uint8 internal constant REQUIRED_PHASE_MASK = HookrModuleTypesV1.ALL_PHASES;
    uint32 internal constant QUERY_GAS = 75_000;
    uint8 internal constant NEW_TOKEN_ORIGIN = 1;
    uint256 internal constant MAX_GUARD_BLOCKS = 100_000;
    uint256 internal constant TOKEN_QUERY_GAS = 50_000;
    bytes32 internal constant GUARD_ACCOUNTING_STORAGE_SLOT =
        keccak256("hookr.market.coordinator.native.mechanics.guard.accounting.v1");

    struct GuardAccounting {
        address module;
        bytes32 moduleCodeHash;
        uint256 cumulativeWithheld;
    }

    struct GuardAccountingStorage {
        mapping(bytes32 poolId => GuardAccounting accounting) pools;
    }

    struct FeeRouteInput {
        bytes32 poolId;
        address quote;
        address currency0;
        address currency1;
        address lpFeeRecipient;
        address partnerRegistry;
        uint256 amount0;
        uint256 amount1;
    }

    error InvalidNativeMechanicsModule();
    error GuardRequiresLockedFoundingPosition();
    error InvalidGuardAccounting();
    error InvalidTreasury();
    error TransferFailed();
    error TaxedTransfer();
    error NativeTransferFailed();

    event LpFeesCollected(bytes32 indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1);
    event GuardLpFeesWithheld(
        bytes32 indexed poolId,
        address indexed module,
        address indexed treasury,
        uint256 amount,
        uint256 cumulativeWithheld,
        uint256 cumulativeEarned
    );

    /// @notice Resolves the one canonical native block and rejects guard use on open-LP origins.
    function validateOrigin(
        IHookrNativeMechanicsCatalogReadV1 registry,
        uint8 origin,
        uint24 baseLpFeePips,
        HookrModuleTypesV1.ModuleSelection[] calldata selections
    ) public view returns (address module, bytes32 codeHash) {
        for (uint256 i; i < selections.length; ++i) {
            HookrModuleTypesV1.ModuleSnapshot memory snapshot = registry.module(selections[i].moduleId);
            if (snapshot.moduleKey != MODULE_KEY) continue;
            if (
                module != address(0) || snapshot.version != 1 || snapshot.configSchemaHash != CONFIG_SCHEMA_HASH
                    || snapshot.executionMode != HookrModuleTypesV1.ExecutionMode.STATEFUL_V1
                    || snapshot.phaseMask != REQUIRED_PHASE_MASK || snapshot.implementation == address(0)
                    || snapshot.implementation.codehash != snapshot.implementationCodeHash
            ) revert InvalidNativeMechanicsModule();
            module = snapshot.implementation;
            codeHash = snapshot.implementationCodeHash;
            (bool ok, uint256 required) = _boundedWord(
                module,
                abi.encodeCall(IHookrNativeMechanicsModuleReadV1.requiresLockedFoundingPosition, (selections[i].config))
            );
            if (!ok || required > 1) revert InvalidNativeMechanicsModule();
            if (required == 1 && origin != NEW_TOKEN_ORIGIN) revert GuardRequiresLockedFoundingPosition();
            bytes calldata config = selections[i].config;
            uint256 guardEndBlock;
            uint256 configuredBaseFeePips;
            assembly ("memory-safe") {
                guardEndBlock := calldataload(add(config.offset, 0xa0))
                configuredBaseFeePips := calldataload(add(config.offset, 0xc0))
            }
            if (
                configuredBaseFeePips != baseLpFeePips || (required == 0 && guardEndBlock != 0)
                    || (required == 1
                        && (guardEndBlock <= block.number || guardEndBlock - block.number > MAX_GUARD_BLOCKS))
            ) revert InvalidNativeMechanicsModule();
        }
    }

    /// @notice Validates origin/base/guard bounds and records the exact module binding atomically.
    function validateAndRecordMarket(
        IHookrNativeMechanicsCatalogReadV1 registry,
        uint8 origin,
        uint24 baseLpFeePips,
        HookrModuleTypesV1.ModuleSelection[] calldata selections,
        bytes32 poolId
    ) public {
        (address module, bytes32 codeHash) = validateOrigin(registry, origin, baseLpFeePips, selections);
        recordMarket(poolId, module, codeHash);
    }

    /// @notice Reads cumulative guarded LP earnings only from the frozen, unchanged implementation.
    function guardLpEarned(address module, bytes32 expectedCodeHash, bytes32 poolId)
        public
        view
        returns (uint256 earned)
    {
        if (module == address(0)) return 0;
        if (module.codehash != expectedCodeHash) revert InvalidNativeMechanicsModule();
        (bool ok, uint256 amount) =
            _boundedWord(module, abi.encodeCall(IHookrNativeMechanicsModuleReadV1.guardLpEarnedQuote, (poolId)));
        if (!ok) revert InvalidNativeMechanicsModule();
        return amount;
    }

    /// @notice Records the exact native-mechanics implementation selected for one market.
    function recordMarket(bytes32 poolId, address module, bytes32 moduleCodeHash) public {
        if ((module == address(0)) != (moduleCodeHash == bytes32(0))) revert InvalidNativeMechanicsModule();
        GuardAccounting storage accounting = _guardStorage().pools[poolId];
        if (accounting.module != address(0) || accounting.moduleCodeHash != bytes32(0)) {
            revert InvalidGuardAccounting();
        }
        accounting.module = module;
        accounting.moduleCodeHash = moduleCodeHash;
    }

    /// @notice Returns the cumulative earned, quarantined, and pending quote amounts for a market.
    function guardAccounting(bytes32 poolId, address partnerRegistry)
        public
        view
        returns (
            address module,
            address treasury,
            uint256 cumulativeEarned,
            uint256 cumulativeWithheld,
            uint256 pending
        )
    {
        GuardAccounting storage accounting = _guardStorage().pools[poolId];
        module = accounting.module;
        treasury = IHookrNativeMechanicsTreasuryReadV1(partnerRegistry).treasuryBeneficiary();
        cumulativeEarned = guardLpEarned(module, accounting.moduleCodeHash, poolId);
        cumulativeWithheld = accounting.cumulativeWithheld;
        if (cumulativeEarned < cumulativeWithheld) revert InvalidGuardAccounting();
        pending = cumulativeEarned - cumulativeWithheld;
    }

    /// @notice Routes founding-position proceeds while quarantining newly earned guarded quote LP fees.
    /// @dev Public library execution uses DELEGATECALL, so transfers originate from the coordinator.
    function routeFoundingPositionFees(FeeRouteInput memory input) public {
        GuardAccounting storage accounting = _guardStorage().pools[input.poolId];
        uint256 recipientAmount0 = input.amount0;
        uint256 recipientAmount1 = input.amount1;
        uint256 cumulativeEarned = guardLpEarned(accounting.module, accounting.moduleCodeHash, input.poolId);
        if (cumulativeEarned < accounting.cumulativeWithheld) revert InvalidGuardAccounting();

        uint256 pending = cumulativeEarned - accounting.cumulativeWithheld;
        bool quoteIsCurrency0 = input.currency0 == input.quote;
        uint256 quoteCollected = quoteIsCurrency0 ? input.amount0 : input.amount1;
        uint256 withheld = pending < quoteCollected ? pending : quoteCollected;
        if (withheld != 0) {
            address treasury = IHookrNativeMechanicsTreasuryReadV1(input.partnerRegistry).treasuryBeneficiary();
            if (treasury == address(0)) revert InvalidTreasury();
            _refund(input.quote, treasury, withheld);
            if (quoteIsCurrency0) recipientAmount0 -= withheld;
            else recipientAmount1 -= withheld;
            accounting.cumulativeWithheld += withheld;
            emit GuardLpFeesWithheld(
                input.poolId, accounting.module, treasury, withheld, accounting.cumulativeWithheld, cumulativeEarned
            );
        }
        if (recipientAmount0 != 0) _refund(input.currency0, input.lpFeeRecipient, recipientAmount0);
        if (recipientAmount1 != 0) _refund(input.currency1, input.lpFeeRecipient, recipientAmount1);
        emit LpFeesCollected(input.poolId, input.lpFeeRecipient, recipientAmount0, recipientAmount1);
    }

    function _boundedWord(address target, bytes memory input) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(QUERY_GAS, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }

    function _refund(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
            return;
        }
        uint256 selfBefore = _balanceOf(token, address(this));
        uint256 toBefore = _balanceOf(token, to);
        bytes memory input = abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount);
        bool transferred;
        uint256 returnSize;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            transferred := call(gas(), token, 0, add(input, 0x20), mload(input), 0, 0x20)
            returnSize := returndatasize()
            word := mload(0)
        }
        if (!transferred || returnSize != 32 || word != 1) revert TransferFailed();
        uint256 selfAfter = _balanceOf(token, address(this));
        uint256 toAfter = _balanceOf(token, to);
        if (
            selfAfter > selfBefore || selfBefore - selfAfter != amount || toAfter < toBefore
                || toAfter - toBefore != amount
        ) revert TaxedTransfer();
    }

    function _balanceOf(address token, address account) private view returns (uint256 balance) {
        bytes memory input = abi.encodeWithSelector(bytes4(0x70a08231), account);
        (bool ok, uint256 result) = _boundedTokenWord(token, input);
        if (!ok) revert TransferFailed();
        return result;
    }

    function _boundedTokenWord(address target, bytes memory input) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(TOKEN_QUERY_GAS, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }

    function _guardStorage() private pure returns (GuardAccountingStorage storage accounting) {
        bytes32 slot = GUARD_ACCOUNTING_STORAGE_SLOT;
        assembly ("memory-safe") {
            accounting.slot := slot
        }
    }
}
