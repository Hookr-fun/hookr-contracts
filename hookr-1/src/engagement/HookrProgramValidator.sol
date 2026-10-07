// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRootRoute} from "../interfaces/IHookrRootRoute.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRouter} from "../interfaces/IHookrRouter.sol";
import {HookrProgramTypes as P} from "../types/HookrProgramTypes.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrProgramValidator} from "../interfaces/IHookrProgramValidator.sol";

/// @title HookrProgramValidator
/// @notice Stateless creation checks. No balances, authority or delegatecall.
contract HookrProgramValidator is HookrReleased, IHookrProgramValidator {
    /// @notice Shortest review window: six days. A veto the sequencer withholds can be forced in through the delayed
    ///         inbox once 28,800 parent blocks have passed since the one it reached the inbox in (chain 4663's
    ///         SequencerInbox delayBlocks at L1 block 26,063,772: four days at 12 s, more when parent slots are
    ///         missed). The window is counted in L2 timestamps, which the sequencer sets inside that inbox's bounds: up
    ///         to 3,600 s (futureSeconds) ahead of the parent chain's time and up to 345,600 s (delaySeconds) behind
    ///         it, so a block can carry finalizeAfter from finalizeAfter - 1 hour of parent-chain time. Assuming honest
    ///         timestamps (the proposal's timestamp not behind parent-chain time), a veto forced in as soon as it may
    ///         be lands before anyone can finalize if that comes more than an hour before finalizeAfter: one sent
    ///         within about the first reviewDelay - 4 days - 1 hour (47 hours at this floor), less 12 s for each parent
    ///         slot missed while it waits. A proposal stamped behind parent-chain time shortens that window by its lag,
    ///         and at this floor a lag of 47 hours closes it; the lag shows on chain as L2 timestamps behind the parent
    ///         chain's. A later veto still lands in an outage, where forced transactions keep their L1 order, but a
    ///         finalize the sequencer includes first wins.
    uint64 public constant MIN_REVIEW_DELAY = 6 days;
    uint64 public constant MAX_REVIEW_DELAY = 30 days;

    /// @inheritdoc IHookrProgramValidator
    function validate(
        P.Terms calldata t,
        P.Scope[] calldata sources,
        P.Milestone[] calldata milestones,
        P.NFTMetadata calldata metadata,
        address manager,
        address router,
        bool lp
    ) external view {
        if (t.mode == P.Mode.Immediate && (t.cashBudget != 0 || t.globalBux || milestones.length != 0)) {
            revert ImmediateValueUnreviewed(t.cashBudget, t.globalBux, milestones.length);
        }
        _terms(t);
        if (sources.length == 0 || sources.length > P.MAX_SCOPES || milestones.length > P.MAX_MILESTONES) {
            revert InvalidProgram();
        }
        // Without milestones no collection is deployed, so its metadata would only bloat the creation event.
        // With milestones the collection constructor bounds name, symbol and base URI.
        if (
            milestones.length == 0
                && (bytes(metadata.name).length != 0
                    || bytes(metadata.symbol).length != 0
                    || bytes(metadata.baseURI).length != 0)
        ) revert InvalidProgram();
        IHookrRegistry registry = IHookrRouter(router).registry();
        for (uint256 i; i < sources.length; ++i) {
            P.Scope calldata s = sources[i];
            IHookrRoot root = IHookrRoot(s.root);
            PoolId id = PoolId.wrap(s.poolId);
            if (
                !registry.isRoot(s.root) || address(root.poolManager()) != manager || !root.knownPool(id)
                    || root.policyHash(id) != s.configHash || _quoteOf(root, id) != s.quoteAsset || s.numerator == 0
                    || s.denominator == 0 || s.numerator > P.MAX_RATE || s.denominator > P.MAX_RATE
            ) revert InvalidScope();
            if (lp) {
                if (
                    s.subjectNumerator == 0 || s.subjectDenominator == 0 || s.subjectNumerator > P.MAX_RATE
                        || s.subjectDenominator > P.MAX_RATE
                ) revert InvalidScope();
            } else if (s.subjectNumerator != 0 || s.subjectDenominator != 0) {
                revert InvalidScope();
            }
        }
        uint256 prior;
        for (uint256 i; i < milestones.length; ++i) {
            P.Milestone calldata m = milestones[i];
            if (m.pointsRequired <= prior || m.pointsRequired > t.walletPointCap || m.maxAwards == 0) {
                revert InvalidProgram();
            }
            prior = m.pointsRequired;
        }
    }

    /// @dev The pool's quote: the root's narrow read (`IHookrRootRoute.poolRoute`), or `IHookrRoot.poolConfig` for a
    ///      root without it, as HookrRouter and HookrForwarder read it. HookrRoot answers both from the same stored
    ///      quote, and the narrow read skips the whole configuration.
    function _quoteOf(IHookrRoot root, PoolId id) private view returns (address) {
        try IHookrRootRoute(address(root)).poolRoute(id) returns (Currency quote, address) {
            return Currency.unwrap(quote);
        } catch {
            return Currency.unwrap(root.poolConfig(id).quote);
        }
    }

    function _terms(P.Terms calldata t) private view {
        if (
            t.start < block.timestamp || t.end <= t.start || t.pointBudget == 0 || t.walletPointCap == 0
                || t.walletPointCap > t.pointBudget || t.pointDecimals > 18 || (t.globalBux && t.pointDecimals != 18)
                || bytes(t.name).length == 0 || bytes(t.name).length > 100 || bytes(t.metadataURI).length > 512
                || t.sourcePolicyHash == bytes32(0)
        ) revert InvalidProgram();
        if (t.cashBudget == 0) {
            if (
                t.rewardToken != address(0) || t.walletCashCap != 0 || t.cashNumerator != 0 || t.cashDenominator != 0
                    || t.dailyCashBudget != 0
            ) revert InvalidProgram();
        } else if (t.rewardToken.code.length == 0 || t.walletCashCap == 0 || t.walletCashCap > t.cashBudget) {
            revert InvalidProgram();
        }
        if (t.mode == P.Mode.Immediate) {
            // Cash, Bux and milestones were rejected above, so only the point rate remains to check.
            if (
                t.pointNumerator == 0 || t.pointDenominator == 0 || t.pointNumerator > P.MAX_RATE
                    || t.pointDenominator > P.MAX_RATE || t.dailyPointBudget != 0 || t.attestor != address(0)
                    || t.reviewer != address(0) || t.reviewDelay != 0
            ) revert InvalidProgram();
        } else {
            uint256 durationDays = (t.end - t.start) / P.DAY;
            if (
                t.start % P.DAY != 0 || (t.end - t.start) % P.DAY != 0 || durationDays == 0 || durationDays > P.MAX_DAYS
                    || uint256(t.dailyPointBudget) * durationDays != t.pointBudget
                    || uint256(t.dailyCashBudget) * durationDays != t.cashBudget || t.pointNumerator != 0
                    || t.pointDenominator != 0 || t.cashNumerator != 0 || t.cashDenominator != 0
                    || t.attestor == address(0) || t.reviewer == address(0) || t.attestor == t.reviewer
                    || t.reviewDelay < MIN_REVIEW_DELAY || t.reviewDelay > MAX_REVIEW_DELAY
            ) revert InvalidProgram();
        }
    }
}
