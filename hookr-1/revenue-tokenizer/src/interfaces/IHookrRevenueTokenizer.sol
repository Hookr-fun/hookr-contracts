// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRevenueSource} from "./IHookrRevenueSource.sol";

/// @title Hookr Multi-stream Revenue Tokenizer (HookRevenue Tokenizer)
/// @notice Lock-to-mint: locks a fee right and mints a fixed-supply revenue token whose holders share everything the right
///         earns. Four ways in, each one transaction:
///         (1) a new Hookr launch: the tokenizer launches the family through the live HookrLauncher with every pool's
///             royalty pointed at the revenue token, and locks the family in the live HookrFamilyLock with a forwarder as
///             beneficiary, for good or until a term's unlock block;
///         (2) an existing pools.trade token: its Fee Beneficiary NFT is pulled into a one-way adapter;
///         (3) not the owner: anyone launches a new Hookr pool for an existing token (the launcher's existing-asset
///             lane) and locks that position, the same as (1);
///         (4) position NFTs: the creator's Uniswap v4 position NFTs (one pool or several, on the Hookr root or not)
///             go into a HookrPositionNftDoor the tokenizer creates, locked until a date or for good; anyone pushes
///             their fees to the revenue token;
///         (5) streams: any mix of the above in one token (`tokenizeStreams`): a new Hookr launch, one or more
///             pools.trade Fee Beneficiary NFTs, a set of v4 position NFTs, a set of Uniswap v3 position NFTs in a
///             HookrV3PositionNftDoor, and any number of outside rights through IHookrRevenueSource adapters (a Pons
///             creator fee, any other platform later), each a door of the one token.
///         Market at mint: in the same call the revenue token's own market opens as a pool in the family, revenue token / ETH on
///         the Hookr root, the creator seeding revenue tokens single-sided above a start price, its family locked to the
///         same forwarder so trading the revenue token feeds its own vault.
/// @dev Ownerless. Every live dependency is pinned at construction: the launcher, the lock, the root, the admitted
///      Rules, the treasury, the pools.trade vaults, the Fee Bridge v2 factory and the PositionManager (the door
///      factory is deployed by the tokenizer for it). Hookr's leg, when there is one, goes to one HookrLegCollector the
///      tokenizer deploys. The leg rule: no leg when the tokenized stream already pays Hookr
///      through our hook (ways 1 and 3, and way 4 when every position's pool hook is the root: Hook Block fees and arb
///      recapture), so there is no double fee; `HOOKR_LEG_BPS_OUTSIDE` (5% of the shares) when it does not (way 2, a
///      pools.trade Fee Beneficiary NFT; way 4 with any position off the root, a mixed list included). The basis
///      points are fixed per way at tokenize time and recorded with the token. A pool on the root with recapture off
///      and no fee-taking Hook Block pays Hookr nothing and still takes no leg, because the pool is on our hook.
interface IHookrRevenueTokenizer {
    /// @notice The revenue token's terms.
    /// @param name ERC-20 name.
    /// @param symbol ERC-20 symbol.
    /// @param supply Fixed supply, minted once at seal.
    /// @param streamSeconds Release period of every arrival, 1 to 14 days; zero for the 7-day default.
    /// @param tipBps The sync caller's tip in basis points of the ETH pulled, at most 100.
    /// @param extraAssets Assets beside native ETH and the family's own currencies (for a FEEB right: HOOKR, if its
    ///        side ever pays out); the whole list is at most 4.
    /// @param recipients Who receives the supply left after the Hookr leg (when there is one) and the market seed.
    /// @param amounts Units per recipient; the sum must equal supply - leg - seed exactly, with `leg = supply x legBps
    ///        / 10,000` for the way's leg: the market seed comes out of the creator's side.
    /// @param termsHash Commitment to the published terms; nonzero.
    struct TokenTerms {
        string name;
        string symbol;
        uint256 supply;
        uint32 streamSeconds;
        uint16 tipBps;
        Currency[] extraAssets;
        address[] recipients;
        uint256[] amounts;
        bytes32 termsHash;
    }

    /// @notice How long the locked families stay locked.
    /// @param unlockBlock The parent block from which the forwarder may release them to the creator;
    ///        type(uint64).max locks for good. A finite block makes a dated income bond: the token earns only while the
    ///        families are locked, and at release the creator takes them back after a final pull. A term is at least
    ///        `MIN_TERM_BLOCKS` from the current block (`TermTooShort` otherwise); past that the creator sets any block.
    ///        Ignored, and recorded as zero, when no family is locked: a Fee Beneficiary NFT or a position-NFT door
    ///        with no market.
    struct LockTerms {
        uint64 unlockBlock;
    }

