// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CanaryRobinhood} from "../script/CanaryRobinhood.s.sol";

contract CanaryEvidenceMathHarness is CanaryRobinhood {
    function lpFeeAfterProtocol(uint256 grossInputWei, uint256 lpFeePips, uint256 protocolFeePips)
        external
        pure
        returns (uint256)
    {
        return _lpFeeAfterProtocol(grossInputWei, lpFeePips, protocolFeePips);
    }
}

contract CanaryEvidenceMathTest is Test {
    CanaryEvidenceMathHarness internal harness;

    function setUp() public {
        harness = new CanaryEvidenceMathHarness();
    }

    function testNoSurgeThresholdMirrorsProtocolFirstPoolMath() public view {
        // 0.001 ETH canary input less its 0.75% LP/pot cut.
        uint256 grossPoolInput = 992_500_000_000_000;

        // base (3,000) + guarded snipe tax (200,000), with the maximum 1,000-pip
        // PoolManager protocol fee. These constants are independently calculated from Pool.sol's
        // combined-fee ceil and protocol-allocation floor, rather than from the helper under test.
        assertEq(harness.lpFeeAfterProtocol(grossPoolInput, 203_000, 1_000), 201_276_022_500_000);
        assertEq(harness.lpFeeAfterProtocol(grossPoolInput, 203_000, 0), 201_477_500_000_000);

        // A real surge override remains strictly above the protocol-aware no-surge threshold.
        assertEq(harness.lpFeeAfterProtocol(grossPoolInput, 230_000, 1_000), 228_046_725_000_000);
        assertGt(
            harness.lpFeeAfterProtocol(grossPoolInput, 230_000, 1_000),
            harness.lpFeeAfterProtocol(grossPoolInput, 203_000, 1_000)
        );
    }

    function testZeroLpFeeAssignsAllFeeToProtocol() public view {
        assertEq(harness.lpFeeAfterProtocol(992_500_000_000_000, 0, 1_000), 0);
        assertEq(harness.lpFeeAfterProtocol(0, 203_000, 1_000), 0);
    }
}
