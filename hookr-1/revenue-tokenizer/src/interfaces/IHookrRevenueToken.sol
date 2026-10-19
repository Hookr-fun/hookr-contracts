// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrDropHost} from "./IHookrDropHost.sol";
import {IHookrERC20Permit} from "./IHookrERC20Permit.sol";
import {IHookrERC20Authorizations} from "./IHookrERC20Authorizations.sol";

/// @title Hookr revenue token
/// @notice A fixed-supply ERC-20 whose holders share, pro rata and without staking, everything the fee rights locked
///         behind it earn: every amount of each of its assets the token recognizes, released over `streamSeconds`.
///         Nothing on a pool, hook, router or launcher calls this contract, and a transfer calls nothing outside it.
/// @dev Born pending from `HookrRevenueTokenizer`, which locks the rights, then calls `seal` once: the doors are fixed, the
///      supply is minted (holders, the Hookr leg collector, the market seed) and nothing can change afterwards. No
///      owner, no pause, no sweep, no second mint. Recognition is by balance delta in `sync`, never in `receive()`,
///      which stays empty so a 100,000-gas forward (HookrTreasury.DELIVERY_GAS) lands.
///      Shares the PoolManager, 0xdead, the token's drop box or the token itself hold earn nothing: every
///      release is split over `earningSupply`, kept by the balance history (IHookrBalanceHistory) the token inherits.
///      Two claim paths that never meet: income from the fee rights (the fixed assets) streams through the token and is
///      claimed here; drops of any asset by anyone go through the token's own drop box (IHookrDropHost.dropBox) and are
///      claimed there by the balance at the end of the block before the drop.
///      A holder never needs gas: every holder action is signed and relayed by anyone, under the token's EIP-712
///      domain (its name, version "1", the chain and its address; `eip712Domain` answers all of it, EIP-5267).
///      `permit` is EIP-2612 with sequential nonces (IHookrERC20Permit); `transferWithAuthorization` and
///      `receiveWithAuthorization` are EIP-3009 with random nonces, what x402's EVM "exact" scheme settles with
///      (IHookrERC20Authorizations); `claimWithSig` and `claimAllWithSig` pay only the account the holder signed for.
///      Every signature is an EOA's ECDSA or a contract account's ERC-1271 answer, so a smart wallet or an EIP-7702
///      account signs like anyone else. Permit2 works as with any ERC-20, nothing more is needed. Shares moved by
///      authorization go through the same ledger settlement and balance checkpoints as a transfer.
interface IHookrRevenueToken is IERC20, IHookrDropHost, IHookrERC20Permit, IHookrERC20Authorizations {
    /// @notice How a door is pulled.
    /// @param RULES A `HookrRules` whose ledger credits this token (a pool's `royaltyTo`, a Hook Block take or an
    ///        advisory fee): the token calls `claim(currency)` for each of its assets.
    /// @param FORWARDER A `HookrFamilyForwarder`, the beneficiary of families locked in HookrFamilyLock: the token
    ///        calls `pull()`, which collects LP fees and recapture accruals and forwards them here.
    /// @param FEEB A `HookrFeebAdapter` holding a pools.trade Fee Beneficiary NFT: the token calls `pull()`.
    /// @param POSITIONS A `HookrPositionNftDoor` holding locked Uniswap v4 position NFTs: the token calls `pull()`,
    ///        which collects every position's fees and forwards them here.
    /// @param SOURCE An `IHookrRevenueSource` adapter standing in for an outside right (a Pons creator fee
    ///        recipient, any other platform's recipient through a later adapter): the token calls
    ///        `pull()`, which claims what the right has and forwards it here; what the token does not list goes
    ///        into the drop box.
    /// @param POSITIONS_V3 A `HookrV3PositionNftDoor` holding locked Uniswap v3 position NFTs: the token calls
    ///        `pull()`, which collects every position's fees, unwraps the wrapped native side and forwards them here.
    enum DoorKind {
        RULES,
        FORWARDER,
        FEEB,
        POSITIONS,
        SOURCE,
        POSITIONS_V3
    }

    /// @notice One door the sync pulls. Fixed at `seal`.
    /// @param kind The door's kind.
    /// @param target The contract pulled.
    /// @param gas The gas stipend the pull is called with; a sync with less than this left before the call reverts
    ///        `SyncStarved` instead of skipping the door.
    struct Door {
        DoorKind kind;
        address target;
        uint32 gas;
    }

