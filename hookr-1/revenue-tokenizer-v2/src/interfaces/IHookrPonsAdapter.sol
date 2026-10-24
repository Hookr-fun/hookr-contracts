// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRevenueSource} from "./IHookrRevenueSource.sol";
import {IHookrForwarding} from "./IHookrForwarding.sol";

/// @title Hookr Pons adapter, part of the HookRevenue Tokenizer
/// @notice The creator fee recipient of one Pons V2 launch, standing in for a revenue token: the creator hands the
///         launch's creator right to the adapter (`transferCreatorFeeRecipient` on the Pons factory), the adapter
///         claims what Pons credits it in the fee escrow and pushes it to the revenue token when the token pulls.
///         One adapter per Pons launch and revenue token, made by HookrPonsAdapterFactory before the token adds it
///         as a stream (at mint or later; the token may not exist yet).
/// @dev One-way from the adapter's side: no function hands the right on, and the adapter is never a payee of the
///      token. The only way the right leaves is what the Pons factory itself allows: its owner can propose another
///      recipient for any launch and anyone executes the proposal after a three-day timelock, so a Pons stream is
///      revocable and the adapter says so (`ends()` is `REVOCABLE`, `pendingOverride()` shows a proposal). While the
///      token has not added the adapter as a door the right can go back to the account it came from (`abort`),
///      together with its escrow income and held native, quote and memecoin balances. A claim or refund that fails
///      can be retried by the origin with `recoverAbort`. When the Pons owner's override moves the right away before
///      the token admits the adapter, `abort` cannot run (the adapter no longer holds the right), but the origin
///      still takes the escrow income credited before with `recoverAbort`: an unbound adapter can never be admitted.
///      Once the token has it as a door there is no refund path, override or not. `pull`
///      takes calls from the revenue token alone (`OnlyRevenueToken`) and pays only a token that has the adapter as a
///      door (`IHookrRevenueToken.isDoor`, `NotADoor` otherwise), so a Pons right never feeds a token that did not
///      take Hookr's leg for it.
///
///      Frozen at bind: the launch's buyback flag. On the Pons factory only the current creator recipient may turn
///      buyback on and only the owner may turn it off, and the adapter never calls either; set it before the
///      transfer. `buybackEnabled()` reads it. A Pons stream has no term of its own: it is forever unless Pons moves
///      it, and the only exit before the token adds it is `abort`.
///
///      A pull: when the launch is in its pool and no internal swap is needed (nothing pending in the memecoin and
///      no buyback pending in the quote), the adapter, being the pool's creator, sweeps the quote-denominated fees
///      itself so the stream does not wait for the Pons operator; then, when the buyback vault names the adapter
///      as the creator recipient and something vested, it releases the buyback (the vault credits the escrow with
///      the memecoin); then it claims every escrow balance it has (native ETH, the quote asset, the memecoin) and
///      forwards: native ETH into the token's empty `receive` with `SEND_GAS`, the quote asset by `transfer` with
///      `FORWARD_GAS`; the memecoin is forwarded when the token lists it as an asset and, less Hookr's leg, handed to
///      the token's drop box otherwise (one immediate drop at a release period under an hour, the stray stream at an hour
///      or more). Each step of a pull is its own attempt with a gas cap; one that fails leaves what it could not move
///      where it is, for the next pull: the escrow keeps a balance until it is claimed. A launch quoted in the
///      revenue token itself is refused (`PairIsRevenueToken`).
interface IHookrPonsAdapter is IHookrRevenueSource, IHookrForwarding {
    /// @notice The adapter's own creator-side sweep of `poolId` went through.
    event Swept(PoolId indexed poolId);
    /// @notice `amount` of the memecoin vested in the buyback vault was released to the escrow.
    event BuybackReleased(uint256 amount);
    /// @notice The escrow paid `eth` native, `quoteAmount` of the quote asset and `memecoinAmount` of the memecoin.
    event Claimed(uint256 eth, uint256 quoteAmount, uint256 memecoinAmount);
    /// @notice The right went back to `origin` before the adapter was admitted.
    event Aborted(address indexed origin);
    /// @notice Pre-admission income in `asset` went to the origin's chosen `to` after cancellation.
    event AbortRecovered(address indexed asset, address indexed to, uint256 amount);
    /// @notice A refund was refused, or the balance read failed (`amount` zero); the origin may retry it.
    event AbortRecoveryFailed(address indexed asset, address indexed to, uint256 amount);

