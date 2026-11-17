// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRevenueSource} from "./IHookrRevenueSource.sol";
import {IHookrForwarding} from "./IHookrForwarding.sol";

/// @title Hookr Doppler adapter, a revenue source of the HookRevenue Tokenizer
/// @notice A beneficiary share of one Doppler launch (Long's launches on Robinhood Chain), standing in for a revenue
///         token. The share's holder makes the adapter (HookrDopplerAdapterFactory), moves its share to it
///         (`updateBeneficiary(poolId, adapter)` on the Doppler hook initializer, the holder's own call), and the
///         revenue token adds the adapter as a stream, at mint or later; the adapter collects what the share earns
///         and pushes it to the token when the token pulls. One adapter per (holder, revenue token, launch). Each
///         holder of a launch makes and binds its own adapter: a share moved into an adapter someone else made is a
///         gift to that adapter's token.
/// @dev One-way: the adapter has no function that moves the share once the token has it as a door, and Doppler has
///      no way to move a share but its holder's own call, so nobody can ever take the share from the token
///      (`revocable()` is false). `pull` takes calls from the revenue token alone (`OnlyRevenueToken`) and pays only
///      a token that has the adapter as a door (`NotADoor` otherwise), so the share never feeds a token that took no
///      Hookr leg for it. Until then the origin can take its own share back (`abort`), only when the adapter holds
///      exactly the share the origin held when the adapter was made and that share was more than half of the launch:
///      then no other holder's share can be in the adapter. A share of half the launch or less (Long's creator holds
///      47.5%) has no way back once bound: if the token never adds the adapter (the mint fails or is abandoned, the
///      token's stream manager is someone else or renounced, or the pool leaves `Locked` first), the share and what
///      it collects stay in the adapter for good. The tokenizer adds the adapter only once it is bound, so a holder
///      binds and adds in one batched transaction (`updateBeneficiary`, then `tokenize` at the mint or `addStreams`),
///      and a failed add undoes the bind.
///
///      A pull: `collectFees(poolId)` on the initializer, which pays the caller its share in the pool's two currencies
///      (the adapter must be the caller: a collection by anyone else only leaves the adapter's part owed in the
///      initializer, paid on the adapter's next call), then the forwards: native ETH into the token's empty `receive`,
///      the numeraire and the launch token by `transfer` when the token lists them (`isAsset`) and, less Hookr's
///      leg, into the token's drop box otherwise (IHookrForwarding; an immediate drop at a release period under an hour, the
///      stray stream at an hour or more). Each step, balance reads included,
///      is its own attempt with a gas cap; a failed one leaves what it could not move where it is, for the next pull,
///      and undoes nothing else.
///
///      The stream stops when the pool stops collecting: Doppler collects only while the pool is `Locked`, and
///      `graduate` (anyone, once the pool's Doppler hook has the graduation flag and the price reached the far
///      tick) moves it out of `Locked` for good. It also stops while the numeraire refuses to move: Doppler pays a
///      holder both currencies in one call, so an ERC-20 numeraire whose issuer blocks the adapter or the
///      initializer, pauses the token, burns from the initializer or swaps its logic stops the launch-token side
///      too, for as long as the issuer keeps it so. `ends()` answers `FOREVER` only for a native ETH numeraire with
///      no graduation path, `REVOCABLE` with zero otherwise, and `ENDED` once the pool left `Locked` or the adapter
///      holds no share.
interface IHookrDopplerAdapter is IHookrRevenueSource, IHookrForwarding {
    /// @notice The adapter's own `collectFees(pool)` call went through; Doppler's `Release` event has what it paid.
    event Collected(PoolId indexed pool);
    /// @notice The adapter's `collectFees(pool)` call reverted this time (the pool left `Locked`, a currency refused
    ///         the payout, or out of gas).
    event CollectFailed(PoolId indexed pool);
    /// @notice Before the token added the adapter, `shares` went back to `origin`, with what the adapter held.
    event Aborted(address indexed origin, uint256 shares);