    /// @notice One asset's accounting.
    /// @param currency The asset; address zero is native ETH, always asset 0.
    /// @param index Released income per earning share unit, scaled by `SCALE`.
    /// @param carry Released income not yet expressible in the index, scaled; below the earning supply it was split
    ///        over.
    /// @param received Total units recognized (released and still streaming), at most `MAX_RECEIVED`.
    /// @param paid Total units paid to holders; never above `received`.
    /// @param pendingStream Recognized units not yet released into the index.
    /// @param streamEnd Timestamp at which `pendingStream` is fully released.
    /// @param lastRelease Timestamp up to which the stream has been released.
    struct Asset {
        Currency currency;
        uint256 index;
        uint256 carry;
        uint128 received;
        uint128 paid;
        uint128 pendingStream;
        uint64 streamEnd;
        uint64 lastRelease;
    }

    /// @notice What `seal` fixes: the doors, the mint and the optional Fee Bridge slice.
    /// @param doors The doors the sync pulls, 1 to `MAX_DOORS`, each target with code.
    /// @param recipients Who receives the minted supply, with `amounts`; the tokenizer puts the Hookr leg collector
    ///        (when the way has a leg) and the market seed (minted to itself) in these lists, so the amounts sum to the
    ///        whole supply.
    /// @param amounts The units minted to each recipient; sum to `totalSupply`.
    /// @param bridge A Fee Bridge v2 for the token's own market pool, or zero.
    /// @param bridgeBps The share of each sync's pulled ETH (after the tip) sent to `bridge`, 0 to `MAX_BRIDGE_BPS`;
    ///        zero with a zero bridge.
    struct Seal {
        Door[] doors;
        address[] recipients;
        uint256[] amounts;
        address bridge;
        uint16 bridgeBps;
    }

    // ------------------------------------------------------------------ errors
    // `InvalidConfig` and `Unauthorized(address)` come from the drop host's interfaces; the signature errors from
    // IHookrAuthorizations and IHookrERC20Authorizations.

    /// @notice `currency` is listed twice, is an ERC-20 with no code, or is not one of the token's assets.
    error InvalidAsset(Currency currency);
    /// @notice `asset` is past the last asset index.
    error UnknownAsset(uint256 asset);
    /// @notice Door `door` of the seal has no code, no gas stipend, or repeats an earlier door's target.
    error InvalidDoor(uint256 door);
    /// @notice `to` cannot take a payout or a mint: the zero address, this token, or its drop box.
    error InvalidRecipient(address to);
    /// @notice A zero amount, a mint that does not sum to the supply, a bonus whose `msg.value` is not `amount`, or
    ///         an arrival past `MAX_RECEIVED`.
    error InvalidAmount(uint256 amount);
    /// @notice The claim would pay nothing.
    error NothingToClaim();
    /// @notice The token is not sealed yet.
    error NotLive();
    /// @notice The token is already sealed.
    error AlreadyLive();
    /// @notice The caller left less gas than door `door` needs; call again with more gas.
    error SyncStarved(uint256 door, uint256 needed);
    /// @notice The doors' stipends plus one reserve each sum to `total`, more than `MAX_SYNC_GAS`: no transaction
    ///         could carry a sync in which every door spent what it was given.
    error SyncTooExpensive(uint256 total);
    /// @notice An ERC-20 moved other than the amount asked: a fee-on-transfer or rebasing token.
    error InexactTransfer();
    /// @notice ETH was sent with an ERC-20 bonus.
    error NativeNotAccepted();

    // ------------------------------------------------------------------ events

    /// @notice The doors were fixed and the supply minted; income recognition starts.
    event Sealed(uint256 doors, uint256 supply, address bridge, uint16 bridgeBps);
    /// @notice `amount` of asset `asset` was recognized and starts streaming until `streamEnd`.
    event IncomeRecognized(uint256 indexed asset, bytes32 indexed sourceId, uint256 amount, uint64 streamEnd);
    /// @notice `amount` of asset `asset` was released into the index, now `index`.
    event IncomeReleased(uint256 indexed asset, uint256 amount, uint256 index);
    /// @notice `account` was paid `amount` of asset `asset` at `to`.
    event IncomeClaimed(address indexed account, uint256 indexed asset, address indexed to, uint256 amount);
    /// @notice Door `door` was pulled; `ok` false when its call reverted and the sync went on.
    event DoorPulled(uint256 indexed door, bool ok);
    /// @notice One sync: `by` was paid `tip` of the `pulledEth` the doors delivered, `bridged` went to the bridge.
    event Synced(address indexed by, uint256 pulledEth, uint256 tip, uint256 bridged);
    /// @notice `from` paid `amount` of asset `asset` in as a bonus; it streams like any other arrival, with no tip.
    event BonusDeposited(address indexed from, uint256 indexed asset, uint256 amount);
    /// @notice `amount` of `asset`, which is not one of the fixed assets, sat in the token and went into the drop
    ///         box as drop `dropId`, shared by the balances at the end of the block before.
    event StrayDropped(address indexed asset, uint256 amount, uint256 dropId);