    /// @notice A PositionManager permit (ERC721Permit_v4) the tokenizer applies before it moves the creator's position
    ///         NFTs, so the creator signs instead of sending an approval first: one `permit` for position `tokenId`
    ///         approving the door factory, or, with `forAll`, one `permitForAll` making the factory an operator for
    ///         every position of the creator (`tokenId` ignored). A permit that fails is skipped, not fatal: a
    ///         front-run permit already set the same approval, and the move itself fails when none is in place.
    /// @dev The PositionManager verifies as Permit2 does: a creator with code is asked through ERC-1271 and its key is
    ///      never tried. An EIP-7702 creator whose code does not answer ERC-1271 approves the door factory
    ///      (`setApprovalForAll`) instead of signing. `permitForAll` outlives the tokenization and is revoked with
    ///      `setApprovalForAll(doorFactory, false)`; a `permit` is consumed by the move.
    /// @param forAll Whether this is a `permitForAll`.
    /// @param tokenId The position a `permit` approves.
    /// @param deadline The last timestamp at which the signature is good.
    /// @param nonce The creator's unordered nonce on the PositionManager.
    /// @param signature The creator's signature over the PositionManager's typed data, `r || s || v`.
    struct PositionPermit {
        bool forAll;
        uint256 tokenId;
        uint256 deadline;
        uint256 nonce;
        bytes signature;
    }

    /// @notice What goes into a position-NFT door (way 4).
    /// @param tokenIds The caller's positions, 1 to `MAX_POSITIONS`.
    /// @param unlockAt The door's unlock timestamp, at least `MIN_TERM_SECONDS` from now, or type(uint64).max for good.
    /// @param permits PositionManager permits applied first, in order; empty when the door factory is already approved.
    struct PositionTerms {
        uint256[] tokenIds;
        uint64 unlockAt;
        PositionPermit[] permits;
    }

    /// @notice The revenue token's own market, opened at mint, or off.
    /// @param open Whether to open it.
    /// @param seed Revenue tokens the creator seeds single-sided, taken from the supply.
    /// @param tickSpacing The pool's tick spacing.
    /// @param sqrtPriceX96 The start price as a sqrt price in Q64.96 (ETH is currency0, the revenue token currency1).
    /// @param tickLower The lower tick of the seed position.
    /// @param tickUpper The upper tick of the seed position; at or below the start price's tick, so the position is
    ///        all revenue token.
    /// @param liquidity The liquidity the seed adds.
    /// @param config The pool's identity, trusted modules and limits; `rules` must be an admitted Rules.
    /// @param rules The pool's native rules; `royaltyTo` is set to the revenue token by the tokenizer.
    /// @param recapture The pool's recapture config; the recommended default is traderBps 0, lpBps 10,000 (the whole
    ///        pool half to the locked position, so the token gets the most recapture).
    /// @param bridgeBps The share of each sync's pulled ETH, after the tip, dripped to the market's LPs through a Fee
    ///        Bridge v2 the tokenizer creates; zero for none.
    /// @param bridgeMaxPerDrip Fee Bridge terms (see IHookrFeeBridge.Terms); ignored at a zero bridgeBps.
    /// @param bridgeMinBlocks Fee Bridge terms.
    /// @param bridgeTipBps Fee Bridge terms.
    /// @param bridgeMaxJumpBps Fee Bridge terms.
    struct MarketTerms {
        bool open;
        uint256 seed;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        HookrTypes.PoolConfig config;
        HookrTypes.RulesConfig rules;
        HookrTypes.RecaptureConfig recapture;
        uint16 bridgeBps;
        uint128 bridgeMaxPerDrip;
        uint32 bridgeMinBlocks;
        uint16 bridgeTipBps;
        uint16 bridgeMaxJumpBps;
    }

    /// @notice One pools.trade Fee Beneficiary NFT going into a stream token.
    /// @param vault An admitted pools.trade vault.
    /// @param tokenId The caller's NFT, approved to the tokenizer.
    struct FeebSource {
        address vault;
        uint256 tokenId;
    }

