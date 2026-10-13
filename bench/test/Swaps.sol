// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {Figures} from "./Figures.sol";

/// @title Swaps
/// @notice How a trader reaches a pool in the bench: a swap through a Universal Router (a V4_SWAP of
///         SWAP_EXACT_IN_SINGLE, SETTLE_ALL and TAKE_ALL, exact input), measured as its own transaction. A swap that
///         reverts reverts the test, so a figure is never the cost of a refusal.
abstract contract Swaps is Figures {
    /// @dev The Universal Router 2.1.1 parameter struct of SWAP_EXACT_IN_SINGLE.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    uint8 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant SETTLE_ALL = 0x0c;
    uint8 private constant TAKE_ALL = 0x0f;
    bytes private constant V4_SWAP = hex"10";

    /// @dev Lets `who` pay `token` to both Universal Routers through Permit2.
    function _approveRouters(address who, address token) internal {
        vm.startPrank(who);
        IERC20(token).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token, ROUTER_CURATED, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(token, ROUTER_NOT_CURATED, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev One exact-input swap of `amountIn` through `router`, sent by `who` (also tx.origin). Returns the
    ///      transaction's whole gas.
    function _swapUniversal(address router, address who, PoolKey memory key, bool zeroForOne, uint128 amountIn)
        internal
        returns (uint256 gas)
    {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amountIn, 1, 0, ""));
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, uint256(amountIn));
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        bool nativeIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1) == address(0);
        if (nativeIn) vm.deal(who, who.balance + amountIn);
        bytes memory call = abi.encodeCall(IUniversalRouter.execute, (V4_SWAP, inputs, vm.getBlockTimestamp() + 3600));
        vm.prank(who, who);
        (bool ok, bytes memory ret) = router.call{value: nativeIn ? amountIn : 0}(call);
        gas = vm.lastCallGas().gasTotalUsed;
        _requireOk(ok, ret);
    }

    /// @dev Bubbles a failed call's revert data, so the cause of a failure reads as the contract's own error.
    function _requireOk(bool ok, bytes memory ret) internal pure {
        if (ok) return;
        assembly ("memory-safe") {
            revert(add(ret, 32), mload(ret))
        }
    }
}
