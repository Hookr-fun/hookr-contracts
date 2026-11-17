// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr FEEB adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes FEEB adapters for one tokenizer: deploys one at a CREATE2 address bound to the account adding the
///         stream, moves that account's Fee Beneficiary NFT into it and checks the adapter owns it, in one call.
/// @dev The account approves this factory for the NFT on the vault (`approve` or `setApprovalForAll`). Only the
///      pinned tokenizer calls `createFor`, so a FEEB right reaches a token's holders through the tokenizer alone,
///      which fixes Hookr's leg for it. Every adapter gets the factory's PositionManager and splitter code hash.
interface IHookrFeebAdapterFactory {
    /// @notice An adapter was made and holds its NFT.
    /// @param adapter The new adapter.
    /// @param returnTo The account adding the stream, who gets the NFT back.
    /// @param revenueToken The revenue token every pull pays.
    /// @param vault The pools.trade vault.
    /// @param tokenId The Fee Beneficiary NFT.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the address is bound to, with the depositor.
    event AdapterCreated(
        address indexed adapter,
        address indexed returnTo,
        address indexed revenueToken,
        address vault,
        uint256 tokenId,
        uint64 unlockAt,
        bytes32 salt
    );

    /// @notice The tokenizer address is zero.
    error TokenizerZero();
    /// @notice The PositionManager has no code or the splitter code hash is zero.
    error InvalidSplitterPins();
    /// @notice Only the pinned tokenizer makes adapters.
    error OnlyTokenizer();

    /// @notice The tokenizer this factory serves alone.
    /// @return The tokenizer.
    function tokenizer() external view returns (address);
    /// @notice True for every adapter this factory made.
    /// @param adapter The address to check.
    /// @return Whether this factory made it.
    function isAdapter(address adapter) external view returns (bool);
    /// @notice The Uniswap v4 PositionManager every adapter reads the position's owner on.
    /// @return The PositionManager.
    function positionManager() external view returns (address);
    /// @notice The runtime code hash of a pools.trade fee splitter every adapter collects through.
    /// @return The splitter's runtime code hash.
    function splitterCodeHash() external view returns (bytes32);

    /// @notice Makes the adapter for `depositor`'s NFT `tokenId` on `vault`, paying `revenueToken` until `unlockAt`
    ///         (or forever), and moves the NFT in. Only the tokenizer.
    /// @param depositor The account adding the stream: the NFT's owner, who approved this factory, and the adapter's
    ///        `returnTo`.
    /// @param revenueToken The revenue token every pull pays.
    /// @param vault The pools.trade vault; must have code.
    /// @param tokenId The Fee Beneficiary NFT.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the address is bound to, with the depositor.
    /// @return adapter The new adapter.
    function createFor(
        address depositor,
        address revenueToken,
        address vault,
        uint256 tokenId,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address adapter);

    /// @notice The address `createFor` gives for these arguments.
    /// @param depositor The account adding the stream.
    /// @param revenueToken The revenue token every pull pays.
    /// @param vault The pools.trade vault.
    /// @param tokenId The Fee Beneficiary NFT.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the address is bound to, with the depositor.
    /// @return The predicted adapter address.
    function predict(
        address depositor,
        address revenueToken,
        address vault,
        uint256 tokenId,
        uint64 unlockAt,
        bytes32 salt
    ) external view returns (address);
}