    /// @notice A v3 NonfungiblePositionManager permit (ERC721Permit) the tokenizer applies before it moves the
    ///         creator's v3 position NFTs: `permit(v3DoorFactory, tokenId, deadline, v, r, s)`, one per position
    ///         (the v3 manager has no `permitForAll`; `setApprovalForAll(v3DoorFactory, true)` is the alternative).
    ///         A permit that fails is skipped, not fatal, as a v4 permit is.
    /// @param tokenId The position the permit approves.
    /// @param deadline The last timestamp at which the signature is good.
    /// @param v The signature's `v`.
    /// @param r The signature's `r`.
    /// @param s The signature's `s`.
    struct V3PositionPermit {
        uint256 tokenId;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice What goes into one stream token (way 5): any mix, at least one stream.
    /// @param launchParams `abi.encode(IHookrLauncher.LaunchParams)` for a new Hookr launch (way 1, or way 3 with
    ///        `token.existing` set), every member's `royaltyTo` naming `predictStreamToken(creator, t)`; empty for no
    ///        launch. The launch's native budgets and fee come with `msg.value` as in `launchAndTokenize`.
    /// @param feebs pools.trade Fee Beneficiary NFTs, each into its own one-way adapter; may be empty.
    /// @param positionIds The caller's Uniswap v4 position NFTs, 1 to `MAX_POSITIONS` in one door; may be empty.
    /// @param positionPermits PositionManager permits applied before the v4 move, as `PositionTerms.permits`.
    /// @param v3PositionIds The caller's Uniswap v3 position NFTs, 1 to `MAX_POSITIONS` in one v3 door; may be empty.
    /// @param v3Permits v3 manager permits applied before the v3 move, one per position at most.
    /// @param sources IHookrRevenueSource adapters already made for the predicted token (a HookrPonsAdapter, any
    ///        adapter), each bound to its right; may be empty.
    /// @param unlockAt The one term of the doors (v4 and v3): at least `MIN_TERM_SECONDS` from now, or
    ///        type(uint64).max for good. Read only when a door is made. The families' term is `LockTerms.unlockBlock`,
    ///        read only when a family is locked (a launch, or the market).
    struct StreamParams {
        bytes launchParams;
        FeebSource[] feebs;
        uint256[] positionIds;
        PositionPermit[] positionPermits;
        uint256[] v3PositionIds;
        V3PositionPermit[] v3Permits;
        address[] sources;
        uint64 unlockAt;
    }

    /// @notice The kinds of stream `streamsOf` reports, one per door and per locked family.
    /// @param RULES A pool's Rules ledger (its royalty and the Hook Block takes credited to the token), frozen in
    ///        the pool at launch: it keeps paying the token after the family is released.
    /// @param FAMILY The launched family in the forwarder: LP fees and recapture until its unlock block.
    /// @param MARKET The token's own market family in the forwarder.
    /// @param FEEB A pools.trade Fee Beneficiary NFT in its adapter, for good.
    /// @param POSITIONS A v4 position-NFT door, until its unlock time.
    /// @param POSITIONS_V3 A v3 position-NFT door, until its unlock time.
    /// @param SOURCE An IHookrRevenueSource adapter, as it answers `ends()`.
    enum StreamKind {
        RULES,
        FAMILY,
        MARKET,
        FEEB,
        POSITIONS,
        POSITIONS_V3,
        SOURCE
    }

    /// @notice One stream of a token and when it ends, read live from the token's doors.
    /// @param kind The kind.
    /// @param target The door (the Rules, the forwarder, the adapter, the door).
    /// @param id The family for `FAMILY` and `MARKET`, the NFT id for `FEEB`, the adapter's `sourceKind` for
    ///        `SOURCE`, zero otherwise.
    /// @param endKind How the stream ends.
    /// @param end The parent block (`AT_BLOCK`), the timestamp (`AT_TIME`) or the pending revocation's earliest
    ///        moment (`REVOCABLE`); zero otherwise.
    struct StreamRecord {
        StreamKind kind;
        address target;
        bytes32 id;
        IHookrRevenueSource.EndKind endKind;
        uint64 end;
    }

    /// @notice What the tokenizer created for one revenue token.
    /// @param creator The account that tokenized.
    /// @param way Which way in made it: `WAY_NEW_LAUNCH` (1), `WAY_FEEB` (2), `WAY_EXISTING_POOL` (3),
    ///        `WAY_POSITIONS` (4) or `WAY_STREAMS` (5); zero for a token this tokenizer did not create.
    /// @param forwarder The family forwarder, or zero (a FEEB right or a door without a market).
    /// @param adapter The FEEB adapter, or zero; on way 5, the first of them. The token's doors list them all.
    /// @param door The v4 position-NFT door, or zero. On way 5 the v3 door and the sources are in the token's doors
    ///        and in `streamsOf`.
    /// @param familyId The launched family, or zero.
    /// @param marketFamilyId The revenue token's market family, or zero.
    /// @param unlockBlock The families' unlock block; zero when no family is locked (way 2 or way 4 without a market:
    ///        a door's own term is its `unlockAt`).
    /// @param legBps Hookr's leg of the supply in basis points, fixed at tokenize time: `HOOKR_LEG_BPS_HOOKR` or
    ///        `HOOKR_LEG_BPS_OUTSIDE`.
    struct Tokenization {
        address creator;
        uint8 way;
        address forwarder;
        address adapter;
        address door;
        bytes32 familyId;
        bytes32 marketFamilyId;
        uint64 unlockBlock;
        uint16 legBps;
    }

