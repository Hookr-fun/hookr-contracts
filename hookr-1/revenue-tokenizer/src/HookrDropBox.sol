// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IHookrDropBox} from "./interfaces/IHookrDropBox.sol";
import {IHookrDropHost} from "./interfaces/IHookrDropHost.sol";
import {HookrAuthorizations} from "./base/HookrAuthorizations.sol";
import {HookrRevenueGuard} from "./base/HookrRevenueGuard.sol";

/// @title Hookr drop box, part of the HookRevenue Tokenizer
/// @notice Where anyone drops ETH or any ERC-20 for the holders of one revenue token; each holder claims its share of
///         each drop by its balance at the end of the block before the drop, itself or by a signature anyone relays.
///         Whatever reaches the box without `drop` (a plain ERC-20 transfer, ETH through `receive`) is a stray that
///         anyone turns into a drop with `dropStray`. See `IHookrDropBox` for the rules.
/// @dev Claims follow checks-effects-interactions and every cash-moving function takes the transient lock, so a
///      native payout recipient that runs code cannot re-enter a claim or a drop, and a hostile ERC-20's
///      `transferFrom` cannot nest a second drop inside the balance measurement of the first. The box keeps one
///      running total per asset of what its drops still owe (`owed`): `drop` and `dropStray` add to it, each claim
///      subtracts what it paid, so a stray is the balance less one storage read, never a loop over the drops. The box
///      has its own EIP-712 domain ("Hookr Drop Box", version "1", its address) and its own nonces
///      (HookrAuthorizations).
contract HookrDropBox is IHookrDropBox, HookrRevenueGuard, HookrAuthorizations {
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrDropBox
    bytes32 public constant CLAIM_DROPS_TYPEHASH =
        keccak256("ClaimDrops(address holder,uint256[] dropIds,address to,bytes32 nonce,uint256 deadline)");

    /// @inheritdoc IHookrDropBox
    address public immutable token;

    Drop[] private _drops;
    /// @inheritdoc IHookrDropBox
    mapping(uint256 dropId => mapping(address holder => bool)) public claimed;
    /// @dev What every drop of an asset still owes its claimers: the sum of their `remaining`.
    mapping(address asset => uint256) private _owedOf;

    /// @param token_ The revenue token; the box is meant to be deployed by it.
    constructor(address token_) EIP712("Hookr Drop Box", "1") {
        token = token_;
    }

    /// @notice Takes native ETH from anyone and writes nothing; `dropStray(address(0))` turns it into a drop.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrDropBox
    function dropCount() external view returns (uint256) {
        return _drops.length;
    }

    /// @inheritdoc IHookrDropBox
    function dropAt(uint256 dropId) external view returns (Drop memory) {
        if (dropId >= _drops.length) revert UnknownDrop(dropId);
        return _drops[dropId];
    }

    /// @inheritdoc IHookrDropBox
    function remaining(uint256 dropId) external view returns (uint256) {
        if (dropId >= _drops.length) revert UnknownDrop(dropId);
        Drop storage d = _drops[dropId];
        return d.amount - d.paid;
    }

    /// @inheritdoc IHookrDropBox
    function claimable(uint256 dropId, address holder) external view returns (uint256) {
        if (dropId >= _drops.length) revert UnknownDrop(dropId);
        if (claimed[dropId][holder]) return 0;
        return _owed(_drops[dropId], holder);
    }

    /// @inheritdoc IHookrDropBox
    function owed(address asset) external view returns (uint256) {
        return _owedOf[asset];
    }

    // ------------------------------------------------------------------ drops

    /// @inheritdoc IHookrDropBox
    function drop(address asset, uint256 amount) external payable nonReentrant returns (uint256 dropId) {
        if (asset == token) revert RefusedAsset(asset);
        uint256 received;
        if (asset == address(0)) {
            if (msg.value != amount) revert InexactValue(amount, msg.value);
            received = amount;
        } else {
            if (msg.value != 0) revert NativeNotAccepted();
            uint256 before = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            received = IERC20(asset).balanceOf(address(this)) - before;
        }
        if (received == 0) revert NothingReceived();
        return _record(asset, received);
    }

    /// @inheritdoc IHookrDropBox
    /// @dev The box's balance of `asset` above what its drops of it still owe. A balance below that (a drop recorded
    ///      too high by a lying token, a rebase down) has nothing stray and is `NothingReceived`, never an
    ///      underflow; a rebase up is stray and goes to the holders like anything else that reached the box.
    function dropStray(address asset) external nonReentrant returns (uint256 dropId) {
        if (asset == token) revert RefusedAsset(asset);
        uint256 held = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        uint256 due = _owedOf[asset];
        if (held <= due) revert NothingReceived();
        unchecked {
            return _record(asset, held - due);
        }
    }

    /// @inheritdoc IHookrDropBox
    /// @dev `to` may be anyone but zero, the revenue token and this box: a drop share paid into the token would be
    ///      recognized by its next sync as streamed income for every holder, and one paid into the box would sit as
    ///      everyone's stray, so the claim paths never meet.
    function claim(uint256[] calldata dropIds, address to) external nonReentrant returns (uint256[] memory amounts) {
        return _claim(msg.sender, dropIds, to);
    }

    /// @inheritdoc IHookrDropBox
    /// @dev The holder's authorization is used before the payouts; a claim that pays nothing reverts and leaves it
    ///      unused.
    function claimWithSig(
        address holder,
        uint256[] calldata dropIds,
        address to,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        _useAuthorization(
            holder,
            nonce,
            keccak256(
                abi.encode(CLAIM_DROPS_TYPEHASH, holder, keccak256(abi.encodePacked(dropIds)), to, nonce, deadline)
            ),
            signature
        );
        return _claim(holder, dropIds, to);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Records `amount` of `asset`, already in the box, as a new drop: the token's snapshot of the block before
    ///      and its earning supply then, the record, the owed total, the event with the caller as `from`.
    function _record(address asset, uint256 amount) private returns (uint256 dropId) {
        (uint48 snapshotBlock, uint256 supply) = IHookrDropHost(token).snapshot();
        if (supply == 0) revert NoEarningSupply(snapshotBlock);

        dropId = _drops.length;
        _drops.push(Drop(asset, snapshotBlock, amount, supply, 0));
        _owedOf[asset] += amount;
        emit Dropped(dropId, msg.sender, asset, amount, snapshotBlock, supply);
    }

    /// @dev `holder`'s share of each listed drop, paid to `to`, each once.
    function _claim(address holder, uint256[] calldata dropIds, address to) private returns (uint256[] memory amounts) {
        if (to == address(0) || to == token || to == address(this)) revert InvalidRecipient(to);
        uint256 n = dropIds.length;
        uint256 count = _drops.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 dropId = dropIds[i];
            if (dropId >= count) revert UnknownDrop(dropId);
            if (claimed[dropId][holder]) revert AlreadyClaimed(dropId);
            Drop storage d = _drops[dropId];
            uint256 due = _owed(d, holder);
            if (due == 0) revert NothingToClaim(dropId);
            claimed[dropId][holder] = true;
            d.paid += due;
            // due <= amount - paid, and the owed total is the sum of every drop's remaining.
            unchecked {
                _owedOf[d.asset] -= due;
            }
            amounts[i] = due;
            emit Claimed(dropId, holder, to, due);
            _pay(d.asset, to, due);
        }
    }

    /// @dev `holder`'s share of `d`: balance at the snapshot times the amount over the earning supply, rounded
    ///      down, capped at what the drop still holds.
    function _owed(Drop storage d, address holder) private view returns (uint256 due) {
        uint256 held = IHookrDropHost(token).balanceAt(holder, d.snapshotBlock);
        if (held == 0) return 0;
        due = Math.mulDiv(held, d.amount, d.earningSupply);
        uint256 left = d.amount - d.paid;
        if (due > left) due = left;
    }

    function _pay(address asset, address to, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert PaymentFailed(to);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