    /// @notice A pin has no code, the launch is not one of the initializer's locked pools, or an address is zero.
    error InvalidConfig();
    /// @notice The launch's numeraire or launch token is the revenue token itself. Doppler pays a holder both
    ///         currencies in one call and the token refuses a transfer to its own door, so no collection could ever
    ///         go through.
    error PairIsRevenueToken();
    /// @notice Only `origin` may abort.
    error NotOrigin(address caller);
    /// @notice The revenue token has this adapter as a door: no path back.
    error AlreadyLive();
    /// @notice The revenue token does not have this adapter as a door: it pays nothing.
    error NotADoor();
    /// @notice `abort` cannot tell the adapter's `held` shares are the origin's own: they differ from
    ///         `originShares`, or `originShares` is not more than half of the launch.
    error AbortRefused(uint256 held, uint256 originShares);
    /// @notice A pay-back during `abort` was refused.
    error TransferFailed(address asset);

    /// @notice The source kind id: `keccak256("doppler.v4")`.
    function SOURCE_KIND() external view returns (bytes32);
    /// @notice Gas the adapter's `collectFees` call gets: 1,500,000 (it pokes every curve position of the pool,
    ///         about 25,000 gas each, and makes two transfers; a live Long pool measured 315,370). The factory only
    ///         makes an adapter for a pool whose collection fits in 1,000,000.
    function COLLECT_GAS() external view returns (uint256);

    /// @notice The Doppler hook initializer that holds the share and the pool's curve positions.
    function initializer() external view returns (address);
    /// @notice The Doppler Airlock of the launch (where its timelock and integrator are read).
    function airlock() external view returns (address);
    /// @notice The launched token (the Doppler "asset").
    function launchToken() external view returns (address);
    /// @notice The pool's other side (address zero for native ETH).
    function numeraire() external view returns (Currency);
    /// @notice The launch's pool on the initializer.
    function poolId() external view returns (PoolId);
    /// @notice The account that made the adapter while holding a share: the only account that may `abort`, and
    ///         where the share goes back to.
    function origin() external view returns (address);
    /// @notice The shares (WAD) the origin and this adapter's address held when the adapter was made.
    function originShares() external view returns (uint256);
    /// @notice The launch's integrator in the Airlock, read when the adapter was made: whoever called the Airlock's
    ///         `create` named it, so it marks a launch platform without proving one.
    function integrator() external view returns (address);

    /// @notice Whether the revenue token has this adapter as one of its doors. The app's "verified" is an
    ///         adapter of the deployed factory (`isAdapter`) that is a door of its `revenueToken`.
    function isDoor() external view returns (bool);
    /// @notice The shares (WAD) of the launch's fees the adapter holds now.
    function shares() external view returns (uint256);
    /// @notice Always false: a Doppler share moves only by its holder's own call, and the adapter makes none once
    ///         the revenue token has it as a door.
    function revocable() external pure returns (bool);
    /// @notice Whether a path exists that would end fee collection for the pool: it is still `Locked` and either
    ///         its Doppler hook has the graduation flag or a live timelock can change the hook.
    function graduable() external view returns (bool);
    /// @notice The launch's timelock when it can change the pool's Doppler hook, zero when no one can (zero or the
    ///         dead address).
    function hookSetter() external view returns (address);
    /// @notice What the initializer already collected and owes the adapter now: in the numeraire and in the launch
    ///         token. Fees the pool's positions earned since the last collection are not counted.
    function pending() external view returns (uint256 numeraireAmount, uint256 launchTokenAmount);

    /// @notice Collects the adapter's share of another pool on the same initializer (a share moved in by mistake)
    ///         into the adapter; its currencies that are not the adapter's own leave through `dropStray`. Anyone.
    function collect(PoolId pool) external;
    /// @notice While the token does not have the adapter as a door, hands the adapter's share back to `origin` and pays
    ///         `origin` what the adapter holds of the pool's two currencies. Only `origin`, and only when the adapter
    ///         holds exactly `originShares` and that is more than half of the launch (`AbortRefused` otherwise).
    function abort() external;
}