    /// @notice A constructor argument has no code or does not fit the others, or a deployment inside a tokenization
    ///         came back other than predicted.
    error InvalidConfig();
    /// @notice The token terms do not hold: no supply or more than `MAX_SUPPLY`, a release period outside 1 to 14 days,
    ///         a tip above `MAX_TIP_BPS`, a zero terms hash, no recipient, a zero recipient or amount, more members
    ///         than a family takes, or a member's `royaltyTo` that is not the predicted revenue token.
    error InvalidTerms();
    /// @notice A term shorter than the minimum: `given` is the unlock block (ways 1 and 3, and every market family) or
    ///         the door's unlock second (way 4), `minimum` the earliest one the call accepts (now plus `MIN_TERM_BLOCKS`
    ///         or `MIN_TERM_SECONDS`). type(uint64).max, forever, is always accepted.
    error TermTooShort(uint64 given, uint64 minimum);
    /// @notice The market terms do not hold: no seed, a bridge slice with no bridge factory or above `MAX_BRIDGE_BPS`,
    ///         or a default market whose seed range or liquidity does not fit.
    error InvalidMarket();
    /// @notice The revenue token would take `count` assets, more than `MAX_ASSETS`.
    error TooManyAssets(uint256 count);
    /// @notice `rules` is not one of the admitted Rules (or, at construction, has no code, trusts another root or is
    ///         listed twice).
    error RulesNotAdmitted(address rules);
    /// @notice `vault` is not one of the admitted pools.trade vaults (or, at construction, has no code or is listed
    ///         twice).
    error VaultNotAdmitted(address vault);
    /// @notice The Fee Beneficiary NFT did not reach the adapter: `owner` holds it.
    error NotNftOwner(address vault, uint256 tokenId, address owner);
    /// @notice The recipients' amounts sum to `sum`; they must sum to `expected`, the supply less the Hookr leg and the
    ///         market seed.
    error MintMismatch(uint256 sum, uint256 expected);
    /// @notice `msg.value` is not what the way needs (the launch fee with a market, nothing otherwise; the budgets and
    ///         the fee on a launch), ETH arrived outside a tokenization, or ETH was left when the call ended.
    error InvalidFunding();
    /// @notice The call re-entered the tokenizer.
    error Reentered();
    /// @notice The door the factory returned is not the factory's, names another revenue token or is not active.
    error DoorMismatch(address door);
    /// @notice A member's (or the market's) Tax + Conversion bind data names a creator recipient (`assetRecipient` or
    ///         `recoveryRecipient` of either leg) that is neither the revenue token nor zero, or is too short to hold the
    ///         block's Config (the market's launch binds with empty data, so Tax + Conversion cannot bind there).
    error AdvisoryRecipientMismatch(address advisory);
    /// @notice Way (5): the streams would make `count` doors, more than the token's `MAX_DOORS` (8).
    error TooManyDoors(uint256 count);
    /// @notice Way (5): no launch, no NFT and no source were given.
    error NothingToTokenize();
    /// @notice Way (5): `source` has no code, names another revenue token, is listed twice, declares a `pullGas`
    ///         outside 100,000 to 3,000,000 (HookrRevenueStreams.MIN_SOURCE_GAS and MAX_SOURCE_GAS: a sync must have
    ///         each door's stipend to spare, so a source cannot ask for more than a v4 door of one position gets),
    ///         or does not answer one of its views within the gas cap with well-formed data.
    error InvalidSource(address source);
    /// @notice Way (5): the outside right does not point at `source` yet (`bound()` is false).
    error SourceNotBound(address source);
    /// @notice Way (5): `source` answers `ends()` as `REVOCABLE` with a date: a revocation of the right is already
    ///         pending or executable (a Pons owner override) from `effectiveAt`, which would end the stream inside any
    ///         term the tokenizer accepts. Wait for it to lapse or be cancelled.
    error SourceRevocationPending(address source, uint64 effectiveAt);
    /// @notice Way (5): the doors' stipends plus one sync reserve each sum to `total`, more than the token's
    ///         `MAX_SYNC_GAS`: no transaction could carry a sync in which every door spent its stipend. Fewer
    ///         positions per door, or fewer sources.
    error SyncTooExpensive(uint256 total);
    /// @notice Way (5): a stream delivers `currency`, which is not native ETH and not in `TokenTerms.extraAssets`.
    error AssetNotListed(Currency currency);

