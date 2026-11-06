// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrIncomeRecovery} from "./IHookrIncomeRecovery.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrDropHost} from "./IHookrDropHost.sol";
import {IHookrERC20Permit} from "./IHookrERC20Permit.sol";
import {IHookrERC20Authorizations} from "./IHookrERC20Authorizations.sol";

/// @title Hookr revenue token
/// @notice A fixed-supply ERC-20 whose holders share, pro rata and without staking, everything the fee rights locked
///         behind it earn: every amount of each listed asset the token recognizes, immediately at zero
///         `streamSeconds` or released over a positive period.
///         Streams are only ever added: the tokenizer locks a fee right in a door and adds the door, at mint or any
///         time after, and nothing can remove a door, change it, or change the supply.
/// @dev Created by `HookrRevenueTokenizer`, which adds the first doors and calls `initialize` once in the same
///      transaction that locks the rights, so no share exists before its income is locked behind it. Later doors come
///      through the same tokenizer, at the stream manager's request (or anyone's, for the tokenizer's own door kinds,
///      when the token was minted with `openStreams`). No owner, no pause, no upgrade, no sweep, no second mint.
///
///      Recognition is by balance delta in the sync, never in `receive()`, which stays empty so a 100,000-gas forward
///      lands. The sync pulls doors in pages (`sync`, `syncRange`, `syncSome`), each door on its own gas stipend, so the
///      number of doors is not bounded by one transaction. Hookr's leg is per door, fixed when the door is added: the
///      sync measures what a legged door delivered in each listed asset and sends that share to the leg collector.
///      No sync and no bonus recognizes anything while the PoolManager is unlocked (`PoolManagerUnlocked`): shares
///      borrowed from it inside an unlock would otherwise take pool inventory's part of the income.
///
///      Shares the PoolManager, 0xdead, the token's drop box, the token itself, the leg collector or the tokenizer
///      hold earn nothing: every release is split over `earningSupply`. A transfer to the token or one of its own
///      doors is refused.
///
///      Two claim paths that never meet: income in the listed assets is accounted and claimed here;
///      drops of any asset go through the token's drop box and are claimed there by the balance at the end of the block
///      before the drop. Every holder action but approving an operator can be signed and relayed (EIP-2612 with
///      ERC-1271, EIP-3009, claims by signature, EIP-5267); a holder approves the operators (ERC-6909's word) that
///      claim for it with `setOperator`, in a transaction of its own.
interface IHookrRevenueToken is
    IERC20,
    IHookrDropHost,
    IHookrERC20Permit,
    IHookrERC20Authorizations,
    IHookrIncomeRecovery
{
    /// @notice How a door is pulled and what kind of fee right it holds.
    /// @param RULES A `HookrRules` whose ledger credits this token (a pool's `royaltyTo`, a Hook Block take): the token
    ///        reads `claimable(currency, this)` and calls `claim(currency)` for each listed asset.
    /// @param FORWARDER The token's `HookrFamilyForwarder`, the beneficiary of its locked Hookr families: `pull()`.
    /// @param FEEB A `HookrFeebAdapter` holding one pools.trade Fee Beneficiary NFT: `pull()`.
    /// @param POSITIONS A `HookrPositionNftDoor` holding Uniswap v4 position NFTs: `pull()`.
    /// @param SOURCE An `IHookrRevenueSource` standing in for an outside right (Pons, Long, any platform): `pull()`.
    /// @param POSITIONS_V3 A `HookrV3PositionNftDoor` holding Uniswap v3 position NFTs: `pull()`.
    /// @param REVENUE_TOKEN A `HookrRevenueTokenDoor` holding shares of another revenue token: `pull()` claims their
    ///        income and drops into this token.
    enum DoorKind {
        RULES,
        FORWARDER,
        FEEB,
        POSITIONS,
        SOURCE,
        POSITIONS_V3,
        REVENUE_TOKEN
    }

    /// @notice One door the sync pulls. Added once, never changed or removed.
    /// @param kind The door's kind.
    /// @param target The contract pulled.
    /// @param gas The gas stipend each call to the door gets; a sync with less than this plus `SYNC_RESERVE_GAS` left
    ///        before the call reverts `SyncStarved` instead of skipping the door.
    /// @param legBps Hookr's leg of what this door delivers, in basis points: 0 or the tokenizer's outside figure.
    struct Door {
        DoorKind kind;
        address target;
        uint32 gas;
        uint16 legBps;
    }

    /// @notice One listed asset's accounting.
    /// @param currency The asset; address zero is native ETH, always asset 0.
    /// @param index Released income per earning share unit, scaled by `SCALE`.
    /// @param carry Released income not yet expressible in the index, scaled; below the earning supply it was split
    ///        over.
    /// @param received Total units recognized (released and pending), at most `MAX_RECEIVED`.
    /// @param paid Total units paid to holders; never above `received`.
    /// @param pendingStream Recognized units not yet released into the index, including immediately due units until
    ///        the next release, claim or share transfer.
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

    /// @notice What `initialize` mints and fixes.
    /// @param recipients Who receives the minted supply, with `amounts` (the creator's recipients and the market seed).
    /// @param amounts The units minted to each recipient; sum to `shareSupply`.
    /// @param bridge A Fee Bridge for the token's own market pool, or zero.
    /// @param bridgeBps The share of each sync's pulled ETH (after the tip) sent to `bridge`, 0 to `MAX_BRIDGE_BPS`;
    ///        zero with a zero bridge.
    struct Mint {
        address[] recipients;
        uint256[] amounts;
        address bridge;
        uint16 bridgeBps;
    }

    // ------------------------------------------------------------------ errors
    // `InvalidConfig` and `Unauthorized(address)` come from the drop host's interfaces; the signature errors from
    // IHookrAuthorizations and IHookrERC20Authorizations.

    /// @notice `currency` is listed twice, is an ERC-20 with no code, is this token, or is not a listed asset.
    error InvalidAsset(Currency currency);
    /// @notice `asset` is past the last listed asset.
    error UnknownAsset(uint256 asset);
    /// @notice Every listed slot is taken (`MAX_ASSETS`).
    error TooManyAssets();
    /// @notice `door` is past the last door.
    error InvalidDoor(uint256 door);
    /// @notice `target` cannot be a door: no code, already a door, this token, its drop box, the PoolManager, 0xdead or
    ///         the tokenizer, a gas stipend outside [`MIN_DOOR_GAS`, `MAX_DOOR_GAS`], a leg above `MAX_LEG_BPS`, or a
    ///         leg on a RULES door. `doorIndexOf` answers it for an address that is not a door.
    error InvalidTarget(address target);
    /// @notice `to` cannot take this: a payout to zero, this token, its drop box or one of its doors; shares (a mint
    ///         or a transfer) to this token or one of its doors; a mint to zero. A transfer to zero is OpenZeppelin's
    ///         `ERC20InvalidReceiver`, and shares may go to the drop box, where they earn nothing.
    error InvalidRecipient(address to);
    /// @notice A zero amount, a mint that does not sum to the supply, a bonus whose `msg.value` is not `amount`, or
    ///         an arrival past `MAX_RECEIVED`.
    error InvalidAmount(uint256 amount);
    /// @notice The claim would pay nothing.
    error NothingToClaim();
    /// @notice The token is not initialized yet.
    error NotLive();
    /// @notice The token is already initialized.
    error AlreadyLive();
    /// @notice The caller left less gas than door `door` needs; call again with more gas or a smaller page.
    error SyncStarved(uint256 door, uint256 needed);
    /// @notice A sync or a bonus ran while the PoolManager was unlocked. Inside an unlock anyone can borrow the shares
    ///         the PoolManager holds (pool inventory, which earns nothing) and would take their part of the income
    ///         recognized then; call it outside an unlock.
    error PoolManagerUnlocked();
    /// @notice An ERC-20 moved other than the amount asked: a fee-on-transfer or rebasing token.
    error InexactTransfer();
    /// @notice ETH was sent with an ERC-20 bonus.
    error NativeNotAccepted();

    // ------------------------------------------------------------------ events

    /// @notice The supply was minted and income recognition started.
    event Initialized(uint256 supply, address bridge, uint16 bridgeBps);
    /// @notice Door `door` was added.
    event DoorAdded(uint256 indexed door, DoorKind kind, address indexed target, uint32 gas, uint16 legBps);
    /// @notice `currency` was listed as asset `asset`; its income accounting starts from this block on.
    event AssetAdded(uint256 indexed asset, Currency indexed currency);
    /// @notice `newManager` may accept the stream manager role from `manager`.
    event StreamManagerTransferStarted(address indexed manager, address indexed newManager);
    /// @notice The stream manager role moved from `manager` to `newManager`; zero closes the stream list for good.
    event StreamManagerTransferred(address indexed manager, address indexed newManager);
    /// @notice `owner` approved or revoked `operator` (ERC-6909's event).
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    /// @notice `amount` of asset `asset` was recognized with release deadline `streamEnd`, now in immediate mode.
    event IncomeRecognized(uint256 indexed asset, bytes32 indexed sourceId, uint256 amount, uint64 streamEnd);
    /// @notice `amount` of asset `asset` was released into the index, now `index`.
    event IncomeReleased(uint256 indexed asset, uint256 amount, uint256 index);
    /// @notice `account` was paid `amount` of asset `asset` at `to`.
    event IncomeClaimed(address indexed account, uint256 indexed asset, address indexed to, uint256 amount);
    /// @notice Door `door` was pulled; `ok` false when its call reverted and the sync went on.
    event DoorPulled(uint256 indexed door, bool ok);
    /// @notice Hookr's leg of what door `door` delivered: `amount` of asset `asset`, sent to the leg collector.
    event LegPaid(uint256 indexed door, uint256 indexed asset, uint256 amount);
    /// @notice Asset `asset`'s balance could not be read (a revert, a burned stipend, a bad answer); it was skipped
    ///         in this sync and nothing else was.
    event AssetReadFailed(uint256 indexed asset);
    /// @notice One sync: `by` was paid `tip` of the `pulledEth` the pulled doors delivered after Hookr's leg,
    ///         `bridged` went to the bridge.
    event Synced(address indexed by, uint256 pulledEth, uint256 tip, uint256 bridged);
    /// @notice `from` paid `amount` of asset `asset` in as a bonus under the release period, with no tip.
    event BonusDeposited(address indexed from, uint256 indexed asset, uint256 amount);
    /// @notice `amount` of `asset`, which is not a listed asset, sat in the token and went into the drop box, where it
    ///         is recorded immediately at a release period under an hour or released in slices otherwise
    ///         (IHookrDropBox.dropStray).
    event StrayDropped(address indexed asset, uint256 amount);

    // ------------------------------------------------------------------ constants

    /// @notice Fixed-point scale of every index and scaled credit: 1e36.
    function SCALE() external view returns (uint256);
    /// @notice Most listed assets a token may have: 8 (native ETH and seven ERC-20s).
    function MAX_ASSETS() external view returns (uint256);
    /// @notice Smallest share supply: 1.
    function MIN_SUPPLY() external view returns (uint256);
    /// @notice Largest share supply: 2^128 - 1.
    function MAX_SUPPLY() external view returns (uint256);
    /// @notice Shortest release period: zero, for immediately claimable income.
    function MIN_STREAM_SECONDS() external view returns (uint32);
    /// @notice Longest release period: 14 days.
    function MAX_STREAM_SECONDS() external view returns (uint32);
    /// @notice Default release period: zero, for immediately claimable income.
    function DEFAULT_STREAM_SECONDS() external view returns (uint32);
    /// @notice Largest sync tip: 100 basis points (1%) of the ETH a sync's pulled doors deliver.
    function MAX_TIP_BPS() external view returns (uint16);
    /// @notice Least ETH a sync's pulled doors must deliver for its caller to be tipped at all: 0.001 ETH.
    function MIN_TIP_PULL() external view returns (uint256);
    /// @notice Largest Fee Bridge slice: 2,000 basis points of each sync's pulled ETH after the tip.
    function MAX_BRIDGE_BPS() external view returns (uint16);
    /// @notice Largest Hookr leg on one door: 500 basis points.
    function MAX_LEG_BPS() external view returns (uint16);
    /// @notice Most units of one asset the token ever recognizes: 2^128 - 1, which keeps every scaled credit below
    ///         2^256.
    function MAX_RECEIVED() external view returns (uint256);
    /// @notice Smallest gas stipend a door may have.
    function MIN_DOOR_GAS() external view returns (uint32);
    /// @notice Largest gas stipend a door may have: 12,000,000, so one door always fits a transaction.
    function MAX_DOOR_GAS() external view returns (uint32);
    /// @notice Gas kept back after each door for what follows it: the leg, the recognitions, the tip and the event.
    ///         A sync needs a door's stipend plus this left before the door, or it reverts `SyncStarved`.
    function SYNC_RESERVE_GAS() external view returns (uint256);
    /// @notice Gas each balance read of a listed asset gets; a read that fails is skipped (`AssetReadFailed`).
    function BALANCE_GAS() external view returns (uint256);
    /// @notice Gas each leg payment of a sync gets: an ERC-20 `transfer` of any listed asset the tokenizer can create
    ///         into the leg collector, or ETH into it. A payment that fails leaves the amount to the holders.
    function LEG_GAS() external view returns (uint256);
    /// @notice Source id of arrivals recognized from a balance delta in a sync (pulls, pushes and plain sends).
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

    /// @notice The tokenizer that created this token: the only caller of `initialize` and `addDoor`.
    function tokenizer() external view returns (address);
    /// @notice Where Hookr's leg goes: the tokenizer's leg collector.
    function legCollector() external view returns (address);
    /// @notice The fixed supply `initialize` mints.
    function shareSupply() external view returns (uint256);
    /// @notice Zero for immediately claimable income, or the period every recognized arrival is released over.
    function streamSeconds() external view returns (uint32);
    /// @notice The sync caller's tip, in basis points of the ETH the pulled doors delivered.
    function tipBps() external view returns (uint16);
    /// @notice Commitment to the published terms at mint. Nonzero.
    function termsHash() external view returns (bytes32);
    /// @notice Whether anyone, not only the stream manager, may add the tokenizer's own door kinds. Fixed at mint.
    function openStreams() external view returns (bool);
    /// @notice Whether `initialize` ran: supply minted, income recognition on.
    function live() external view returns (bool);
    /// @notice The Fee Bridge a slice of each sync's ETH goes to, or zero.
    function bridge() external view returns (address);
    /// @notice The slice of each sync's pulled ETH, after the tip, sent to `bridge`.
    function bridgeBps() external view returns (uint16);

    // ------------------------------------------------------------------ stream manager

    /// @notice Who may add streams and listed assets; zero once the list is closed.
    function streamManager() external view returns (address);
    /// @notice The account that may accept the stream manager role, or zero.
    function pendingStreamManager() external view returns (address);
    /// @notice Starts handing the role to `newManager`, who accepts with `acceptStreamManager`. Only the manager.
    function transferStreamManager(address newManager) external;
    /// @notice Takes the role offered by `transferStreamManager`. Only the pending manager.
    function acceptStreamManager() external;
    /// @notice Gives up the role for good: no stream or listed asset can be added at the manager's request again.
    ///         Only the manager.
    function renounceStreamManager() external;

    // ------------------------------------------------------------------ assets

    /// @notice Number of listed assets.
    function assetCount() external view returns (uint256);
    /// @notice Listed asset `asset` and its accounting; reverts `UnknownAsset` past the last one.
    function assetAt(uint256 asset) external view returns (Asset memory);
    /// @notice The index of listed asset `currency`; reverts `InvalidAsset` when it is not one.
    function assetOf(Currency currency) external view returns (uint256);
    /// @notice Whether `currency` is a listed asset.
    function isAsset(Currency currency) external view returns (bool);
    /// @notice Lists `currency`, an ERC-20 with code that is not this token, as the next asset: from this block on it
    ///         streams instead of dropping. Only the tokenizer or the stream manager.
    function addAsset(Currency currency) external returns (uint256 asset);
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
    /// @notice Pays the caller's claim in every asset to `to`: an asset with nothing due pays zero, and one whose payout
    ///         fails is skipped with its credit kept while the others pay. Reverts `NothingToClaim` when no asset paid.
    function claimAll(address to) external returns (uint256[] memory amounts);
    /// @notice `claim` for `holder` by one of its operators (or `holder` itself), paid to `to`.
    function claimFrom(address holder, uint256 asset, address to) external returns (uint256 amount);
    /// @notice `claimAll` for `holder` by one of its operators (or `holder` itself), paid to `to`.
    function claimAllFrom(address holder, address to) external returns (uint256[] memory amounts);
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
    /// @notice Whether `operator` may claim `owner`'s income here and its drops in the box.
    function isOperator(address owner, address operator) external view returns (bool);
    /// @notice Approves or revokes `operator` for the caller.
    function setOperator(address operator, bool approved) external returns (bool);
    /// @notice Releases every asset's due stream into its index. Permissionless. A transfer does it too; a claim
    ///         releases its own asset, a claim of every asset each asset it does not skip, a sync each asset it
    ///         recognizes an arrival in, and a bonus its own asset.
    function poke() external;

    // ------------------------------------------------------------------ doors and sync

    /// @notice Number of doors.
    function doorCount() external view returns (uint256);
    /// @notice Door `door`.
    function doorAt(uint256 door) external view returns (Door memory);
    /// @notice Up to `count` doors from `start`; fewer at the end of the list.
    function doors(uint256 start, uint256 count) external view returns (Door[] memory);
    /// @notice Whether `target` is one of this token's doors.
    function isDoor(address target) external view returns (bool);
    /// @notice The index of door `target`; reverts `InvalidTarget` when it is not a door.
    function doorIndexOf(address target) external view returns (uint256);
    /// @notice Hookr's leg of what door `door` delivers, in basis points, fixed when the door was added; zero for an
    ///         address that is not a door. A door reads it to take the leg itself on a currency this token does not
    ///         list, which the sync cannot measure.
    function legOf(address door) external view returns (uint16);
    /// @notice Pulls every door, then settles the sync: Hookr's leg of each legged door's delivery, the caller's tip
    ///         of the ETH the doors delivered after the leg (from `MIN_TIP_PULL`), the bridge slice, and one
    ///         recognition per listed asset. Anyone may call, outside a PoolManager unlock (`PoolManagerUnlocked`
    ///         inside one, as for every sync and `depositBonus`). A token with more doors than one transaction carries
    ///         is synced in pages with `syncRange`.
    function sync() external returns (uint256 tip);
    /// @notice `sync` over doors `start` to `start + count - 1`, clipped to the last door.
    function syncRange(uint256 start, uint256 count) external returns (uint256 tip);
    /// @notice `sync` over the listed doors alone, in that order: a way to skip a door that burns its stipend. An
    ///         index past the last door is `InvalidDoor`; an empty list pulls nothing and recognizes the pushes.
    function syncSome(uint256[] calldata doorIds) external returns (uint256 tip);
    /// @notice Pays `amount` of asset `asset` in as a bonus. Native: send exactly `amount` as value. ERC-20: approve
    ///         first; a transfer that lands short is refused. Recognized at once and never tipped; Hookr's leg is not
    ///         taken on it (a payer's payment source takes the leg before it calls this). Refused while the PoolManager
    ///         is unlocked (`PoolManagerUnlocked`), so a payer pays outside its own unlock.
    function depositBonus(uint256 asset, uint256 amount) external payable;
    /// @notice Moves everything this token holds of `asset`, an ERC-20 that is not a listed asset, into the drop box,
    ///         which records it immediately at a release period under an hour or releases it in slices otherwise. Anyone may
    ///         call. A listed asset, native ETH or this token is refused (`InvalidAsset`).
    function dropStray(address asset) external;
    /// @notice Claims the income this token's shares of `revenueToken`, another revenue token, earned there (the shares
    ///         of a listed asset its holders have not claimed yet) into this token: a listed asset arrives as surplus
    ///         the next sync recognizes, any other waits for `dropStray`. When `revenueToken` lists this token as an asset,
    ///         this token's own share of that asset is claimed to 0xdead first (`IncomeRetired`; the token cannot
    ///         pay holders in its own shares), then everything else is claimed in. Anyone may call; nothing due claims
    ///         nothing. This token itself is refused (`InvalidAsset`). When `revenueToken` lists this token, the call
    ///         reverts `IncomeRecoveryStarved(asset)` below about 1,775,000 gas, whether or not anything is due
    ///         (nothing is lost; retry with more gas). Above that, the claim of everything else gets only the gas the
    ///         retirement leaves, and one that runs out collects nothing without reverting: when both tokens list
    ///         eight assets, give the call 3,000,000 gas for the whole collection.
    function collectIncome(address revenueToken) external;

    // ------------------------------------------------------------------ tokenizer

    /// @notice Mints the whole supply and fixes the bridge. Only the tokenizer, once.
    function initialize(Mint calldata m) external;
    /// @notice Adds a door. Only the tokenizer, which locked the fee right behind it first.
    function addDoor(Door calldata door) external returns (uint256 id);
}
