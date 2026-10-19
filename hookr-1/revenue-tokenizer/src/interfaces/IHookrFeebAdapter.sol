// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr FEEB adapter, part of the HookRevenue Tokenizer
/// @notice Holds one pools.trade Fee Beneficiary NFT for good and claims its creator fee for a revenue token. Only the NFT's
///         owner can claim, and the vault pays msg.sender, so the adapter is the owner and the claimer; whatever
///         arrives is forwarded to the revenue token, whose next sync recognizes it.
/// @dev One-way: nothing can move the NFT out. `onERC721Received` returns the selector and does nothing else;
///      tokenization is the tokenizer's own call, never a callback. `receive()` is empty so the vault's payout lands.
interface IHookrFeebAdapter is IERC721Receiver {
    /// @notice The vault has no code.
    error InvalidConfig();
    /// @notice The adapter does not own the NFT; `owner` does.
    error NotBound(address owner);
    /// @notice Only the revenue token's tokenizer deploys an adapter for it; `caller` is not it.
    error OnlyTokenizer(address caller);
    /// @notice `asset` is native ETH or one of the token's assets: `pull` forwards those.
    error ListedAsset(address asset);
    /// @notice The adapter holds nothing of `asset`, or its balance cannot be read.
    error NothingToForward(address asset);
    /// @notice `asset` refused the transfer to the revenue token.
    error ForwardRefused(address asset);

    /// @notice The NFT's pending fee was claimed: `eth` native and `other` of the other side were forwarded.
    event Pulled(uint256 eth, uint256 other);
    /// @notice The revenue token could not take `amount` of `currency` this time; it stays in the adapter for a later
    ///         pull. An `amount` of zero means the asset's balance could not be read.
    event ForwardFailed(Currency indexed currency, uint256 amount);
    /// @notice `amount` of `asset`, which the token does not list, was forwarded to the revenue token.
    event UnlistedForwarded(address indexed asset, uint256 amount);

    /// @notice Gas one ERC-20 forward to the revenue token gets: 300,000. A transfer that burns more fails on its own
    ///         and the asset waits here.
    function FORWARD_GAS() external view returns (uint256);
    /// @notice Gas one `balanceOf` read of an asset gets: 50,000. A read that fails leaves the asset here.
    function BALANCE_GAS() external view returns (uint256);
    /// @notice The revenue token every pull pays.
    function token() external view returns (address);
    /// @notice The pools.trade vault holding the NFT.
    function vault() external view returns (address);
    /// @notice The Fee Beneficiary NFT this adapter claims for.
    function tokenId() external view returns (uint256);
    /// @notice Whether the adapter owns the NFT.
    function bound() external view returns (bool);
    /// @notice The fee pending for the NFT: the ETH side, then the other side.
    function pending() external view returns (uint256 eth, uint256 other);

    /// @notice Claims the NFT's pending fee and forwards it to the revenue token (native ETH, and any other side that is
    ///         one of the token's assets). Anyone may call; the revenue token's sync does. Reverts `NotBound` until the
    ///         adapter owns the NFT.
    /// @return eth The native ETH forwarded.
    function pull() external returns (uint256 eth);

    /// @notice Moves the adapter's whole balance of `asset`, an ERC-20 that is not one of the token's assets, to
    ///         the revenue token, where `dropStray` splits it among the holders. Anyone may call; the only
    ///         destination is the token. Native ETH and the listed assets are `ListedAsset`; an empty or unreadable
    ///         balance is `NothingToForward`; a refused transfer is `ForwardRefused`.
    /// @return amount What moved.
    function forwardUnlisted(address asset) external returns (uint256 amount);
}
