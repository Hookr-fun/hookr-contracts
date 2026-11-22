// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrMatchVault
/// @notice Matches an approved asset with HOOKR on one approved ASSET/HOOKR pool per asset: a wallet brings only the
///         asset, the vault adds the HOOKR the pool's price asks for, and the full-range liquidity is minted as two
///         Uniswap v4 positions, the provider's and Hookr's, that the vault holds until the match's unlock time.
interface IHookrMatchVault {
    /// @notice The settings every new match reads. A stored match keeps the ones it was made with.
    struct Settings {
        /// @notice The provider's part of the minted liquidity, in basis points (5,000 to 7,500).
        uint16 providerShareBps;
        /// @notice The provider's part of the fees Hookr's position earns until it is swept, in basis points.
        uint16 hookrFeesToProviderBps;
        /// @notice The lock, in seconds (7 days to 26 weeks).
        uint32 lockSeconds;
        /// @notice The least HOOKR one match may add.
        uint128 minHookrPerMatch;
        /// @notice The most HOOKR one wallet may hold in live matches, over all pools.
        uint128 maxHookrPerWallet;
        /// @notice The most HOOKR in live matches, over all pools.
        uint128 globalCap;
        /// @notice The most HOOKR matched in one UTC day.
        uint128 dayCap;
        /// @notice Where Hookr's positions go when swept.
        address hookrSink;
    }

    /// @notice One approved pool's settings.
    struct PoolSettings {
        /// @notice The most HOOKR in live matches on the pool.
        uint128 poolCap;
        /// @notice The least in-range liquidity the pool must hold for a match (above 0).
        uint128 minPoolLiquidity;
        /// @notice The most the pool's tick, and the log's newest record, may differ from the log's average (10 to
        ///         500).
        uint24 bandTicks;
        /// @notice The corridor's lower tick: the pool's tick and the average must both be at or above it.
        int24 tickMin;
        /// @notice The corridor's upper tick: the pool's tick and the average must both be at or below it.
        int24 tickMax;
        /// @notice The average's window, in seconds (6 to 48 of the log's intervals).
        uint32 window;
        /// @notice The longest one record may stand inside the window, in seconds (1 to 4 of the log's intervals).
        uint32 maxStand;
        /// @notice The pool's price log.
        bytes32 logId;
    }

    /// @notice An approved pool as the vault stores it.
    struct PoolInfo {
        PoolKey key;
        /// @notice The approved asset: the pool's currency that is not HOOKR.
        address asset;
        /// @notice Whether HOOKR is the pool's currency0.
        bool hookrIs0;
        bool approved;
        /// @notice Whether new matches on the pool are paused.
        bool paused;
        /// @notice HOOKR in live matches on the pool.
        uint128 live;
        PoolSettings settings;
    }

    /// @notice One match.
    struct Match {
        /// @notice Who owns the match: collects its fees and withdraws the provider's position.
        address owner;
        PoolId poolId;
        /// @notice The provider's position (a Uniswap v4 PositionManager token).
        uint256 providerTokenId;
        /// @notice Hookr's position.
        uint256 hookrTokenId;
        uint128 providerLiquidity;
        uint128 hookrLiquidity;
        /// @notice The asset the provider brought.
        uint128 assetIn;
        /// @notice The HOOKR the vault added.
        uint128 hookrMatched;
        uint48 start;
        /// @notice From this time the owner may withdraw and anyone may sweep.
        uint48 unlockTime;
        /// @notice The provider's part of the fees on Hookr's position, frozen at entry.
        uint16 hookrFeesToProviderBps;
        bool withdrawn;
        bool swept;
    }

    /// @notice A deposit's inputs.
    struct DepositParams {
        PoolId poolId;
        /// @notice The most asset to bring; what a limit leaves unused is returned in the same transaction.
        uint256 assetAmount;
        /// @notice The least total liquidity the provider accepts.
        uint128 minLiquidity;
        /// @notice Who owns the match.
        address owner;
        uint256 deadline;
    }

    /// @notice What a deposit would do now. `ok` false carries the first refusal in `reason`.
    struct Quote {
        bool ok;
        /// @notice Empty when ok; else NOT_APPROVED, PAUSED, NO_AVERAGE, OUT_OF_CORRIDOR, PRICE_MOVING, POOL_TOO_THIN,
        ///         VAULT_EMPTY, BELOW_MINIMUM or RANGE_FULL.
        bytes32 reason;
        uint256 assetUsed;
        uint256 hookrMatched;
        uint128 liquidity;
        uint128 providerLiquidity;
        uint48 unlockTime;
        int24 poolTick;
        int24 averageTick;
        /// @notice HOOKR room left for this wallet, this pool, today, and in total (the last also bounded by the
        ///         vault's balance).
        uint256 roomWallet;
        uint256 roomPool;
        uint256 roomDay;
        uint256 roomTotal;
    }

