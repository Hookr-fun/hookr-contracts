// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Family pinger
/// @notice Keeps a family's due actions running: one call runs every zap vault, zap mesh and fee bridge of the family
///         that is ready, each on its own with a gas cap, and pays the caller a small tip from the pinger's budget.
interface IHookrFamilyPinger {
    error Reentered();
    error InvalidRewardRecipient(address rewardTo);
    error UnexpectedNative(address sender);

    /// @notice What an action is, which fixes the calls the pinger makes to it.
    /// @dev ZAP: a Zap Relay vault or a Zap Mesh: `ready()` then `zap(rewardTo)`. DRIP: a fee bridge: `ready()` then
    ///      `drip(rewardTo)`, or `record()` when it is not ready, so it can drip in a later block. PROTOCOL: a vault or
    ///      mesh: `payProtocol()` when `protocolOwed()` is above zero. The pinger's tip is earned by real work, read
    ///      from what the call returned: a zap that deployed quote, a drip that donated at least 1% of its bridge's
    ///      maxPerDrip, a payout that paid something. A record earns nothing.
    struct Action {
        address target;
        uint8 kind;
    }

    /// @notice One ping: who called, who was paid, which actions ran (bit i for action i) and the tip paid.
    event Pinged(address indexed caller, address indexed rewardTo, uint256 ran, uint256 tip);
    /// @notice An action that was due failed; the others still ran. `reason` is at most the first 256 bytes of what it
    ///         reverted with.
    event ActionFailed(uint8 indexed index, bytes reason);

    function factory() external view returns (address);
    /// @notice The actions, in the order they run.
    function actions() external view returns (Action[] memory);
    /// @notice The native tip one ping pays when an action did real work, from the pinger's budget.
    function tip() external view returns (uint128);
    /// @notice Fewest blocks between two tipped pings.
    function minBlocks() external view returns (uint32);
    /// @notice The gas each action gets: exactly this, or the action does not run.
    function gasPerAction() external view returns (uint32);
    /// @notice The block of the last tipped ping (zero before the first).
    function lastTipBlock() external view returns (uint64);
    /// @notice Which actions would run now: bit i for action i.
    function due() external view returns (uint256 mask);
    /// @notice Runs every action that is due. Anyone.
    /// @param rewardTo Receives the vaults' and bridges' own rewards and the pinger's tip.
    function ping(address rewardTo) external returns (uint256 ran);
    /// @notice Claims the pinger's native HookrRules claim into its budget: the path for a pinger named as a royalty
    ///         payee. Anyone.
    function collect(address rules) external returns (uint256 amount);
}

/// @title Family pinger factory
/// @notice Makes pingers at CREATE2 addresses keyed by (creator, salt), accepting only actions the Hookr factories made.
interface IHookrFamilyPingerFactory {
    error InvalidPinger(uint8 code);
    error InvalidAction(uint256 index);

    event PingerCreated(address indexed pinger, address indexed creator, uint256 actions, uint128 tip);

    /// @notice The Zap Relay accrual whose vaults may be actions.
    function zapAccrual() external view returns (address);
    /// @notice The Zap Mesh accrual whose meshes may be actions.
    function meshAccrual() external view returns (address);
    /// @notice The fee bridge factory whose bridges may be actions.
    function bridgeFactory() external view returns (address);
    function isPinger(address pinger) external view returns (bool);
    function create(
        IHookrFamilyPinger.Action[] calldata actions,
        uint128 tip,
        uint32 minBlocks,
        uint32 gasPerAction,
        bytes32 salt
    ) external returns (address pinger);
    function predict(
        address creator,
        IHookrFamilyPinger.Action[] calldata actions,
        uint128 tip,
        uint32 minBlocks,
        uint32 gasPerAction,
        bytes32 salt
    ) external view returns (address);
}
