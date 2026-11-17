// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title pools.trade FeeSplitter, the subset the FEEB adapter and the state view use
/// @notice The custodian of a pools.trade launch's Uniswap v4 position: it owns the position whose id equals the Fee
///         Beneficiary NFT's id and, on `collectFees`, takes the position's LP fees and splits them by fixed shares.
///         The vault's share of the native side reaches the vault, which credits it to the NFT (`amounts`).
/// @dev The adapter collects through a splitter only when its runtime code hashes to the pinned `splitterCodeHash`.
///      `collectFees` returns nothing, so it is declared without a return value.
interface IFeeSplitter {
    /// @notice One recipient's fixed shares: of the native side, of the token side, both in basis points of 10,000,
    ///         and whether the recipient is called back with what it received.
    struct FeeSplit {
        address recipient;
        uint16 nativeBps;
        uint16 tokenBps;
        bool useCallback;
    }

    /// @notice Takes the LP fees of each position in `tokenIds`, which the splitter must own, and pays them out by the
    ///         shares together with whatever the splitter already held. Anyone may call. Reverts while the
    ///         PoolManager is unlocked.
    function collectFees(uint256[] calldata tokenIds) external;

    /// @notice The fixed shares, set at construction.
    function getSplits() external view returns (FeeSplit[] memory);

    /// @notice The v4 PositionManager whose positions the splitter holds.
    function positionManager() external view returns (address);
}
