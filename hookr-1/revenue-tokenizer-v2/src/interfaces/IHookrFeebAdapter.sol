// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrRevenueDoor} from "./IHookrRevenueDoor.sol";
import {IHookrForwarding} from "./IHookrForwarding.sol";
import {IHookrDoorTerm} from "./IHookrDoorTerm.sol";

/// @title Hookr FEEB adapter, part of the HookRevenue Tokenizer
/// @notice Holds one pools.trade Fee Beneficiary NFT until its term ends (7 days or more, or forever) and claims its
///         creator fee for a revenue token. Only the NFT's owner can claim, and the vault pays msg.sender, so the
///         adapter is the owner and the claimer; what arrives is forwarded to the revenue token on its next pull.
///
///         The vault holds only what the launch's fee splitter has paid it. The splitter owns the Uniswap v4
///         position whose id equals the NFT's id, and the position's fees reach the vault only when someone calls the
///         splitter's `collectFees`, which anyone may. So before it claims, the adapter has the splitter collect the
///         position: when the position's owner on `positionManager` has the runtime code hash `splitterCodeHash`,
///         the adapter calls `collectFees([tokenId])` on it, on its own attempt with `COLLECT_GAS`. A collect that
///         fails or does not apply never stops the claim.
/// @dev Made by HookrFeebAdapterFactory for its tokenizer alone, which moves the NFT in from the account that adds the
///      stream; that account is `returnTo`. `pull` takes calls from the revenue token alone. From the unlock time
///      anyone may `release`: the splitter's collect, then a strict final claim into the adapter, then the NFT goes
///      back to `returnTo` by a plain `transferFrom`, with no approval left on it and nothing pending in the vault;
///      the claimed ETH reaches the token on its next pull. A vault that refuses the final claim keeps the NFT here
///      until it pays.
interface IHookrFeebAdapter is IHookrRevenueDoor, IHookrForwarding, IHookrDoorTerm {
    /// @notice The vault has no code.
    error InvalidConfig();
    /// @notice The adapter does not own the NFT; `owner` does.
    error NotBound(address owner);

    /// @notice The vault paid the NFT's pending fee: `eth` reached the adapter.
    event Claimed(uint256 eth);
    /// @notice The vault refused the claim this time; the fee stays pending there for a later pull.
    event ClaimFailed();
    /// @notice The fee splitter `splitter` collected the NFT's position, paying the vault its share.
    event FeesCollected(address indexed splitter);
    /// @notice The fee splitter `splitter` refused the collect this time; the fees stay in the position.
    event CollectFailed(address indexed splitter);
    /// @notice The NFT went back to `returnTo`.
    event Released(address indexed returnTo);

    /// @notice Gas the vault's `claim` gets during a pull: 500,000.
    function CLAIM_GAS() external view returns (uint256);
    /// @notice Gas the read of the position's owner gets: 50,000.
    function OWNER_READ_GAS() external view returns (uint256);
    /// @notice Gas the splitter's `collectFees` gets: 600,000, twice the most a live collect took on 4663.
    function COLLECT_GAS() external view returns (uint256);
    /// @notice The gas stipend the tokenizer gives this door: 1,700,000 (the owner read, the collect, the vault's
    ///         reads and the claim at their caps, and the native forward at `SEND_GAS`).
    function PULL_GAS() external view returns (uint32);
    /// @notice The pools.trade vault holding the NFT.
    function vault() external view returns (address);
    /// @notice The Uniswap v4 PositionManager whose position id is the NFT's id.
    function positionManager() external view returns (address);
    /// @notice The runtime code hash of a pools.trade fee splitter: the position's owner is collected only when its
    ///         code hashes to this.
    function splitterCodeHash() external view returns (bytes32);
    /// @notice The fee splitter a pull collects before it claims: the owner of position `tokenId` on
    ///         `positionManager` when its runtime code hashes to `splitterCodeHash`, zero otherwise or when the owner
    ///         cannot be read.
    function splitter() external view returns (address);
    /// @notice The Fee Beneficiary NFT this adapter claims for.
    function tokenId() external view returns (uint256);
    /// @notice Whether the NFT went back to `returnTo`.
    function released() external view returns (bool);
    /// @notice Whether the adapter owns the NFT.
    function bound() external view returns (bool);
    /// @notice The fee pending for the NFT in the vault: the ETH side, then the other side. A pull first has the
    ///         splitter collect the position, so it can bring more than this; HookrRevenueStateView adds that share.
    function pending() external view returns (uint256 eth, uint256 other);

    /// @notice From the unlock time, has the splitter collect the position, claims the NFT's pending fee into the
    ///         adapter and returns the NFT to `returnTo`. Anyone may call. Reverts before the unlock, always on a
    ///         right locked forever, once released, and when the vault refuses the final claim; a collect that fails
    ///         does not stop it.
    function release() external;
}