    // ------------------------------------------------------------------ constants

    /// @notice Fixed-point scale of every index and scaled credit: 1e36.
    function SCALE() external view returns (uint256);
    /// @notice Most assets a token may have: 4 (native ETH and the family's other currencies).
    function MAX_ASSETS() external view returns (uint256);
    /// @notice Most doors a token may have: 8.
    function MAX_DOORS() external view returns (uint256);
    /// @notice Smallest share supply: 1.
    function MIN_SUPPLY() external view returns (uint256);
    /// @notice Largest share supply: 2^128 - 1.
    function MAX_SUPPLY() external view returns (uint256);
    /// @notice Shortest release period: 1 day.
    function MIN_STREAM_SECONDS() external view returns (uint32);
    /// @notice Longest release period: 14 days.
    function MAX_STREAM_SECONDS() external view returns (uint32);
    /// @notice The release period the tokenizer uses when the creator passes zero: 7 days.
    function DEFAULT_STREAM_SECONDS() external view returns (uint32);
    /// @notice Largest sync tip: 100 basis points (1%) of the ETH a sync pulls.
    function MAX_TIP_BPS() external view returns (uint16);
    /// @notice Least ETH a sync must pull for its caller to be tipped at all: 0.001 ETH.
    function MIN_TIP_PULL() external view returns (uint256);
    /// @notice Largest Fee Bridge slice: 2,000 basis points of each sync's pulled ETH after the tip.
    function MAX_BRIDGE_BPS() external view returns (uint16);
    /// @notice Most units of one asset the token ever recognizes: 2^128 - 1, which keeps every scaled credit below
    ///         2^256.
    function MAX_RECEIVED() external view returns (uint256);
    /// @notice Largest single recognition: the same bound as `MAX_RECEIVED`, so the room left under it is the only check
    ///         a recognition needs.
    function MAX_RECOGNITION() external view returns (uint256);
    /// @notice Gas kept back for what follows the last door of a sync: up to four recognitions into fresh storage, the
    ///         tip, the bridge slice and the event; 300,000. A sync needs each door's stipend plus this left before the
    ///         door, or it reverts `SyncStarved`.
    function SYNC_RESERVE_GAS() external view returns (uint256);
    /// @notice The most the doors' stipends plus one `SYNC_RESERVE_GAS` each may sum to: 28,000,000, so a sync in
    ///         which every door burns all it is given still fits a 32,000,000-gas transaction, Robinhood Chain's cap.
    function MAX_SYNC_GAS() external view returns (uint256);
    /// @notice Source id of arrivals recognized from a balance delta in `sync` (pulls, pushes and plain sends).
    function SOURCE_SYNC() external view returns (bytes32);
    /// @notice Source id of `depositBonus` arrivals.
    function SOURCE_BONUS() external view returns (bytes32);
    /// @notice The EIP-712 type hash of `claimWithSig`:
    ///         `Claim(address holder,uint256 asset,address to,bytes32 nonce,uint256 deadline)`.
    function CLAIM_TYPEHASH() external view returns (bytes32);
    /// @notice The EIP-712 type hash of `claimAllWithSig`: `ClaimAll(address holder,address to,bytes32 nonce,uint256 deadline)`.
    function CLAIM_ALL_TYPEHASH() external view returns (bytes32);

    // ------------------------------------------------------------------ fixed terms
    // `DEAD`, `poolManager`, `clock`, `earns`, `earningSupply`, the balance history and `dropBox` come from the drop
    // host's interfaces.

    /// @notice The tokenizer that created this token: the only caller of `seal`.
    function tokenizer() external view returns (address);
    /// @notice The fixed supply `seal` mints.
    function shareSupply() external view returns (uint256);
    /// @notice The period every recognized arrival is released over.
    function streamSeconds() external view returns (uint32);
    /// @notice The sync caller's tip, in basis points of the ETH the sync pulled.
    function tipBps() external view returns (uint16);
    /// @notice Commitment to the published terms (sources, lock, disclosures). Nonzero.
    function termsHash() external view returns (bytes32);
    /// @notice Whether `seal` ran: doors fixed, supply minted, income recognition on.
    function live() external view returns (bool);
    /// @notice The Fee Bridge a slice of each sync's ETH goes to, or zero.
    function bridge() external view returns (address);
    /// @notice The slice of each sync's pulled ETH, after the tip, sent to `bridge`.
    function bridgeBps() external view returns (uint16);

