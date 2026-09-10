// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrArbTypesV2} from "./HookrArbTypesV2.sol";

/// @title HookrWthFeePolicyV2
/// @notice Realized-profit waterfall expected from the reviewed Hookr x WTH executor profile.
/// @dev This profile fixes all five shares. The executor accounts for the full waterfall; route
///      operation, signer authority, and recipient acceptance remain separate release inputs.
library HookrWthFeePolicyV2 {
    uint256 internal constant BPS = 10_000;

    uint16 internal constant CREATOR_BPS = 4_000;
    uint16 internal constant TRADER_BPS = 2_000;
    uint16 internal constant TRIGGER_POOL_LP_BPS = 2_000;
    uint16 internal constant WTH_BPS = 1_000;
    uint16 internal constant HOOKR_BPS = 1_000;

    bytes32 internal constant INTEGRATION_ID = keccak256("hookr.integration.wth-arb.v2");
    bytes32 internal constant FEE_POLICY_ID =
        keccak256("hookr.fee-policy.wth-arb.v2:creator=4000,trader=2000,trigger-pool-lp=2000,wth=1000,hookr=1000");

    struct Allocation {
        uint256 creator;
        uint256 trader;
        uint256 triggerPoolLp;
        uint256 wth;
        uint256 hookr;
    }

    function isValid(HookrArbTypesV2.ProfitSplit memory split) internal pure returns (bool) {
        return split.creator != address(0) && split.creatorBps == CREATOR_BPS && split.traderBps == TRADER_BPS
            && split.triggerPoolBps == TRIGGER_POOL_LP_BPS;
    }

    /// @notice Applies the fixed Hookr-owned WTH-v2 waterfall while conserving every unit.
    /// @dev Each named share rounds down and Hookr receives the residual dust. Activation still
    ///      requires acceptance of the exact routing ABI, policy, recipients, and rounding rule.
    function allocate(uint256 gross, HookrArbTypesV2.ProfitSplit memory split)
        internal
        pure
        returns (Allocation memory out)
    {
        if (!isValid(split)) revert("HOOKR_WTH_BAD_SPLIT");
        out.creator = (gross * split.creatorBps) / BPS;
        out.trader = (gross * split.traderBps) / BPS;
        out.triggerPoolLp = (gross * split.triggerPoolBps) / BPS;
        out.wth = (gross * WTH_BPS) / BPS;
        out.hookr = gross - out.creator - out.trader - out.triggerPoolLp - out.wth;
    }
}
