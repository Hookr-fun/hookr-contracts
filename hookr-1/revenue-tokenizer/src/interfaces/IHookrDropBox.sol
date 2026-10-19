// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrAuthorizations} from "./IHookrAuthorizations.sol";

/// @title Hookr drop box, part of the HookRevenue Tokenizer
/// @notice Where anyone drops ETH or any ERC-20 for the holders of one revenue token. Each drop is split over the
///         holders' balances at the end of the block before it landed; every holder claims its own share whenever
///         it likes, for as long as it likes, itself or by a signature anyone relays. No token list, no owner, no
///         pause, no sweep.
/// @dev One box per revenue token, deployed by the token at construction. It is separate from the token because the
///      token recognizes its own fixed assets by balance delta: a drop of ETH into the token itself would be
///      counted as streamed income. Here the dropped assets sit apart and only drop accounting touches them.
///
///      A share is settled at the snapshot: holders who sold after it still claim that drop, buyers after it get
///      nothing from it. A buyer in the drop's own block gets nothing (the snapshot is the block before), and a
///      flash loan cannot change a past block's balance. Shares held by the PoolManager, 0xdead or the box itself
///      are not in the earning supply, so pool liquidity is not counted twice and stranded shares do not dilute.
///
///      Each drop is paid only from what it received. A token that reverts, lies about balances, rebases or
///      charges fees can only shortchange drops of that same token; drops of other assets are unaffected. Within one
///      such token the drops share one balance: an earlier drop recorded too high (the token lied during its
///      `drop`) is paid from later honest drops of it, and a token that burns on the way out or rebases down shorts
///      the last claimers of it. Indexers should show, per asset, the sum of `remaining` next to the box's real
///      balance and flag a shortfall; droppers should prefer wrapped forms of rebasing tokens. Dust that pro-rata
///      rounding leaves (at most one unit per claimer) stays in the box. Assets sent straight to the box without
///      `drop` (native ETH through its `receive`, an ERC-20 by a plain transfer) are strays: anyone turns them into
///      a drop with `dropStray`, which records what the box holds of the asset above what its drops of it still
///      owe. The revenue token does the same for what is sent straight to it (IHookrRevenueToken.dropStray).
///
///      A claim pays the caller's own share, so a contract that holds shares and has no code path to `claim` (a
///      v2/v3 pool, a lending market, a vault) earns a share of every drop that nobody can take; Hookr's leg
///      collector gets that path from `HookrDropSweep`. A position held through the block before a drop is paid in
///      full even if it exits in the drop's own block, so a dropper whose timing is predictable should drop in
///      several pieces or at unpredictable times; the "block before" rule is the only on-chain defense.
interface IHookrDropBox is IHookrAuthorizations {
    /// @notice One drop.
    /// @param asset The dropped asset; address zero is native ETH.
    /// @param snapshotBlock The block whose end-of-block balances share the drop: `clock() - 1` when it landed.
    /// @param amount What the box received (the balance delta for an ERC-20, so a fee-on-transfer token credits
    ///        what arrived).
    /// @param earningSupply The earning supply at `snapshotBlock`, the denominator of every share.
    /// @param paid Total paid out to claimers so far.
    struct Drop {
        address asset;
        uint48 snapshotBlock;
        uint256 amount;
        uint256 earningSupply;
        uint256 paid;
    }

    /// @notice The revenue token itself cannot be dropped into its own box.
    error RefusedAsset(address asset);
    /// @notice A native drop must send exactly `amount` as value.
    error InexactValue(uint256 expected, uint256 sent);
    /// @notice An ERC-20 drop must send no value.
    error NativeNotAccepted();
    /// @notice The drop brought nothing to the box.
    error NothingReceived();
    /// @notice No shares earned at the snapshot block, so nobody could ever claim; the drop is refused.
    error NoEarningSupply(uint48 snapshotBlock);
    /// @notice `dropId` does not exist yet.
    error UnknownDrop(uint256 dropId);
    /// @notice The caller already claimed `dropId`.
    error AlreadyClaimed(uint256 dropId);
    /// @notice The caller held nothing at `dropId`'s snapshot, or nothing is left in it.
    error NothingToClaim(uint256 dropId);
    /// @notice The payout address was zero, the revenue token or this box.
    error InvalidRecipient(address to);
    /// @notice The native payout to `to` failed.
    error PaymentFailed(address to);

    /// @notice `from` dropped `amount` of `asset` as drop `dropId`, shared by balances at `snapshotBlock` over
    ///         `earningSupply`.
    event Dropped(
        uint256 indexed dropId,
        address indexed from,
        address indexed asset,
        uint256 amount,
        uint48 snapshotBlock,
        uint256 earningSupply
    );
    /// @notice `holder` claimed `amount` of drop `dropId`, paid to `to`.
    event Claimed(uint256 indexed dropId, address indexed holder, address indexed to, uint256 amount);

    /// @notice The EIP-712 type hash of `claimWithSig`:
    ///         `ClaimDrops(address holder,uint256[] dropIds,address to,bytes32 nonce,uint256 deadline)`.
    function CLAIM_DROPS_TYPEHASH() external view returns (bytes32);
    /// @notice The revenue token whose holders this box pays.
    function token() external view returns (address);
    /// @notice Number of drops so far; ids run from 0 to this less one.
    function dropCount() external view returns (uint256);
    /// @notice Drop `dropId`; reverts `UnknownDrop` past the end.
    function dropAt(uint256 dropId) external view returns (Drop memory);
    /// @notice What drop `dropId` still holds: `amount - paid`.
    function remaining(uint256 dropId) external view returns (uint256);
    /// @notice Whether `holder` claimed drop `dropId`.
    function claimed(uint256 dropId, address holder) external view returns (bool);
    /// @notice What `holder` can claim from drop `dropId` now: its share, capped at what is left, zero once
    ///         claimed.
    function claimable(uint256 dropId, address holder) external view returns (uint256);
    /// @notice What every drop of `asset` still owes its claimers in all: the sum of their `remaining`. The box's
    ///         balance of `asset` above it is stray.
    function owed(address asset) external view returns (uint256);

    /// @notice Drops `amount` of `asset` for the holders. Native: `asset` zero and `amount` as value. ERC-20:
    ///         approve first; what actually arrives is what is shared. Anyone, any time; the snapshot is the block
    ///         before this one.
    function drop(address asset, uint256 amount) external payable returns (uint256 dropId);
    /// @notice Records what the box holds of `asset` above `owed(asset)` as a new drop for the holders: anything
    ///         that reached the box without `drop`. Anyone, any time; the snapshot is the block before this one,
    ///         as for `drop`. Nothing stray is `NothingReceived`; the revenue token is `RefusedAsset`.
    function dropStray(address asset) external returns (uint256 dropId);
    /// @notice Pays the caller's share of each listed drop to `to`, each once. Reverts on an unknown or already
    ///         claimed id, on one the caller has no share in, and on a `to` that is zero, the revenue token or this
    ///         box (`InvalidRecipient`).
    function claim(uint256[] calldata dropIds, address to) external returns (uint256[] memory amounts);
    /// @notice `claim` for `holder`, relayed by anyone with `holder`'s signature over
    ///         `ClaimDrops(holder, dropIds, to, nonce, deadline)` under this box's domain: pays `holder`'s shares to
    ///         the `to` it signed and nowhere else, uses `nonce` once (`cancelAuthorization` revokes it), and is
    ///         refused past `deadline`.
    function claimWithSig(
        address holder,
        uint256[] calldata dropIds,
        address to,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256[] memory amounts);
}
