// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The parts of Chop's contracts on Robinhood Chain that HookrLogLock calls.
/// @dev Signatures and ABI shapes only, written from the verified deployments. No Chop source is compiled here.

/// @notice A log's settings, as the index manager decodes them from `baseConfig`.
struct ChopConfig {
    address partner;
    uint256 debondCooldown;
    bool hasTransferTax;
    bool blacklistTKNpTKNPoolV2;
}

/// @notice A log's fees in hundredths of a percent, as the index manager decodes them from `baseConfig`.
struct ChopFees {
    uint16 burn;
    uint16 bond;
    uint16 debond;
    uint16 buy;
    uint16 sell;
    uint16 partner;
}

/// @notice Chop's registry of logs. The only door through which its factory deploys a log.
interface IChopIndexManager {
    /// @notice The dependencies every log must name. Set once by Chop.
    function canonicalConfig()
        external
        view
        returns (
            address chop,
            address stable,
            address feeRouter,
            address rewardsWhitelist,
            address twap,
            address dexAdapter,
            address seeder
        );

    /// @notice Deploys a log, its staking token and its rewards contract, and creates the log's pair.
    /// @param owner Recorded as the log's creator. Must be the caller unless the caller is authorized by Chop.
    function deployNewIndex(
        string memory indexName,
        string memory indexSymbol,
        bytes memory baseConfig,
        bytes memory immutables,
        address owner
    ) external returns (address index);

    /// @notice The creator recorded for a log. Only the creator or Chop's seeder may make the first wrap.
    function creatorOf(address index) external view returns (address);
}

/// @notice A log: one token wrapped into a log token that trades against CHOP on a Uniswap v2 pair.
interface IChopLog {
    /// @notice Wraps `amount` of `token` and mints log tokens to the caller. The first wrap pays no fee.
    function bond(address token, uint256 amount, uint256 amountMintMin) external;

    /// @notice Adds log tokens and the paired token to the log's pair. The liquidity tokens go to the caller.
    /// @param slippage In thousandths: 0 accepts only the full amounts.
    function addLiquidityV2(uint256 logTokens, uint256 pairedTokens, uint256 slippage, uint256 deadline)
        external
        returns (uint256 liquidity);

    /// @notice The staking token that takes this log's liquidity tokens.
    function lpStakingPool() external view returns (address);

    /// @notice The log's pair.
    function v2Pool() external view returns (address);
}

/// @notice A log's staking token. One staked liquidity token mints one staking token.
interface IChopStaking {
    /// @notice Pulls `amount` liquidity tokens from the caller and mints the same amount of staking tokens to `user`.
    function stake(address user, uint256 amount) external;

    /// @notice The rewards contract that tracks this staking token.
    function POOL_REWARDS() external view returns (address);
}

/// @notice A log's rewards contract.
interface IChopRewards {
    /// @notice Pays `wallet` every matured reward, in each reward token.
    function claimReward(address wallet) external;

    /// @notice Every token this contract has ever paid as a reward.
    function getAllRewardsTokens() external view returns (address[] memory);

    /// @notice A wallet's reward record for a token. `realized` is everything ever paid to the wallet in that token.
    function rewards(address token, address wallet) external view returns (uint256 excluded, uint256 realized);
}
