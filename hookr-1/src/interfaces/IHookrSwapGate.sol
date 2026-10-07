// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IHookrSwapGate
/// @notice A contract that vouches for a swap's payer before HookrRouter unlocks the PoolManager. `swapGated` lets its
///         caller fund a swap made for another identity, the payer: the root then records that payer for the swap's
///         receipt, Programs credit, compliance checks and Rules claims (the trader's arb recapture share, a refund),
///         as it records `msg.sender` on a plain `swap`. The router asks a gate only when the registry reports it as a
///         live GATE admission of the swap's own root (kind GATE, its runtime codehash the pinned one), and the gate
///         answers for that one swap.
/// @dev Day-one consumer: HookrFamilyRouter, whose Multi-pool launch trade legs it funds and vouches for the trader who
///      called it; later the limit-orders book. Invariants: only a live, unrevoked GATE admission of the pool's own
///      root whose runtime codehash is the pinned one can vouch, and none while a brake holds that root closed and the
///      registry's owner can still reopen it (`IHookrRegistry.rootReopenable`); the router calls `beforeUnlock` once
///      per swap, first thing in `swapGated`, with the admission's gas and its reentrancy lock held, and a vouch never
///      outlives that call (one vouch serves one swap); a gate is never a pool module, since a root binds Rules and
///      advisories only from admissions of those kinds; the router's `swap` and `swapFor` never ask a gate. A gate is
///      inert until a queued `ADMIT` of kind GATE for the root executes: until then `swapGated` refuses it.
interface IHookrSwapGate {
    /// @notice Vouches for `payer` as the identity of the swap HookrRouter is about to execute for `caller`.
    /// @dev Called only by HookrRouter, inside `swapGated`, before the swap's checks and its PoolManager unlock and
    ///      after the router has checked the gate's admission; the router holds its reentrancy lock, so no router entry
    ///      point runs during the call, and a swap the router then refuses reverts the call's effects with it. The
    ///      router counts only a clean 32-byte return equal to this function's selector: a revert, any other word, a
    ///      shorter or longer return or running out of the admission's gas refuses the swap. A gate answers only for a
    ///      swap it means to vouch for (for example one its own call asked for, with the payer it recorded), so nobody
    ///      can name another account's identity through it.
    /// @param caller The account that called `swapGated` and funds the swap's input.
    /// @param payer The identity the caller asks the root to record for the swap; never zero.
    /// @param key The pool of the swap.
    /// @param zeroForOne The swap's direction: true sells currency0.
    /// @param amountSpecified The swap's amount: negative for an exact input, positive for an exact output.
    /// @param data The caller's data for the gate; the router passes it on unread and never to the root.
    /// @return The selector of this function, `IHookrSwapGate.beforeUnlock.selector`, when the gate vouches.
    function beforeUnlock(
        address caller,
        address payer,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata data
    ) external returns (bytes4);
}