    /// @notice `token` was created by `creator` through way `way`: `supply` minted, families locked until
    ///         `unlockBlock` (zero when no family is locked), `legBps` of the supply minted to the Hookr leg collector
    ///         (zero for a stream on our hook).
    event Tokenized(
        address indexed token,
        address indexed creator,
        uint8 way,
        address forwarder,
        address adapter,
        address door,
        bytes32 familyId,
        bytes32 marketFamilyId,
        uint256 supply,
        uint64 unlockBlock,
        uint16 legBps
    );
    /// @notice Pool `member` of `token`'s launch (a member's index, or `MARKET_MEMBER` for the revenue token's own market)
    ///         binds Hook Block `advisory`, admitted on the root to take quote, whose payee is the block's own and not
    ///         readable by the tokenizer: the block binds as on any launch, and the app reads the block's payee to
    ///         show where its cut goes. Tax + Conversion is never reported here: its creator payout is checked to be
    ///         the token. A block admitted with no quote take is not reported either: it can only surcharge the LP
    ///         fee, which the locked position earns for the token.
    event AdvisoryPayeeUnchecked(address indexed token, uint256 member, address indexed advisory);
    /// @notice Way (4), before the door is created: position `tokenId` sits on a pool with hook `hooks`; `hookrPool`
    ///         when that is the root; `hookCanBlockCollection` when a hook that is not the root runs on liquidity
    ///         removals, so its author could make this position's collection fail and keep this one NFT in the door.
    event PositionReported(uint256 indexed tokenId, address hooks, bool hookrPool, bool hookCanBlockCollection);
    /// @notice `token`'s own market opened: pool `poolId` of family `familyId`, its position holding `seed` revenue tokens
    ///         (the seed minted less what the launcher returned to the creator); `bridge` drips `bridgeBps` of each
    ///         sync's ETH to its LPs, or is zero.
    event MarketOpened(
        address indexed token,
        bytes32 indexed familyId,
        PoolId indexed poolId,
        uint256 seed,
        address bridge,
        uint16 bridgeBps
    );
    /// @notice Way (5): stream `index` of `token` is `kind` at `target` (`id` as `StreamRecord.id`), ending as
    ///         `endKind` at `end` as of the mint; `streamsOf(token)` answers the same live.
    event StreamAdded(
        address indexed token,
        uint256 index,
        StreamKind kind,
        address indexed target,
        bytes32 id,
        IHookrRevenueSource.EndKind endKind,
        uint64 end
    );

