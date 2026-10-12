// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// @dev The protocol fee controller live on Robinhood Chain 4663 (`PoolManager.protocolFeeController()`): Uniswap's
///      fee adapter, whose fee setter stores per-pool overrides and whose `triggerFeeUpdate` pushes the stored fee
///      onto an initialized pool. Selectors read from its runtime at the fork block.
interface IV4FeeAdapter {
    function feeSetter() external view returns (address);
    function getFee(PoolKey calldata key) external view returns (uint24);
    function setPoolOverride(PoolId id, uint24 fee) external;
    function triggerFeeUpdate(PoolKey calldata key) external;
}

/// @dev A Hookr 1 periphery on a 4663 fork against the live PoolManager, as LauncherDevBuyFork deploys it.
abstract contract ProtocolFeeForkBase is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    /// @dev foundry.toml's fork_block_number.
    uint256 internal constant FORK_BLOCK = 74_062_645;
    uint24 internal constant MAX_PROTOCOL_FEE = (1000 << 12) | 1000;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bool internal live;
    IV4FeeAdapter internal adapter;

    function _setUpFork() internal {
        if (bytes(vm.envOr("ALCHEMY_RPC_URL", string(""))).length == 0) return;
        vm.createSelectFork("robinhood", FORK_BLOCK);
        _deployPeriphery(PM);
        adapter = IV4FeeAdapter(PM.protocolFeeController());
        live = true;
    }

    /// @dev The release's registry delay.
    function _registryDelay() internal pure override returns (uint48) {
        return 30 minutes;
    }

    /// @dev The setter stores the v4 maximum for the pool; a stranger pushes it.
    function _protocolFeeOn(PoolKey memory key) internal {
        vm.prank(adapter.feeSetter());
        adapter.setPoolOverride(key.toId(), MAX_PROTOCOL_FEE);
        vm.prank(address(0xBEEF));
        adapter.triggerFeeUpdate(key);
    }

    /// @dev Router exact-input swap by the trader; returns the output and the PoolManager Swap event's fee.
    function _swapFee(PoolKey memory key, bool buy, uint128 amount, bool native)
        internal
        returns (uint256 amountOut, uint24 fee)
    {
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        vm.recordLogs();
        vm.prank(trader);
        (, amountOut) = router.swap{value: buy && native ? amount : 0}(p, address(0), new uint256[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(PM) && logs[i].topics[0] == SWAP_EVENT) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }
}

/// @notice PC-02 (09-24 audit, gap-lens, never independently verified, Low): the Uniswap v4 protocol fee (at most 0.1%
///         per direction) can be set by Uniswap governance and pushed by anyone onto Hookr pools; it sits outside
///         Hookr's frozen terms (the 09-24 finder measured a 12.2% cut of a King of the Pool arb recapture).
/// @dev Reproduced on a 4663 fork at r31, live: the PoolManager's controller is Uniswap's fee adapter; its fee setter
///      stores an override for a Hookr 1 pool, an unrelated account pushes it, and the next router buy pays the v4
///      protocol fee on top of the pool's frozen LP fee, out of the trader's output. Hookr cannot refuse it: v4 gives a
///      hook no say over the protocol fee. The executor guide already tells the partner to price it into every leg
///      ("Price every leg ... the v4 protocol fee"); creators and traders are not
///      told.
contract HookrRootProtocolFeeAdapterForkTest is ProtocolFeeForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpFork();
    }

    function test_fork_anyoneCanPushTheSettersProtocolFeeOntoAHookrPool() public {
        if (!live) return;
        assertGt(address(adapter).code.length, 0, "the live controller is a contract");
        (, PoolKey memory key,,) = _launch(true, true);
        emit log_named_address("protocol fee controller", address(adapter));
        emit log_named_address("its fee setter", adapter.feeSetter());
        emit log_named_uint("its fee for a new Hookr pool before any override", adapter.getFee(key));

        uint256 snapshot = vm.snapshotState();
        (uint256 outWithout, uint24 feeWithout) = _swapFee(key, true, 1e20, true);
        vm.revertToState(snapshot);

        _protocolFeeOn(key);
        (,, uint24 protocolFee,) = PM.getSlot0(key.toId());
        assertEq(protocolFee, MAX_PROTOCOL_FEE, "a stranger pushed the setter's fee onto the Hookr pool");
        uint256 accrued = PM.protocolFeesAccrued(key.currency0);
        (uint256 outWith, uint24 feeWith) = _swapFee(key, true, 1e20, true);
        assertGt(feeWith, feeWithout, "the buy's total fee rose by the v4 protocol fee");
        assertLt(outWith, outWithout, "paid out of the trader's output");
        assertGt(PM.protocolFeesAccrued(key.currency0), accrued, "accrued to the v4 protocol, not to Hookr or the LPs");
        emit log_named_uint("swap fee without the v4 protocol fee (pips)", feeWithout);
        emit log_named_uint("swap fee with it (pips)", feeWith);
        emit log_named_uint("trader output lost (bps)", (outWithout - outWith) * 10_000 / outWithout);
    }
}