    /// @notice The factory's launch record does not exist or has no code behind it.
    error InvalidConfig();
    /// @notice The launch's quote is the revenue token itself. The escrow pays a claim to the adapter and the token
    ///         refuses a transfer to its own door, so that side could never leave the escrow.
    error PairIsRevenueToken();
    /// @notice Only `origin` may abort.
    error NotOrigin(address caller);
    /// @notice The revenue token has this adapter as a door: no path back.
    error AlreadyLive();
    /// @notice The revenue token does not have this adapter as a door: it pays nothing.
    error NotADoor();
    /// @notice Recovery requires a completed cancellation, or a right Pons has moved away from the adapter.
    error NotAborted();
    /// @notice An existing revenue token did not answer its admission check, so recovery is refused.
    error AdmissionUnread();
    /// @notice A refund cannot be paid to zero or this adapter.
    error InvalidRecoveryRecipient(address to);

    /// @notice The source kind id: `keccak256("pons.v2")`.
    function SOURCE_KIND() external view returns (bytes32);
    /// @notice Gas the adapter's own sweep of the pool gets: 1,000,000.
    function SWEEP_GAS() external view returns (uint256);
    /// @notice Gas a buyback release gets: 400,000.
    function RELEASE_GAS() external view returns (uint256);

    /// @notice The Pons V2 launch factory that holds the creator right.
    function factory() external view returns (address);
    /// @notice The Pons meme hook of the launch's pool.
    function hook() external view returns (address);
    /// @notice The Pons fee escrow the adapter claims from.
    function escrow() external view returns (address);
    /// @notice The Pons buyback vault the adapter releases from.
    function buybackVault() external view returns (address);
    /// @notice The Pons launch (its memecoin).
    function memecoin() external view returns (address);
    /// @notice The launch's quote asset: native ETH (address zero) or an ERC-20. The adapter's only listed asset.
    function quote() external view returns (Currency);
    /// @notice The launch's pool on the meme hook (memecoin / quote, the launch's fee and spacing).
    function poolId() external view returns (PoolId);
    /// @notice The account that held the creator right when the adapter was made: the only account that may
    ///         `abort`, and where the right goes back to.
    function origin() external view returns (address);
    /// @notice Always true: the Pons factory owner can move the right after its timelock.
    function revocable() external pure returns (bool);
    /// @notice The factory owner's pending override of the launch's creator right, or zero fields: `newRecipient`
    ///         takes the right from `effectiveAt` to `expiresAt`, the moment anyone executes it.
    function pendingOverride() external view returns (address newRecipient, uint256 effectiveAt, uint256 expiresAt);
    /// @notice What a pull would claim now: the escrow's native, quote and memecoin balances for the adapter, and
    ///         the buyback the adapter could release.
    function pending()
        external
        view
        returns (uint256 eth, uint256 quoteAmount, uint256 memecoinAmount, uint256 buybackReleasable);

    /// @notice Whether the launch's buyback is on: half the creator's hook-fee share then buys the memecoin and
    ///         vests five years. Set by the creator before the bind; afterwards only Pons can turn it off.
    function buybackEnabled() external view returns (bool);
    /// @notice Whether the revenue token has this adapter as one of its doors. The app's "verified" is a
    ///         factory-made adapter (`HookrPonsAdapterFactory.isAdapter`) that is a door of its `revenueToken`.
    function isDoor() external view returns (bool);
    /// @notice Whether the origin successfully returned the right before admission.
    function aborted() external view returns (bool);

    /// @notice Hands the creator right back to `origin`. Only `origin`, only while the adapter is not a door of the
    ///         revenue token (`AlreadyLive` otherwise). The adapter must hold the right. Attempts to claim and refund all income in
    ///         native ETH, the quote and the memecoin to the origin. A refused currency stays claimable or held for
    ///         `recoverAbort`; a callback admitting the adapter reverts the cancellation.
    function abort() external;
    /// @notice Claims and refunds native ETH, the quote and the memecoin to `to` after a completed abort, or once the
    ///         right is no longer the adapter's (a Pons override executed before admission; `NotAborted` while it is
    ///         still bound and not aborted). Only the origin, and never after admission, including admission inside a
    ///         callback (`AlreadyLive`). Failed currencies stay available for another attempt; `to` cannot be zero or
    ///         this adapter.
    function recoverAbort(address to) external;
}