    /// @notice The HookrLauncher families launch on.
    function launcher() external view returns (address);
    /// @notice The HookrFamilyLock the families are locked in.
    function lock() external view returns (address);
    /// @notice The Hookr root every market opens on.
    function root() external view returns (address);
    /// @notice The HookrTreasury whose target the leg collector pays.
    function treasury() external view returns (address);
    /// @notice The HookrLegCollector holding Hookr's leg of every revenue token that has one.
    function collector() external view returns (address);
    /// @notice The Fee Bridge v2 factory, or zero for no bridges.
    function bridgeFactory() external view returns (address);
    /// @notice The Uniswap v4 PoolManager.
    function poolManager() external view returns (address);
    /// @notice The Uniswap v4 PositionManager whose NFTs a door locks.
    function positionManager() external view returns (address);
    /// @notice The HookrPositionNftDoorFactory this tokenizer deployed, the only one whose doors it seals in; the
    ///         creator approves it on the PositionManager before `tokenizePositions`.
    function doorFactory() external view returns (address);
    /// @notice The Uniswap v3 NonfungiblePositionManager whose NFTs a v3 door locks.
    function positionManagerV3() external view returns (address);
    /// @notice The HookrV3PositionNftDoorFactory this tokenizer deployed, the only one whose v3 doors it seals in; the
    ///         creator approves it on the v3 manager before `tokenizeStreams` with v3 positions.
    function v3DoorFactory() external view returns (address);
    /// @notice Most position NFTs one door takes: 64 (HookrPositionNftDoor.MAX_POSITIONS).
    function MAX_POSITIONS() external view returns (uint256);
    /// @notice The shortest term of a locked family (ways 1 and 3, and the market family of every way), in parent-chain
    ///         blocks from the block of the call: 50,400, seven days of 12-second parent blocks. `block.number` on
    ///         Robinhood Chain is the parent chain's height, so a missed parent slot makes the real term slightly
    ///         longer, never shorter. Past it the creator sets any block; type(uint64).max is forever.
    function MIN_TERM_BLOCKS() external view returns (uint64);
    /// @notice The shortest term of a position-NFT door (way 4), in seconds from the call: seven days. The door's clock
    ///         is `block.timestamp`; the market family it may open follows `MIN_TERM_BLOCKS`. Past it the creator sets
    ///         any date; type(uint64).max is forever.
    function MIN_TERM_SECONDS() external view returns (uint64);
    /// @notice Whether `rules` is one of the admitted Rules a family member may bind (the live HookrRules and the
    ///         whole-pot Rules).
    function isAdmittedRules(address rules) external view returns (bool);
    /// @notice Whether `vault` is one of the admitted pools.trade vaults.
    function isAdmittedVault(address vault) external view returns (bool);
    /// @notice Every admitted Rules, in construction order; the first is what `defaultMarket` binds.
    function admittedRules() external view returns (address[] memory);
    /// @notice Every admitted pools.trade vault, in construction order.
    function admittedVaults() external view returns (address[] memory);
    /// @notice The way numbers `Tokenization.way` records: a new Hookr launch (1), a pools.trade Fee Beneficiary NFT
    ///         (2), a new Hookr pool for an existing token (3), position NFTs in a door (4), streams (5).
    function WAY_NEW_LAUNCH() external view returns (uint8);
    function WAY_FEEB() external view returns (uint8);
    function WAY_EXISTING_POOL() external view returns (uint8);
    function WAY_POSITIONS() external view returns (uint8);
    function WAY_STREAMS() external view returns (uint8);
    /// @notice The `member` an `AdvisoryPayeeUnchecked` carries for the revenue token's own market: type(uint256).max.
    function MARKET_MEMBER() external view returns (uint256);
    /// @notice How many revenue tokens this tokenizer has created.
    function tokenCount() external view returns (uint256);
    /// @notice The `i`-th revenue token created, in creation order; `tokenizations(tokenAt(i))` is its record.
    function tokenAt(uint256 i) external view returns (address);
    /// @notice Hookr's leg of a supply whose stream does not pay Hookr through our hook (a pools.trade Fee Beneficiary
    ///         NFT), in basis points: 500. Of a mint of 100 the collector takes 5 and the creator's side 95. A
    ///         constant: no owner, no setter.
    function HOOKR_LEG_BPS_OUTSIDE() external view returns (uint16);
    /// @notice Hookr's leg of a supply whose stream already pays Hookr through our hook (a Hookr launch, a new Hookr
    ///         pool): 0, so there is no double fee.
    function HOOKR_LEG_BPS_HOOKR() external view returns (uint16);
    /// @notice What was created for revenue token `token`; zero fields for a token this tokenizer did not create.
    function tokenizations(address token) external view returns (Tokenization memory);

    /// @notice The revenue token `launchAndTokenize(p, t, ...)` called by `creator` would create. A pure function of the
    ///         creator, the terms and the launch's currencies (CREATE2, salt `keccak256(abi.encode(creator,
    ///         t.termsHash))`), so a front end fills every member's `royaltyTo` in before the call. A creator reusing a
    ///         terms hash with the same token terms would collide with its earlier token and the call reverts.
    function predictRevenueToken(address creator, IHookrLauncher.LaunchParams calldata p, TokenTerms calldata t)
        external
        view
        returns (address);

