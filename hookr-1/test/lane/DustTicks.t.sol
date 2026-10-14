// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";

/// @notice RCP-01: one-wei positions anyone adds on an arb recapture's path cannot push the two-venue executor past the
///         lane's gas cap. Each leg stops at MAX_CROSSINGS initialized ticks, so dust shrinks an arb recapture instead
///         of cancelling it, and an executor that does run out of its grant is reported as LaneOutOfGas.
contract DustTicksTest is LaneFixture {
    using PoolIdLibrary for PoolKey;

    /// @dev The lane cap the review reproduced the starvation at.
    uint32 internal constant REVIEWED_CAP = 500_000;

    struct Dust {
        uint32 cap;
        uint256 onReference;
        uint256 onHookr;
        bool warm;
        int24 spacing;
    }

    struct Out {
        uint256 succeeded;
        uint256 failed;
        bytes4 reason;
        uint256 pushed;
        uint256 pot;
    }

    function setUp() public {
        _setUpLane();
    }

    /// @dev A two-venue executor opened at gas cap `d.cap`; a King of the Pool pool; a hookless 0.05% reference venue
    ///      with spacing `d.spacing`, optionally with prior fee growth in both currencies (the steady state). A third
    ///      party plants one-wei positions at consecutive spacings on both legs' paths: below tick 0 on the reference
    ///      venue and above the post-buy tick on the Hookr pool. An honest authenticated buy of 1e23 ETH follows.
    function _scenario(Dust memory d) internal returns (Out memory o) {
        uint256 snap = vm.snapshotState();
        TwoVenueExecutor ex =
            new TwoVenueExecutor(manager, address(root), partner, PARTNER_BPS, 500, d.spacing, address(0), 1e23);
        _openLane(address(ex), d.cap);
        PoolKey memory k = _openKoth(ETH);
        PoolKey memory ref = PoolKey(ETH, _subjectOf(k), 500, d.spacing, IHooks(address(0)));
        seeder.seed{value: 1e24}(ref, SQRT_ONE, -60_000 / d.spacing * d.spacing, 60_000 / d.spacing * d.spacing, 1e24);
        Actor third = _newActor(k);
        if (d.warm) {
            third.directSwap(ref, true, -int256(1e21), 4295128740);
            third.directSwap(ref, false, -int256(1e21), SQRT_ONE);
        }
        for (uint256 i; i < d.onReference; ++i) {
            int24 upper = -int24(int256(i)) * d.spacing;
            seeder.seed{value: 1e6}(ref, SQRT_ONE, upper - d.spacing, upper, 1);
        }
        for (uint256 i; i < d.onHookr; ++i) {
            int24 lower = -3000 + int24(int256(i)) * 60;
            third.modify(k, lower, lower + 60, 1);
        }
        vm.recordLogs();
        _buy(k, ETH, whale, 1e23);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root) || uint256(logs[i].topics[2]) != 2) continue;
            if (logs[i].topics[0] == SUCCEEDED) {
                o.succeeded++;
                (, uint256 p) = abi.decode(logs[i].data, (uint256, uint256));
                o.pushed += p;
            } else if (logs[i].topics[0] == FAILED) {
                o.failed++;
                o.reason = abi.decode(logs[i].data, (bytes4));
            }
        }
        (,,, uint128 pot) = _hill(k);
        o.pot = pot;
        vm.revertToState(snap);
    }

    /// The reviewer's case: 16 one-wei positions on a steady-state venue failed the after-phase arb recapture open at a
    /// 500k cap. The bounded legs land a smaller arb recapture that still funds the pot.
    function test_dustShrinksTheArbRecaptureInsteadOfCancellingIt() public {
        Out memory control = _scenario(Dust(REVIEWED_CAP, 0, 0, true, 10));
        Out memory griefed = _scenario(Dust(REVIEWED_CAP, 16, 0, true, 10));
        assertEq(control.succeeded, 1);
        assertGt(_profitOf(control.pushed), 3e21, "the profit the push stands for");
        assertEq(griefed.succeeded, 1, "after-phase arb recapture lands");
        assertEq(griefed.failed, 0);
        assertGt(griefed.pushed, 0, "the lane still pushes");
        assertGt(griefed.pot, 0, "the pot is funded");
        assertLt(griefed.pushed, control.pushed, "dust shrinks the arb recapture");
    }

    /// Dust on both legs' paths on fresh venues, where every crossing writes zero slots: any number of positions costs
    /// at most MAX_CROSSINGS cold crossings per leg, which the fixture's cap covers.
    function test_capCoversBoundedLegsOnBothVenues() public {
        for (uint256 n = 8; n <= 40; n += 16) {
            Out memory o = _scenario(Dust(REVIEWED_CAP, n, n, false, 60));
            assertEq(o.succeeded, 1, "lands at any dust count under the reviewed cap");
            o = _scenario(Dust(LANE_GAS, n, n, false, 60));
            assertEq(o.succeeded, 1, "lands at any dust count");
            assertGt(o.pushed, 0);
        }
        Out memory warm = _scenario(Dust(LANE_GAS, 40, 50, true, 10));
        assertEq(warm.succeeded, 1);
    }

    /// An executor that spends its whole grant is reported as LaneOutOfGas, not as an empty reason, and the swap still
    /// completes.
    function test_starvedExecutorReportsOutOfGas() public {
        Out memory o = _scenario(Dust(300_000, 40, 50, false, 60));
        assertEq(o.succeeded, 0);
        assertEq(o.failed, 1);
        assertEq(o.reason, IHookrLaneEvents.LaneOutOfGas.selector);
    }
}
