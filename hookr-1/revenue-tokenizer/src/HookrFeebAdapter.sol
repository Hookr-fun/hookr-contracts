// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {HookrAssetList} from "./base/HookrAssetList.sol";
import {HookrForward} from "./libraries/HookrForward.sol";
import {IHookrFeebAdapter} from "./interfaces/IHookrFeebAdapter.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";
import {IBeneficiaryVault} from "./interfaces/external/IBeneficiaryVault.sol";

/// @title Hookr FEEB adapter, part of the HookRevenue Tokenizer
/// @notice Holds one pools.trade Fee Beneficiary NFT for good and claims its creator fee for a revenue token. The vault pays
///         msg.sender and only the NFT's owner may claim, so the adapter is both; what arrives is forwarded to the
///         token, whose next sync recognizes it.
/// @dev One-way by design: no function moves the NFT out, approves anyone or calls anything on the vault but `claim`
///      and its two reads. `onERC721Received` returns the selector and nothing else; the tokenizer pulls the NFT in its
///      own call and checks `ownerOf` afterwards. `receive()` is empty so the vault's payout lands. Only the token's
///      tokenizer deploys one (`OnlyTokenizer`): a Fee Beneficiary right reaches a token's holders through the
///      tokenizer alone, which takes the Hookr leg for it.
///
///      The vault's `claim` is not wrapped: a vault that refuses the claim makes the pull revert, and the revenue token's
///      sync, which calls each door in its own try/catch, skips this door for that block. Nothing is lost: the fee stays
///      pending in the vault.
contract HookrFeebAdapter is IHookrFeebAdapter, HookrAssetList {
    Currency internal constant NATIVE = Currency.wrap(address(0));
    /// @inheritdoc IHookrFeebAdapter
    uint256 public constant FORWARD_GAS = 300_000;
    /// @inheritdoc IHookrFeebAdapter
    uint256 public constant BALANCE_GAS = 50_000;

    /// @inheritdoc IHookrFeebAdapter
    address public immutable token;
    /// @inheritdoc IHookrFeebAdapter
    address public immutable vault;
    /// @inheritdoc IHookrFeebAdapter
    uint256 public immutable tokenId;

    /// @param token_ The revenue token every pull pays; its asset list is read once here (HookrAssetList), and its
    ///        `tokenizer` must be the deployer.
    /// @param vault_ The pools.trade vault holding the NFT; must have code.
    /// @param tokenId_ The Fee Beneficiary NFT.
    constructor(address token_, address vault_, uint256 tokenId_) HookrAssetList(token_) {
        if (vault_.code.length == 0) revert InvalidConfig();
        if (IHookrRevenueToken(token_).tokenizer() != msg.sender) revert OnlyTokenizer(msg.sender);
        token = token_;
        vault = vault_;
        tokenId = tokenId_;
    }

    /// @notice Takes the vault's payout; forwarded by the same pull.
    receive() external payable {}

    /// @inheritdoc IERC721Receiver
    /// @notice Accepts any ERC-721 and does nothing else: no state, no call, no check. Tokenization is the tokenizer's
    ///         own call.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc IHookrFeebAdapter
    function bound() public view returns (bool) {
        return IBeneficiaryVault(vault).ownerOf(tokenId) == address(this);
    }

    /// @inheritdoc IHookrFeebAdapter
    function pending() external view returns (uint256 eth, uint256 other) {
        return IBeneficiaryVault(vault).amounts(tokenId);
    }

    /// @inheritdoc IHookrFeebAdapter
    /// @dev Returns 0 without touching the vault while nothing is pending. Otherwise the adapter must own the NFT
    ///      (`NotBound` with the actual owner), claims with no minimums (the vault pays what is pending; the revenue token's
    ///      ledger needs no floor) and forwards its whole native balance to the token with an exact send (the token's
    ///      `receive` is empty, so that never fails). The other side compounds in the pool and pays nothing;
    ///      should a vault ever pay it as an ERC-20, every one of the token's ERC-20 assets this adapter then holds is
    ///      forwarded too, each on its own attempt with `FORWARD_GAS` after a balance read with `BALANCE_GAS`: an asset
    ///      whose issuer refuses the token's address, or whose `balanceOf` fails, stays here (`ForwardFailed`) and
    ///      never stops the ETH. Anything that is not one of the token's assets waits for `forwardUnlisted`.
    function pull() external returns (uint256 eth) {
        IBeneficiaryVault v = IBeneficiaryVault(vault);
        (uint256 pendingEth, uint256 pendingOther) = v.amounts(tokenId);
        if (pendingEth == 0 && pendingOther == 0) return 0;
        address owner = v.ownerOf(tokenId);
        if (owner != address(this)) revert NotBound(owner);
        v.claim(tokenId, 0, 0);
        eth = address(this).balance;
        if (eth != 0) HookrSettlement.send(NATIVE, token, eth);
        uint256 other;
        uint256 assets = _assetCount;
        for (uint256 a = 1; a < assets; ++a) {
            address asset = Currency.unwrap(_assetAt(a));
            (bool read, uint256 amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
            if (!read) {
                emit ForwardFailed(Currency.wrap(asset), 0);
                continue;
            }
            if (amount == 0) continue;
            if (HookrForward.transfer(asset, token, amount, FORWARD_GAS)) other += amount;
            else emit ForwardFailed(Currency.wrap(asset), amount);
        }
        emit Pulled(eth, other);
    }

    /// @inheritdoc IHookrFeebAdapter
    /// @dev The token's own `dropStray` then splits it. Native ETH and the token's assets are `pull`'s.
    function forwardUnlisted(address asset) external returns (uint256 amount) {
        if (asset == address(0)) revert ListedAsset(asset);
        uint256 assets = _assetCount;
        for (uint256 a = 1; a < assets; ++a) {
            if (Currency.unwrap(_assetAt(a)) == asset) revert ListedAsset(asset);
        }
        bool read;
        (read, amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
        if (!read || amount == 0) revert NothingToForward(asset);
        if (!HookrForward.transfer(asset, token, amount, FORWARD_GAS)) revert ForwardRefused(asset);
        emit UnlistedForwarded(asset, amount);
    }
}