    /// @notice Ways (1) and (3): launches `p` through the launcher with every member's `royaltyTo` naming the revenue token
    ///         `predictRevenueToken(msg.sender, p, t)` gives (or zero with a zero `royaltyBps`; `InvalidTerms` otherwise),
    ///         locks the family for the forwarder, opens the market when `m.open`, and mints with no Hookr leg
    ///         (`HOOKR_LEG_BPS_HOOKR`: the pools are on our hook). `msg.value` is every
    ///         native budget (members, dev buys, the market's none) plus the launch fee, plus the fee again when a
    ///         market opens; ERC-20 budgets are pulled from the caller, who approved this tokenizer. Refunds and
    ///         dev-bought subject go back to the caller.
    ///         A member that binds a Hook Block (`config.advisory`) binds it as on any launch, every admitted block
    ///         allowed. Tax + Conversion (the block that declares `EXCLUSIVE_GROUP()`
    ///         keccak256("DIRECTIONAL_QUOTE_TAX")) must name the revenue token, or zero, as the `assetRecipient` and
    ///         `recoveryRecipient` of both legs of its bind data, so its creator payout (`HookrTaxQueue.payCreator`, a
    ///         push the next sync recognizes with no tip) reaches the token (`AdvisoryRecipientMismatch`); any other
    ///         block admitted on the root to take quote pays its own payee, which the tokenizer cannot read, so it
    ///         emits `AdvisoryPayeeUnchecked(token, i, advisory)` for the app to show where that cut goes; a block
    ///         admitted with no quote take binds with no report. The market's block, when `m.config.advisory` is set,
    ///         is held to the same rule with the empty bind data its launch sends (`MARKET_MEMBER`).
    ///         The last two returns are the launcher's own, so an `eth_call` of this function quotes a dev buy.
    /// @return token The revenue token.
    /// @return forwarder The family forwarder.
    /// @return familyId The launched family.
    /// @return marketFamilyId The market family, or zero.
    /// @return subject The family's subject (the new token for way 1, `p.token.existing` for way 3).
    /// @return subjectOut The subject every dev buy delivered to the caller, net of Auto Burn (the launcher's figure).
    function launchAndTokenize(
        IHookrLauncher.LaunchParams calldata p,
        TokenTerms calldata t,
        LockTerms calldata l,
        MarketTerms calldata m
    )
        external
        payable
        returns (
            address token,
            address forwarder,
            bytes32 familyId,
            bytes32 marketFamilyId,
            address subject,
            uint256 subjectOut
        );

    /// @notice A market the tokenizer fills in for a way with no pool to copy a config from (a FEEB right, a door):
    ///         the revenue token / ETH pool on the root bound to the first admitted Rules (the live HookrRules), 60 tick
    ///         spacing, a 0.3% base LP fee with no dynamic fee, no Auto Burn, LP Rewards 2%, royalty 5% (set to the
    ///         token at launch), the 25% protocol share, no guard, no Hook Block, King of the Pool off; arb recapture
    ///         on with the whole pool half to the locked position (traderBps 0, lpBps 10,000, 36,000 release blocks);
    ///         no bridge. The `seed` revenue tokens sit single-sided in one range from the start price up to about a
    ///         million times it (138,120 ticks, clamped at the lowest tick), with the liquidity that places them.
    ///         Reverts `InvalidMarket` on a zero or unplaceable seed; TickMath refuses a price out of range. A pure
    ///         function of its inputs, so a front end calls it and passes the result as `MarketTerms`; the caller may
    ///         change any field before the call (a creator clears `recapture.on` while the root's lane is closed).
    /// @param sqrtPriceX96 The start price as a sqrt price in Q64.96 (ETH is currency0, the revenue token currency1).
    /// @param seed Revenue tokens seeded, taken from the supply; the same figure goes in `MarketTerms.seed`.
    function defaultMarket(uint160 sqrtPriceX96, uint256 seed) external view returns (MarketTerms memory);

    /// @notice Way (4): the caller's position NFTs `p.tokenIds` (the door factory approved for each on the
    ///         PositionManager, by an approval sent before or by `p.permits` applied here) go into a new
    ///         HookrPositionNftDoor locked until `p.unlockAt` (seconds; at least `MIN_TERM_SECONDS` from now, or
    ///         type(uint64).max for good), the market opens when `m.open` (its family locked until `l.unlockBlock`, at
    ///         least `MIN_TERM_BLOCKS` from now or forever), and the revenue token mints: with no Hookr leg when every
    ///         position's pool hook is the root, with the outside leg otherwise. The token's assets are native ETH,
    ///         every position pool's currencies and `t.extraAssets`, at most 4. Before the door is created a
    ///         `PositionReported` says, per NFT, whether its pool is on the root and whether its hook could block the
    ///         door's collection. At `p.unlockAt` anyone calls the door's `release`: each NFT goes back to the caller,
    ///         its depositor, after a final collection.
    /// @param p The positions, the door's term and the permits.
    /// @param t The revenue token's terms.
    /// @param l The market family's lock terms; read only when `m.open`.
    /// @param m The market, or off.
    /// @return token The revenue token.
    /// @return door The position-NFT door.
    /// @return forwarder The family forwarder, or zero without a market.
    /// @return marketFamilyId The market family, or zero.
    function tokenizePositions(
        PositionTerms calldata p,
        TokenTerms calldata t,
        LockTerms calldata l,
        MarketTerms calldata m
    ) external payable returns (address token, address door, address forwarder, bytes32 marketFamilyId);

