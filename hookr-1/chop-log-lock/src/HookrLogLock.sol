// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ChopConfig, ChopFees, IChopIndexManager, IChopLog, IChopRewards, IChopStaking} from "./interfaces/IChop.sol";
import {IHookrLogLock} from "./interfaces/IHookrLogLock.sol";

/// @title HookrLogLock
/// @notice Opens a Chop log for a token, seeds its CHOP pair and holds the staked liquidity until an unlock time.
/// @dev One call wraps the token, adds the pair's first liquidity, stakes it and records who may collect its rewards
/// and when the stake unlocks. The contract has no owner and nothing in it can be changed after deployment.
///
/// Chop's staking token frees a stake ten minutes after it is made, so a lock has to be a holder Chop's contracts
/// cannot tell apart from any other: this contract. What it cannot do is bind Chop's own code. The log, the staking
/// token and the rewards contract sit behind beacons Chop can upgrade, and a position is only as safe as they are.
contract HookrLogLock is IHookrLogLock, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev The fees Chop's index manager requires of every log, in hundredths of a percent.
    uint16 private constant BURN_FEE = 1500;
    uint16 private constant BOND_FEE = 100;
    uint16 private constant DEBOND_FEE = 100;
    uint16 private constant BUY_FEE = 50;
    uint16 private constant SELL_FEE = 50;
    /// @dev The most Chop lets a log's partner take of each fee batch, in hundredths of a percent.
    uint16 private constant MAX_PARTNER_FEE = 500;
    /// @dev A log holds one token at full weight.
    uint256 private constant FULL_WEIGHT = 1e18;

    /// @notice Chop's registry, the only door through which a log is deployed.
    IChopIndexManager public immutable indexManager;
    /// @notice CHOP: the token every log opened here is paired with and rewarded in.
    IERC20 public immutable chop;
    /// @notice Receives the partner share of each log's fee batches, in log tokens. Zero when no share is taken.
    address public immutable partner;
    /// @notice The partner share of each fee batch, in hundredths of a percent.
    uint16 public immutable partnerFee;

    /// @dev The rest of Chop's canonical dependencies, read once at deployment. Chop sets them once.
    address private immutable STABLE;
    address private immutable FEE_ROUTER;
    address private immutable REWARDS_WHITELIST;
    address private immutable TWAP;
    address private immutable DEX_ADAPTER;

    /// @inheritdoc IHookrLogLock
    mapping(uint256 id => Position) public positions;
    /// @inheritdoc IHookrLogLock
    uint256 public count;
    /// @notice What each position has paid its beneficiary, per reward token. Compared against Chop's own count of
    /// what the position's rewards contract has paid this contract, so a claim anyone makes for the lock is never lost.
    mapping(uint256 id => mapping(address token => uint256)) public paid;

    /// @param indexManager_ Chop's index manager.
    /// @param partner_ Receives the partner share of every log opened here, or zero for none.
    /// @param partnerFee_ The partner share in hundredths of a percent, at most 500. Zero when `partner_` is zero.
    constructor(IChopIndexManager indexManager_, address partner_, uint16 partnerFee_) {
        if (partnerFee_ > MAX_PARTNER_FEE || (partner_ == address(0) && partnerFee_ != 0)) revert InvalidPartner();
        (address chop_, address stable, address feeRouter, address whitelist, address twap, address dexAdapter,) =
            indexManager_.canonicalConfig();
        if (chop_ == address(0)) revert NoCanonicalConfig();
        indexManager = indexManager_;
        chop = IERC20(chop_);
        partner = partner_;
        partnerFee = partnerFee_;
        STABLE = stable;
        FEE_ROUTER = feeRouter;
        REWARDS_WHITELIST = whitelist;
        TWAP = twap;
        DEX_ADAPTER = dexAdapter;
    }

    /// @inheritdoc IHookrLogLock
    function open(OpenParams calldata params) external nonReentrant returns (uint256 id, address log, uint256 staked) {
        if (params.token == address(0) || params.beneficiary == address(0)) revert ZeroAddress();
        if (params.tokenAmount == 0 || params.chopAmount == 0) revert ZeroAmount();
        if (block.timestamp > params.deadline) revert Expired();
        if (params.unlockTime <= block.timestamp) revert InvalidUnlockTime();

        log = _deployLog(params.token);
        address staking = IChopLog(log).lpStakingPool();
        IERC20 pair = IERC20(IChopLog(log).v2Pool());

        // The first wrap is open only to the log's creator and pays no fee.
        IERC20 token = IERC20(params.token);
        token.safeTransferFrom(msg.sender, address(this), params.tokenAmount);
        token.forceApprove(log, params.tokenAmount);
        IChopLog(log).bond(params.token, params.tokenAmount, 1);
        uint256 logTokens = IERC20(log).balanceOf(address(this));
        if (logTokens == 0) revert NothingMinted();

        // The pair is empty, so it takes both sides in full at the price the two amounts set.
        chop.safeTransferFrom(msg.sender, address(this), params.chopAmount);
        chop.forceApprove(log, params.chopAmount);
        IChopLog(log).addLiquidityV2(logTokens, params.chopAmount, 0, params.deadline);
        staked = pair.balanceOf(address(this));
        if (staked == 0) revert NothingMinted();

        pair.forceApprove(staking, staked);
        IChopStaking(staking).stake(address(this), staked);

        // Nothing may be left outside the lock: every wrapped token is paired and every liquidity token staked.
        if (
            IERC20(log).balanceOf(address(this)) != 0 || pair.balanceOf(address(this)) != 0
                || IERC20(staking).balanceOf(address(this)) != staked
        ) revert NothingMinted();

        id = ++count;
        positions[id] = Position({
            log: log,
            staking: staking,
            beneficiary: params.beneficiary,
            unlockTime: params.unlockTime,
            staked: staked,
            released: false
        });
        emit Opened(
            id, params.token, log, params.beneficiary, params.unlockTime, params.tokenAmount, params.chopAmount, staked
        );
    }

    /// @inheritdoc IHookrLogLock
    function collect(uint256 id) external nonReentrant {
        Position memory position = _positionOf(id);
        _collect(id, position);
    }

    /// @inheritdoc IHookrLogLock
    function release(uint256 id) external nonReentrant {
        Position memory position = _positionOf(id);
        if (position.released) revert AlreadyReleased();
        if (block.timestamp < position.unlockTime) revert Locked();
        positions[id].released = true;
        _collect(id, position);
        IERC20(position.staking).safeTransfer(position.beneficiary, position.staked);
        emit Released(id, position.beneficiary, position.staked);
    }

    /// @inheritdoc IHookrLogLock
    function setBeneficiary(uint256 id, address beneficiary) external {
        Position memory position = _positionOf(id);
        if (position.released) revert AlreadyReleased();
        if (beneficiary == address(0)) revert ZeroAddress();
        positions[id].beneficiary = beneficiary;
        emit BeneficiarySet(id, position.beneficiary, beneficiary);
    }

    /// @inheritdoc IHookrLogLock
    function extend(uint256 id, uint64 unlockTime) external {
        Position memory position = _positionOf(id);
        if (position.released) revert AlreadyReleased();
        if (unlockTime <= position.unlockTime) revert InvalidUnlockTime();
        positions[id].unlockTime = unlockTime;
        emit Extended(id, position.unlockTime, unlockTime);
    }

    /// @dev Deploys a canonical log for `token` with this contract as its creator.
    function _deployLog(address token) private returns (address log) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory weights = new uint256[](1);
        weights[0] = FULL_WEIGHT;
        bytes memory baseConfig = abi.encode(
            ChopConfig({partner: partner, debondCooldown: 0, hasTransferTax: false, blacklistTKNpTKNPoolV2: false}),
            ChopFees({
                burn: BURN_FEE,
                bond: BOND_FEE,
                debond: DEBOND_FEE,
                buy: BUY_FEE,
                sell: SELL_FEE,
                partner: partnerFee
            }),
            tokens,
            weights,
            address(0),
            false
        );
        // Paired token, reward token, then Chop's canonical dependencies. A CHOP pair names no reward router.
        bytes memory immutables =
            abi.encode(address(chop), address(chop), STABLE, FEE_ROUTER, REWARDS_WHITELIST, TWAP, DEX_ADAPTER);
        string memory symbol = IERC20Metadata(token).symbol();
        log = indexManager.deployNewIndex(
            string.concat("Chop ", symbol), string.concat("ch", symbol), baseConfig, immutables, address(this)
        );
        if (indexManager.creatorOf(log) != address(this)) revert NotCreator();
    }

    /// @dev Claims the position's matured rewards and pays the beneficiary everything the position's rewards contract has
    /// paid this contract and the beneficiary has not yet had. Chop's `claimReward` takes any caller, so rewards can
    /// reach the lock outside this call; Chop's per-wallet `realized` count still holds them, and each position has its
    /// own rewards contract, so the count is the position's own.
    function _collect(uint256 id, Position memory position) private {
        IChopRewards rewards = IChopRewards(IChopStaking(position.staking).POOL_REWARDS());
        rewards.claimReward(address(this));
        address[] memory tokens = rewards.getAllRewardsTokens();
        for (uint256 i; i < tokens.length; ++i) {
            (, uint256 realized) = rewards.rewards(tokens[i], address(this));
            uint256 owed = realized - paid[id][tokens[i]];
            if (owed != 0) {
                paid[id][tokens[i]] = realized;
                IERC20(tokens[i]).safeTransfer(position.beneficiary, owed);
                emit Collected(id, tokens[i], position.beneficiary, owed);
            }
        }
    }

    /// @dev A position, readable only by its beneficiary. A released position can still collect.
    function _positionOf(uint256 id) private view returns (Position memory position) {
        position = positions[id];
        if (position.log == address(0)) revert NoPosition();
        if (msg.sender != position.beneficiary) revert NotBeneficiary();
    }
}
