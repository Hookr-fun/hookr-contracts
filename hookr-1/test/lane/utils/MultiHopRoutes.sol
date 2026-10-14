// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrLaneEvents} from "../../../src/interfaces/IHookrLaneEvents.sol";

/// @notice A route through several pools in one unlock, as a v4 router runs it: exact input on the first pool, each
///         pool's whole output as exact input on the next, then settle. Unauthenticated.
contract HopRoute is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    struct Hop {
        PoolKey key;
        bool zeroForOne;
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function run(Hop[] calldata hops, uint256 amountIn) external payable {
        manager.unlock(abi.encode(hops, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (Hop[] memory hops, uint256 amountIn) = abi.decode(data, (Hop[], uint256));
        int256 amount = -int256(amountIn);
        for (uint256 i; i < hops.length; ++i) {
            bool z = hops[i].zeroForOne;
            BalanceDelta d = manager.swap(
                hops[i].key, SwapParams(z, amount, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), ""
            );
            amount = -int256(z ? d.amount1() : d.amount0());
        }
        for (uint256 i; i < hops.length; ++i) {
            _close(hops[i].key.currency0);
            _close(hops[i].key.currency1);
        }
        return "";
    }

    function _close(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d > 0) {
            manager.take(c, address(this), uint256(d));
        } else if (d < 0) {
            uint256 owed = uint256(-d);
            if (c.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(manager), owed);
                manager.settle();
            }
        }
    }

    receive() external payable {}
}

/// @notice Routes and least-limit searches shared by the multi-hop suites.
abstract contract MultiHopRoutes {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SUCCEEDED_TOPIC =
        keccak256("CorrectionSucceeded(bytes32,uint8,address,uint256,uint256,address)");
    bytes32 internal constant FAILED_TOPIC = keccak256("CorrectionFailed(bytes32,uint8,address,bytes4)");

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    HopRoute internal hop;
    HopRoute.Hop[] internal two;
    HopRoute.Hop[] internal three;

    function routeAt(uint256 hops, uint256 g) external {
        require(msg.sender == address(this));
        hop.run{gas: g}(hops == 3 ? three : two, 1e18);
    }

    /// @dev The least gas limit (to 1,000) the route succeeds with in the current state, as a binary-searching
    ///      eth_estimateGas finds it.
    function _least(uint256 hops) internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 40_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = VM.snapshotState();
            try this.routeAt(hops, mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            VM.revertToState(snap);
        }
    }

    /// @dev Runs the route at `g` in the current state, then rolls back: 0 success, 1 InsufficientLaneGas, 2 other.
    function _tryAt(uint256 hops, uint256 g) internal returns (uint256 result) {
        uint256 snap = VM.snapshotState();
        try this.routeAt(hops, g) {
            result = 0;
        } catch (bytes memory err) {
            result = _contains(err, IHookrLaneEvents.InsufficientLaneGas.selector) ? 1 : 2;
        }
        VM.revertToState(snap);
    }

    function _contains(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    /// @dev Runs the route at `g` and returns, per hop, the lane calls that ran on its pool (succeeded or failed open)
    ///      and what its before-phase pushed; rolls back.
    function _ranAt(uint256 hops, uint256 g, address root)
        internal
        returns (uint256[] memory ran, uint256[] memory pushedBefore)
    {
        HopRoute.Hop[] memory route = hops == 3 ? three : two;
        ran = new uint256[](route.length);
        pushedBefore = new uint256[](route.length);
        uint256 snap = VM.snapshotState();
        VM.recordLogs();
        this.routeAt(hops, g);
        Vm.Log[] memory logs = VM.getRecordedLogs();
        for (uint256 h; h < route.length; ++h) {
            bytes32 id = PoolId.unwrap(route[h].key.toId());
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != root || logs[i].topics.length < 2 || logs[i].topics[1] != id) continue;
                if (logs[i].topics[0] == SUCCEEDED_TOPIC) {
                    ran[h]++;
                    (, uint256 p) = abi.decode(logs[i].data, (uint256, uint256));
                    if (uint256(logs[i].topics[2]) == 1) pushedBefore[h] += p;
                } else if (logs[i].topics[0] == FAILED_TOPIC) {
                    ran[h]++;
                }
            }
        }
        VM.revertToState(snap);
    }
}
