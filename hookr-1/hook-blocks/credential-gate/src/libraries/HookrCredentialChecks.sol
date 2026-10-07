// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrCompliance} from "hookr/interfaces/IHookrCompliance.sol";

/// @title Hookr credential checks
/// @notice Identity and price-band checks any Hookr advisory can embed next to its own advice, as HookrSessionTiers
///         does for session surcharges: the compliance registry's credential and sanctions rules, a minimum balance of
///         a named token, a frozen allowlist and a price band. Every check is a view and fails closed.
/// @dev The caller supplies the frozen Gate of the pool and its allowlist membership mapping. Each function returns
///      the compliance Decision and which check decided, so an advisory can explain its answer.
library HookrCredentialChecks {
    /// @notice Which check refused.
    enum Check {
        NONE,
        COMPLIANCE,
        BALANCE,
        ALLOWLIST,
        RANGE
    }

    /// @notice The identity settings of one pool.
    /// @param compliance The compliance registry.
    /// @param listId Credential list. Zero: sanctions only.
    /// @param requireAll Tier bits a credential must hold.
    /// @param blockAny Tier bits a credential must not hold.
    /// @param haltSellsWhenSourceDown A failed external sanctions source stops exits too.
    /// @param balanceToken Token an entry must hold at least `minBalance` of. Zero: off.
    /// @param minBalance Raw minimum balance.
    /// @param allowlist Whether entries must be allowlist members.
    struct Gate {
        IHookrCompliance compliance;
        bytes32 listId;
        uint32 requireAll;
        uint32 blockAny;
        bool haltSellsWhenSourceDown;
        address balanceToken;
        uint128 minBalance;
        bool allowlist;
    }

    /// @notice Gas forwarded to a balance read.
    uint256 internal constant BALANCE_GAS = 50_000;

    /// @notice Check for an entry into the subject (a buy, or an add). A gated entry must pass the credential list,
    ///         the minimum balance and the allowlist; an ungated one only the sanctions rule. A failed sanctions source
    ///         or balance read refuses.
    function entry(Gate memory g, mapping(address => bool) storage members, address who, bool gated)
        internal
        view
        returns (IHookrCompliance.Decision d, Check c)
    {
        d = g.compliance.check(gated ? g.listId : bytes32(0), who, gated ? g.requireAll : 0, gated ? g.blockAny : 0);
        if (d != IHookrCompliance.Decision.ALLOW) return (d, Check.COMPLIANCE);
        if (!gated) return (d, Check.NONE);
        if (g.balanceToken != address(0)) {
            (bool ok, uint256 held) = balanceOf(g.balanceToken, who);
            if (!ok) return (IHookrCompliance.Decision.SOURCE_FAILED, Check.BALANCE);
            if (held < g.minBalance) return (IHookrCompliance.Decision.NO_CREDENTIAL, Check.BALANCE);
        }
        if (g.allowlist && !members[who]) return (IHookrCompliance.Decision.NO_CREDENTIAL, Check.ALLOWLIST);
        return (d, Check.NONE);
    }

    /// @notice Check for an exit into the quote (a sell): the sanctions rule, then, when `kyc`, whether the list ever
    ///         credentialed the wallet. A failed source stops the exit only with haltSellsWhenSourceDown. Once the list
    ///         has credentialed a wallet, nothing done to that credential or list later stops its exit: a per-wallet
    ///         revocation, a tier rewrite, an expiry, a revoked or voided issuer or a suspended list all leave it open.
    ///         The sanctions rule still stops any exit: an officer's listing stops one wallet's at once, and the
    ///         compliance owner's sanctions source, set through the timelock, stops the exit of every wallet it lists.
    ///         "Credentialed" is read from the registry's stored record: any record an attester of the list wrote for
    ///         the wallet, a live credential or the trace a revocation or rewrite leaves (its issuer is never zero). A
    ///         wallet the list never recorded is refused, on a suspended list too, so a wallet that only received the
    ///         subject by transfer cannot sell through a gated sell side. Balance and allowlist never gate an exit.
    function exit(Gate memory g, address who, bool kyc) internal view returns (IHookrCompliance.Decision d, Check c) {
        (bool listed, bool failed) = g.compliance.sanctionStatus(who);
        if (listed) return (IHookrCompliance.Decision.SANCTIONED, Check.COMPLIANCE);
        if (failed && g.haltSellsWhenSourceDown) return (IHookrCompliance.Decision.SOURCE_FAILED, Check.COMPLIANCE);
        if (!kyc) return (IHookrCompliance.Decision.ALLOW, Check.NONE);
        d = g.compliance.checkCredential(g.listId, who, g.requireAll, g.blockAny);
        if (d == IHookrCompliance.Decision.ALLOW) return (d, Check.NONE);
        bool recorded =
            d != IHookrCompliance.Decision.UNKNOWN_LIST && g.compliance.credential(g.listId, who).issuer != address(0);
        if (recorded) return (IHookrCompliance.Decision.ALLOW, Check.NONE);
        return (d, Check.COMPLIANCE);
    }

    /// @notice Whether a swap may start at `tick` inside the band [lower, upper]. Inside the band every swap may start;
    ///         above it only swaps that lower the price (zeroForOne), below it only swaps that raise it. With `strict`,
    ///         the swap's price limit must also sit inside the band, so it stops at the edge. An advisory that binds a
    ///         band before its pool initializes also refuses adds while the tick is outside it, or the pool can open
    ///         outside its band, where only swaps toward it start.
    function inBand(int24 tick, bool zeroForOne, uint160 limit, int24 lower, int24 upper, bool strict)
        internal
        pure
        returns (bool)
    {
        if (tick > upper && !zeroForOne) return false;
        if (tick < lower && zeroForOne) return false;
        if (!strict) return true;
        return zeroForOne ? limit >= TickMath.getSqrtPriceAtTick(lower) : limit <= TickMath.getSqrtPriceAtTick(upper);
    }

    /// @notice Bounded `balanceOf` read that must return exactly one word.
    function balanceOf(address token, address who) internal view returns (bool ok, uint256 held) {
        bytes memory input = abi.encodeWithSignature("balanceOf(address)", who);
        assembly ("memory-safe") {
            ok := staticcall(BALANCE_GAS, token, add(input, 32), mload(input), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            held := mload(0)
        }
    }
}
