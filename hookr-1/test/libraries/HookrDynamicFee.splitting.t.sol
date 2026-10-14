// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// L-01 old numbers: k=20 split buys in one parent block: subject +913 bps, protocol dynamic fee -9,522 bps.
// Fixed then: the dynamic fee integrated a marginal rate over the parent block's same-direction movement. Now the
// dynamic fee charges the path average of its rate from the pool's anchor, which each piece carries to its end price.

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

/// @notice Audit finding L-01.
contract HookrDynamicFeeSplittingTest is EconomicsSecurityBase {
    function _run(uint256 k) internal returns (uint256 protocolClaim, uint256 subjectOut) {
        uint256 snap = vm.snapshotState();
        (PoolKey memory key,, Currency quote) = _launchMember(_dynamicFeeMember(Currency.wrap(address(0))), true);
        subjectOut = _buys(key, k);
        protocolClaim = rules.claimable(quote, protocol);
        vm.revertToState(snap);
    }

    function _buys(PoolKey memory key, uint256 k) internal returns (uint256 subjectOut) {
        uint128 slice = uint128(2e22 / k);
        for (uint256 i; i < k; ++i) {
            (, uint256 out) = _buyAs(trader, key, slice);
            subjectOut += out;
        }
    }

    function testSplitsPayOneSwapDynamicFee() public {
        (uint256 single, uint256 singleOut) = _run(1);
        uint256[4] memory ks = [uint256(2), 10, 20, 50];
        for (uint256 i; i < ks.length; ++i) {
            (uint256 split, uint256 splitOut) = _run(ks[i]);
            assertGe(split * 100, single * 97, "protocol dynamic fee share");
            assertLe(splitOut * 10_000, singleOut * 10_015, "subject gain");
        }
    }
}