    /// @notice What `tokenizePositions(tokenIds, ..)` with `extraAssets` would fix, read from the PositionManager: the
    ///         leg basis points, the token's asset list, and per NFT whether its pool is on the root and whether its
    ///         hook could block the door's collection. Reverts as the call would on the list and the asset count.
    function previewPositions(uint256[] calldata tokenIds, Currency[] calldata extraAssets)
        external
        view
        returns (uint16 legBps, Currency[] memory assets, bool[] memory hookrPool, bool[] memory hookCanBlockCollection);

    /// @notice Way (2): pulls Fee Beneficiary NFT `tokenId` of `vault` (approved to this tokenizer by its holder, the
    ///         caller) into a new one-way adapter, opens the market when `m.open` (locked until `l.unlockBlock`), and
    ///         mints with Hookr's outside leg (`HOOKR_LEG_BPS_OUTSIDE`: the right pays Hookr nothing on its own).
    ///         Claim the NFT's pending fee before calling: what is pending at transfer becomes token income.
    /// @return token The revenue token.
    /// @return adapter The FEEB adapter.
    /// @return forwarder The family forwarder, or zero without a market.
    /// @return marketFamilyId The market family, or zero.
    function tokenizeFeeb(
        address vault,
        uint256 tokenId,
        TokenTerms calldata t,
        LockTerms calldata l,
        MarketTerms calldata m
    ) external payable returns (address token, address adapter, address forwarder, bytes32 marketFamilyId);

    /// @notice The revenue token `tokenizeStreams(p, t, ...)` called by `creator` would create, for any `p`: the
    ///         token's assets are native ETH then `t.extraAssets`, so the address is a pure function of the creator
    ///         and the terms (CREATE2, salt `keccak256(abi.encode(creator, t.termsHash))`). A front end calls it
    ///         first, makes the adapters for that address, fills every launch member's `royaltyTo` with it, and only
    ///         then tokenizes.
    function predictStreamToken(address creator, TokenTerms calldata t) external view returns (address);

    /// @notice Way (5): one revenue token from any mix of streams. In order: the terms are checked (the supply, the
    ///         recipients, the stream window, the tip, both terms; `t.extraAssets` must list every currency the
    ///         streams deliver, `AssetNotListed` otherwise, and native ETH is always asset 0); the token is deployed
    ///         at `predictStreamToken(msg.sender, t)`; the launch runs (ways 1 and 3's rules, every member's
    ///         `royaltyTo` the token) and its family is locked for the forwarder until `l.unlockBlock`; each FEEB NFT
    ///         moves into its own one-way adapter; the v4 positions go into one door and the v3 positions into one v3
    ///         door, both locked until `p.unlockAt` with the permits applied first; every source is checked
    ///         (`revenueToken()` is the token, `bound()`, `assets()` listed, `pullGas()` in bounds); the token is
    ///         sealed with every door (at most `MAX_DOORS`, `TooManyDoors` otherwise), the market opens when
    ///         `m.open`, and everything left comes back to the caller. Hookr's leg is `HOOKR_LEG_BPS_HOOKR` only when
    ///         every stream is on our hook (a launch, v4 positions all on the root, a market); a FEEB NFT, a v3
    ///         position, a v4 position off the root or any source makes it `HOOKR_LEG_BPS_OUTSIDE`. One
    ///         `StreamAdded` per stream says what each is and when it ends; the record's `way` is `WAY_STREAMS`.
    ///         `msg.value` is the launch's budgets and fee when there is a launch, plus the launch fee when a market
    ///         opens, nothing otherwise.
    /// @param p The streams.
    /// @param t The revenue token's terms; `extraAssets` is the whole asset list but native ETH.
    /// @param l The families' lock terms; read only when a family is locked.
    /// @param m The market, or off.
    /// @return token The revenue token; `tokenizations(token)` and `streamsOf(token)` say the rest.
    function tokenizeStreams(
        StreamParams calldata p,
        TokenTerms calldata t,
        LockTerms calldata l,
        MarketTerms calldata m
    ) external payable returns (address token);

    /// @notice Every stream of `token` and when it ends, read live: one record per door, and one per family of the
    ///         forwarder door (the launched family and the market family); a source's record is what it answers
    ///         `ends()` now, so a revoked Pons stream shows `ENDED`. Empty for a token this tokenizer did not create.
    function streamsOf(address token) external view returns (StreamRecord[] memory);
}
