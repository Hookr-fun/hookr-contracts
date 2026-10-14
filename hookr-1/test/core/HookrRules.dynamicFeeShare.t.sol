// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @notice The protocol's share of a dynamic fee is floored, never rounded up: on a pool with only a dynamic fee at a 25%
///         protocol share, the quote take of a buy in pips is floor(dynamic fee x 2,500 / 10,000), where the dynamic
///         fee is what the buyer's LP fee carries above the base fee plus that take. Mutation gate RL-4 (the share
///         was rounded up).
contract HookrRulesDynamicFeeShareTest is EconomicsSecurityBase {
    function testFuzz_theProtocolShareOfADynamicFeeIsFloored(uint128 raw) public {
        uint128 amount = uint128(bound(raw, 1e22, 5e22)) / 1_000_000 * 1_000_000;
        (PoolKey memory key,,) = _launchMember(_dynamicFeeMember(Currency.wrap(address(0))), false);
        HookrTypes.ExecutionReceipt memory r = _quoteBuy(key, amount);
        // The take is quoteFee of `amount` gross, an exact multiple of a pip's worth at these amounts, less the wei or
        // two the reserve rounds off: round to the nearest pip.
        uint256 rate = (r.quoteFee * 1_000_000 + amount / 2) / amount;
        uint256 dynamicFee = uint256(r.lpFeePips) - 3_000 + rate;
        assertGt(dynamicFee, 0, "a dynamic fee was charged");
        assertEq(rate, dynamicFee * 2_500 / 10_000, "the protocol's share, floored");
    }
}
