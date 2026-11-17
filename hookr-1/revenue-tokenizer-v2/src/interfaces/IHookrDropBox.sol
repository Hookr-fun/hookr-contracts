// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrIncomeRecovery} from "./IHookrIncomeRecovery.sol";

import {IHookrAuthorizations} from "./IHookrAuthorizations.sol";

/// @title Hookr drop box, part of the HookRevenue Tokenizer
/// @notice Where anyone drops ETH or any ERC-20 for the holders of one revenue token. Each drop is split over the
///         holders' balances at the end of the block before it landed; every holder claims its own share whenever
///         it likes, for as long as it likes, itself or by a signature anyone relays. No token list, no owner, no
///         pause, no sweep.
/// @dev One box per revenue token, deployed by the token at construction. It is separate from the token because the
///      token recognizes its listed assets by balance delta: a drop of ETH into the token itself would be
///      counted as streamed income. Here the dropped assets sit apart and only drop accounting touches them.
///
///      A share is settled at the snapshot: holders who sold after it still claim that drop, buyers after it get
///      nothing from it. A buyer in the drop's own block gets nothing (the snapshot is the block before), and a
///      flash loan cannot change a past block's balance. Shares held by the PoolManager, 0xdead, the box itself, the
///      token, its leg collector or its tokenizer are not in the earning supply, so pool liquidity is not counted
///      twice and stranded shares do not dilute.
///
///      Each drop is paid only from what it received. A token that reverts, lies about balances, rebases or
///      charges fees can only shortchange drops of that same token; drops of other assets are unaffected. Within one
///      such token the drops share one balance: an earlier drop recorded too high (the token lied during its
///      `drop`) is paid from later honest drops of it, and a token that burns on the way out or rebases down shorts
///      the last claimers of it. Indexers should show, per asset, the sum of `remaining` next to the box's real
///      balance and flag a shortfall; droppers should prefer wrapped forms of rebasing tokens. Dust that pro-rata
///      rounding leaves (at most one unit per claimer) stays in the box.
///
///      Assets sent straight to the box without `drop` (native ETH through its `receive`, an ERC-20 by a plain
///      transfer) and what the revenue token hands over from its own `dropStray` are strays. With a release period
///      under one hour (zero, the default, included), `dropStray` records the whole new receipt as one immediately
///      claimable drop, against the previous block's earning balances; no slice cadence or pending stream applies.
///      (Slices are never shorter than an hour, so a shorter stream would release each stray whole in one slice and
///      make the next wait up to an hour.) No earning supply at that snapshot refuses a strict recognition: the mint
///      block, and any later block in which every share sat in excluded accounts (the pool, 0xdead); best-effort
///      collection leaves the unrecorded funds for a later retry. Every such receipt is its own drop and snapshot, so
///      drops grow with the count of receipts, not with time, and each rounds every holder's share down; the caller
///      of a booking (`dropStray`, a door's sync, `collectIncome*`, `collectDrops`) picks the block whose balances
///      share it, and a holder at the end of the block before is paid even if it sells first thing in the next.
///      With a release period of an hour or more, a stray joins that asset's stray stream with the same by-weight
///      window as the token's income, and the stream reaches the holders as drops in slices, at most
///      one slice every `STRAY_SLICE_SECONDS` (`releaseStray`, anyone's call, or the next `dropStray`). Each slice is
///      an ordinary drop snapshotted at the block before it, so a holder for one block shares in one slice at most.
///      A slice carries what the stream released since the last one, and the stream advances at most
///      `STRAY_SLICE_SECONDS` of its time between two recorded slices, however many calls or strays land between
///      them, so a slice called late is no lump: the stream waits for the calls. A slice is recorded with the box as
///      `from`. A door that delivers a currency its token does not list hands it to the box the same way: an
///      immediate drop or the stream, by the period.
///
///      Shares of another revenue token that sit in the box (a stray of it, or drops of it not claimed yet) earn that
///      token's income for the box. `collectIncome` claims it into the box, anyone's call, and adds what arrives to
///      stray recognition, immediate or in slices according to this token's release period.
///
///      A claim pays the caller's own share, or a holder's share to whoever its operator names (`claimFrom`, with
///      the operators the holder approved on the revenue token). A position held through the block before a drop is
///      paid in full even if it exits in the drop's own block, so a dropper whose timing is predictable should drop in
///      several pieces or at unpredictable times; the "block before" rule is the only on-chain defense.
interface IHookrDropBox is IHookrAuthorizations, IHookrIncomeRecovery {
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

    /// @notice One asset's positive-duration stray stream. Zero-duration recognition leaves these fields empty.
    /// @param pending Stray units not yet released.
    /// @param ready Units released and waiting for the next slice.
    /// @param end Timestamp at which `pending` is fully released.
    /// @param last Timestamp up to which the stream has been released.
    /// @param lastSlice Where the slice the stream is filling started: the timestamp of the last slice, or, when an
    ///        idle stream started filling again, the timestamp it stood at then; zero before the first. The stream
    ///        runs at most `STRAY_SLICE_SECONDS` past it until the next slice is recorded.
    struct Stray {
        uint128 pending;
        uint128 ready;
        uint64 end;
        uint64 last;
        uint64 lastSlice;
    }

