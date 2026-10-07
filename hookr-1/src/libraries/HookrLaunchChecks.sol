// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrLauncher} from "../periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../interfaces/IHookrLauncher.sol";
import {HookrToken} from "../support/HookrToken.sol";
import {IHookrRegistryGovernance} from "../interfaces/IHookrRegistryGovernance.sol";

/// @title HookrLaunchChecks
/// @notice launchFamily's checks that run once per launch and write no family state: the members' knobs (supply
///         weights, the minimum dynamic fee liquidity divisor and the lock end), the retained-supply cap's range and
///         the opening price check across members; a new token's tagline and logo URI, which it sets; and the launch
///         fee's terms, which the launcher's fallback serves.
/// @dev An external (linked) library, so these checks sit here and not in HookrLauncher's runtime. It is deployed
///      through CREATE3 and linked into the launcher's bytecode before the launcher is deployed, as HookrTokenDeployer
///      is. The launcher runs `checkFamily` and the launch fee's functions by DELEGATECALL on the call's own calldata,
///      so the library's events are logged by the launcher and its refusals are the launcher's errors. `checkFamily`
///      writes no launcher storage; the launch fee's functions write only the launch fee's terms (FEE_SLOT);
///      `familyBounds` is pure and answers a direct call.
library HookrLaunchChecks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev The least and the largest MemberKnobs.dynamicFeeLiquidityDivisor; zero means the launcher's default,
    ///      DYNAMIC_FEE_LIQUIDITY_DIVISOR (100). At 2 a dynamic fee pool's minimum dynamic fee liquidity is half its
    ///      launch liquidity, so a swap through the launch band carries the anchor with twice the quote it needs; at 1
    ///      the two are equal, a swap can fall a rounding short, and an order split in thirty pieces saved more than the
    ///      single order's simulation lead. At 10,000 the minimum is a ten-thousandth of the launch liquidity, at least
    ///      1. At both ends, as at the default, a dust trap adds nothing to the next buyers' fee, a split saves
    ///      nothing and a sandwich costs more than without dynamic fees (LauncherFamilyDivisorBoundsTest).
    uint256 internal constant MIN_DYNAMIC_FEE_LIQUIDITY_DIVISOR = 2;
    uint256 internal constant MAX_DYNAMIC_FEE_LIQUIDITY_DIVISOR = 10_000;
    /// @dev The widest OpeningCheck.toleranceBps, 10%.
    uint256 internal constant MAX_OPENING_TOLERANCE_BPS = 1_000;
    /// @dev The latest MemberKnobs.lockEndBlock, in parent blocks after the launch block: HookrRules' own bound on a
    ///      guard's length, which the launcher also applies to guards.
    uint256 internal constant MAX_LOCK_END_BLOCKS = 100_000;

    /// @dev The launch fee's terms, three words: the fee every launch pays now and the treasury whose target receives
    ///      it; a pending fee and treasury; and when the pending change can apply, with the registry owner who proposed
    ///      it (an owner change voids it).
    /// @custom:storage-location erc7201:hookr.launcher.fee
    struct LaunchFeeTerms {
        uint96 fee;
        address treasury;
        uint96 pendingFee;
        address pendingTreasury;
        uint48 readyAt;
        address proposer;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.launcher.fee")) - 1)) & ~bytes32(uint256(0xff)), in the
    ///      launcher's storage.
    bytes32 internal constant FEE_SLOT = 0x20f07448c0b2d5c51ffada9cf0e4a2ea531a113fa48dbf93a3d0662d08ca8300;
    /// @dev The highest launch fee: 0.01 of the native currency.
    uint256 internal constant MAX_LAUNCH_FEE = 0.01 ether;
    /// @dev How long after it is ready a proposed fee can still apply: HookrRegistry's GRACE_PERIOD.
    uint256 internal constant FEE_GRACE = 14 days;
    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q192 = 1 << 192;

    /// @dev The launch fee's terms in the calling launcher's storage.
    function feeTerms() internal pure returns (LaunchFeeTerms storage t) {
        assembly ("memory-safe") {
            t.slot := FEE_SLOT
        }
    }

    /// @notice IHookrLaunchFee.launchFee, run by the launcher's fallback.
    function launchFee()
        external
        view
        returns (uint256 fee, address treasury, uint256 pendingFee, address pendingTreasury, uint256 readyAt)
    {
        LaunchFeeTerms storage t = feeTerms();
        return (t.fee, t.treasury, t.pendingFee, t.pendingTreasury, t.readyAt);
    }

    /// @notice IHookrLaunchFee.proposeLaunchFee, run by the launcher's fallback: only the registry's owner. A fee above
    ///         zero needs a treasury with code. A new proposal replaces a pending one.
    function proposeLaunchFee(uint96 fee, address treasury) external {
        IHookrRegistryGovernance registry = _registry();
        if (msg.sender != registry.owner()) revert IHookrLauncher.NotFeeGovernor(msg.sender);
        if (fee > MAX_LAUNCH_FEE || (fee != 0 && treasury.code.length == 0)) {
            revert IHookrLauncher.InvalidLaunchFee(fee, treasury);
        }
        uint256 readyAt = block.timestamp + registry.delay();
        LaunchFeeTerms storage t = feeTerms();
        (t.pendingFee, t.pendingTreasury, t.readyAt, t.proposer) = (fee, treasury, uint48(readyAt), msg.sender);
        emit IHookrLauncher.LaunchFeeProposed(fee, treasury, readyAt);
    }

    /// @notice IHookrLaunchFee.acceptLaunchFee, run by the launcher's fallback: only the registry's owner, for its own
    ///         proposal, from its ready time and for FEE_GRACE after it.
    function acceptLaunchFee() external {
        if (msg.sender != _registry().owner()) revert IHookrLauncher.NotFeeGovernor(msg.sender);
        LaunchFeeTerms storage t = feeTerms();
        uint256 readyAt = t.readyAt;
        if (
            readyAt == 0 || t.proposer != msg.sender || block.timestamp < readyAt
                || block.timestamp > readyAt + FEE_GRACE
        ) revert IHookrLauncher.LaunchFeeNotReady(readyAt);
        (uint96 fee, address treasury) = (t.pendingFee, t.pendingTreasury);
        (t.fee, t.treasury) = (fee, treasury);
        (t.pendingFee, t.pendingTreasury, t.readyAt, t.proposer) = (0, address(0), 0, address(0));
        emit IHookrLauncher.LaunchFeeSet(fee, treasury);
    }

    /// @notice IHookrLaunchFee.clearLaunchFee, run by the launcher's fallback: the registry's owner or guardian.
    function clearLaunchFee() external {
        IHookrRegistryGovernance registry = _registry();
        if (msg.sender != registry.owner() && msg.sender != registry.guardian()) {
            revert IHookrLauncher.NotFeeGovernor(msg.sender);
        }
        LaunchFeeTerms storage t = feeTerms();
        t.fee = 0;
        (t.pendingFee, t.pendingTreasury, t.readyAt, t.proposer) = (0, address(0), 0, address(0));
        emit IHookrLauncher.LaunchFeeSet(0, t.treasury);
    }

    /// @dev The registry of the launcher this library runs in.
    function _registry() private view returns (IHookrRegistryGovernance) {
        return IHookrRegistryGovernance(address(HookrLauncher(address(this)).registry()));
    }

    /// @notice The bounds launchFamily's knobs and opening check are held to.
    /// @return minDivisor The least nonzero dynamicFeeLiquidityDivisor.
    /// @return maxDivisor The largest dynamicFeeLiquidityDivisor.
    /// @return maxToleranceBps The widest opening check tolerance, in basis points.
    /// @return maxLockEndBlocks The latest lockEndBlock, in parent blocks after the launch block.
    function familyBounds()
        external
        pure
        returns (uint256 minDivisor, uint256 maxDivisor, uint256 maxToleranceBps, uint256 maxLockEndBlocks)
    {
        return (
            MIN_DYNAMIC_FEE_LIQUIDITY_DIVISOR,
            MAX_DYNAMIC_FEE_LIQUIDITY_DIVISOR,
            MAX_OPENING_TOLERANCE_BPS,
            MAX_LOCK_END_BLOCKS
        );
    }

    /// @notice Checks launchFamily's inputs beyond those every launch checks, sets a new token's tagline and logo URI,
    ///         and logs FamilyWeights and FamilyOpeningChecked where they apply.
    /// @dev Refuses with HookrLauncher's errors: InvalidFamily for knobs or references whose count does not fit the
    ///      members, InvalidRetainedCap, InvalidWeights, WeightMismatch, InvalidDivisor, InvalidLockEnd,
    ///      OpeningToleranceOutOfRange, OpeningReferenceMismatch, OpeningReferenceUninitialized and
    ///      OpeningOutsideTolerance, and InvalidFunding for a tagline or logo URI on an existing token; with
    ///      TickMath.InvalidSqrtPrice, as the PoolManager would at the pool's initialization, for a member's opening price
    ///      outside the PoolManager's range when an opening check reads it; and with HookrToken.InvalidMetadata for a
    ///      tagline or logo URI past its bound.
    /// @param familyId The family being launched.
    /// @param subject The family's subject, new or existing.
    /// @param manager The PoolManager the opening check reads its reference pools on.
    /// @param p launchFamily's input, exactly as the launcher received it.
    /// @return lockEnd The latest member lockEndBlock, zero for none.
    /// @return divisors Member i's dynamicFeeLiquidityDivisor in bits [16i, 16i + 16); zero for the default.
    /// @return maxRetainedBps The family's retained cap, checked.
    function checkFamily(
        bytes32 familyId,
        address subject,
        IPoolManager manager,
        IHookrLauncher.LaunchParams calldata p
    ) external returns (uint256 lockEnd, uint256 divisors, uint256 maxRetainedBps) {
        IHookrLauncher.Member[] calldata members = p.members;
        IHookrLauncher.MemberKnobs[] calldata knobs = p.knobs;
        uint256 n = members.length;
        if (knobs.length != n) revert IHookrLauncher.InvalidFamily();
        bool isNew = p.token.existing == address(0);
        maxRetainedBps = p.maxRetainedBps;
        if (maxRetainedBps > BPS || (!isNew && maxRetainedBps != BPS)) {
            revert IHookrLauncher.InvalidRetainedCap(maxRetainedBps);
        }
        if (bytes(p.tagline).length != 0 || bytes(p.logoURI).length != 0) {
            if (!isNew) revert IHookrLauncher.InvalidFunding();
            // The launcher created the token in this transaction, so it is the one account the token lets set these.
            HookrToken(subject).setPresentation(p.tagline, p.logoURI);
        }
        bool weighted = knobs[0].subjectWeightBps != 0;
        if (weighted && !isNew) revert IHookrLauncher.InvalidWeights();
        uint256 lastGuardEnd;
        for (uint256 i; i < n; ++i) {
            uint256 guardEnd = members[i].rules.guardEndBlock;
            if (guardEnd > lastGuardEnd) lastGuardEnd = guardEnd;
        }
        uint256 weightSum;
        uint16[8] memory weights;
        for (uint256 i; i < n; ++i) {
            IHookrLauncher.Member calldata m = members[i];
            IHookrLauncher.MemberKnobs calldata k = knobs[i];
            uint16 weight = k.subjectWeightBps;
            if ((weight != 0) != weighted) revert IHookrLauncher.InvalidWeights();
            if (weighted) {
                weightSum += weight;
                weights[i] = weight;
                // The subject's side of the member's budget: amount0Max when the subject sorts first.
                uint256 budget = uint160(subject) < uint160(Currency.unwrap(m.quote)) ? m.amount0Max : m.amount1Max;
                uint256 expected = _bps(p.token.supply, weight);
                if (budget != expected) revert IHookrLauncher.WeightMismatch(uint8(i), budget, expected);
            }
            uint256 divisor = k.dynamicFeeLiquidityDivisor;
            if (
                divisor != 0
                    && (m.rules.dynamicFeeSens == 0
                        || divisor < MIN_DYNAMIC_FEE_LIQUIDITY_DIVISOR
                        || divisor > MAX_DYNAMIC_FEE_LIQUIDITY_DIVISOR)
            ) revert IHookrLauncher.InvalidDivisor(uint8(i), divisor);
            divisors |= divisor << (16 * i);
            uint256 end = k.lockEndBlock;
            if (end != 0) {
                if (end < lastGuardEnd || end > block.number + MAX_LOCK_END_BLOCKS) {
                    revert IHookrLauncher.InvalidLockEnd(uint8(i), end);
                }
                if (end > lockEnd) lockEnd = end;
            }
        }
        if (weighted) {
            if (weightSum > BPS) revert IHookrLauncher.InvalidWeights();
            emit IHookrLauncher.FamilyWeights(familyId, weights);
        }
        IHookrLauncher.OpeningCheck calldata opening = p.opening;
        uint256 tolerance = opening.toleranceBps;
        PoolKey[] calldata references = opening.references;
        if (tolerance == 0 && references.length == 0) return (lockEnd, divisors, maxRetainedBps);
        if (tolerance == 0 || tolerance > MAX_OPENING_TOLERANCE_BPS) {
            revert IHookrLauncher.OpeningToleranceOutOfRange(uint16(tolerance));
        }
        if (references.length != n - 1) revert IHookrLauncher.InvalidFamily();
        _checkOpening(manager, subject, members, references, tolerance);
        emit IHookrLauncher.FamilyOpeningChecked(familyId, uint16(tolerance), keccak256(abi.encode(references)));
    }

    /// @dev Converts every member's opening price into member 0's quote through its reference pool and refuses one
    ///      outside member 0's opening price by more than `tolerance` basis points. All prices are subject prices in a
    ///      quote, as Q64.96 sqrt prices: a pool's sqrtPriceX96 is sqrt(currency1 / currency0), so it is inverted
    ///      (floor(2^192 / sqrtPriceX96)) where the subject, or for a reference member 0's quote, is currency1.
    ///      Member i's converted sqrt price is floor(sqrtMember × sqrtReference / 2^96). Every step rounds down, so the
    ///      converted sqrt price is at most the exact one and above it less (sqrtMember + sqrtReference) / 2^96 + 1,
    ///      and member 0's at most its exact one and above it less 1: relative to the price, under 2^-30 whenever
    ///      every sqrt price in the check is at least 2^64 (a price of at least 2^-64), far inside the least tolerance
    ///      of one basis point. The band is compared exactly on the squares, in 512 bits: converted^2 x 10,000 from
    ///      p0 x (10,000 - tolerance) to p0 x (10,000 + tolerance), p0 being member 0's squared sqrt price. That is
    ///      the integer band [p0 x (10,000 - tolerance) / 10,000 rounded up, p0 x (10,000 + tolerance) / 10,000
    ///      rounded down], so the band itself never widens. Two members of one family never share a quote, so every
    ///      member after the first names a reference pool.
    function _checkOpening(
        IPoolManager manager,
        address subject,
        IHookrLauncher.Member[] calldata members,
        PoolKey[] calldata references,
        uint256 tolerance
    ) private view {
        address quote0 = Currency.unwrap(members[0].quote);
        uint256 s0 = _oriented(_memberPrice(members[0]), uint160(subject) > uint160(quote0));
        (uint256 lowHi, uint256 lowLo) = _mul512(s0 * (BPS - tolerance), s0);
        (uint256 highHi, uint256 highLo) = _mul512(s0 * (BPS + tolerance), s0);
        for (uint256 i = 1; i < members.length; ++i) {
            PoolKey calldata ref = references[i - 1];
            address quote = Currency.unwrap(members[i].quote);
            address c0 = Currency.unwrap(ref.currency0);
            address c1 = Currency.unwrap(ref.currency1);
            if (!((c0 == quote && c1 == quote0) || (c0 == quote0 && c1 == quote))) {
                revert IHookrLauncher.OpeningReferenceMismatch(uint8(i));
            }
            PoolKey memory key = ref;
            (uint160 sqrtReference,,,) = manager.getSlot0(key.toId());
            if (sqrtReference == 0) revert IHookrLauncher.OpeningReferenceUninitialized(uint8(i));
            // The member's subject price in its quote, times its quote's price in member 0's quote: the reference's
            // sqrt price is member 0's quote per the member's quote when the member's quote is its currency0.
            uint256 converted = FullMath.mulDiv(
                _oriented(_memberPrice(members[i]), uint160(subject) > uint160(quote)),
                _oriented(sqrtReference, c0 != quote),
                Q96
            );
            (uint256 hi, uint256 lo) = _mul512(converted * 100, converted * 100);
            if (_lt(hi, lo, lowHi, lowLo) || _lt(highHi, highLo, hi, lo)) {
                revert IHookrLauncher.OpeningOutsideTolerance(
                    uint8(i),
                    converted >= 1 << 176 ? type(uint256).max : FullMath.mulDiv(converted, converted, Q96),
                    FullMath.mulDivRoundingUp(s0 * (BPS - tolerance), s0, BPS * Q96),
                    FullMath.mulDiv(s0 * (BPS + tolerance), s0, BPS * Q96)
                );
            }
        }
    }

    /// @dev A member's opening sqrt price, refused as the PoolManager refuses it at initialization when it is outside
    ///      [MIN_SQRT_PRICE, MAX_SQRT_PRICE).
    function _memberPrice(IHookrLauncher.Member calldata m) private pure returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = m.sqrtPriceX96;
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert TickMath.InvalidSqrtPrice(sqrtPriceX96);
        }
    }

    /// @dev `sqrtPriceX96`, or floor(2^192 / sqrtPriceX96) when `invert`: the sqrt price of the reciprocal, rounded
    ///      down. Every sqrt price here is at least MIN_SQRT_PRICE, so the reciprocal stays under 2^160.
    function _oriented(uint160 sqrtPriceX96, bool invert) private pure returns (uint256) {
        return invert ? Q192 / sqrtPriceX96 : sqrtPriceX96;
    }

    /// @dev a x b in 512 bits, as FullMath computes it: the high and the low word.
    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @dev Whether the 512-bit (aHi, aLo) is below (bHi, bLo).
    function _lt(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo) private pure returns (bool) {
        return aHi < bHi || (aHi == bHi && aLo < bLo);
    }

    /// @dev floor(amount x bps / 10,000) for any amount and any bps up to 10,000, without overflow.
    function _bps(uint256 amount, uint256 bps) private pure returns (uint256) {
        return amount / BPS * bps + amount % BPS * bps / BPS;
    }
}