    // ------------------------------------------------------------------ assets

    /// @notice Number of assets, fixed at construction.
    function assetCount() external view returns (uint256);
    /// @notice Asset `asset` and its accounting; reverts `UnknownAsset` past the last one.
    function assetAt(uint256 asset) external view returns (Asset memory);
    /// @notice The index of asset `currency`; reverts `InvalidAsset` when it is not one.
    function assetOf(Currency currency) external view returns (uint256);
    /// @notice Whether `currency` is one of the assets.
    function isAsset(Currency currency) external view returns (bool);
    /// @notice Balance of asset `asset` above `received - paid`: arrivals not yet recognized, which the next sync
    ///         recognizes without a tip.
    function surplus(uint256 asset) external view returns (uint256);
    /// @notice Stream of asset `asset` that a release now would move into the index.
    function releasable(uint256 asset) external view returns (uint256);

    // ------------------------------------------------------------------ holders

    /// @notice Units of asset `asset` that `account` can claim now, with the stream released to this block.
    function claimable(address account, uint256 asset) external view returns (uint256);
    /// @notice Pays the caller's claim in asset `asset` to `to`: the lesser of what it is owed and what the token
    ///         holds; the rest stays owed.
    function claim(uint256 asset, address to) external returns (uint256 amount);
    /// @notice Pays the caller's claim in every asset to `to`, skipping assets with nothing due.
    function claimAll(address to) external returns (uint256[] memory amounts);
    /// @notice `claim` for `holder`, relayed by anyone with `holder`'s signature over
    ///         `Claim(holder, asset, to, nonce, deadline)`: pays `holder`'s claim to the `to` it signed and nowhere
    ///         else, uses `nonce` once (`cancelAuthorization` revokes it), and is refused past `deadline`.
    function claimWithSig(
        address holder,
        uint256 asset,
        address to,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 amount);
    /// @notice `claimAll` for `holder`, relayed with `holder`'s signature over `ClaimAll(holder, to, nonce, deadline)`.
    function claimAllWithSig(address holder, address to, bytes32 nonce, uint256 deadline, bytes calldata signature)
        external
        returns (uint256[] memory amounts);
    /// @notice Releases every asset's due stream into its index. Permissionless; transfers, claims and syncs do it too.
    function poke() external;

    // ------------------------------------------------------------------ doors and sync

    /// @notice Number of doors, fixed at `seal`.
    function doorCount() external view returns (uint256);
    /// @notice The `i`-th door.
    function doorAt(uint256 i) external view returns (Door memory);
    /// @notice Pulls every door (each in its own try/catch, with a gas check first), then recognizes each asset's
    ///         balance delta, pays the caller `tipBps` of the ETH the doors pulled when that is at least
    ///         `MIN_TIP_PULL`, and sends the bridge its slice. Anyone may call. Arrivals that were already here
    ///         (pushes, bonuses) are recognized too, with no tip on them.
    function sync() external returns (uint256 tip);
    /// @notice `sync` over the doors at the listed indexes alone, in that order, with the same tip, bridge slice and
    ///         recognition: a way to recognize what the honest doors delivered while skipping one that burns its
    ///         stipend. An index past the last door is `InvalidDoor`; an empty list pulls nothing and recognizes the
    ///         pushes. Anyone may call.
    function syncSome(uint256[] calldata doors) external returns (uint256 tip);
    /// @notice Pays `amount` of asset `asset` in as a bonus. Native: send exactly `amount` as value. ERC-20: approve
    ///         first; a transfer that lands short is refused. Recognized at once, never tipped.
    function depositBonus(uint256 asset, uint256 amount) external payable;
    /// @notice Turns everything this token holds of `asset`, an ERC-20 that is not one of its fixed assets, into a
    ///         drop for the holders: the balance moves into the drop box, which records it as a drop shared by the
    ///         balances at the end of the block before (IHookrDropBox.dropStray). Anyone may call, so whatever is
    ///         sent straight to the token ends up split: the fixed assets and native ETH by the sync, everything
    ///         else here. A fixed asset, native ETH or this token is refused (`InvalidAsset`); a zero balance is
    ///         refused by the box (`NothingReceived`).
    function dropStray(address asset) external returns (uint256 dropId);

    // ------------------------------------------------------------------ tokenizer

    /// @notice Fixes the doors and mints the whole supply. Only the tokenizer, once.
    function seal(Seal calldata s) external;
}