    error InvalidWiring();
    error InvalidSettings(bytes32 what);
    error InvalidPool(bytes32 what);
    error InvalidRecipient(address recipient);
    error PoolNotApproved(PoolId poolId);
    error PoolAlreadyApproved(PoolId poolId);
    error AssetAlreadyApproved(address asset);
    error Paused();
    error NotPaused();
    error DeadlinePassed();
    error Reentrancy();
    error ManagerUnlocked();
    error PositionManagerChanged();
    error AmountMismatch(uint256 asked, uint256 arrived);
    error AverageUnavailable();
    error PriceOutOfCorridor(int24 poolTick, int24 averageTick);
    error PriceOutOfBand(int24 poolTick, int24 averageTick);
    error PoolTooThin();
    error RangeFull();
    error NotEnoughGas();
    error NothingAvailable();
    error BelowMinimum(uint256 hookrMatched, uint256 minimum);
    error LiquidityTooLow(uint128 liquidity, uint128 minimum);
    error MintMismatch();
    error UnknownMatch(uint256 matchId);
    error NotMatchOwner(address caller);
    error StillLocked(uint48 unlockTime);
    error AlreadyWithdrawn();
    error AlreadySwept();
    error OnlySelf();

    event PoolApproved(PoolId indexed poolId, address indexed asset, PoolKey key, PoolSettings settings);
    event PoolSettingsSet(PoolId indexed poolId, PoolSettings settings);
    event PoolPauseSet(PoolId indexed poolId, bool paused, address indexed by);
    event AllPauseSet(bool paused, address indexed by);
    event SettingsSet(Settings settings);
    event RulesListed(address indexed rules, bool listed);
    event PoolRetired(PoolId indexed poolId, address indexed asset, address indexed by);
    event Matched(
        uint256 indexed matchId,
        address indexed owner,
        PoolId indexed poolId,
        uint256 assetUsed,
        uint256 hookrMatched,
        uint128 providerLiquidity,
        uint128 hookrLiquidity,
        uint256 providerTokenId,
        uint256 hookrTokenId,
        uint48 unlockTime
    );
    event FeesCollected(uint256 indexed matchId, address indexed recipient, uint256 amount0, uint256 amount1);
    event Withdrawn(uint256 indexed matchId, address indexed recipient, uint256 providerTokenId);
    event Swept(uint256 indexed matchId, address indexed sink, uint256 hookrTokenId, bool feesCollected);
    event IdleWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Brings the asset, has the vault add the HOOKR and mints the match's two positions.
    function deposit(DepositParams calldata p)
        external
        returns (uint256 matchId, uint256 assetUsed, uint256 hookrMatched, uint128 liquidity, uint48 unlockTime);

    /// @notice Sends the match's uncollected fees to `recipient`: those of the provider's position while the vault
    ///         holds it, and the provider's part of those of Hookr's position until it is swept. The match's owner,
    ///         at any time.
    function collectFees(uint256 matchId, address recipient) external returns (uint256 amount0, uint256 amount1);

    /// @notice Sends the provider's position to `recipient`. The match's owner, from the unlock time.
    function withdraw(uint256 matchId, address recipient) external returns (uint256 providerTokenId);

    /// @notice Sends the last fees on Hookr's position to the match's owner, then Hookr's position to the sink.
    ///         Anyone, from the unlock time.
    function sweep(uint256 matchId) external returns (uint256 hookrTokenId);

    /// @notice Records the pool's price in its log when a record is due. Anyone.
    function record(PoolId poolId) external returns (bool written);

    function approvedPools() external view returns (PoolId[] memory);
    function pool(PoolId poolId) external view returns (PoolInfo memory);
    function quote(PoolId poolId, uint256 assetAmount, address owner) external view returns (Quote memory);
    function matchOf(uint256 matchId) external view returns (Match memory);
    function matchesOf(address owner, uint256 offset, uint256 limit) external view returns (uint256[] memory);
    function matchCount() external view returns (uint256);
    function pendingFees(uint256 matchId) external view returns (uint256 amount0, uint256 amount1);
    function available() external view returns (uint256 balance, uint256 roomDay, uint256 roomTotal);
    function settings() external view returns (Settings memory);
    function allPaused() external view returns (bool);
    function rulesListed(address rules) external view returns (bool);
    function liveOf(address owner) external view returns (uint256);
    function globalLive() external view returns (uint256);
    function matchedOn(uint256 day) external view returns (uint256);
}
