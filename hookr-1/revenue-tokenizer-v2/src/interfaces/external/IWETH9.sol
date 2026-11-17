// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Wrapped native token, the subset the doors and adapters use
/// @notice Wraps and unwraps native ETH one to one. The v3 position-NFT door unwraps what it collects in it, so the
///         revenue token streams native ETH instead of listing the wrapper as an asset.
/// @dev On Robinhood Chain 4663 the wrapper is an upgradeable proxy; an unwrap that fails is reported, never fatal,
///      and the wrapper then stays where it is until a later pull (or is forwarded as an ERC-20 asset when the
///      token lists it).
interface IWETH9 is IERC20 {
    /// @notice Wraps `msg.value`.
    function deposit() external payable;
    /// @notice Unwraps `amount` to the caller.
    function withdraw(uint256 amount) external;
}
