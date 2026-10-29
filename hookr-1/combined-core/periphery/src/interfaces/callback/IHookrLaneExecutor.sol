// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IHookrLaneExecutor
/// @notice The calls a Hookr root makes on a recapture executor. `partnerBps()` is not read.
interface IHookrLaneExecutor {
    /// @notice Selector 0x488301cd: `executeArbitrage((address,address,uint24,int24,address),address)`. Called in
    ///         both phases of a lane pool's swap: before the swap is quoted and after it settles.
    /// @param triggeringPool The pool whose swap opened the arb recapture window.
    /// @param rebateRecipient The swap's authenticated payer in the after-phase, zero in the before-phase and for an
    ///        unauthenticated swap.
    /// @return realizedProfitQuote Not read: the executor keeps the pool's frozen partner share of the profit and
    ///         pushes the rest, and each push's profit is taken from the push. The call must still return one word.
    function executeArbitrage(PoolKey calldata triggeringPool, address rebateRecipient)
        external
        returns (uint256 realizedProfitQuote);

    /// @notice Selector 0x9e97c424: `checkV3PoolsMev(address,address,address,bool)`. Asked by staticcall with at
    ///         most 200,000 gas on every outer swap of a lane pool, right after its before-phase call, and only while
    ///         the lane is switched on and the executor's code is the frozen one. True refuses the swap
    ///         (HookrRoot.MevCallbackRefused): the swapper is closing an arbitrage inside a v3 pool's callback. A revert,
    ///         a missing function (a view of another signature included) or any answer but a single true word lets the
    ///         swap go on.
    /// @param subject The pool's subject token.
    /// @param quote The pool's quote currency, address(0) for native ETH.
    /// @param swapper The caller of PoolManager.swap: a router, or the contract that swaps directly.
    /// @param zeroForOne The swap's direction on the lane pool, in its key's order (the `zeroForOne` of the swap's
    ///        SwapParams): true for currency0 in and currency1 out, false for currency1 in and currency0 out. The key's
    ///        currency0 is the lower of `subject` and `quote`, so the swap buys the subject exactly when
    ///        `zeroForOne == (quote < subject)`; on an ETH pool (`quote` is address(0), always currency0) a buy is
    ///        `zeroForOne` true. It lets the view tell a same-direction split across pools in one unlock (a buy on
    ///        another venue and a buy here) from a swap closing an arbitrage.
    /// @return True when the swapper is closing an arbitrage inside a v3 pool's callback and the swap must be refused.
    function checkV3PoolsMev(address subject, address quote, address swapper, bool zeroForOne)
        external
        view
        returns (bool);
}
