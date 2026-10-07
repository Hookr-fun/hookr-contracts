// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../interfaces/IHookrOwnedRoots.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {HookrTokenDeployer} from "../libraries/HookrTokenDeployer.sol";
import {HookrLaunchChecks} from "../libraries/HookrLaunchChecks.sol";
import {HookrSettlement} from "../libraries/HookrSettlement.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrLauncherView} from "../interfaces/IHookrLauncherView.sol";
import {IHookrRecaptureRules} from "../interfaces/IHookrRecaptureRules.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {IHookrLauncher} from "../interfaces/IHookrLauncher.sol";

/// @title HookrLauncher
/// @notice Atomic funded Market Families. The family owner controls every LP position, except that no member's
///         principal can leave its pool before principalLockedUntil: the family's last Anti-Snipe guard end, or a
///         later block its launch chose (a dev buy's lock or a launchFamily member's lock end).
/// @dev Removal proceeds and fees go from the PoolManager straight to the chosen recipient, as tokens or as
///      PoolManager ERC-6909 claims, so no issuer action against this shared contract can lock an exit. The
///      Launcher holds no assets between calls: anything it holds while idle was sent by mistake and anyone may
///      sweep it. Any future custody here would have to be excluded from sweep. Each member is priced from the
///      creator's input and nothing rebalances members; only launchFamily's optional opening check compares their
///      opening prices, and it only refuses a launch outside the creator's tolerance (OpeningCheck). A family's
///      per-block Anti-Snipe buy cap is the sum of its members' caps.
///      The principal lock stops LP withdrawal only. It is not a supply lock: a creator holding the subject
///      outside the pools (retained new-token supply, dev-bought subject or existing-token holdings), or buying it
///      from a sibling pool it priced, can still sell it into a guarded pool and take buyers' quote during the guard.
///      A new-token launch may make dev buys, one through launchWithBuy or one per member through launchFamily: this
///      contract's only swaps, each on its member's pool right after that member's add, delivered to the creator.
///      The creator then holds at most MAX_DEV_BUY_BPS of supply, every dev buy's subject and the unplaced subject
///      together; subject in the bands returns with the principal once principalLockedUntil passes. The bound covers
///      launchWithBuy and launchFamily only: a creator contract that launches and then buys through a router in the
///      same transaction makes an ordinary, uncapped buy. launchFamily's retained cap (LaunchParams.maxRetainedBps)
///      also bounds what the creator holds of a new token when the launch returns, with or without a dev buy.
///      Every launch entry point takes `msg.value` equal to its native budgets plus the launch fee (IHookrLaunchFee:
///      zero at deploy, at most 0.01 of the native currency, set through the registry owner's timelock), exactly, and
///      pays the fee to the treasury's target before any pool opens.
///      Existing subjects are permissionless on-chain: this contract checks only that the token has code and
///      moves exact amounts on the creator's own transfers. Issuer powers, sell restrictions and Auto Burn's
///      dependence on transfers to the burn address are asset qualification, not Launcher checks.
///      Guards and principal locks are counted in this chain's block.number, the parent (L1) height on
///      Arbitrum-style chains, so their wall-clock length differs by chain. New tokens are created from this contract's
///      address by the linked library HookrTokenDeployer, which it runs by DELEGATECALL.
contract HookrLauncher is HookrReleased, IUnlockCallback, IHookrLauncherView, IHookrLauncher {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice One PoolManager liquidity change for a family member.
    /// @dev `to` receives removal proceeds and collected fees; on additions it is the payer. `claims` bit 0 and
    ///      bit 1 deliver currency0 and currency1 as PoolManager ERC-6909 claims instead of tokens.
    struct Request {
        bytes32 familyId;
        uint8 member;
        int256 liquidityDelta;
        uint256 bound0;
        uint256 bound1;
        address to;
        uint8 claims;
    }

    /// @notice One redemption of the caller's own PoolManager ERC-6909 claims.
    struct Redemption {
        address owner;
        Currency currency;
        uint256 amount;
        address to;
    }

    /// @notice A family transfer awaiting acceptance. `claims` is chosen by the current owner: bits (2i, 2i+1)
    ///         pay member i's currency0/currency1 fees to that owner as PoolManager ERC-6909 claims on acceptance.
    struct PendingTransfer {
        address to;
        uint16 claims;
    }

    /// @dev A family record. The first word packs `owner`, `memberCount` and `lockedUntil`; `lockedUntil` is at
    ///      most MAX_DEV_BUY_LOCK_BLOCKS past the launch block, so it fits in 64 bits. Every member shares `subject`
    ///      and `root`.
    struct Family {
        address owner;
        uint8 memberCount;
        uint64 lockedUntil;
        address subject;
        address root;
    }

    /// @dev A member's stored position in two words: the quote, the range and whether it launched with recapture,
    ///      then the liquidity. Its PoolKey is rebuilt from the family's subject and root. A member with no position
    ///      has `tickSpacing` zero, since the PoolManager initializes no pool with a tick spacing below 1.
    struct Range {
        Currency quote;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        bool recapture;
        uint128 liquidity;
    }

    /// @custom:storage-location erc7201:hookr.launcher
    /// @dev The reentrancy state lives in transient storage.
    struct State {
        uint256 nonce;
        mapping(bytes32 familyId => Family) families;
        mapping(bytes32 familyId => PendingTransfer) transfers;
        mapping(bytes32 familyId => mapping(uint8 member => Range)) ranges;
        mapping(PoolId => bytes32) poolFamily;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.launcher")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT = 0xe360b19a8732989700805aac9d6e452e852d1078d68e6b904d61b3d7a73a4200;
    uint8 private constant IDLE = 0;
    uint8 private constant BUSY = 2;
    uint8 private constant EXPECT_FAMILY = 3;
    uint8 private constant IN_CALLBACK = 4;
    uint8 private constant DONE = 5;
    uint8 private constant EXPECT_REDEEM = 6;
    uint8 private constant EXPECT_LAUNCH_BUY = 7;
    /// @dev HookrRules' own bound on guardEndBlock - block.number; a longer guard fails closed here.
    uint256 private constant MAX_GUARD_BLOCKS = 100_000;
    /// @notice A dynamic fee member's launch liquidity divided by this is its pool's minimum dynamic fee liquidity,
    ///         unless launchFamily's MemberKnobs.dynamicFeeLiquidityDivisor names another (2 to 10,000).
    uint256 public constant DYNAMIC_FEE_LIQUIDITY_DIVISOR = 100;
    /// @notice Existing-token salt that skips members whose PoolKey is already initialized instead of reverting.
    bytes32 public constant SKIP_TAKEN = bytes32(uint256(1));
    /// @dev The dev buy's fixed bounds. Private like HookrRules' dynamic fee windows: public getters would sit in the
    ///      dispatcher ahead of withdraw, addLiquidity and unlockCallback and cost every Launcher call about 130 gas.
    ///      MAX_DEV_BUY_BPS (500, 5%): most of the supply a creator holds when a launch with a dev buy returns, the
    ///      dev-bought subject (net of Auto Burn) plus the unplaced supply refunded to it.
    uint256 private constant MAX_DEV_BUY_BPS = 500;
    /// @dev MAX_DEV_BUY_LOCK_BLOCKS (2,628,000): longest DevBuy.lockBlocks, 365 days of 12-second parent blocks.
    uint256 private constant MAX_DEV_BUY_LOCK_BLOCKS = 2_628_000;
    /// @dev The retained cap of launch, launchAdvised and launchWithBuy: no cap and no FamilyRetained.
    uint256 private constant NOT_A_FAMILY_LAUNCH = type(uint256).max;

    /// @inheritdoc IHookrLauncher
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrLauncher
    IHookrRegistry public immutable registry;
    uint8 private transient _lock;
    bytes32 private transient _pending;
    /// @dev The pool of the dev buy whose swap is running, zero otherwise.
    bytes32 private transient _launchBuyPool;

    modifier idle() {
        if (_lock != IDLE) revert Reentered();
        _lock = BUSY;
        _;
        _lock = IDLE;
    }

    /// @dev Refuses a PoolManager, registry or linked library (HookrTokenDeployer, HookrLaunchChecks) without code, so
    ///      the libraries must be deployed before the launcher: one linked to an empty address would refuse every
    ///      new-token launch and launchFamily, and its fallback would answer the launch fee's functions with nothing.
    constructor(IPoolManager manager, IHookrRegistry _registry) {
        if (
            address(manager).code.length == 0 || address(_registry).code.length == 0
                || address(HookrTokenDeployer).code.length == 0 || address(HookrLaunchChecks).code.length == 0
        ) revert InvalidFamily();
        poolManager = manager;
        registry = _registry;
    }

    /// @inheritdoc IHookrLauncherView
    /// @notice Current owner of a family. Unknown families return zero.
    function familyOwner(bytes32 familyId) external view returns (address) {
        return _state().families[familyId].owner;
    }

    /// @inheritdoc IHookrLauncher
    function pendingFamilyOwner(bytes32 familyId) external view returns (address pendingOwner, uint16 claims) {
        PendingTransfer storage t = _state().transfers[familyId];
        return (t.to, t.claims);
    }

    /// @inheritdoc IHookrLauncher
    function memberCount(bytes32 familyId) external view returns (uint8) {
        return _state().families[familyId].memberCount;
    }

    /// @inheritdoc IHookrLauncherView
    function poolFamily(PoolId id) external view returns (bytes32) {
        return _state().poolFamily[id];
    }

    /// @inheritdoc IHookrLauncherView
    /// @notice The pool whose dev buy is swapping right now, or zero. Set only around each dev buy's swap, the only
    ///         swaps this contract sends, so an advisory can admit it as the family owner's own buy.
    function launchBuyPool() external view returns (PoolId) {
        return PoolId.wrap(_launchBuyPool);
    }

    /// @inheritdoc IHookrLauncher
    function position(bytes32 familyId, uint8 member) external view returns (Position memory p) {
        State storage s = _state();
        Range storage r = s.ranges[familyId][member];
        p.key = _positionKey(s.families[familyId], r);
        p.tickLower = r.tickLower;
        p.tickUpper = r.tickUpper;
        p.liquidity = r.liquidity;
    }

    /// @inheritdoc IHookrLauncher
    function principalLockedUntil(bytes32 familyId) external view returns (uint256) {
        return _state().families[familyId].lockedUntil;
    }

    /// @inheritdoc IHookrLauncher
    function memberKey(address subject, Currency quote, int24 tickSpacing, address rootAddress)
        external
        view
        returns (PoolKey memory key, bool available)
    {
        key = _key(subject, quote, tickSpacing, rootAddress);
        PoolId id = key.toId();
        (uint160 price,,,) = poolManager.getSlot0(id);
        available = price == 0 && !IHookrRoot(rootAddress).knownPool(id);
    }

    /// @inheritdoc IHookrLauncher
    function predictToken(address creator, Token calldata token) external view returns (address) {
        if (creator == address(0) || token.existing != address(0) || token.supply == 0) revert InvalidFunding();
        return HookrTokenDeployer.predict(address(this), creator, token.salt, token.name, token.symbol, token.supply);
    }

    /// @inheritdoc IHookrLauncher
    function launch(Token calldata token, address rootAddress, Member[] calldata members, uint256 deadline)
        external
        payable
        idle
        returns (bytes32 familyId, address subject)
    {
        (familyId, subject,) =
            _launch(token, rootAddress, members, new bytes[](members.length), new DevBuy[](0), deadline);
    }

    /// @inheritdoc IHookrLauncher
    function launchAdvised(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        uint256 deadline
    ) external payable idle returns (bytes32 familyId, address subject) {
        if (advisoryConfigs.length != members.length) revert InvalidFamily();
        (familyId, subject,) = _launch(token, rootAddress, members, advisoryConfigs, new DevBuy[](0), deadline);
    }

    /// @inheritdoc IHookrLauncher
    function launchWithBuy(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        DevBuy calldata buy,
        uint256 deadline
    ) external payable idle returns (bytes32 familyId, address subject, uint256 subjectOut) {
        if (advisoryConfigs.length != members.length) revert InvalidFamily();
        _checkBuy(token, members, buy);
        DevBuy[] memory buys = new DevBuy[](1);
        buys[0] = buy;
        return _launch(token, rootAddress, members, advisoryConfigs, buys, deadline);
    }

    /// @inheritdoc IHookrLauncher
    function launchFamily(LaunchParams calldata p)
        external
        payable
        idle
        returns (bytes32 familyId, address subject, uint256 subjectOut)
    {
        Member[] calldata members = p.members;
        if (p.advisoryConfigs.length != members.length) revert InvalidFamily();
        DevBuy[] calldata buys = p.buys;
        uint256 bought;
        for (uint256 k; k < buys.length; ++k) {
            _checkBuy(p.token, members, buys[k]);
            uint256 bit = uint256(1) << buys[k].member;
            if (bought & bit != 0) revert InvalidDevBuy();
            bought |= bit;
        }
        return _launch(p.token, p.root, members, p.advisoryConfigs, buys, p.deadline);
    }

    /// @dev Refuses a dev buy outside its bounds: a new token, a nonzero quoteIn of at most 2^127 - 1 and minSubjectOut,
    ///      a member of the family, a lock of at most MAX_DEV_BUY_LOCK_BLOCKS, and a member either unguarded
    ///      (guardEndBlock zero) or guarded past this block with a Snipe and a buy cap covering quoteIn.
    function _checkBuy(Token calldata token, Member[] calldata members, DevBuy calldata buy) private view {
        if (
            token.existing != address(0) || buy.quoteIn == 0 || buy.minSubjectOut == 0 || buy.member >= members.length
                || buy.quoteIn > uint128(type(int128).max) || buy.lockBlocks > MAX_DEV_BUY_LOCK_BLOCKS
        ) revert InvalidDevBuy();
        HookrTypes.RulesConfig calldata rules = members[buy.member].rules;
        uint256 guardEnd = rules.guardEndBlock;
        if (
            guardEnd != 0
                && (guardEnd <= block.number || buy.quoteIn > rules.maxBuyQuoteAmount || rules.snipeTaxPips == 0)
        ) revert InvalidDevBuy();
    }

    /// @dev Every launch. `buys` are checked dev buys, at most one per member. Under launchFamily (`msg.sig`) the
    ///      family's knobs, retained cap and opening check go through HookrLaunchChecks first; every other launch
    ///      skips them, with no retained cap and no FamilyRetained. The launch path never takes a constant argument
    ///      here: the optimizer would then copy this whole function once per constant. A family opens only while the
    ///      registry's rootOpenFor(root, msg.sender) holds: the registry's brakes for every root, and for an owned
    ///      root also its factory's answer for this caller (public, owner-only or paused).
    function _launch(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] memory advisoryConfigs,
        DevBuy[] memory buys,
        uint256 deadline
    ) private returns (bytes32 familyId, address subject, uint256 subjectOut) {
        State storage s = _state();
        IHookrRoot root = IHookrRoot(rootAddress);
        if (
            block.timestamp > deadline || members.length == 0 || members.length > 8
                || !IHookrOwnedRoots(address(registry)).rootOpenFor(rootAddress, msg.sender)
                || address(root.poolManager()) != address(poolManager)
        ) revert InvalidFamily();
        bool isNew = token.existing == address(0);
        if (isNew) {
            if (token.supply == 0) revert InvalidFunding();
            subject = HookrTokenDeployer.deploy(msg.sender, token.salt, token.name, token.symbol, token.supply);
        } else {
            if (
                token.supply != 0 || (token.salt != bytes32(0) && token.salt != SKIP_TAKEN)
                    || token.existing.code.length == 0
            ) {
                revert InvalidFunding();
            }
            subject = token.existing;
        }
        familyId = keccak256(abi.encode(block.chainid, address(this), msg.sender, ++s.nonce));
        uint256 lockedUntil;
        uint256 divisors;
        uint256 maxRetainedBps = NOT_A_FAMILY_LAUNCH;
        if (msg.sig == this.launchFamily.selector) {
            (lockedUntil, divisors, maxRetainedBps) = _checkFamily(familyId, subject);
        }
        PoolKey[] memory keys = new PoolKey[](members.length);
        Currency[] memory currencies = new Currency[](members.length + 1);
        uint256[] memory budgets = new uint256[](currencies.length);
        uint256[] memory balances = new uint256[](currencies.length);
        uint256[] memory spent = new uint256[](currencies.length);
        currencies[0] = Currency.wrap(subject);
        uint256 skipped;

        for (uint8 i; i < members.length; ++i) {
            Member calldata m = members[i];
            if (
                Currency.unwrap(m.quote) == subject || m.liquidity == 0 || m.liquidity > uint128(type(int128).max)
                    || m.tickLower >= m.tickUpper || (m.config.advisory == address(0) && advisoryConfigs[i].length != 0)
            ) revert InvalidFamily();
            for (uint256 j = 1; j <= i; ++j) {
                if (Currency.unwrap(currencies[j]) == Currency.unwrap(m.quote)) revert InvalidFamily();
            }
            currencies[i + 1] = m.quote;
            PoolKey memory key = _key(subject, m.quote, m.tickSpacing, rootAddress);
            bool subjectFirst = Currency.unwrap(key.currency0) == subject;
            PoolId id = key.toId();
            (uint160 price,,,) = poolManager.getSlot0(id);
            bool taken = price != 0 || root.knownPool(id);
            // A taken member's ERC-20 budgets are never pulled. A native quote is currency0 and its budget arrives
            // with msg.value either way, so a taken native member's budget is still counted, then refunded whole.
            if (!taken || Currency.unwrap(key.currency0) == address(0)) {
                budgets[i + 1] = subjectFirst ? m.amount1Max : m.amount0Max;
            }
            if (taken) {
                if (isNew || token.salt != SKIP_TAKEN) revert PoolExists(i, id);
                skipped |= uint256(1) << i;
                emit MemberSkipped(familyId, i, id);
                continue;
            }
            budgets[0] += subjectFirst ? m.amount0Max : m.amount1Max;
            keys[i] = key;
            s.ranges[familyId][i] = Range(m.quote, m.tickSpacing, m.tickLower, m.tickUpper, m.recapture.on, m.liquidity);
            s.poolFamily[id] = familyId;
            // Rules admit only this Launcher as LP until guardEndBlock, so no member's principal may leave before
            // the family's last guard ends: a sibling's withdrawable subject would otherwise drain a guarded pool.
            uint256 guardEnd = m.rules.guardEndBlock;
            if (guardEnd > block.number + MAX_GUARD_BLOCKS) revert GuardTooLong(i, guardEnd);
            if (guardEnd > lockedUntil) lockedUntil = guardEnd;
        }
        if (skipped == (uint256(1) << members.length) - 1) revert InvalidFamily();
        // Byte i of `buyOf` is one more than the index of member i's dev buy, zero for none.
        uint256 buyOf;
        for (uint256 k; k < buys.length; ++k) {
            DevBuy memory buy = buys[k];
            // A dev buy is collected with its member's liquidity budget and spent in full.
            budgets[buy.member + 1] += buy.quoteIn;
            uint256 until = block.number + buy.lockBlocks;
            if (until > lockedUntil) lockedUntil = until;
            buyOf |= (k + 1) << (8 * uint256(buy.member));
        }
        s.families[familyId] = Family(msg.sender, uint8(members.length), uint64(lockedUntil), subject, rootAddress);
        // Reserve every member's budget before initializing any pool.
        uint256 nativeRequired;
        for (uint256 i; i < currencies.length; ++i) {
            Currency currency = currencies[i];
            if (i == 0 && isNew) {
                if (budgets[0] > token.supply) revert InvalidFunding();
            } else if (Currency.unwrap(currency) == address(0)) {
                nativeRequired = budgets[i];
                balances[i] = address(this).balance - msg.value;
            } else {
                balances[i] = HookrSettlement.balance(currency, address(this));
                uint256 payerBefore = HookrSettlement.balance(currency, msg.sender);
                if (budgets[i] != 0) {
                    IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), budgets[i]);
                }
                if (
                    HookrSettlement.balance(currency, address(this)) != balances[i] + budgets[i]
                        || HookrSettlement.balance(currency, msg.sender) != payerBefore - budgets[i]
                ) revert InvalidFunding();
            }
        }
        _payLaunchFee(familyId, nativeRequired);
        for (uint8 i; i < members.length; ++i) {
            if ((skipped >> i) & 1 != 0) continue;
            Member calldata m = members[i];
            PoolKey memory key = keys[i];
            HookrTypes.PoolConfig memory config = m.config;
            config.subject = Currency.wrap(subject);
            config.quote = m.quote;
            config.liquidityOwner = address(this);
            root.initializePool(key, config, _rulesData(m, i, divisors), advisoryConfigs[i], m.sqrtPriceX96);
            Request memory request =
                Request(familyId, i, int256(uint256(m.liquidity)), m.amount0Max, m.amount1Max, msg.sender, 0);
            uint256 paid0;
            uint256 paid1;
            uint256 k = uint8(buyOf >> (8 * uint256(i)));
            if (k != 0) {
                DevBuy memory buy = buys[k - 1];
                uint256 out;
                (paid0, paid1, out) = _executeWithBuy(request, buy.quoteIn, m.sqrtPriceX96);
                if (out < buy.minSubjectOut) revert DevBuySlippage(out, buy.minSubjectOut);
                subjectOut += out;
            } else {
                (paid0, paid1) = _execute(request);
            }
            bool subjectFirst = Currency.unwrap(key.currency0) == subject;
            spent[0] += subjectFirst ? paid0 : paid1;
            spent[i + 1] = subjectFirst ? paid1 : paid0;
            if (k != 0) spent[i + 1] += buys[k - 1].quoteIn;
            emit MemberLaunched(familyId, i, key.toId(), Currency.unwrap(m.quote), m.liquidity);
        }
        for (uint256 i; i < currencies.length; ++i) {
            uint256 supplied = i == 0 && isNew ? token.supply : budgets[i];
            uint256 refund = supplied - spent[i];
            if (i == 0 && isNew) {
                uint256 held = subjectOut + refund;
                if (buys.length != 0) {
                    // floor(supply * MAX_DEV_BUY_BPS / 10_000) for any supply: 10_000 is a multiple of MAX_DEV_BUY_BPS.
                    uint256 cap = token.supply / (10_000 / MAX_DEV_BUY_BPS);
                    if (held > cap) revert DevBuyAboveCap(held, cap);
                }
                if (maxRetainedBps != NOT_A_FAMILY_LAUNCH) {
                    // floor(supply * maxRetainedBps / 10_000), maxRetainedBps at most 10,000 (HookrLaunchChecks).
                    uint256 cap =
                        token.supply / 10_000 * maxRetainedBps + token.supply % 10_000 * maxRetainedBps / 10_000;
                    if (held > cap) revert RetainedAboveCap(held, cap);
                    emit FamilyRetained(familyId, held, cap);
                }
            }
            if (HookrSettlement.balance(currencies[i], address(this)) != balances[i] + refund) revert InvalidFunding();
            HookrSettlement.send(currencies[i], msg.sender, refund);
            if (HookrSettlement.balance(currencies[i], address(this)) != balances[i]) revert InvalidFunding();
        }
        emit FamilyLaunched(familyId, msg.sender, subject, rootAddress);
    }

    /// @dev Takes msg.value as the native budgets plus the launch fee, exactly, and pays the fee to the treasury's
    ///      target before any pool opens. At a zero fee it calls nothing.
    function _payLaunchFee(bytes32 familyId, uint256 nativeRequired) private {
        HookrLaunchChecks.LaunchFeeTerms storage t = HookrLaunchChecks.feeTerms();
        uint256 fee = t.fee;
        if (msg.value != nativeRequired + fee) revert InvalidFunding();
        if (fee != 0) {
            address target = IHookrTreasury(t.treasury).target();
            (bool ok,) = target.call{value: fee}("");
            if (!ok) revert LaunchFeeUndelivered(target, fee);
            emit LaunchFeePaid(familyId, target, fee);
        }
    }

    /// @dev Runs HookrLaunchChecks.checkFamily by DELEGATECALL on launchFamily's own calldata, the call now running:
    ///      `familyId`, `subject` and the PoolManager, then launchFamily's arguments byte for byte, with the offset of
    ///      its one argument moved past the three words put before it, so the library reads exactly the LaunchParams
    ///      this call decoded. Bubbles the library's revert. Returns the latest member lockEndBlock, the members'
    ///      packed divisors and the checked retained cap.
    function _checkFamily(bytes32 familyId, address subject)
        private
        returns (uint256 lockEnd, uint256 divisors, uint256 maxRetainedBps)
    {
        address checks = address(HookrLaunchChecks);
        bytes4 selector = HookrLaunchChecks.checkFamily.selector;
        IPoolManager manager = poolManager;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), familyId)
            mstore(add(ptr, 0x24), subject)
            mstore(add(ptr, 0x44), manager)
            mstore(add(ptr, 0x64), add(calldataload(4), 0x80))
            calldatacopy(add(ptr, 0x84), 4, sub(calldatasize(), 4))
            if iszero(delegatecall(gas(), checks, ptr, add(calldatasize(), 0x80), ptr, 0x60)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), 0x60) { revert(0, 0) }
            lockEnd := mload(ptr)
            divisors := mload(add(ptr, 0x20))
            maxRetainedBps := mload(add(ptr, 0x40))
        }
    }

    /// @inheritdoc IHookrLauncher
    function withdraw(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint256 deadline
    ) external idle returns (uint256 amount0, uint256 amount1) {
        return _withdraw(familyId, member, liquidity, min0, min1, recipient, 0, deadline);
    }

    /// @inheritdoc IHookrLauncher
    function withdrawWithClaims(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint8 claims,
        uint256 deadline
    ) external idle returns (uint256 amount0, uint256 amount1) {
        return _withdraw(familyId, member, liquidity, min0, min1, recipient, claims, deadline);
    }

    /// @inheritdoc IHookrLauncher
    function transferFamily(bytes32 familyId, address newOwner, uint16 claims) external idle {
        State storage s = _state();
        Family storage f = s.families[familyId];
        if (f.owner != msg.sender) revert NotOwner();
        if (newOwner == address(this) || newOwner == address(poolManager)) revert InvalidRecipient(newOwner);
        if (uint256(claims) >> (2 * uint256(f.memberCount)) != 0) revert InvalidClaims(claims);
        s.transfers[familyId] = PendingTransfer(newOwner, claims);
        emit FamilyTransferStarted(familyId, msg.sender, newOwner, claims);
    }

    /// @inheritdoc IHookrLauncher
    function acceptFamily(bytes32 familyId) external idle {
        State storage s = _state();
        PendingTransfer memory t = s.transfers[familyId];
        if (msg.sender != t.to) revert NotPendingOwner(familyId, msg.sender);
        Family storage f = s.families[familyId];
        uint8 n = f.memberCount;
        address previous = f.owner;
        delete s.transfers[familyId];
        // Earned fees belong to the old owner. Transfer only the remaining position.
        for (uint8 i; i < n; ++i) {
            Range storage r = s.ranges[familyId][i];
            if (r.liquidity != 0) {
                PoolKey memory key = _positionKey(f, r);
                _collect(
                    familyId,
                    i,
                    key,
                    HookrSettlement.balance(key.currency0, address(this)),
                    HookrSettlement.balance(key.currency1, address(this)),
                    previous,
                    uint8((t.claims >> (2 * i)) & 3)
                );
            }
        }
        f.owner = msg.sender;
        emit FamilyTransferred(familyId, msg.sender);
    }

    /// @inheritdoc IHookrLauncher
    function addLiquidity(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint128 max0,
        uint128 max1,
        uint256 deadline
    ) external payable idle returns (uint256 amount0, uint256 amount1) {
        State storage s = _state();
        Family storage f = s.families[familyId];
        if (f.owner != msg.sender) revert NotOwner();
        if (member >= f.memberCount || liquidity == 0 || block.timestamp > deadline) revert InvalidFamily();
        Range storage r = s.ranges[familyId][member];
        uint128 held = r.liquidity;
        if (uint256(held) + liquidity > uint128(type(int128).max)) revert InvalidFunding();
        PoolKey memory key = _positionKey(f, r);
        uint256 nativeRequired = Currency.unwrap(key.currency0) == address(0) ? max0 : 0;
        if (msg.value != nativeRequired) revert InvalidFunding();
        uint256 before0 = HookrSettlement.balance(key.currency0, address(this));
        uint256 before1 = HookrSettlement.balance(key.currency1, address(this));
        if (held != 0) _collect(familyId, member, key, before0, before1, msg.sender, 0);
        before0 -= nativeRequired;
        _fund(key.currency0, max0);
        _fund(key.currency1, max1);
        (amount0, amount1) = _execute(Request(familyId, member, int256(uint256(liquidity)), max0, max1, msg.sender, 0));
        r.liquidity = held + liquidity;
        HookrSettlement.send(key.currency0, msg.sender, uint256(max0) - amount0);
        HookrSettlement.send(key.currency1, msg.sender, uint256(max1) - amount1);
        if (
            HookrSettlement.balance(key.currency0, address(this)) != before0
                || HookrSettlement.balance(key.currency1, address(this)) != before1
        ) revert InvalidFunding();
        emit LiquidityAdded(familyId, member, liquidity, amount0, amount1);
    }

    /// @inheritdoc IHookrLauncher
    function redeem(Currency currency, uint256 amount, address recipient) external idle {
        if (amount == 0) revert InvalidAmount(amount);
        if (recipient == address(0) || recipient == address(this) || recipient == address(poolManager)) {
            revert InvalidRecipient(recipient);
        }
        bytes memory data = abi.encode(Redemption(msg.sender, currency, amount, recipient));
        _pending = keccak256(data);
        _lock = EXPECT_REDEEM;
        poolManager.unlock(data);
        if (_lock != DONE) revert InvalidCallback();
        _lock = BUSY;
        emit ClaimsRedeemed(msg.sender, currency, recipient, amount);
    }

    /// @inheritdoc IHookrLauncher
    function sweep(Currency currency, address recipient) external idle returns (uint256 amount) {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);
        amount = HookrSettlement.balance(currency, address(this));
        if (amount == 0) revert InvalidAmount(amount);
        HookrSettlement.send(currency, recipient, amount);
        emit Swept(currency, recipient, amount);
    }

    function _withdraw(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint8 claims,
        uint256 deadline
    ) private returns (uint256 amount0, uint256 amount1) {
        State storage s = _state();
        Family storage f = s.families[familyId];
        if (f.owner != msg.sender) revert NotOwner();
        if (
            member >= f.memberCount || recipient == address(0) || recipient == address(this)
                || recipient == address(poolManager) || block.timestamp > deadline
        ) revert InvalidFamily();
        if (claims > 3) revert InvalidClaims(claims);
        Range storage r = s.ranges[familyId][member];
        uint128 held = r.liquidity;
        if (liquidity > held) revert InvalidFamily();
        PoolKey memory key = _positionKey(f, r);
        if (held != 0) {
            if (liquidity != 0) {
                // Same parent clock and comparison as HookrRules.beforeAddLiquidity; family-wide.
                uint256 lockedUntil = f.lockedUntil;
                if (block.number < lockedUntil) revert PrincipalLocked(familyId, member, lockedUntil);
                r.liquidity = held - liquidity;
            }
            uint256 before0 = HookrSettlement.balance(key.currency0, address(this));
            uint256 before1 = HookrSettlement.balance(key.currency1, address(this));
            (amount0, amount1) =
                _execute(Request(familyId, member, -int256(uint256(liquidity)), min0, min1, recipient, claims));
            if (
                HookrSettlement.balance(key.currency0, address(this)) != before0
                    || HookrSettlement.balance(key.currency1, address(this)) != before1
            ) revert InvalidFunding();
        } else if (!r.recapture || (min0 | min1) != 0) {
            // A recapture member stays collectable after its owner withdrew all of it, since later arb recaptures can
            // still accrue to it: an empty position pays nothing and calls no PoolManager, so a minimum is refused.
            revert InvalidFamily();
        }
        // The liquidity owner accrual follows the position's fees, so an owner that can collect fees (a partner
        // launcher or a locker) never strands it, also after withdrawing all of the position.
        if (r.recapture) {
            (IHookrRecaptureRules rules, PoolId id) = _accrualOf(f, key);
            rules.claimPool(id, recipient);
        }
        emit LiquidityRemoved(familyId, member, liquidity, amount0, amount1);
    }

    function _fund(Currency currency, uint256 amount) private {
        if (Currency.unwrap(currency) == address(0) || amount == 0) return;
        uint256 beforeBalance = HookrSettlement.balance(currency, address(this));
        uint256 beforePayer = HookrSettlement.balance(currency, msg.sender);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        if (
            HookrSettlement.balance(currency, address(this)) != beforeBalance + amount
                || HookrSettlement.balance(currency, msg.sender) != beforePayer - amount
        ) revert InvalidFunding();
    }

    /// @dev `before0` and `before1` are this contract's balances of the key's currencies before the collection.
    function _collect(
        bytes32 familyId,
        uint8 member,
        PoolKey memory key,
        uint256 before0,
        uint256 before1,
        address recipient,
        uint8 claims
    ) private {
        _execute(Request(familyId, member, 0, 0, 0, recipient, claims));
        if (
            HookrSettlement.balance(key.currency0, address(this)) != before0
                || HookrSettlement.balance(key.currency1, address(this)) != before1
        ) revert InvalidFunding();
    }

    /// @dev Member `i`'s Rules data (HookrRules.bind): its config alone, or the config and its HookrTypes.RulesKnobs
    ///      when it has dynamic fees, arb recapture or a knob off its default, with its RecaptureConfig after them when
    ///      it has arb recapture. Its knobs are launchFamily's MemberKnobs (`MemberKnobs`), all zero under every other
    ///      launch. A dynamic fee member's minimum dynamic fee liquidity is its launch liquidity divided by its divisor
    ///      (bits [16i, 16i + 16) of `divisors`; zero: DYNAMIC_FEE_LIQUIDITY_DIVISOR), at least 1 and at most
    ///      2^96 - 1, and four zero tempo knobs are the default tempo.
    function _rulesData(Member calldata m, uint256 i, uint256 divisors) private pure returns (bytes memory) {
        // The six RulesKnobs words, in their ABI order: the minimum dynamic fee liquidity, the four tempo knobs and the
        // Snipe curve.
        uint256[6] memory k;
        if (msg.sig == HookrLauncher.launchFamily.selector) {
            LaunchParams calldata p;
            assembly ("memory-safe") {
                p := add(4, calldataload(4))
            }
            MemberKnobs calldata knobs = p.knobs[i];
            // MemberKnobs' last five words are those knobs in the same order. Copied unchecked: a word wider than its
            // type passes through, and the Rules' decoder refuses it.
            assembly ("memory-safe") {
                calldatacopy(add(k, 0x20), add(knobs, 0x60), 0xa0)
            }
        }
        if (m.rules.dynamicFeeSens != 0) {
            uint256 divisor = uint16(divisors >> (16 * i));
            uint256 minimum = m.liquidity / (divisor == 0 ? DYNAMIC_FEE_LIQUIDITY_DIVISOR : divisor);
            if (minimum == 0) minimum = 1;
            if (minimum > type(uint96).max) minimum = type(uint96).max;
            k[0] = minimum;
            if (k[1] | k[2] | k[3] | k[4] == 0) {
                k[1] = HookrTypes.DEFAULT_WINDOW_SECONDS;
                k[2] = HookrTypes.DEFAULT_RESET_SECONDS;
                k[3] = HookrTypes.DEFAULT_CARRY_BPS;
                k[4] = HookrTypes.DEFAULT_MOVE_TICKS;
            }
        }
        if (m.recapture.on) return abi.encode(m.rules, k, m.recapture);
        if (k[0] | k[1] | k[2] | k[3] | k[4] | k[5] == 0) return abi.encode(m.rules);
        return abi.encode(m.rules, k);
    }

    /// @inheritdoc IHookrLauncher
    function claimRecapture(bytes32 familyId, uint8 member, address to) external idle returns (uint256) {
        State storage s = _state();
        Family storage f = s.families[familyId];
        if (f.owner != msg.sender) revert NotOwner();
        (IHookrRecaptureRules rules, PoolId id) = _accrualOf(f, _positionKey(f, s.ranges[familyId][member]));
        return rules.claimPool(id, to);
    }

    /// @dev The Rules holding a member's recapture accrual, and the member's pool. Reads the one field it needs from the
    ///      root's `poolConfig` answer, its third word (`rules`), without decoding the other thirteen. Like the decoded
    ///      read, it bubbles a failed call's revert and reverts on a short answer or a `rules` word that is not an
    ///      address.
    function _accrualOf(Family storage f, PoolKey memory key)
        private
        view
        returns (IHookrRecaptureRules rules, PoolId id)
    {
        id = key.toId();
        address root = f.root;
        bytes4 selector = IHookrRoot.poolConfig.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), id)
            // Copy the first three words of the answer: subject, quote, rules.
            if iszero(staticcall(gas(), root, ptr, 0x24, ptr, 0x60)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            // A PoolConfig is fourteen static words.
            if lt(returndatasize(), 0x1c0) { revert(0, 0) }
            rules := mload(add(ptr, 0x40))
            if shr(160, rules) { revert(0, 0) }
        }
    }

    function _execute(Request memory request) private returns (uint256 amount0, uint256 amount1) {
        bytes memory data = abi.encode(request);
        _pending = keccak256(data);
        _lock = EXPECT_FAMILY;
        (amount0, amount1) = abi.decode(poolManager.unlock(data), (uint256, uint256));
        if (_lock != DONE) revert InvalidCallback();
        _lock = BUSY;
    }

    /// @dev A member's launch add followed by its dev buy, in one unlock.
    function _executeWithBuy(Request memory request, uint256 quoteIn, uint160 launchPrice)
        private
        returns (uint256 amount0, uint256 amount1, uint256 subjectOut)
    {
        bytes memory data = abi.encode(request, quoteIn, launchPrice);
        _pending = keccak256(data);
        _lock = EXPECT_LAUNCH_BUY;
        (amount0, amount1, subjectOut) = abi.decode(poolManager.unlock(data), (uint256, uint256, uint256));
        if (_lock != DONE) revert InvalidCallback();
        _lock = BUSY;
    }

    /// @inheritdoc IUnlockCallback
    /// @notice Runs only the pending family position change, launch add and dev buy, or claim redemption.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        uint8 mode = _lock;
        if (
            msg.sender != address(poolManager)
                || (mode != EXPECT_FAMILY && mode != EXPECT_REDEEM && mode != EXPECT_LAUNCH_BUY)
                || keccak256(data) != _pending
        ) revert InvalidCallback();
        _lock = IN_CALLBACK;
        delete _pending;
        if (mode == EXPECT_FAMILY) {
            (uint256 amount0, uint256 amount1) = _modify(abi.decode(data, (Request)));
            result = abi.encode(amount0, amount1);
        } else if (mode == EXPECT_LAUNCH_BUY) {
            (Request memory request, uint256 quoteIn, uint160 launchPrice) =
                abi.decode(data, (Request, uint256, uint160));
            (uint256 amount0, uint256 amount1) = _modify(request);
            result = abi.encode(amount0, amount1, _devBuy(request, quoteIn, launchPrice));
        } else {
            Redemption memory r = abi.decode(data, (Redemption));
            poolManager.burn(r.owner, r.currency.toId(), r.amount);
            HookrSettlement.takeTo(poolManager, r.currency, r.to, r.amount);
        }
        _lock = DONE;
    }

    /// @dev The dev buy, straight after the member's add settled: an exact-input buy of `quoteIn` from the launch
    ///      price, filled in full, paid from this contract's funded balance, with the subject taken from the
    ///      PoolManager straight to the family owner (`request.to`, the launch caller). Refuses a pool whose price
    ///      moved since initialization, which only a swap inside this unlock could do.
    function _devBuy(Request memory request, uint256 quoteIn, uint160 launchPrice)
        private
        returns (uint256 subjectOut)
    {
        State storage s = _state();
        Family storage f = s.families[request.familyId];
        Range storage r = s.ranges[request.familyId][request.member];
        PoolKey memory key = _positionKey(f, r);
        PoolId id = key.toId();
        (uint160 price,,,) = poolManager.getSlot0(id);
        if (price != launchPrice || request.to != f.owner) revert InvalidDevBuy();
        Currency quote = r.quote;
        bool quoteIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
        _launchBuyPool = PoolId.unwrap(id);
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams(
                quoteIs0, -int256(quoteIn), quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        _launchBuyPool = 0;
        (int128 quoteDelta, int128 subjectDelta) =
            quoteIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 paid = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : 0;
        // The root refuses a buy whose subject delta is negative.
        if (paid != quoteIn) revert DevBuyPartialFill(paid, quoteIn);
        subjectOut = uint256(uint128(subjectDelta));
        (uint160 priceAfter,,,) = poolManager.getSlot0(id);
        HookrSettlement.pay(poolManager, quote, address(this), quoteIn);
        HookrSettlement.takeTo(poolManager, Currency.wrap(f.subject), request.to, subjectOut);
        emit DevBuyExecuted(
            request.familyId,
            id,
            request.to,
            request.member,
            quoteIn,
            subjectOut,
            launchPrice,
            priceAfter,
            f.lockedUntil
        );
    }

    /// @dev Modifies only the pending family position and settles its exact token deltas.
    function _modify(Request memory request) private returns (uint256 amount0, uint256 amount1) {
        State storage s = _state();
        Family storage f = s.families[request.familyId];
        Range storage r = s.ranges[request.familyId][request.member];
        PoolKey memory key = _positionKey(f, r);
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                r.tickLower,
                r.tickUpper,
                request.liquidityDelta,
                keccak256(abi.encode(request.familyId, request.member))
            ),
            ""
        );
        if (fees.amount0() < 0 || fees.amount1() < 0) revert InvalidFunding();
        if (fees.amount0() != 0 || fees.amount1() != 0) {
            emit LPFeesCollected(
                request.familyId,
                request.member,
                key.toId(),
                f.owner,
                request.to,
                uint256(int256(fees.amount0())),
                uint256(int256(fees.amount1()))
            );
        }
        if (request.liquidityDelta > 0) {
            if (delta.amount0() > 0 || delta.amount1() > 0) revert InvalidFunding();
            amount0 = uint256(-int256(delta.amount0()));
            amount1 = uint256(-int256(delta.amount1()));
            if ((amount0 == 0 && amount1 == 0) || amount0 > request.bound0 || amount1 > request.bound1) {
                revert Slippage();
            }
            HookrSettlement.pay(poolManager, key.currency0, address(this), amount0);
            HookrSettlement.pay(poolManager, key.currency1, address(this), amount1);
        } else {
            if (delta.amount0() < 0 || delta.amount1() < 0) revert InvalidFunding();
            amount0 = uint256(int256(delta.amount0()));
            amount1 = uint256(int256(delta.amount1()));
            // The bounds cover the principal: the delta less the fees accrued since the position's last touch.
            if (
                amount0 - uint256(int256(fees.amount0())) < request.bound0
                    || amount1 - uint256(int256(fees.amount1())) < request.bound1
            ) revert Slippage();
            _deliver(key.currency0, request.to, amount0, request.claims & 1 != 0);
            _deliver(key.currency1, request.to, amount1, request.claims & 2 != 0);
        }
    }

    /// @dev The PoolManager pays the recipient directly; this contract never custodies exit proceeds.
    function _deliver(Currency currency, address to, uint256 amount, bool asClaim) private {
        if (asClaim) HookrSettlement.mintTo(poolManager, currency, to, amount);
        else HookrSettlement.takeTo(poolManager, currency, to, amount);
    }

    function _key(address subject, Currency quote, int24 tickSpacing, address rootAddress)
        private
        pure
        returns (PoolKey memory)
    {
        bool subjectFirst = uint160(subject) < uint160(Currency.unwrap(quote));
        return PoolKey(
            subjectFirst ? Currency.wrap(subject) : quote,
            subjectFirst ? quote : Currency.wrap(subject),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing,
            IHooks(rootAddress)
        );
    }

    /// @dev The member's PoolKey, or an all-zero key for a member with no position.
    function _positionKey(Family storage f, Range storage r) private view returns (PoolKey memory key) {
        int24 tickSpacing = r.tickSpacing;
        if (tickSpacing != 0) key = _key(f.subject, r.quote, tickSpacing, f.root);
    }

    /// @notice Serves the launch fee's terms (IHookrLaunchFee: launchFee, proposeLaunchFee, acceptLaunchFee and
    ///         clearLaunchFee) from the linked library HookrLaunchChecks, by DELEGATECALL on this call's own calldata.
    ///         Any other call that matches no function reverts with no data, as it did before this fallback.
    fallback() external {
        bytes4 selector = msg.sig;
        if (
            selector != HookrLaunchChecks.launchFee.selector && selector != HookrLaunchChecks.proposeLaunchFee.selector
                && selector != HookrLaunchChecks.acceptLaunchFee.selector
                && selector != HookrLaunchChecks.clearLaunchFee.selector
        ) revert();
        address checks = address(HookrLaunchChecks);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), checks, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") { s.slot := SLOT }
    }
}
