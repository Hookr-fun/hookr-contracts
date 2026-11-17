// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrRulesStorage as S} from "./HookrRulesStorage.sol";

/// @notice Shared rounding and ledger allocation. Swap allocations never write liabilities individually.
library HookrSinks {
    error InvalidSink();
    function split(uint256 gross, uint16 protocolBps) internal pure returns (uint256 protocol, uint256 creator) {
        if (protocolBps > 10_000) revert InvalidSink();
        protocol = FullMath.mulDivRoundingUp(gross, protocolBps, 10_000);
        creator = gross - protocol;
    }
    function carve(uint256 rulesFee, uint24 ownTake, uint24 finalTake) internal pure returns (uint256) {
        if (ownTake > finalTake) revert InvalidSink();
        return ownTake == 0 ? 0 : FullMath.mulDiv(rulesFee, ownTake, finalTake);
    }
    function clamp128(uint128 held, uint256 addition) internal pure returns (uint128 next, uint256 accepted, uint256 excess) {
        uint256 room = type(uint128).max - uint256(held);
        accepted = addition < room ? addition : room;
        return (uint128(uint256(held) + accepted), accepted, addition - accepted);
    }
    function allocateClaim(S.State storage s, Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (recipient == address(0)) revert InvalidSink();
        s.claims[currency][recipient] += amount;
    }
    function allocateAccrual(S.State storage s, PoolId id, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        if (s.poolAccrued[id][currency] == 0) {
            Currency[] storage currencies = s.accruedCurrencies[id];
            bool listed;
            for (uint256 i; i < currencies.length; ++i) if (currencies[i] == currency) { listed = true; break; }
            if (!listed) currencies.push(currency);
        }
        s.poolAccrued[id][currency] += amount;
    }
    function allocateCrown(S.State storage s, PoolId id, uint256 amount) internal returns (uint256 accepted, uint256 excess) {
        (uint128 next, uint256 kept, uint256 rest) = clamp128(s.hills[id].pot, amount);
        if (kept != 0) s.hills[id].pot = next;
        return (kept, rest);
    }
    function allocateHolderPot(S.HolderPotState storage s, PoolId id, uint256 amount) internal returns (uint256 accepted, uint256 excess) {
        (uint128 next, uint256 kept, uint256 rest) = clamp128(s.pots[id].open, amount);
        if (kept != 0) s.pots[id].open = next;
        return (kept, rest);
    }
    /// @notice C2 commits the total OTHER-party swap allocation once, after every module's carve.
    /// Hookr's rule-fee residual is absent from that total and gets no claim write.
    function commitSwapLiabilities(S.State storage s, Currency currency, uint256 totalNonProtocol) internal {
        if (totalNonProtocol != 0) s.liabilities[currency] += totalNonProtocol;
    }
    /// @notice Explicit funded claim, including Hookr recapture/sweep credits: both ledger and liability grow.
    function fundClaim(S.State storage s, Currency currency, address recipient, uint256 amount) internal {
        allocateClaim(s, currency, recipient, amount);
        if (amount != 0) s.liabilities[currency] += amount;
    }
    function fundAccrual(S.State storage s, PoolId id, Currency currency, uint256 amount) internal {
        allocateAccrual(s, id, currency, amount);
        if (amount != 0) s.liabilities[currency] += amount;
    }
    /// @dev Outflow 0 is an LP fee, not a take-side ledger credit; C2/modules must leave it on the LP-fee path.
    function allocateOutflow(S.State storage s, PoolId id, Currency currency, uint8 outflow, address payee, uint256 amount)
        internal returns (uint256 accepted, uint256 excess)
    {
        if (outflow == 1) { allocateAccrual(s, id, currency, amount); return (amount, 0); }
        if (outflow == 2) return allocateHolderPot(S.holderPot(), id, amount);
        if (outflow == 3) return allocateCrown(s, id, amount);
        if (outflow == 4) { allocateClaim(s, currency, payee, amount); return (amount, 0); }
        revert InvalidSink();
    }
    /// @dev For deposits/recapture already moved into the core, account only what an outflow actually accepts.
    /// The caller routes a clamped excess elsewhere or leaves it as Hookr's residual, explicitly.
    function fundOutflow(S.State storage s, PoolId id, Currency currency, uint8 outflow, address payee, uint256 amount)
        internal returns (uint256 accepted, uint256 excess)
    {
        (accepted, excess) = allocateOutflow(s, id, currency, outflow, payee, amount);
        if (accepted != 0) s.liabilities[currency] += accepted;
    }
}
