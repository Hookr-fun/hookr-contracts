// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BestRouteTypes} from "./HookrBestRouteTypes.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";

/// @title Hookr route planner
/// @notice Encodes one route as the commands and inputs of a single Universal Router 2.1.1 `execute` call.
/// @dev Input layouts are the ones the pinned router build on Robinhood Chain 4663 decodes, read back by
///      execution on a fork at L2 block 70,430,000 (fork/UniversalRouterLayout.t.sol):
///      - V3_SWAP_EXACT_IN takes six fields, `(recipient, amountIn, amountOutMin, path, payerIsUser,
///        uint256[] minHopPriceX36)`. The five-field layout only works when the missing array's offset
///        happens to read a zero length (an amountIn of CONTRACT_BALANCE on a one-pool path); an explicit
///        amount or a two-pool path then reverts `SliceOutOfBounds()`.
///      - SWAP_EXACT_IN_SINGLE takes `(poolKey, zeroForOne, amountIn, amountOutMinimum, uint256 minHopPriceX36,
///        hookData)`. The five-field struct only works on pools whose currency0 is native ETH.
///      - A nonzero minHopPriceX36 is a per-hop floor on amountOut * 1e36 / amountIn; this planner passes zero
///        and relies on the route-level minimum on the last hop and the final take.
///      A v3 segment is one V3_SWAP_EXACT_IN over a packed path. A v4 segment (hookless pools, and a Hookr pool
///      when its root trusts this router) is one V4_SWAP of chained SWAP_EXACT_IN_SINGLE actions. Between
///      segments the working balance sits in the router; WRAP_ETH or UNWRAP_WETH converts ETH and WETH where a
///      v3 leg meets a native v4 leg. Every currency the router may still hold after a partial fill is swept
///      back to the caller at the end, so nothing is left for the next caller to take: the native input, the
///      WETH it was wrapped into, each v3 segment's input and every intermediate of a multi-pool v3 path (a
///      later hop that fills partly leaves the rest of the previous hop's output in the router). A v4 segment
///      needs no sweep: an unconsumed credit or debt fails the PoolManager's settlement check and the call
///      reverts.
library HookrRoutePlanner {
    // Universal Router command bytes.
    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant SWEEP = 0x04;
    uint8 internal constant WRAP_ETH = 0x0b;
    uint8 internal constant UNWRAP_WETH = 0x0c;
    uint8 internal constant V4_SWAP = 0x10;
    // v4 router action bytes.
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE = 0x0b;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE = 0x0e;
    uint8 internal constant TAKE_ALL = 0x0f;
    /// @notice Recipient sentinel the router maps to the account that called `execute`.
    address internal constant MSG_SENDER = address(1);
    /// @notice Recipient sentinel the router maps to itself.
    address internal constant ADDRESS_THIS = address(2);
    /// @notice Amount sentinel: the router's whole balance of the currency.
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;
    /// @notice v4 amount sentinel: the router's open delta in the currency.
    uint128 internal constant OPEN_DELTA = 0;
    /// @notice Longest route this planner encodes.
    uint256 internal constant MAX_STEPS = 3;
    uint256 private constant MAX_COMMANDS = 16;

    /// @notice SWAP_EXACT_IN_SINGLE parameters as the pinned router decodes them.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    error EmptyRoute();
    error TooManySteps(uint256 steps);
    error InvalidStep(uint256 index);
    error Discontinuous(uint256 index);
    error InvalidEndpoint();
    error RepeatedAsset(uint256 index);
    error InvalidAmount();

    /// @notice Reverts unless `steps` is a route this planner can encode from `currencyIn` to `currencyOut`.
    /// @dev Checks shapes only; whether each pool exists is the caller's question.
    function validate(BestRouteTypes.Step[] memory steps, address currencyIn, address currencyOut, address weth)
        internal
        pure
    {
        uint256 n = steps.length;
        if (n == 0) revert EmptyRoute();
        if (n > MAX_STEPS) revert TooManySteps(n);
        for (uint256 i; i < n; ++i) {
            BestRouteTypes.Step memory s = steps[i];
            if (s.currencyIn == s.currencyOut) revert InvalidStep(i);
            if (s.venue == BestRouteTypes.Venue.V3) {
                if (
                    s.currencyIn == address(0) || s.currencyOut == address(0) || s.fee >= 1_000_000
                        || s.tickSpacing != 0 || s.hooks != address(0)
                ) revert InvalidStep(i);
            } else if (s.venue == BestRouteTypes.Venue.V4) {
                // A hookless pool cannot carry the dynamic-fee flag; its static fee is at most 100%.
                if (s.fee > 1_000_000 || s.tickSpacing <= 0 || s.hooks != address(0)) revert InvalidStep(i);
            } else if (s.tickSpacing <= 0 || s.hooks == address(0)) {
                revert InvalidStep(i);
            }
            if (i != 0) {
                BestRouteTypes.Step memory p = steps[i - 1];
                address a = p.currencyOut;
                address b = s.currencyIn;
                if (a != b) {
                    bool pV3 = p.venue == BestRouteTypes.Venue.V3;
                    bool sV3 = s.venue == BestRouteTypes.Venue.V3;
                    bool unwrap = pV3 && !sV3 && a == weth && b == address(0);
                    bool wrap = !pV3 && sV3 && a == address(0) && b == weth;
                    if (!unwrap && !wrap) revert Discontinuous(i);
                }
            }
        }
        BestRouteTypes.Step memory first = steps[0];
        BestRouteTypes.Step memory last = steps[n - 1];
        bool inOk = first.venue == BestRouteTypes.Venue.V3
            ? first.currencyIn == (currencyIn == address(0) ? weth : currencyIn)
            : first.currencyIn == currencyIn;
        bool outOk = last.venue == BestRouteTypes.Venue.V3
            ? last.currencyOut == (currencyOut == address(0) ? weth : currencyOut)
            : last.currencyOut == currencyOut;
        if (!inOk || !outOk) revert InvalidEndpoint();
        // No asset twice: whole-balance commands between segments must only ever see this route's funds.
        for (uint256 i; i <= n; ++i) {
            address x = _asset(i == n ? last.currencyOut : steps[i].currencyIn, weth);
            for (uint256 j; j < i; ++j) {
                if (_asset(steps[j].currencyIn, weth) == x) revert RepeatedAsset(i);
            }
        }
    }

    /// @notice Encodes the route. `amountIn` is exact; the caller receives at least `minOut` or the call reverts.
    /// @return commands One byte per command.
    /// @return inputs One ABI-encoded input per command.
    /// @return value The msg.value to send: `amountIn` for a native input, else zero.
    function build(
        BestRouteTypes.Step[] memory steps,
        address currencyIn,
        address currencyOut,
        uint256 amountIn,
        uint256 minOut,
        address weth
    ) internal pure returns (bytes memory commands, bytes[] memory inputs, uint256 value) {
        validate(steps, currencyIn, currencyOut, weth);
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max)) || minOut == 0 || minOut > type(uint128).max)
        {
            revert InvalidAmount();
        }
        commands = new bytes(MAX_COMMANDS);
        inputs = new bytes[](MAX_COMMANDS);
        address[] memory sweeps = new address[](MAX_COMMANDS);
        uint256 c;
        uint256 w;
        bool nativeIn = currencyIn == address(0);
        value = nativeIn ? amountIn : 0;
        if (nativeIn) sweeps[w++] = address(0);
        uint256 start;
        while (start < steps.length) {
            bool v3 = steps[start].venue == BestRouteTypes.Venue.V3;
            uint256 end = start;
            while (end + 1 < steps.length && (steps[end + 1].venue == BestRouteTypes.Venue.V3) == v3) ++end;
            bool first = start == 0;
            bool last = end == steps.length - 1;
            if (v3) {
                (c, w) = _v3Segment(
                    steps,
                    start,
                    end,
                    first,
                    last,
                    currencyOut,
                    amountIn,
                    minOut,
                    commands,
                    inputs,
                    c,
                    sweeps,
                    w,
                    nativeIn,
                    weth
                );
            } else {
                c = _v4Segment(steps, start, end, first, last, amountIn, minOut, commands, inputs, c);
            }
            start = end + 1;
        }
        for (uint256 i; i < w; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (sweeps[j] == sweeps[i]) seen = true;
            }
            if (seen) continue;
            commands[c] = bytes1(SWEEP);
            inputs[c++] = abi.encode(sweeps[i], MSG_SENDER, uint256(0));
        }
        assembly ("memory-safe") {
            mstore(commands, c)
            mstore(inputs, c)
        }
    }

    /// @notice The calldata of `execute(commands, inputs, deadline)`.
    function executeCalldata(bytes memory commands, bytes[] memory inputs, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(IUniversalRouter.execute, (commands, inputs, deadline));
    }

    /// @notice The v4 PoolKey and direction of a v4 or Hookr step.
    function poolKey(BestRouteTypes.Step memory s) internal pure returns (PoolKey memory key, bool zeroForOne) {
        zeroForOne = s.currencyIn < s.currencyOut;
        (address c0, address c1) = zeroForOne ? (s.currencyIn, s.currencyOut) : (s.currencyOut, s.currencyIn);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), s.fee, s.tickSpacing, IHooks(s.hooks));
    }

    /// @notice The packed v3 path `tokenIn | fee | tokenOut [| fee | tokenOut]` over steps `start..end`.
    function v3Path(BestRouteTypes.Step[] memory steps, uint256 start, uint256 end)
        internal
        pure
        returns (bytes memory path)
    {
        path = abi.encodePacked(steps[start].currencyIn);
        for (uint256 i = start; i <= end; ++i) {
            path = abi.encodePacked(path, steps[i].fee, steps[i].currencyOut);
        }
    }

    function _v3Segment(
        BestRouteTypes.Step[] memory steps,
        uint256 start,
        uint256 end,
        bool first,
        bool last,
        address currencyOut,
        uint256 amountIn,
        uint256 minOut,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 c,
        address[] memory sweeps,
        uint256 w,
        bool nativeIn,
        address weth
    ) private pure returns (uint256, uint256) {
        bool payerIsUser;
        uint256 amount;
        if (first) {
            amount = amountIn;
            if (nativeIn) {
                commands[c] = bytes1(WRAP_ETH);
                inputs[c++] = abi.encode(ADDRESS_THIS, amountIn);
                sweeps[w++] = weth;
            } else {
                // The v3 callback pulls exactly what the pool asks for, through Permit2, from the caller.
                payerIsUser = true;
            }
        } else {
            amount = CONTRACT_BALANCE;
            if (steps[start - 1].currencyOut == address(0)) {
                commands[c] = bytes1(WRAP_ETH);
                inputs[c++] = abi.encode(ADDRESS_THIS, CONTRACT_BALANCE);
            }
            sweeps[w++] = steps[start].currencyIn;
        }
        bool unwrapAtEnd = last && currencyOut == address(0);
        commands[c] = bytes1(V3_SWAP_EXACT_IN);
        inputs[c++] = abi.encode(
            last && !unwrapAtEnd ? MSG_SENDER : ADDRESS_THIS,
            amount,
            last ? minOut : 0,
            v3Path(steps, start, end),
            payerIsUser,
            new uint256[](0)
        );
        if (unwrapAtEnd) {
            commands[c] = bytes1(UNWRAP_WETH);
            inputs[c++] = abi.encode(MSG_SENDER, minOut);
        }
        // A multi-pool path pays every later hop from the router's balance of the previous hop's output, so a later
        // hop that fills only partly leaves that intermediate in the router. Sweep each intermediate back as well.
        for (uint256 i = start; i < end; ++i) {
            sweeps[w++] = steps[i].currencyOut;
        }
        return (c, w);
    }

    function _v4Segment(
        BestRouteTypes.Step[] memory steps,
        uint256 start,
        uint256 end,
        bool first,
        bool last,
        uint256 amountIn,
        uint256 minOut,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 c
    ) private pure returns (uint256) {
        uint256 hops = end - start + 1;
        bytes memory actions = new bytes(hops + 2);
        bytes[] memory params = new bytes[](hops + 2);
        uint256 a;
        address segIn = steps[start].currencyIn;
        address segOut = steps[end].currencyOut;
        if (!first) {
            if (segIn == address(0) && steps[start - 1].currencyOut != address(0)) {
                // A v3 leg delivered WETH; the router unwraps its whole balance before settling native ETH.
                commands[c] = bytes1(UNWRAP_WETH);
                inputs[c++] = abi.encode(ADDRESS_THIS, uint256(0));
            }
            actions[a] = bytes1(SETTLE);
            params[a++] = abi.encode(segIn, CONTRACT_BALANCE, false);
        }
        for (uint256 i = start; i <= end; ++i) {
            (PoolKey memory key, bool zeroForOne) = poolKey(steps[i]);
            actions[a] = bytes1(SWAP_EXACT_IN_SINGLE);
            params[a++] = abi.encode(
                ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    // forge-lint: disable-next-line(unsafe-typecast) -- build() bounds amountIn to int128 and minOut to uint128.
                    amountIn: first && i == start ? uint128(amountIn) : OPEN_DELTA,
                    // forge-lint: disable-next-line(unsafe-typecast) -- as above.
                    amountOutMinimum: last && i == end ? uint128(minOut) : 0,
                    minHopPriceX36: 0,
                    hookData: bytes("")
                })
            );
        }
        if (first) {
            actions[a] = bytes1(SETTLE_ALL);
            params[a++] = abi.encode(segIn, amountIn);
        }
        if (last) {
            actions[a] = bytes1(TAKE_ALL);
            params[a++] = abi.encode(segOut, minOut);
        } else {
            actions[a] = bytes1(TAKE);
            params[a++] = abi.encode(segOut, ADDRESS_THIS, uint256(OPEN_DELTA));
        }
        assembly ("memory-safe") {
            mstore(actions, a)
            mstore(params, a)
        }
        commands[c] = bytes1(V4_SWAP);
        inputs[c++] = abi.encode(actions, params);
        return c;
    }

    function _asset(address currency, address weth) private pure returns (address) {
        return currency == weth ? address(0) : currency;
    }
}
