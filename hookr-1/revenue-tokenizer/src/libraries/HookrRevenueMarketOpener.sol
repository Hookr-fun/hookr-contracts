// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";
import {IHookrFeeBridge, IHookrFeeBridgeFactory} from "../interfaces/external/IHookrFeeBridge.sol";
import {HookrRevenueDoorDeployer} from "./HookrRevenueDoorDeployer.sol";

/// @title Hookr revenue market opener
/// @notice The tokenizer's launches: the family launch of ways (1) and (3), funded from the creator and sent to the
///         launcher with its params as they arrived; and a revenue token's own market, one ETH-quoted pool on the root,
///         seeded single-sided with revenue tokens the tokenizer holds from the seal, its family locked in the
///         HookrFamilyLock for the token's forwarder, with the market's Fee Bridge v2 before it when asked.
/// @dev By delegatecall, so the tokenizer is the launch's caller, the family's first owner and the locker, and the
///      budgets are pulled from the tokenizer's caller, the creator. Kept apart from the tokenizer because the
///      launcher's Member and the bridge's Terms encoders alone are near 8,000 bytes, and a `LaunchParams` decoder
///      is no smaller.
library HookrRevenueMarketOpener {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    /// @dev The default market's figures (IHookrRevenueTokenizer.defaultMarket): the live standard terms of a Hookr
    ///      launch, with no Auto Burn of the revenue token, and the seed range's span: 138,120 ticks is 2,302 spacings,
    ///      1.0001^138,120 about 996,000, so the seed covers the revenue token from its start price up to about a million
    ///      times it. The lowest tick a 60-spaced range may start at is -887,220 (TickMath.MIN_TICK rounded up).
    int24 internal constant DEFAULT_TICK_SPACING = 60;
    int24 internal constant DEFAULT_RANGE_TICKS = 138_120;
    int24 internal constant LOWEST_SPACED_TICK = -887_220;
    uint24 internal constant DEFAULT_BASE_LP_FEE_PIPS = 3_000;
    uint24 internal constant DEFAULT_MAX_LP_FEE_PIPS = 600_000;
    uint24 internal constant DEFAULT_MAX_QUOTE_TAKE_PIPS = 200_000;
    uint16 internal constant DEFAULT_MAX_SUBJECT_TAKE_BPS = 1_000;
    uint16 internal constant DEFAULT_LP_REWARDS_BPS = 200;
    uint16 internal constant DEFAULT_ROYALTY_BPS = 500;
    uint16 internal constant DEFAULT_PROTOCOL_SHARE_BPS = 2_500;
    uint32 internal constant DEFAULT_RULES_GAS_LIMIT = 2_000_000;
    uint32 internal constant DEFAULT_RELEASE_BLOCKS = 36_000;
    bytes32 internal constant DEFAULT_POLICY_ID = keccak256("hookr-fee-token-market-v1");
    /// @dev The `member` an `AdvisoryPayeeUnchecked` carries for the market (IHookrRevenueTokenizer.MARKET_MEMBER).
    uint256 internal constant MARKET_MEMBER = type(uint256).max;

    /// @notice The default market terms for a revenue token on `rules` (IHookrRevenueTokenizer.defaultMarket): the pool's
    ///         config, Rules and recapture, and the single-sided seed range below the start price's tick with the
    ///         liquidity that places `seed` revenue tokens in it (the launcher rounds the amount up to at most `seed`;
    ///         any dust comes back to the creator).
    function defaultTerms(address rules, uint160 sqrtPriceX96, uint256 seed)
        external
        pure
        returns (IHookrRevenueTokenizer.MarketTerms memory m)
    {
        if (seed == 0) revert IHookrRevenueTokenizer.InvalidMarket();
        int24 start = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 upper = start / DEFAULT_TICK_SPACING * DEFAULT_TICK_SPACING;
        if (upper > start) upper -= DEFAULT_TICK_SPACING;
        int24 lower = upper - DEFAULT_RANGE_TICKS;
        if (lower < LOWEST_SPACED_TICK) lower = LOWEST_SPACED_TICK;
        if (lower >= upper) revert IHookrRevenueTokenizer.InvalidMarket();
        uint256 liquidity = FullMath.mulDiv(
            seed, FixedPoint96.Q96, TickMath.getSqrtPriceAtTick(upper) - TickMath.getSqrtPriceAtTick(lower)
        );
        if (liquidity == 0 || liquidity > type(uint128).max) revert IHookrRevenueTokenizer.InvalidMarket();
        m.open = true;
        m.seed = seed;
        m.tickSpacing = DEFAULT_TICK_SPACING;
        m.sqrtPriceX96 = sqrtPriceX96;
        m.tickLower = lower;
        m.tickUpper = upper;
        m.liquidity = uint128(liquidity);
        m.config.rules = rules;
        m.config.baseLpFeePips = DEFAULT_BASE_LP_FEE_PIPS;
        m.config.caps =
            HookrTypes.Caps(DEFAULT_MAX_LP_FEE_PIPS, DEFAULT_MAX_QUOTE_TAKE_PIPS, DEFAULT_MAX_SUBJECT_TAKE_BPS);
        m.config.rulesGasLimit = DEFAULT_RULES_GAS_LIMIT;
        m.config.policyId = DEFAULT_POLICY_ID;
        m.rules.maxFeePips = DEFAULT_BASE_LP_FEE_PIPS;
        m.rules.lpBps = DEFAULT_LP_REWARDS_BPS;
        m.rules.royaltyBps = DEFAULT_ROYALTY_BPS;
        m.rules.protocolShareBps = DEFAULT_PROTOCOL_SHARE_BPS;
        m.recapture.on = true;
        m.recapture.lpBps = 10_000;
        m.recapture.releaseBlocks = DEFAULT_RELEASE_BLOCKS;
    }

    /// @notice Funds and launches the family of ways (1) and (3) for the calling tokenizer: pulls every ERC-20 budget
    ///         of `launchParams` from the creator (the tokenizer's caller) and approves the launcher for it, requires
    ///         `msg.value` to be exactly the native budgets plus the launch fee, plus the fee again with a market, then
    ///         calls `launcher.launchFamily` with the params as they arrived and the native budgets plus the fee as
    ///         value. A launcher revert is bubbled as is.
    /// @param launcher The HookrLauncher.
    /// @param launchParams The `LaunchParams` as the tokenizer received them: the bytes of the struct's own encoding.
    /// @param subject The family's subject (the new token's predicted address, or the existing token).
    /// @param token The revenue token, so a refund of it counts among the currencies.
    /// @param fee The launch fee.
    /// @param market Whether a market opens in the same call, taking a second fee.
    /// @return familyId The launched family.
    /// @return launched The subject the launcher reports.
    /// @return subjectOut The subject every dev buy delivered.
    /// @return currencies Every currency the launch touched, for the refunds: native ETH, the subject, `token` and
    ///         each member's quote.
    function launch(
        address launcher,
        bytes calldata launchParams,
        address subject,
        address token,
        uint256 fee,
        bool market
    ) external returns (bytes32 familyId, address launched, uint256 subjectOut, Currency[] memory currencies) {
        IHookrLauncher.LaunchParams memory p =
            abi.decode(abi.encodePacked(uint256(32), launchParams), (IHookrLauncher.LaunchParams));
        uint256 nativeBudget;
        (nativeBudget, currencies) = _fund(launcher, p, subject, token);
        if (msg.value != nativeBudget + fee + (market ? fee : 0)) revert IHookrRevenueTokenizer.InvalidFunding();
        (bool ok, bytes memory ret) = launcher.call{value: nativeBudget + fee}(
            abi.encodePacked(IHookrLauncher.launchFamily.selector, uint256(32), launchParams)
        );
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        (familyId, launched, subjectOut) = abi.decode(ret, (bytes32, address, uint256));
    }

    /// @dev Pulls every ERC-20 budget from the creator and approves the launcher, as the launcher will pull them from
    ///      the tokenizer: the subject's budget (an existing token only; a new one is minted to the launcher) is the
    ///      sum of the subject-side maxima, each quote's its member's quote-side maximum plus that member's dev buy.
    ///      Native ETH is always currency0, so a native quote's budget is `amount0Max` plus its dev buy; it is returned
    ///      and comes with `msg.value`. A SKIP_TAKEN member whose key is taken is budgeted too: the launcher pulls less
    ///      and the rest goes back to the creator with the refunds. Lists every currency the call touches.
    function _fund(address launcher, IHookrLauncher.LaunchParams memory p, address subject, address token)
        private
        returns (uint256 nativeBudget, Currency[] memory currencies)
    {
        uint256 n = p.members.length;
        currencies = new Currency[](n + 3);
        currencies[0] = NATIVE;
        currencies[1] = Currency.wrap(subject);
        currencies[2] = Currency.wrap(token);
        uint256 subjectBudget;
        for (uint256 i; i < n; ++i) {
            IHookrLauncher.Member memory member = p.members[i];
            currencies[i + 3] = member.quote;
            bool subjectFirst = uint160(subject) < uint160(Currency.unwrap(member.quote));
            subjectBudget += subjectFirst ? member.amount0Max : member.amount1Max;
            uint256 quoteBudget = subjectFirst ? member.amount1Max : member.amount0Max;
            for (uint256 k; k < p.buys.length; ++k) {
                if (p.buys[k].member == i) quoteBudget += p.buys[k].quoteIn;
            }
            if (member.quote.isAddressZero()) nativeBudget += quoteBudget;
            else _pull(launcher, member.quote, quoteBudget);
        }
        if (p.token.existing != address(0)) _pull(launcher, Currency.wrap(subject), subjectBudget);
    }

    function _pull(address launcher, Currency c, uint256 amount) private {
        if (amount == 0) return;
        IERC20 erc20 = IERC20(Currency.unwrap(c));
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        erc20.forceApprove(launcher, amount);
    }

    /// @notice What `open` needs beside the market terms.
    struct Market {
        address launcher;
        address lock;
        address root;
        address token;
        address forwarder;
        uint64 unlockBlock;
        uint256 fee;
    }

    /// @notice A Fee Bridge v2 for `token`'s market pool, made before the token is sealed because the seal records
    ///         it: the pool's key is predicted from the revenue token, native ETH, the tick spacing and the root (the
    ///         launcher's keys ignore everything else) and must still be free; `open` afterwards opens exactly that key.
    function makeBridge(
        address launcher,
        address root,
        address factory,
        address token,
        IHookrRevenueTokenizer.MarketTerms calldata m
    ) external returns (address bridge) {
        (PoolKey memory key, bool available) = IHookrLauncher(launcher).memberKey(token, NATIVE, m.tickSpacing, root);
        if (!available) revert IHookrRevenueTokenizer.InvalidMarket();
        IHookrFeeBridge.Terms memory terms = IHookrFeeBridge.Terms(
            key, NATIVE, m.bridgeMaxPerDrip, m.bridgeMinBlocks, m.bridgeTipBps, m.bridgeMaxJumpBps
        );
        bridge = IHookrFeeBridgeFactory(factory).create(terms, keccak256(abi.encode(token)));
    }

    /// @notice Opens the market with the `m.seed` revenue tokens the tokenizer holds and the launch fee from its balance,
    ///         then locks the family for the forwarder until the unlock block. The seed range must lie at or below the
    ///         start price's tick (ETH is currency0, the revenue token currency1), so the position holds revenue token only;
    ///         the royalty, when any, goes to the token. The launcher refunds unspent seed to the tokenizer. The
    ///         market's Hook Block, when `m.config.advisory` is set, is held to the rule a launch member's is held to
    ///         (HookrRevenueDoorDeployer.checkAdvisory as `MARKET_MEMBER`, with the empty bind data this launch sends: a
    ///         Tax + Conversion block needs its Config and so fails `AdvisoryRecipientMismatch`; another quote-taking
    ///         block binds and is reported; a fee-only block binds with no report).
    /// @return familyId The market's family.
    /// @return poolId The market pool.
    /// @return placed The revenue tokens the market position took: the seed less what the launcher gave back.
    function open(Market memory k, IHookrRevenueTokenizer.MarketTerms calldata m)
        external
        returns (bytes32 familyId, PoolId poolId, uint256 placed)
    {
        int24 startTick = TickMath.getTickAtSqrtPrice(m.sqrtPriceX96);
        if (m.liquidity == 0 || m.tickLower >= m.tickUpper || m.tickUpper > startTick) {
            revert IHookrRevenueTokenizer.InvalidMarket();
        }
        if (m.config.advisory != address(0)) {
            HookrRevenueDoorDeployer.checkAdvisory(k.launcher, k.root, m.config.advisory, "", k.token, MARKET_MEMBER);
        }
        IERC20(k.token).forceApprove(k.launcher, m.seed);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory member = members[0];
        member.quote = NATIVE;
        member.tickSpacing = m.tickSpacing;
        member.sqrtPriceX96 = m.sqrtPriceX96;
        member.tickLower = m.tickLower;
        member.tickUpper = m.tickUpper;
        member.liquidity = m.liquidity;
        member.amount1Max = uint128(m.seed);
        member.config = m.config;
        member.rules = m.rules;
        member.recapture = m.recapture;
        member.rules.royaltyTo = m.rules.royaltyBps != 0 ? k.token : address(0);
        (familyId,) = IHookrLauncher(k.launcher).launch{value: k.fee}(
            IHookrLauncher.Token(k.token, "", "", 0, bytes32(0)), k.root, members, block.timestamp
        );
        IHookrLauncher(k.launcher).transferFamily(familyId, k.lock, 0);
        IHookrFamilyLock(k.lock).lock(familyId, k.forwarder, k.unlockBlock);
        poolId = IHookrLauncher(k.launcher).position(familyId, 0).key.toId();
        placed = m.seed - IERC20(k.token).balanceOf(address(this));
    }
}
