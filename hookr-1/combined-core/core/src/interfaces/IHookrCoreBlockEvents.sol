// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
interface IHookrCoreBlockEvents {
    /// @notice Existing pot reserve overflow moved to the liquidity owner's accrual without a new liability.
    event PoolAccrued(PoolId indexed id, Currency indexed currency, uint256 amount);
    /// @notice The pool's settings word is out of range, sets a field of a block that is off, turns no block on, or
    ///         asks for something the pool cannot have (dynamic fees, a zero protocol share, a Holder Pot outflow
    ///         without a Holder Pot).
    error CoreBlocksConfig();
    /// @notice poke ran while the PoolManager was unlocked, where a flash-lent balance could pass a look.
    error ManagerUnlocked();
    /// @notice The pool runs no core block that this call serves.
    error NotCoreBlocksPool();

    /// @notice A pool froze its core blocks at bind.
    /// @param id The pool.
    /// @param word Its settings word.
    event CoreBlocksBound(PoolId indexed id, uint256 word);

    /// @notice A swap paid core-block charges in the pool's quote, net of Hookr's share, to their outflows. Charges paid
    ///         as LP fee go to in-range liquidity inside the swap and are not in this event.
    /// @param id The pool.
    /// @param payer The swap's payer.
    /// @param exitFee Exit Clock's quote charge, net of Hookr's share.
    /// @param stormFee Storm Fee's quote charge, net of Hookr's share.
    /// @param potCut Holder Pot's own cut, net of Hookr's share.
    event CoreBlocksTaken(PoolId indexed id, address indexed payer, uint256 exitFee, uint256 stormFee, uint256 potCut);

    /// @notice Exit Clock gave a seller back what its quote charged above the exact rate of what filled.
    /// @param id The pool.
    /// @param seller The seller.
    /// @param amount The rebate, credited to its claims in the pool's quote.
    event ExitRebated(PoolId indexed id, address indexed seller, uint256 amount);

    /// @notice Holder Pot closed an epoch and paid its pot to the holders by weight.
    /// @param id The pool.
    /// @param epoch The epoch closed, 1 for the one that starts at the bind.
    /// @param pot The pot paid out.
    /// @param weight The total holder weight it was split by.
    /// @param checkpoint The checkpoint the payout was written to.
    event HolderPotClosed(PoolId indexed id, uint256 indexed epoch, uint256 pot, uint256 weight, uint256 checkpoint);

    /// @notice Holder Pot closed an epoch that no holder had yet earned in, and carried its pot into the next.
    /// @param id The pool.
    /// @param epoch The epoch whose pot carried, 1 for the one that starts at the bind.
    /// @param pot The pot carried.
    event HolderPotCarried(PoolId indexed id, uint256 indexed epoch, uint256 pot);

    /// @notice A holder's earnings were moved into its claims, payable with the Rules' claim.
    /// @param id The pool.
    /// @param wallet The holder.
    /// @param amount The amount credited, in the pool's quote.
    event HolderCredited(PoolId indexed id, address indexed wallet, uint256 amount);

    /// @notice A look (the holder's own swap, or a poke) found it holding less than its records: its uncredited earnings
    ///         went back to the pot, less the poker's bounty, and its clock restarted at what it holds.
    /// @param id The pool.
    /// @param wallet The holder.
    /// @param poker The poke's caller, paid the bounty; zero for the holder's own swap.
    /// @param amount The earnings forfeited.
    /// @param bounty The poker's part of them.
    event HolderForfeited(
        PoolId indexed id, address indexed wallet, address indexed poker, uint256 amount, uint256 bounty
    );

    /// @notice A holder's tracked position changed.
    /// @param id The pool.
    /// @param wallet The holder.
    /// @param position Its tracked tokens.
    /// @param entryEpoch The epoch its holding time counts from, 1 for the one that starts at the bind.
    event HolderMoved(PoolId indexed id, address indexed wallet, uint256 position, uint256 entryEpoch);

    /// @notice Storm Fee moved the pool's fee level.
    /// @param id The pool.
    /// @param fromPips The level before, in pips.
    /// @param toPips The level after, in pips.
    /// @param variance The pool's realized variance after the sample, in ticks squared.
    event StormStepped(PoolId indexed id, uint256 fromPips, uint256 toPips, uint256 variance);

}
