// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IHookrLaunchHook} from "./interfaces/IHookrLaunchHook.sol";

interface IHookrLaunchpadIdentity {
    function owner() external view returns (address);
    function poolManager() external view returns (IPoolManager);
}

interface IHookrRouterIdentity {
    function poolManager() external view returns (IPoolManager);
    function hook() external view returns (address);
}

/// @title HookrHookRegistry
/// @notice Append-only registry of reviewed hook families that new Hookr pools may select.
/// @dev Id zero is reserved for the launchpad's existing HookrHook path. A registration cannot be
///      edited or removed, so the hook and router addresses a creator reviews cannot change later.
///      Runtime code-hash checks do not make a proxy's delegated implementation immutable. The
///      owner must register non-upgradeable hook and router deployments only.
contract HookrHookRegistry {
    uint160 internal constant ALL_HOOK_FLAGS = (1 << 14) - 1;
    uint256 public constant MAX_HOOK_CONFIG_BYTES = 2048;

    struct HookDefinition {
        IHookrLaunchHook hook;
        address router;
        uint160 requiredFlags;
        bytes32 hookRuntimeHash;
        bytes32 routerRuntimeHash;
    }

    struct PendingSelection {
        uint32 hookId;
        bytes32 intentId;
        bytes config;
    }

    address public immutable launchpad;
    HookDefinition[] internal definitions;
    mapping(address token => uint32 hookId) public hookIdOf;
    mapping(address token => bytes32 configHash) public hookConfigHashOf;
    mapping(address token => bytes config) internal pendingConfigOf;
    mapping(address creator => PendingSelection selection) internal pendingSelectionOf;

    event HookRegistered(
        uint32 indexed hookId,
        address indexed hook,
        address indexed router,
        uint160 requiredFlags,
        bytes32 hookRuntimeHash,
        bytes32 routerRuntimeHash
    );
    event HookSelected(
        address indexed token, uint32 indexed hookId, address indexed hook, address router, bytes32 configHash
    );
    event HookSelectionStaged(
        address indexed creator, uint32 indexed hookId, bytes32 indexed intentId, bytes32 configHash
    );
    event HookSelectionCancelled(address indexed creator, uint32 indexed hookId, bytes32 indexed intentId);

    error NotOwner();
    error InvalidHook();
    error InvalidRouter();
    error UnknownHook();
    error NotLaunchpad();
    error InvalidSelection();

    constructor(address launchpad_) {
        if (launchpad_ == address(0)) revert InvalidHook();
        launchpad = launchpad_;
        definitions.push(); // id zero remains the legacy/default HookrHook path
    }

    /// @notice Register one immutable hook/router pair for future launches.
    function registerHook(IHookrLaunchHook hook, address router) external returns (uint32 hookId) {
        IHookrLaunchpadIdentity pad = IHookrLaunchpadIdentity(launchpad);
        if (msg.sender != pad.owner()) revert NotOwner();

        address hookAddress = address(hook);
        if (hookAddress.code.length == 0 || hook.launchpad() != launchpad) revert InvalidHook();
        if (address(hook.poolManager()) != address(pad.poolManager())) revert InvalidHook();

        uint160 requiredFlags = hook.REQUIRED_FLAGS();
        if (uint160(hookAddress) & ALL_HOOK_FLAGS != requiredFlags) revert InvalidHook();
        if (router.code.length == 0) revert InvalidRouter();
        IHookrRouterIdentity routerIdentity = IHookrRouterIdentity(router);
        if (address(routerIdentity.poolManager()) != address(pad.poolManager()) || routerIdentity.hook() != hookAddress)
        {
            revert InvalidRouter();
        }

        hookId = uint32(definitions.length);
        bytes32 hookRuntimeHash = hookAddress.codehash;
        bytes32 routerRuntimeHash = router.codehash;
        definitions.push(
            HookDefinition({
                hook: hook,
                router: router,
                requiredFlags: requiredFlags,
                hookRuntimeHash: hookRuntimeHash,
                routerRuntimeHash: routerRuntimeHash
            })
        );
        emit HookRegistered(hookId, hookAddress, router, requiredFlags, hookRuntimeHash, routerRuntimeHash);
    }

    function getHook(uint32 hookId) external view returns (HookDefinition memory definition) {
        return _getHook(hookId);
    }

    /// @notice Stage one registered hook for the caller's next intent-bound launch.
    /// @dev The nonzero intent binds the two transactions. The launchpad refuses a different
    ///      intent while a selection is pending, so a typo cannot silently use the default hook.
    function stageHook(uint32 hookId, bytes calldata config, bytes32 intentId) external {
        if (intentId == 0 || config.length > MAX_HOOK_CONFIG_BYTES) revert InvalidSelection();
        HookDefinition memory definition = _getHook(hookId);
        _requireCurrentCode(definition);
        pendingSelectionOf[msg.sender] = PendingSelection({hookId: hookId, intentId: intentId, config: config});
        emit HookSelectionStaged(msg.sender, hookId, intentId, keccak256(config));
    }

    function cancelStagedHook() external {
        PendingSelection storage selection = pendingSelectionOf[msg.sender];
        if (selection.hookId == 0) revert InvalidSelection();
        emit HookSelectionCancelled(msg.sender, selection.hookId, selection.intentId);
        delete pendingSelectionOf[msg.sender];
    }

    function stagedHook(address creator) external view returns (uint32 hookId, bytes32 intentId, bytes32 configHash) {
        PendingSelection storage selection = pendingSelectionOf[creator];
        return (selection.hookId, selection.intentId, keccak256(selection.config));
    }

    /// @notice Validate the creator's staged selection for an exact launch intent.
    /// @dev Binding the new token later in the same launch transaction consumes the selection.
    function validateStagedHook(address creator, bytes32 intentId) external view returns (uint32 hookId) {
        if (msg.sender != launchpad) revert NotLaunchpad();
        PendingSelection storage selection = pendingSelectionOf[creator];
        hookId = selection.hookId;
        if (hookId == 0) return 0;
        if (intentId == 0 || selection.intentId != intentId) revert InvalidSelection();
        HookDefinition memory definition = _getHook(hookId);
        _requireCurrentCode(definition);
    }

    /// @notice Bind a registered hook and its opaque config to one new token.
    /// @dev Only the launchpad can call this. The hook decodes and validates the config before
    ///      PoolManager initialization. The registry deletes the raw bytes after that boundary.
    function bindStagedHook(address creator, address token, uint32 hookId) external {
        if (msg.sender != launchpad) revert NotLaunchpad();
        PendingSelection storage selection = pendingSelectionOf[creator];
        if (token == address(0) || hookIdOf[token] != 0 || selection.hookId != hookId) revert InvalidSelection();
        HookDefinition memory definition = _getHook(hookId);
        _requireCurrentCode(definition);
        definition.hook.validateHookConfig(selection.config);
        bytes32 configHash = keccak256(selection.config);
        hookIdOf[token] = hookId;
        hookConfigHashOf[token] = configHash;
        pendingConfigOf[token] = selection.config;
        delete pendingSelectionOf[creator];
        emit HookSelected(token, hookId, address(definition.hook), definition.router, configHash);
    }

    /// @notice Return the selected hook and consume its raw launch config.
    /// @dev A revert later in the pool-open transaction also rolls this deletion back.
    function consumeForPool(address token)
        external
        returns (uint32 hookId, IHookrLaunchHook hook, bytes memory config)
    {
        if (msg.sender != launchpad) {
            revert NotLaunchpad();
        }
        hookId = hookIdOf[token];
        if (hookId == 0) return (0, IHookrLaunchHook(address(0)), bytes(""));
        HookDefinition memory definition = _getHook(hookId);
        _requireCurrentCode(definition);
        hook = definition.hook;
        config = pendingConfigOf[token];
        delete pendingConfigOf[token];
    }

    function hookForToken(address token, IHookrLaunchHook defaultHook)
        external
        view
        returns (uint32 hookId, IHookrLaunchHook selectedHook)
    {
        hookId = hookIdOf[token];
        if (hookId == 0) return (0, defaultHook);
        HookDefinition memory definition = _getHook(hookId);
        _requireCurrentCode(definition);
        return (hookId, definition.hook);
    }

    function hooksCount() external view returns (uint256) {
        return definitions.length - 1;
    }

    function _getHook(uint32 hookId) internal view returns (HookDefinition memory definition) {
        if (hookId == 0 || hookId >= definitions.length) revert UnknownHook();
        return definitions[hookId];
    }

    function _requireCurrentCode(HookDefinition memory definition) internal view {
        if (
            address(definition.hook).codehash != definition.hookRuntimeHash
                || definition.router.codehash != definition.routerRuntimeHash
        ) revert InvalidSelection();
    }
}
