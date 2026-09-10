// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrModuleTypesV1} from "./HookrModuleTypesV1.sol";
import {
    IHookrNativeMechanicsCatalogReadV1,
    IHookrNativeMechanicsTreasuryReadV1
} from "./HookrNativeMechanicsCoordinatorLibV1.sol";

/// @notice Protocol-share tier read the admitting coordinator must expose alongside its treasury.
/// @dev The coordinator resolves exactly one share per creator address and this library proves the
///      frozen config carries that share. Nothing about the market's own fee split is an input.
interface IHookrNativeMechanicsProtocolShareReadV2 {
    function protocolShareBps(address creator) external view returns (uint24 shareBps);
}

interface IHookrNativeMechanicsModuleReadV2 {
    function requiresLockedFoundingPosition(bytes calldata config) external pure returns (bool required);
    function validateProtocolShare(bytes calldata config) external view returns (bool enforced);
    function protocolRecipient() external view returns (address recipient);
    function guardLpEarnedQuote(bytes32 poolId) external view returns (uint256 amount);
}

/// @title Hookr Native Mechanics Coordinator Library V2
/// @notice Bounded coordinator-side admission and guard-fee read boundary for the native block.
/// @dev V2 differences from V1, all admission-side: only `HookrNativeMechanicsBlockV2` (module
///      version 2) is admitted, admission proves the module's within-ceiling protocol share, that
///      the config's exact share equals the coordinator's own tier resolution for this creator, AND
///      that the module's immutable protocol recipient is the coordinator's own treasury
///      beneficiary, and `validateAndRecordMarket` returns the bound module so the coordinator can
///      require one. `HookrMarketCoordinatorV3`/`V4` keep using V1 with their already deployed
///      library. The guard-accounting storage slot is deliberately unchanged, so a coordinator may
///      read the same per-pool module binding through either library.
///
///      V2 no longer withholds guard-window LP fees at collect time. Base fee earned during the
///      guard belongs to the founding position like any other LP fee, and the protocol's revenue
///      comes from its share inside each opted-in add-on instead (docs/FEE_MODEL_V2.md §6).
library HookrNativeMechanicsCoordinatorLibV2 {
    bytes32 internal constant MODULE_KEY = keccak256("HOOKR_NATIVE_MECHANICS");
    bytes32 internal constant CONFIG_SCHEMA_HASH = keccak256(
        "HookrNativeMechanicsBlockV2.Config(bytes32 poolId,address kernel,address subject,address quote,address lockedLiquidityProvider,uint40 guardEndBlock,uint24 baseFeePips,uint24 maxFeePips,uint24 snipeTaxPips,uint16 surgeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint32 potEveryNBuys,uint96 maxBuyQuoteAmount,uint96 potMinBuyWei,address royaltyTo,address protocolRecipient,uint24 protocolShareBps)"
    );
    uint8 internal constant REQUIRED_PHASE_MASK = HookrModuleTypesV1.ALL_PHASES;
    /// @dev V2 keeps the V1 Config layout but carries its own schema string, and only V2 enforces
    ///      the protocol share, so this path admits version 2 exclusively.
    uint32 internal constant MIN_MODULE_VERSION = 2;
    uint32 internal constant MAX_MODULE_VERSION = 2;
    /// @dev Larger than V1's 75k because `validateProtocolShare` on a V2 module itself performs a
    ///      bounded `decimals()` read on a possibly cold ERC-20 quote.
    uint32 internal constant QUERY_GAS = 150_000;
    uint8 internal constant NEW_TOKEN_ORIGIN = 1;
    uint256 internal constant MAX_GUARD_BLOCKS = 100_000;
    uint256 internal constant TOKEN_QUERY_GAS = 50_000;
    bytes32 internal constant GUARD_ACCOUNTING_STORAGE_SLOT =
        keccak256("hookr.market.coordinator.native.mechanics.guard.accounting.v1");

    struct GuardAccounting {
        address module;
        bytes32 moduleCodeHash;
    }

    struct GuardAccountingStorage {
        mapping(bytes32 poolId => GuardAccounting accounting) pools;
    }

    struct FeeRouteInput {
        bytes32 poolId;
        address currency0;
        address currency1;
        address lpFeeRecipient;
        uint256 amount0;
        uint256 amount1;
    }

    error InvalidNativeMechanicsModule();
    error ProtocolShareTierMismatch(uint24 expected, uint24 actual);
    error GuardRequiresLockedFoundingPosition();
    error InvalidGuardAccounting();
    error TransferFailed();
    error TaxedTransfer();
    error NativeTransferFailed();

    event LpFeesCollected(bytes32 indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1);

    /// @notice Resolves the one canonical native block and rejects guard use on open-LP origins.
    /// @param treasuryReader Contract exposing `treasuryBeneficiary()` and `protocolShareBps()`;
    ///        the coordinator passes itself.
    /// @param creator Account opening the market, used by the coordinator's share-tier resolution.
    function validateOrigin(
        IHookrNativeMechanicsCatalogReadV1 registry,
        uint8 origin,
        uint24 baseLpFeePips,
        HookrModuleTypesV1.ModuleSelection[] calldata selections,
        address treasuryReader,
        address creator
    ) public view returns (address module, bytes32 codeHash) {
        for (uint256 i; i < selections.length; ++i) {
            HookrModuleTypesV1.ModuleSnapshot memory snapshot = registry.module(selections[i].moduleId);
            if (snapshot.moduleKey != MODULE_KEY) continue;
            if (
                module != address(0) || snapshot.version < MIN_MODULE_VERSION || snapshot.version > MAX_MODULE_VERSION
                    || snapshot.configSchemaHash != CONFIG_SCHEMA_HASH
                    || snapshot.executionMode != HookrModuleTypesV1.ExecutionMode.STATEFUL_V1
                    || snapshot.phaseMask != REQUIRED_PHASE_MASK || snapshot.implementation == address(0)
                    || snapshot.implementation.codehash != snapshot.implementationCodeHash
            ) revert InvalidNativeMechanicsModule();
            module = snapshot.implementation;
            codeHash = snapshot.implementationCodeHash;
            (bool ok, uint256 required) = _boundedWord(
                module,
                abi.encodeCall(IHookrNativeMechanicsModuleReadV2.requiresLockedFoundingPosition, (selections[i].config))
            );
            if (!ok || required > 1) revert InvalidNativeMechanicsModule();
            if (required == 1 && origin != NEW_TOKEN_ORIGIN) revert GuardRequiresLockedFoundingPosition();
            // V2 enforces one bounded protocol share paid to its own immutable treasury.
            // `validateConfig` is `pure` and cannot read that immutable, so admission proves it
            // through this read.
            (bool shareOk, uint256 enforced) = _boundedWord(
                module, abi.encodeCall(IHookrNativeMechanicsModuleReadV2.validateProtocolShare, (selections[i].config))
            );
            if (!shareOk || enforced != 1) revert InvalidNativeMechanicsModule();
            // The config may name any recipient the module accepts; admission additionally ties the
            // module's own immutable recipient to this coordinator's treasury beneficiary.
            (bool recipientOk, uint256 moduleRecipient) =
                _boundedWord(module, abi.encodeCall(IHookrNativeMechanicsModuleReadV2.protocolRecipient, ()));
            address treasury = IHookrNativeMechanicsTreasuryReadV1(treasuryReader).treasuryBeneficiary();
            if (!recipientOk || treasury == address(0) || moduleRecipient != uint256(uint160(treasury))) {
                revert InvalidNativeMechanicsModule();
            }
            bytes calldata config = selections[i].config;
            uint256 guardEndBlock;
            uint256 configuredBaseFeePips;
            uint256 configuredShareBps;
            assembly ("memory-safe") {
                guardEndBlock := calldataload(add(config.offset, 0xa0))
                configuredBaseFeePips := calldataload(add(config.offset, 0xc0))
                configuredShareBps := calldataload(add(config.offset, 0x260))
            }
            // `validateProtocolShare` above proved the config re-encodes canonically and carries a
            // within-ceiling share, so these raw words equal the decoded fields. The module bounds
            // the share; the coordinator alone decides which share inside that bound this market
            // gets, and the frozen config pins it for the pool's whole life.
            _requireTierShare(treasuryReader, creator, configuredShareBps);
            if (
                configuredBaseFeePips != baseLpFeePips || (required == 0 && guardEndBlock != 0)
                    || (required == 1
                        && (guardEndBlock <= block.number || guardEndBlock - block.number > MAX_GUARD_BLOCKS))
            ) revert InvalidNativeMechanicsModule();
        }
    }

    /// @notice Validates origin/base/guard bounds and records the exact module binding atomically.
    /// @return module The bound native-mechanics implementation, or zero when none was selected.
    function validateAndRecordMarket(
        IHookrNativeMechanicsCatalogReadV1 registry,
        uint8 origin,
        uint24 baseLpFeePips,
        HookrModuleTypesV1.ModuleSelection[] calldata selections,
        bytes32 poolId,
        address treasuryReader,
        address creator
    ) public returns (address module) {
        bytes32 codeHash;
        (module, codeHash) = validateOrigin(registry, origin, baseLpFeePips, selections, treasuryReader, creator);
        recordMarket(poolId, module, codeHash);
    }

    /// @dev Proves the frozen config's protocol share is exactly the one the coordinator resolves
    ///      for this creator. The read is gas-bounded like every other admission read, so a
    ///      coordinator that reverts or returns a short word fails admission closed.
    function _requireTierShare(address treasuryReader, address creator, uint256 configuredShareBps) private view {
        (bool tierOk, uint256 expected) = _boundedWord(
            treasuryReader, abi.encodeCall(IHookrNativeMechanicsProtocolShareReadV2.protocolShareBps, (creator))
        );
        if (!tierOk || expected > type(uint24).max) revert InvalidNativeMechanicsModule();
        if (expected != configuredShareBps) {
            // Both values are bounded to uint24 above and by the module's own ceiling.
            // forge-lint: disable-next-line(unsafe-typecast)
            revert ProtocolShareTierMismatch(uint24(expected), uint24(configuredShareBps));
        }
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
            _boundedWord(module, abi.encodeCall(IHookrNativeMechanicsModuleReadV2.guardLpEarnedQuote, (poolId)));
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

    /// @notice Returns the bound native module and its cumulative guard-window LP earnings.
    /// @dev Informational only. Nothing is withheld from a founding position any more, so there is
    ///      no quarantined or pending amount to report.
    function guardAccounting(bytes32 poolId) public view returns (address module, uint256 cumulativeEarned) {
        GuardAccounting storage accounting = _guardStorage().pools[poolId];
        module = accounting.module;
        cumulativeEarned = guardLpEarned(module, accounting.moduleCodeHash, poolId);
    }

    /// @notice Routes the whole founding-position collection to its fee recipient.
    /// @dev Public library execution uses DELEGATECALL, so transfers originate from the coordinator.
    ///      100% of both currencies goes to `lpFeeRecipient`: base fee earned during the guard
    ///      window belongs to the founding position like any other LP fee, and the protocol takes
    ///      its share inside the add-ons at swap time instead (docs/FEE_MODEL_V2.md §6).
    function routeFoundingPositionFees(FeeRouteInput memory input) public {
        if (input.amount0 != 0) _refund(input.currency0, input.lpFeeRecipient, input.amount0);
        if (input.amount1 != 0) _refund(input.currency1, input.lpFeeRecipient, input.amount1);
        emit LpFeesCollected(input.poolId, input.lpFeeRecipient, input.amount0, input.amount1);
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
