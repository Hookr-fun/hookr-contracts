// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrLaunchFee
/// @notice The launch fee's terms, served by HookrLauncher's fallback from HookrLaunchChecks.
interface IHookrLaunchFee {
    /// @notice The fee every launch pays now, the treasury whose target receives it, and a pending change: its fee, its
    ///         treasury and when it can apply (zero for none).
    /// @return fee The fee every launch pays now, in wei of the native currency; zero for none.
    /// @return treasury The treasury whose `target()` receives the fee.
    /// @return pendingFee The proposed fee, zero when none is pending.
    /// @return pendingTreasury The proposed treasury, zero when none is pending.
    /// @return readyAt When the proposal can apply (block.timestamp), zero when none is pending.
    function launchFee()
        external
        view
        returns (uint256 fee, address treasury, uint256 pendingFee, address pendingTreasury, uint256 readyAt);

    /// @notice The registry's owner proposes a launch fee of `fee` wei (at most 0.01 of the native currency) paid to
    ///         `treasury`'s target; it can apply from the registry's timelock delay on, for 14 days. A new proposal
    ///         replaces a pending one.
    /// @param fee The proposed fee in wei, at most 0.01 of the native currency.
    /// @param treasury The treasury whose target receives it; above a zero fee it must hold code.
    function proposeLaunchFee(uint96 fee, address treasury) external;

    /// @notice The registry's owner applies its own pending proposal from its ready time and for 14 days after it.
    function acceptLaunchFee() external;

    /// @notice The registry's owner or guardian sets the fee to zero at once and drops any pending proposal.
    function clearLaunchFee() external;
}
