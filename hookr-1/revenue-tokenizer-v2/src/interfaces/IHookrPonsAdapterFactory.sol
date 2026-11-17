// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr Pons adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes Pons adapters at predictable addresses, before the revenue token adds them as a stream. The app
///         labels an adapter this factory made as verified; any other IHookrRevenueSource is unverified.
/// @dev Only the launch's current creator fee recipient may create the adapter for it, so the adapter's `origin`
///      is the right's holder and `abort` can only ever return the right to the account that gave it; a launch
///      quoted in the revenue token itself is refused (`PairIsRevenueToken`). The address
///      depends on the origin, the revenue token and the memecoin, so two holders of the same right in turn each
///      get their own adapter. No owner.
interface IHookrPonsAdapterFactory {
    /// @notice An adapter was made for `memecoin`, paying `revenueToken`, by `origin`.
    event AdapterCreated(
        address indexed adapter, address indexed revenueToken, address indexed memecoin, address origin
    );

    /// @notice The launch factory has no code.
    error InvalidConfig();
    /// @notice The caller does not hold the launch's creator right; `recipient` does.
    error NotCreatorFeeRecipient(address caller, address recipient);
    /// @notice The Pons factory has no launch record for `memecoin`.
    error UnknownLaunch(address memecoin);
    /// @notice The launch's quote is the revenue token itself, which the escrow could never pay into the adapter.
    error PairIsRevenueToken();
    /// @notice `revenueToken` has code but does not answer `isDoor` in one word (a plain ERC-20, a Safe): the adapter's
    ///         admission check could never be read, so its `abort` and `recoverAbort` would never run.
    error NotARevenueToken(address revenueToken);

    /// @notice The Pons V2 launch factory every adapter reads.
    function launchFactory() external view returns (address);
    /// @notice True for every adapter this factory made.
    function isAdapter(address adapter) external view returns (bool);
    /// @notice Makes the adapter for `memecoin` paying `revenueToken`, with the caller as origin. Only the launch's
    ///         current creator fee recipient. `revenueToken` may not exist yet (the tokenizer's predicted address); one
    ///         that has code must answer `isDoor` (`NotARevenueToken`). An address with no code now that later gets
    ///         code which does not answer (an account delegated by EIP-7702) is not covered: check the address first.
    ///         The caller then hands the right to the adapter on the Pons factory.
    function create(address revenueToken, address memecoin) external returns (address adapter);
    /// @notice The address `create(revenueToken, memecoin)` called by `origin` gives.
    function predict(address origin, address revenueToken, address memecoin) external view returns (address);
}
