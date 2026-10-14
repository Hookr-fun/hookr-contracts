// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";

/// @notice The two-venue executor's honest arbitrage, run only in the after-phase of swaps paid by `affiliate`; idle
///         otherwise. The lab code runs by DELEGATECALL, so this contract is the executor the root sees.
contract GatedExecutor {
    address public immutable root;
    address public immutable impl;
    address public affiliate;

    constructor(address _root, address _impl) {
        root = _root;
        impl = _impl;
    }

    function setAffiliate(address a) external {
        affiliate = a;
    }

    function executeArbitrage(PoolKey calldata key, address trader) external returns (uint256) {
        require(msg.sender == root, "root");
        if (trader == address(0) || trader != affiliate) return 0;
        (bool ok, bytes memory ret) = impl.delegatecall(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return abi.decode(ret, (uint256));
    }

    receive() external payable {}
}

/// @notice ATK-EX-2 regression (who gets the trader leg): the executor decides in which swap's after-phase it
///         recaptures. Before the fix, idle after the whale's buy that opened the gap, it closed the gap in the
///         after-phase of an affiliate's dust sell and the affiliate collected the trader leg of the whole arb
///         recapture. The trader leg is now paid only on what the named trader's own swap accounts for, and only when
///         the arb recapture undid its move: the dust sell collects nothing and the arb recapture's trader share goes
///         to the LP accrual.
contract ExecutorAttributionTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;

    GatedExecutor internal gated;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        TwoVenueExecutor lab =
            new TwoVenueExecutor(manager, address(root), partner, PARTNER_BPS, 3000, 60, address(0), 1e24);
        gated = new GatedExecutor(address(root), address(lab));
        gated.setAffiliate(minnow);
        _openLane(address(gated), 3_000_000);
        (, key) = _one(_newSubject(), true, false, 0);
        _seedRef(key);
        _buy(key, ETH, attacker, 1e18);
        _nextBlock();
    }

    function test_regression_anAffiliatesDustSellCollectsNoTraderLeg() public {
        vm.recordLogs();
        _buy(key, ETH, whale, 5e22);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.pushedBefore + o.pushedAfter, 0, "idle after the buy that opened the gap");
        assertEq(rules.claimable(ETH, whale), 0);
        _nextBlock();
        uint256 lpBefore = _accrued(key);
        vm.recordLogs();
        _sell(key, ETH, minnow, 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        o = _outcome(logs);
        assertGt(o.pushedAfter, 0, "the whole gap closed in the affiliate's after-phase");
        uint256 rest = o.pushedAfter - _cut(o.profitAfter, o.pushedAfter);
        console2.log(
            "pushed in the affiliate's after-phase; affiliate trader leg", o.pushedAfter, rules.claimable(ETH, minnow)
        );
        console2.log("  the trader leg before the fix", rest * 2000 / 10_000);
        assertEq(rules.claimable(ETH, minnow), 0, "the affiliate's dust sell collects nothing");
        assertEq(rules.claimable(ETH, whale), 0);
        assertEq(_splits(logs).trader, 0);
        assertEq(_accrued(key) - lpBefore, rest, "the arb recapture's trader share went to the LP accrual");
    }
}
