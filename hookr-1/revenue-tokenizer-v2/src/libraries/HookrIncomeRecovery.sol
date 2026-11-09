// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrDropHost} from "../interfaces/IHookrDropHost.sol";
import {IHookrDropBox} from "../interfaces/IHookrDropBox.sol";
import {IHookrIncomeRecovery} from "../interfaces/IHookrIncomeRecovery.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrForward} from "./HookrForward.sol";

/// @title Hookr income recovery
/// @notice Bounded collection of drops earned by shares held in a revenue token or its box, and the token host's
///         income in another revenue token with its own-token share retired (`collectIncome`).
/// @dev Called by delegatecall under the host's reentrancy lock. Every destination is address(this), except a drop
///      paid in the host's own revenue token (`refusedAsset`): the token refuses its own shares and the box would
///      keep shares that earn nothing, so that share is claimed straight to 0xdead, as the basket door retires its
///      own-token income and drops, and no credit strands in the source box (where it would keep earning the host
///      token's income for the source's holders). Foreign calls get a fixed stipend and copy at most five words. No
///      host storage is read or written. `IncomeRetired` and `DropIncomeRetired` carry only what left the source for
///      0xdead across the capped claim: the smaller of the rise of 0xdead's balance of the host's revenue token and the
///      fall of the source's balance of it (the source revenue token's for income, the source box's for a drop), each
///      read before and after with `VIEW_GAS`; a failed read counts nothing. Never the figure the source answered, and
///      never another contract's retirement that code the source runs triggers during its claim (a basket door's
///      `claimDrop`, a door's `dropStray`, the forwarder's `flushClaims`): a source that moves none of its own host
///      shares makes the host emit nothing. A source that sends its own host shares elsewhere while such a
///      retirement runs can still be credited up to what it sent, so indexers book 0xdead's balance of the host, not
///      these events. The amount in `DropIncomeCollected` is what the source box's `claim` answered; a fake source can
///      report any figure there, so indexers should book the host's balance changes (the box's `StrayAdded` and
///      `Dropped`, the token's recognition), never that event.
library HookrIncomeRecovery {
    address private constant DEAD = address(0xdead);

    uint256 private constant VIEW_GAS = 100_000;
    uint256 private constant CLAIM_GAS = 1_600_000;
    uint256 private constant HOST_GAS = 160_000;
    uint256 private constant BOX_ASSET_GAS = 400_000;

    /// @notice The token host's income in another revenue token: when `revenueToken` lists the host itself as an asset,
    ///         the host's share of that asset is claimed to 0xdead first (the host refuses its own shares, so
    ///         `claimAll` skips it and the credit would strand in `revenueToken`, where its shares keep earning the
    ///         host's income for `revenueToken`'s holders), with `CLAIM_GAS` and only with that much left
    ///         (`IncomeRecoveryStarved(asset)` otherwise); then `claimAll(address(this))` with the gas left, by a call
    ///         that copies no return data, as the host's own `collectIncome` always made it. Nothing due, an unread
    ///         listing or a source that is no revenue token moves nothing and does not revert.
    /// @return retired What left `revenueToken` for 0xdead: the smaller of the rise of 0xdead's balance of the host
    ///         and the fall of `revenueToken`'s balance of the host across the claim (zero when nothing of its own
    ///         moved or a read failed, whatever the source answered).
    function collectIncome(address revenueToken) external returns (uint256 retired) {
        if (revenueToken == address(this)) return 0;
        Currency self = Currency.wrap(address(this));
        (bool read, uint256 listed) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.isAsset, (self)), VIEW_GAS);
        if (read && listed != 0) {
            (bool found, uint256 asset) =
                HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.assetOf, (self)), VIEW_GAS);
            if (found) {
                (bool before, uint256 dead) = HookrForward.balanceOf(address(this), DEAD, VIEW_GAS);
                if (gasleft() < CLAIM_GAS + CLAIM_GAS / 63 + VIEW_GAS) {
                    revert IHookrIncomeRecovery.IncomeRecoveryStarved(asset);
                }
                // The source's balance is read after the check, from the room it keeps past the claim, so the floor
                // stays where IHookrRevenueToken.collectIncome and docs/gas.md put it.
                (bool heldRead, uint256 held) = HookrForward.balanceOf(address(this), revenueToken, VIEW_GAS);
                bytes memory retire = abi.encodeCall(IHookrRevenueToken.claim, (asset, DEAD));
                assembly ("memory-safe") {
                    pop(call(CLAIM_GAS, revenueToken, 0, add(retire, 0x20), mload(retire), 0, 0))
                }
                retired = _retired(address(this), revenueToken, before && heldRead, dead, held);
                if (retired != 0) emit IHookrIncomeRecovery.IncomeRetired(revenueToken, asset, retired);
            }
        }
        bytes memory data = abi.encodeCall(IHookrRevenueToken.claimAll, (address(this)));
        assembly ("memory-safe") {
            pop(call(gas(), revenueToken, 0, add(data, 0x20), mload(data), 0, 0))
        }
    }

    /// @notice Claims the host's own drop credits. `refusedAsset` is the revenue token whose holders the host pays.
    function collectDrops(address revenueToken, address refusedAsset, uint256[] calldata dropIds)
        external
        returns (uint256[] memory amounts)
    {
        (, amounts) = _collect(revenueToken, refusedAsset, dropIds, HOST_GAS);
    }

    /// @notice The same collection with the paid currencies, for a box that recognizes each as a stray (an immediate
    ///         drop at a release period under an hour, the stray stream at an hour or more).
    function collectBoxDrops(address revenueToken, address refusedAsset, uint256[] calldata dropIds)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        return _collect(revenueToken, refusedAsset, dropIds, HOST_GAS + dropIds.length * BOX_ASSET_GAS);
    }

    function _collect(address revenueToken, address refusedAsset, uint256[] calldata dropIds, uint256 reserve)
        private
        returns (address[] memory assets, uint256[] memory amounts)
    {
        uint256 n = dropIds.length;
        if (n > 8) revert IHookrIncomeRecovery.TooManyRecoveryDrops(n);
        amounts = new uint256[](n);
        assets = new address[](n);
        (bool read, uint256 boxWord) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrDropHost.dropBox, ()), VIEW_GAS);
        if (!read || boxWord >> 160 != 0) return (assets, amounts);
        address box = address(uint160(boxWord));
        if (box.code.length == 0 || box == address(this)) return (assets, amounts);
        uint256[] memory one = new uint256[](1);
        for (uint256 i; i < n; ++i) {
            uint256 id = dropIds[i];
            if (gasleft() < CLAIM_GAS + CLAIM_GAS / 63 + VIEW_GAS + reserve) {
                revert IHookrIncomeRecovery.IncomeRecoveryStarved(id);
            }
            (bool valid, address asset) = _asset(box, id);
            if (!valid) continue;
            one[0] = id;
            if (asset == refusedAsset) {
                (bool before, uint256 dead, uint256 held) = _balances(refusedAsset, box);
                _claim(box, abi.encodeCall(IHookrDropBox.claim, (one, DEAD)));
                uint256 retired = _retired(refusedAsset, box, before, dead, held);
                if (retired != 0) emit IHookrIncomeRecovery.DropIncomeRetired(revenueToken, id, retired);
                continue;
            }
            uint256 amount = _claim(box, abi.encodeCall(IHookrDropBox.claim, (one, address(this))));
            if (amount != 0) {
                assets[i] = asset;
                amounts[i] = amount;
                emit IHookrIncomeRecovery.DropIncomeCollected(revenueToken, id, amount);
            }
        }
    }

    function _asset(address box, uint256 id) private view returns (bool valid, address asset) {
        bytes memory data = abi.encodeCall(IHookrDropBox.dropAt, (id));
        uint256 word;
        assembly ("memory-safe") {
            let p := mload(0x40)
            valid := staticcall(VIEW_GAS, box, add(data, 0x20), mload(data), p, 0xa0)
            valid := and(valid, eq(returndatasize(), 0xa0))
            word := mload(p)
            valid := and(valid, iszero(shr(160, word)))
        }
        asset = address(uint160(word));
    }

    /// @dev 0xdead's and `source`'s balances of `token`, each a capped read; `read` only when both succeeded.
    function _balances(address token, address source) private view returns (bool read, uint256 dead, uint256 held) {
        (bool deadRead, uint256 deadBalance) = HookrForward.balanceOf(token, DEAD, VIEW_GAS);
        (bool heldRead, uint256 heldBalance) = HookrForward.balanceOf(token, source, VIEW_GAS);
        return (deadRead && heldRead, deadBalance, heldBalance);
    }

    /// @dev What left `source` for 0xdead since `dead` and `held` were read before the claim (`before` false:
    ///      unread, so nothing is counted): the smaller of 0xdead's rise and `source`'s fall in `token`, so a
    ///      retirement code inside the claim triggers elsewhere is never counted as the source's; zero when a read
    ///      after fails or either did not move.
    function _retired(address token, address source, bool before, uint256 dead, uint256 held)
        private
        view
        returns (uint256)
    {
        (bool read, uint256 deadNow, uint256 heldNow) = _balances(token, source);
        if (!before || !read || deadNow <= dead || heldNow >= held) return 0;
        uint256 rise = deadNow - dead;
        uint256 fall = held - heldNow;
        return rise < fall ? rise : fall;
    }

    function _claim(address box, bytes memory data) private returns (uint256 amount) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            let ok := call(CLAIM_GAS, box, 0, add(data, 0x20), mload(data), p, 0x60)
            ok := and(ok, eq(returndatasize(), 0x60))
            ok := and(ok, and(eq(mload(p), 0x20), eq(mload(add(p, 0x20)), 1)))
            amount := mul(mload(add(p, 0x40)), ok)
        }
    }
}