    /// @notice The revenue token itself cannot be dropped into its own box, and the box earns none of its income.
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
    /// @notice The payout address was zero, the revenue token, this box or one of the token's doors.
    error InvalidRecipient(address to);
    /// @notice The caller is neither the holder nor one of its operators.
    error Unauthorized(address caller);
    /// @notice A fresh immediate stray receipt, or an asset's pending stray stream, would pass 2^128 - 1 units.
    error StrayTooLarge(uint256 amount);
    /// @notice No slice of this asset's stray stream may be released before `next`.
    error SliceNotDue(uint256 next);
    /// @notice The native payout to `to` failed.
    error PaymentFailed(address to);
    /// @notice Too little gas was left to give an income claim its cap and finish its accounting.
    error IncomeCollectionStarved(uint256 asset);

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
    /// @notice `amount` of `asset` was recognized: an immediate drop when `end` is now, otherwise a stray stream.
    event StrayAdded(address indexed asset, uint256 amount, uint64 end);
    /// @notice `holder` claimed `amount` of drop `dropId`, paid to `to`.
    event Claimed(uint256 indexed dropId, address indexed holder, address indexed to, uint256 amount);
    /// @notice The box claimed its income in `revenueToken`: `claimed[i]` of that token's asset `i`, of which `added[i]`
    ///         was recorded immediately or joined the asset's stray stream.
    event IncomeCollected(address indexed revenueToken, uint256[] claimed, uint256[] added);
    /// @notice One income asset was collected into this box, of which `added` was recorded or joined its stream.
    event IncomeAssetCollected(address indexed revenueToken, uint256 indexed asset, uint256 claimed, uint256 added);

    /// @notice The EIP-712 type hash of `claimWithSig`:
    ///         `ClaimDrops(address holder,uint256[] dropIds,address to,bytes32 nonce,uint256 deadline)`.
    function CLAIM_DROPS_TYPEHASH() external view returns (bytes32);
    /// @notice The revenue token whose holders this box pays.
    function token() external view returns (address);
    /// @notice The least time between two slices of a stray stream: the token's release period over 24, at least
    ///         one hour. Zero when the token's release period is under one hour: `dropStray` records immediate drops
    ///         instead.
    function STRAY_SLICE_SECONDS() external view returns (uint256);
    /// @notice Asset `asset`'s stray stream; empty for zero-duration recognition.
    function strayOf(address asset) external view returns (Stray memory);
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
    ///         balance of `asset` above it and the stray stream (`pending + ready`) is a new stray.
    function owed(address asset) external view returns (uint256);

    /// @notice Drops `amount` of `asset` for the holders. Native: `asset` zero and `amount` as value. ERC-20:
    ///         approve first; what actually arrives is what is shared. Anyone, any time; the snapshot is the block
    ///         before this one.
    function drop(address asset, uint256 amount) external payable returns (uint256 dropId);
    /// @notice Adds what the box holds of `asset` beyond its books (`owed` plus the stray stream) to the asset's stray
    ///         stream, then releases a slice when one is due. With a release period under an hour (zero included; an
    ///         hour exactly still streams), records the full new amount as one immediately claimable previous-block
    ///         drop instead; no earning supply is `NoEarningSupply`.
    ///         Anyone, any time. Nothing new is `NothingReceived`; the revenue token is `RefusedAsset`.
    function dropStray(address asset) external returns (uint256 amount);
    /// @notice Claims the income the box's shares of `revenueToken`, another revenue token, earned there, into the box,
    ///         and recognizes what arrived of each asset under `dropStray`'s rules (an asset with
    ///         nothing new skipped). Every source read, strict per-asset claim and balance read is gas-capped and
    ///         copies bounded return data. Failed assets are skipped; insufficient caller gas is
    ///         `IncomeCollectionStarved`. Anyone, any time. Nothing due or an unread source returns an empty list;
    ///         the box's own token is `RefusedAsset`. Returns what was recorded or joined a stray stream, by asset index;
    ///         a zero-duration receipt with no earning supply at the snapshot stays unrecorded and returns zero.
    function collectIncome(address revenueToken) external returns (uint256[] memory amounts);
    /// @notice Claims this box's income in one asset of another revenue token into this box and recognizes it as
    ///         `dropStray` does (one immediate drop under an hour's release period, the stray stream otherwise). The
    ///         same caps and skips as `collectIncome`, without visiting sibling assets. Returns
    ///         zero for an unknown asset, unread source, failed claim or unread balance. The box's own token is
    ///         `RefusedAsset`; the holder and recipient are always this box.
    function collectIncomeAsset(address revenueToken, uint256 asset) external returns (uint256 amount);
    /// @notice Releases a slice of `asset`'s positive-duration stray stream as a drop shared by balances at the end of the block
    ///         before: what the stream released since the last slice. Anyone, once every `STRAY_SLICE_SECONDS`
    ///         (`SliceNotDue` before); nothing released is `NothingReceived`, no earning share `NoEarningSupply`.
    ///         A token whose release period is under an hour has no slice to advance and always reverts
    ///         `NothingReceived`; `dropStray` already records its full new receipts.
    function releaseStray(address asset) external returns (uint256 dropId);
    /// @notice Pays the caller's share of each listed drop to `to`, each once. Reverts on an unknown or already
    ///         claimed id, on one the caller has no share in, and on a `to` that is zero, the revenue token, this
    ///         box or one of the token's doors (`InvalidRecipient`).
    function claim(uint256[] calldata dropIds, address to) external returns (uint256[] memory amounts);
    /// @notice `claim` for `holder` by `holder` itself or one of its operators on the revenue token
    ///         (IHookrRevenueToken.isOperator), paid to `to`.
    function claimFrom(address holder, uint256[] calldata dropIds, address to)
        external
        returns (uint256[] memory amounts);
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
