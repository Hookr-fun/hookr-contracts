// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

/// @notice N10 parity: a pool launched with today's defaults (launch, which binds the default Rules knobs) trades to
///         the wei as it did at r31-final. One digest covers every observable of a fixed run: the DF-01 swap shapes
///         (exact-input and exact-output buys and sells) at five fee settings, a dynamic fee pool traded across its
///         windows, a reset, counted and uncounted moves and both directions, a decaying Snipe under its buy cap, a
///         dynamic fee pool inside its guard, and a pool without dynamic fees. For each swap: the input, the output,
///         the execution receipt, the price after, the pool's dynamic fee state and the protocol's claim. The widest
///         fee setting is the most sensitive pool at the widest span the dynamic fee's reach bound admits there. The
///         digest below was measured by running this file unchanged on r31-final (f5714e2) and on r31-all; this
///         release's knobs and reach bound leave it as it was.
contract RulesKnobsParityTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev The digest of the run on r31-final.
    bytes32 internal constant R31_FINAL_DIGEST = 0x43a6aae9f0537bde613301a76bbcd6bf12767c8235ce736ca7dd489c2752e016;

    address internal buyer = address(0xB0B);

    /// @dev The run's digest and swap count, kept in memory: a snapshot revert resets this contract's storage.
    struct Run {
        bytes32 digest;
        uint256 swaps;
    }

    function setUp() public override {
        super.setUp();
        tokenA.transfer(buyer, 1e28);
        tokenB.transfer(buyer, 1e28);
        vm.startPrank(buyer);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _open(IHookrLauncher.Member memory m) internal returns (PoolKey memory key) {
        (key,,) = _launchMember(m, false);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev One swap by `buyer`, quoted first (the quote must equal the execution), folded into the run's digest.
    function _trade(Run memory run, PoolKey memory key, bool buy, bool exactInput, uint128 amount) internal {
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = buyer;
        HookrTypes.ExecutionReceipt memory r = quoter.quote(p, buyer);
        vm.prank(buyer);
        (uint256 input, uint256 output) = router.swap(p, address(0), new uint256[](0));
        assertEq(input, r.inputAmount, "quote input");
        assertEq(output, r.outputAmount, "quote output");
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (
            uint256 minLiquidity,
            int24 referenceTick,
            int24 anchorTick,
            uint40 movedAt,
            uint40 referenceAt,
            int24 movedTick
        ) = rules.referenceState(key.toId());
        uint256 claim = rules.claimable(root.poolConfig(key.toId()).quote, protocol);
        run.digest = keccak256(
            abi.encode(
                run.digest,
                abi.encode(input, output, r.lpFeePips, r.quoteFee, r.quoteRefund, r.subjectBurn, r.actualQuote),
                abi.encode(price, tick, minLiquidity, referenceTick, anchorTick, movedAt, referenceAt, movedTick, claim)
            )
        );
        ++run.swaps;
    }

    function _wait(uint256 seconds_) internal {
        vm.warp(vm.getBlockTimestamp() + seconds_);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// DF-01's shapes: a fresh pool's first swap, each shape at each fee setting.
    function _shapes(Run memory run) internal {
        // The last two: the most sensitive pool at the widest span the reach bound admits there (75,000).
        uint24[5] memory maxFees = [uint24(30_000), 100_000, 100_000, 75_000, 75_000];
        uint16[5] memory senses = [uint16(1), 5, 5, 10, 10];
        bool[5] memory fulls = [false, false, true, false, true];
        for (uint256 i; i < 5; ++i) {
            for (uint256 s; s < 4; ++s) {
                uint256 snap = vm.snapshotState();
                IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
                m.rules.maxFeePips = maxFees[i];
                m.rules.dynamicFeeSens = senses[i];
                if (fulls[i]) {
                    m.rules.burnBps = 100;
                    m.rules.lpBps = 200;
                    m.rules.royaltyBps = 500;
                    m.rules.royaltyTo = royalty;
                }
                PoolKey memory key = _open(m);
                bool buy = s < 2;
                bool exactInput = s % 2 == 0;
                _trade(run, key, buy, exactInput, exactInput ? 5e22 : 4e22);
                vm.revertToState(snap);
            }
        }
    }

    /// A default dynamic fee pool traded across its windows: steps, a reset, uncounted small moves, counted moves, both
    /// directions and both exact sides.
    function _tempo(Run memory run) internal {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))));
        _trade(run, key, true, true, 3e22);
        _wait(10);
        _trade(run, key, true, true, 2e21);
        _wait(21);
        _trade(run, key, false, true, 1e21);
        _wait(30);
        _trade(run, key, true, false, 5e21);
        _wait(39);
        _trade(run, key, true, true, 1e22);
        _wait(5);
        _trade(run, key, true, true, 1e22);
        _wait(29);
        _trade(run, key, false, false, 4e21);
        _wait(150);
        _trade(run, key, false, true, 3e22);
        _wait(1);
        _trade(run, key, true, true, 1e20);
        _wait(61);
        _trade(run, key, true, true, 2e22);
        _wait(119);
        _trade(run, key, false, true, 2e22);
        _wait(300);
        _trade(run, key, true, true, 4e22);
        vm.revertToState(snap);
    }

    /// A linear decaying Snipe, 500,000 to 10,000 pips over 120 s, under a per-block buy cap, on a pool without and one
    /// with dynamic fees.
    function _snipe(Run memory run) internal {
        for (uint256 dyn; dyn < 2; ++dyn) {
            uint256 snap = vm.snapshotState();
            IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
            if (dyn == 0) {
                m.rules.maxFeePips = 3000;
                m.rules.dynamicFeeSens = 0;
            }
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
            m.rules.snipeTaxPips = 500_000;
            m.rules.snipeFloorPips = 10_000;
            m.rules.snipeDecaySeconds = 120;
            m.rules.maxBuyQuoteAmount = 2e22;
            PoolKey memory key = _open(m);
            uint256[7] memory waits = [uint256(0), 1, 29, 30, 59, 1, 100];
            for (uint256 w; w < waits.length; ++w) {
                _wait(waits[w]);
                _trade(run, key, true, true, 1e21);
                _trade(run, key, false, true, 5e20);
            }
            vm.revertToState(snap);
        }
    }

    /// A pool without dynamic fees but with LP Rewards, Auto Burn and a royalty (the fixture's member).
    function _plain(Run memory run) internal {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _open(_member(Currency.wrap(address(0))));
        _trade(run, key, true, true, 3e22);
        _trade(run, key, true, false, 1e22);
        _wait(40);
        _trade(run, key, false, true, 2e22);
        _trade(run, key, false, false, 1e22);
        vm.revertToState(snap);
    }

    function test_defaultsTradeAsAtR31Final() public {
        Run memory run;
        _shapes(run);
        _tempo(run);
        _snipe(run);
        _plain(run);
        emit log_named_uint("swaps", run.swaps);
        emit log_named_bytes32("digest", run.digest);
        assertEq(run.swaps, 20 + 12 + 28 + 4, "every swap ran");
        assertEq(run.digest, R31_FINAL_DIGEST, "r31-final's digest");
    }
}
