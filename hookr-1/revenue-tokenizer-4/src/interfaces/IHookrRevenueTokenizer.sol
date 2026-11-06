// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrRevenueTokenizerSourcePins} from "./IHookrRevenueTokenizerSourcePins.sol";
import {EndKind} from "../types/EndKind.sol";

/// @title HookRevenue Tokenizer
/// @notice Locks fee rights and mints a fixed-supply revenue token whose holders share everything the rights earn,
///      then adds more streams to it at any time. One call mints a token from any mix of streams: a new Hookr
///      launch, a Hookr family its owner hands over, a pool's Rules ledger, pools.trade Fee Beneficiary NFTs,
///      Uniswap v4 and v3 position NFTs, shares of other revenue tokens, and any outside right through an
///      `IHookrRevenueSource` (Pons, Long, any platform later). The same mix can be added to an existing token with
///      `addStreams`.
/// @dev Ownerless; every live dependency is pinned at construction, and the Rules a launch, a market or a RULES
///      door may use are the ones the registry admits on the root at the moment of the call. The tokenizer locks
///      each right in a door first, then adds the door to the token, in one transaction, so no stream exists before
///      its right is locked and no share exists before the first streams are. Streams are only added: nothing can
///      remove one.
///
/// Who adds: the token's stream manager, or anyone when the token was minted with `openStreams`, for the
///      tokenizer's own door kinds only (no source, no new listed asset).
///
/// Hookr's leg, per door, fixed when the door is added: `HOOKR_LEG_BPS_HOOKR` (0) for a stream that already pays
///      Hookr through our hook (a Hookr family, the market, a Rules ledger, v4 positions whose pools all sit on the
///      root, a revenue token door), `HOOKR_LEG_BPS_OUTSIDE` (500, 5% of what the door delivers) for anything else.
///      A set of v4 positions is split into one door on the root and one off it, so a mix never pays the leg on its
///      Hookr part. The token's sync takes the leg; no shares are minted to Hookr.
///
/// Hook Blocks: every block the registry admits binds on a tokenized launch exactly as on a normal one. Tax +
///      Conversion's creator payout must name the revenue token (`AdvisoryRecipientMismatch`); any other block
///      admitted to take quote pays its own payee and is reported (`AdvisoryPayeeUnchecked`).
interface IHookrRevenueTokenizer is IHookrRevenueTokenizerSourcePins {
    /// @notice The revenue token's terms, fixed at mint.
    /// @param name ERC-20 name.
    /// @param symbol ERC-20 symbol.
    /// @param supply Fixed supply, minted once.
    /// @param streamSeconds Zero for immediately claimable income, or a positive release period up to 14 days.
    /// @param tipBps The sync caller's tip in basis points of the ETH the pulled doors deliver, at most 100.
    /// @param assets ERC-20s listed beside native ETH from the start (eight in all with ETH). A stream's own
    ///      currencies are listed only when its call sets `StreamParams.listAssets`, while there is room; a
    ///      market's ERC-20 quote is listed at mint whatever the flag. A revenue token listing more than one asset
    ///      is `InvalidTerms`.
    /// @param recipients Who receives the supply left after the market seed; never zero, the tokenizer or the leg
    ///      collector.
    /// @param amounts Units per recipient; sum to `supply - seed`.
    /// @param termsHash Commitment to the published terms; nonzero, and used once per creator (`TermsHashUsed`).
    /// @param streamManager Who may add streams and listed assets later; zero closes the list at mint.
    /// @param openStreams Whether anyone may also add the tokenizer's own door kinds.
    struct TokenTerms {
        string name;
        string symbol;
        uint256 supply;
        uint32 streamSeconds;
        uint16 tipBps;
        Currency[] assets;
        address[] recipients;
        uint256[] amounts;
        bytes32 termsHash;
        address streamManager;
        bool openStreams;
    }

    /// @notice A PositionManager permit (ERC721Permit_v4) applied before the caller's v4 positions move: one
    ///      `permit` for `tokenId` approving the v4 door factory, or with `forAll` one `permitForAll`. A permit
    ///      that fails is skipped; the move fails on its own when no approval is in place.
    /// @param forAll Whether the signature approves every position.
    /// @param tokenId The position approved when `forAll` is false.
    /// @param deadline Last timestamp at which the permit is valid.
    /// @param nonce The permit nonce.
    /// @param signature The owner's permit signature.
    struct PositionPermit {
        bool forAll;
        uint256 tokenId;
        uint256 deadline;
        uint256 nonce;
        bytes signature;
    }

    /// @notice A v3 NonfungiblePositionManager permit applied before the caller's v3 positions move:
    ///      `permit(v3DoorFactory, tokenId, deadline, v, r, s)`. Skipped when it fails, as a v4 permit is.
    /// @param tokenId The v3 position to approve.
    /// @param deadline Last timestamp at which the permit is valid.
    /// @param v The signature recovery identifier.
    /// @param r The signature r component.
    /// @param s The signature s component.
    struct V3PositionPermit {
        uint256 tokenId;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice One pools.trade Fee Beneficiary NFT.
    /// @param vault An admitted pools.trade vault.
    /// @param tokenId The caller's NFT, approved to the FEEB adapter factory.
    struct FeebSource {
        address vault;
        uint256 tokenId;
    }

    /// @notice Shares of another revenue token from this tokenizer, locked in a door that claims their income and
    ///      drops into this token (a basket: a token whose streams are other revenue tokens). The door returns the
    ///      shares to the caller at the end of `StreamParams.unlockAt`; Hookr's leg on it is zero.
    /// @param token The inner revenue token; never the token the door pays.
    /// @param amount Shares the tokenizer moves from the caller into the door once it is created; the caller
    ///      approves the tokenizer on the inner token.
    struct RevenueTokenShares {
        address token;
        uint256 amount;
    }

    /// @notice The streams one call adds. Any mix; at least one stream.
    /// @param launchParams `abi.encode(IHookrLauncher.LaunchParams)` for a new Hookr launch (a new token, or a new
    ///      Hookr pool for an existing token) on the pinned root, every member's `royaltyTo` the revenue token when its
    ///      `royaltyBps` is nonzero and zero otherwise; empty for none. A new token's `salt` starts with the caller's
    ///      address (`bytes20(salt) == caller`), and its address (`launcher.predictToken(tokenizer, token)`) must still
    ///      be free. Its budgets and fee come with `msg.value`. A member with a royalty or a Hook Block has its ERC-20
    ///      quote listed, as that quote carries the token's Rules credit: only the creator or the stream manager may
    ///      list one (an outsider on an open token launches such a member on ETH or a listed currency, else
    ///      `NotStreamManager`), and a full list is the token's `TooManyAssets`. A royalty- or Hook-Block-bearing
    ///      member quote that is a revenue token listing more than one asset is `InvalidTerms`, listed or not; a member
    ///      with neither carries no Rules credit for the token and may launch on such a quote.
    /// @param families Hookr families whose owner, the caller, made this tokenizer the pending owner
    ///      (`transferFamily(family, tokenizer, claims)`); each is accepted (the fees so far go to the caller, and
    ///      each member's arb recapture accrual so far to the caller's claims in its Rules), handed to the lock for
    ///      the token's forwarder until `unlockBlock` and registered there returning to the caller. Every member's
    ///      pool must be on the pinned root (`FamilyOffRoot`): a family on another root is outside our hook and has
    ///      no door kind here. Its Hook Blocks and royalty are taken as they are, and no Rules door is added for
    ///      it. A family released from this token's forwarder may be added to it again, for a new term.
    /// @param rules Admitted Rules ledgers that already credit the revenue token (pools launched with its
    ///      `royaltyTo`). The RULES door claims only in listed currencies: credit in another waits in the Rules
    ///      until it is listed, and stays there with no stream manager or a full list.
    /// @param feebs pools.trade Fee Beneficiary NFTs, each into its own adapter.
    /// @param positionIds The caller's Uniswap v4 positions, split into one door on the root and one off it.
    /// @param positionPermits PositionManager permits applied before the v4 move.
    /// @param v3PositionIds The caller's Uniswap v3 positions, into one v3 door; none on a pool of the revenue
    ///      token itself (`V3PairIsRevenueToken`).
    /// @param v3Permits v3 manager permits applied before the v3 move.
    /// @param revenueTokens Shares of other revenue tokens, each into its own door.
    /// @param sources `IHookrRevenueSource` contracts bound to their rights and naming the revenue token, none
    ///      declaring the revenue token itself as one of its assets.
    /// @param unlockBlock The families' term, in parent blocks: at least `MIN_TERM_BLOCKS` ahead, or forever.
    /// @param unlockAt The doors' term, in seconds: at least `MIN_TERM_SECONDS` ahead, or forever.
    /// @param listAssets Whether to list the currencies these streams bring that the token does not list yet, while
    ///      there is room (never a revenue token listing more than one asset); without it only a launch's quotes
    ///      that carry Rules credit are listed, and the income the other currencies push reaches the holders as
    ///      strays. Only the stream manager in `addStreams`; at mint the creator may set it.
    struct StreamParams {
        bytes launchParams;
        bytes32[] families;
        address[] rules;
        FeebSource[] feebs;
        uint256[] positionIds;
        PositionPermit[] positionPermits;
        uint256[] v3PositionIds;
        V3PositionPermit[] v3Permits;
        RevenueTokenShares[] revenueTokens;
        address[] sources;
        uint64 unlockBlock;
        uint64 unlockAt;
        bool listAssets;
    }

    /// @notice The revenue token's own market, opened at mint, or off.
    /// @param open Whether to open it.
    /// @param quote The market's other side: native ETH, or an ERC-20 such as HOOKR; not a revenue token listing
    ///      more than one asset (`InvalidMarket`).
    /// @param seed Revenue tokens seeded single-sided, taken from the supply.
    /// @param tickSpacing The pool's tick spacing.
    /// @param sqrtPriceX96 The start price as a sqrt price in Q64.96 of the sorted pair.
    /// @param tickLower The lower tick of the seed position.
    /// @param tickUpper The upper tick of the seed position; the position holds only the revenue token at the
    ///      start.
    /// @param liquidity The liquidity the seed adds.
    /// @param config The pool's identity, trusted modules and limits; `rules` must be an admitted Rules.
    /// @param rules The pool's native rules; `royaltyTo` is set to the revenue token when `royaltyBps` is nonzero,
    ///      else to zero.
    /// @param recapture The pool's arb recapture config.
    /// @param bridgeBps The share of each sync's pulled ETH, after the tip, dripped to the market's LPs through a
    ///      Fee Bridge the tokenizer creates; zero for none.
    /// @param bridgeMaxPerDrip Most native currency one drip moves, in wei, tip included;
    ///      unused when `bridgeBps` is zero.
    /// @param bridgeMinBlocks Fewest blocks between drips; unused when `bridgeBps` is zero.
    /// @param bridgeTipBps Keeper tip in basis points of the donation; unused when `bridgeBps` is zero.
    /// @param bridgeMaxJumpBps Maximum rise in in-range liquidity since the keeper's record, in basis points;
    ///      unused when `bridgeBps` is zero.
    struct MarketTerms {
        bool open;
        Currency quote;
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

    /// @notice The kinds of stream the records report.
    /// @param RULES A pool's Rules ledger (its royalty and the Hook Block takes credited to the token), frozen in
    ///      the pool.
    /// @param FAMILY A Hookr family in the forwarder: LP fees and arb recapture until its unlock block.
    /// @param MARKET The token's own market family in the forwarder.
    /// @param FEEB A pools.trade Fee Beneficiary NFT in its adapter.
    /// @param POSITIONS A v4 position-NFT door.
    /// @param POSITIONS_V3 A v3 position-NFT door.
    /// @param SOURCE An `IHookrRevenueSource`.
    /// @param REVENUE_TOKEN Shares of another revenue token in a door.
    enum StreamKind {
        RULES,
        FAMILY,
        MARKET,
        FEEB,
        POSITIONS,
        POSITIONS_V3,
        SOURCE,
        REVENUE_TOKEN
    }

    /// @notice One stream of a token.
    /// @param kind The kind.
    /// @param door The door the token pulls (the Rules, the forwarder, the adapter, the door, the source).
    /// @param id The family for `FAMILY` and `MARKET`, the NFT id for `FEEB`, the inner token for `REVENUE_TOKEN`,
    ///      the source's `sourceKind` for `SOURCE`, zero otherwise.
    /// @param legBps Hookr's leg of the door, in basis points.
    /// @param addedAt When the stream was added.
    /// @param endKind How the stream ends, read live.
    /// @param end The parent block, the timestamp or the pending revocation's earliest moment; zero otherwise.
    /// @param family For `FAMILY` and `MARKET`, the family's index in the forwarder (`familyAt`, `extendTerm`,
    ///      `release`); zero otherwise. A family released from the forwarder and added again gets a new index and a
    ///      new record; the earlier record keeps its own index, and reads `ENDED`.
    struct StreamRecord {
        StreamKind kind;
        address door;
        bytes32 id;
        uint16 legBps;
        uint64 addedAt;
        EndKind endKind;
        uint64 end;
        uint32 family;
    }

    /// @notice What the tokenizer keeps per revenue token.
    /// @param creator The account that minted it.
    /// @param forwarder The family forwarder, or zero until a family is locked.
    /// @param marketFamilyId The market family, or zero.
    /// @param createdAt The mint's timestamp.
    struct Tokenization {
        address creator;
        address forwarder;
        bytes32 marketFamilyId;
        uint64 createdAt;
    }

    /// @notice A constructor argument has no code or does not fit the others, or a deployment came back other than
    ///      predicted.
    error InvalidConfig();
    /// @notice The token terms or a stream's terms do not hold: the supply, the release period, the tip, the terms
    ///      hash, the recipients, a listed asset or a credit-bearing launch quote that is a revenue token listing
    ///      more than one asset, a member's `royaltyTo` that does not follow its `royaltyBps`, a launch off the
    ///      pinned root or with the wrong member count, zero inner shares, `launchParams` too short to read, or a bad
    ///      position list.
    error InvalidTerms();
    /// @notice A term shorter than the minimum: `minimum` is the earliest block or second the call accepts.
    error TermTooShort(uint64 given, uint64 minimum);
    /// @notice The market terms do not hold, or the quote is a revenue token listing more than one asset.
    error InvalidMarket();
    /// @notice `rules` is not one of the admitted Rules.
    error RulesNotAdmitted(address rules);
    /// @notice `vault` is not one of the admitted pools.trade vaults.
    error VaultNotAdmitted(address vault);
    /// @notice The recipients' amounts sum to `sum`, not `expected`.
    error MintMismatch(uint256 sum, uint256 expected);
    /// @notice `msg.value` is not what the call needs, or ETH was left when the call ended.
    error InvalidFunding();
    /// @notice The call re-entered the tokenizer.
    error Reentered();
    /// @notice A factory returned a door that is not its own, names another token, or holds a different number of
    ///      root positions than were asked.
    error DoorMismatch(address door);
    /// @notice A Tax + Conversion bind names a creator recipient that is neither the revenue token nor zero.
    error AdvisoryRecipientMismatch(address advisory);
    /// @notice No stream was given.
    error NothingToAdd();
    /// @notice `token` was not made by this tokenizer.
    error UnknownToken(address token);
    /// @notice `caller` may not add these streams: it is not the stream manager, and the token is not open to the
    ///      kinds or the listing asked for.
    error NotStreamManager(address caller);
    /// @notice `family` is not pending to this tokenizer from its owner.
    error FamilyNotHanded(bytes32 family);
    /// @notice `token` cannot be locked in a door of itself, or was not made by this tokenizer.
    error InvalidInnerToken(address token);
    /// @notice `source` has no code, names another revenue token, is listed twice, declares a `pullGas` out of
    ///      bounds or the revenue token itself among its assets, or does not answer its views within the gas cap.
    error InvalidSource(address source);
    /// @notice The outside right does not point at `source` yet, or `source` has already ended.
    error SourceNotBound(address source);
    /// @notice A revocation of `source`'s right is pending from `effectiveAt`.
    error SourceRevocationPending(address source, uint64 effectiveAt);
    /// @notice A new token's launch salt does not start with the caller's address: `bytes20(salt)` must be the
    ///      caller, so no one else can launch the subject the caller predicted through this tokenizer first.
    error LaunchSaltNotCaller(bytes32 salt);
    /// @notice The new token a launch would create at `subject` exists already.
    error SubjectTaken(address subject);
    /// @notice A pool of handed family `family` is not on the pinned root, so its stream is outside our hook.
    error FamilyOffRoot(bytes32 family);
    /// @notice `creator` minted a token under `termsHash` before; one terms hash names one token.
    error TermsHashUsed(address creator, bytes32 termsHash);
    /// @notice v3 position `tokenId` is on a pool of the revenue token itself. A pool outside the v4 PoolManager
    ///      that holds the token is an earning holder that never claims, so its share of every income and drop
    ///      would stay in the token for good.
    error V3PairIsRevenueToken(uint256 tokenId);

    /// @notice `creator` minted `token`: `supply` units, its stream manager `streamManager`.
    /// @param token The revenue token created.
    /// @param creator The caller that created it.
    /// @param supply The fixed supply minted.
    /// @param streamManager The account allowed to add all supported stream kinds.
    /// @param openStreams Whether anyone may add the tokenizer's own door kinds.
    event Tokenized(
        address indexed token, address indexed creator, uint256 supply, address streamManager, bool openStreams
    );
    /// @notice Stream `index` of `token` was added by `by`: `kind` at `door` (`id` as `StreamRecord.id`), Hookr's
    ///      leg `legBps`, ending as `endKind` at `end` as of now.
    /// @param token The revenue token receiving the stream.
    /// @param index The stream index in its records.
    /// @param kind The stream kind.
    /// @param door The door the token pulls.
    /// @param id The underlying right identifier, as defined by StreamRecord.
    /// @param legBps Hookr's leg in basis points.
    /// @param endKind How the right ends.
    /// @param end The end block or timestamp, or zero.
    /// @param by The account that added the stream.
    event StreamAdded(
        address indexed token,
        uint256 index,
        StreamKind kind,
        address indexed door,
        bytes32 id,
        uint16 legBps,
        EndKind endKind,
        uint64 end,
        address by
    );
    /// @notice Pool `member` of a launch for `token` (`MARKET_MEMBER` for the market) binds Hook Block `advisory`,
    ///      which pays its own payee.
    /// @param token The revenue token.
    /// @param member The launch member index, or MARKET_MEMBER.
    /// @param advisory The Hook Block that pays its own recipient.
    event AdvisoryPayeeUnchecked(address indexed token, uint256 member, address indexed advisory);
    /// @notice Position `tokenId` sits on a pool with hook `hooks`; `hookrPool` when that is the root;
    ///      `hookCanBlockCollection` when that hook could make its collection fail.
    /// @param tokenId The v4 position.
    /// @param hooks Its pool's hook.
    /// @param hookrPool Whether its pool uses the pinned root.
    /// @param hookCanBlockCollection Whether hook permissions can block collection.
    event PositionReported(uint256 indexed tokenId, address hooks, bool hookrPool, bool hookCanBlockCollection);
    /// @notice `token`'s market opened: pool `poolId` of family `familyId`, holding `seed` revenue tokens; `bridge`
    ///      drips `bridgeBps` of each sync's ETH to its LPs, or is zero.
    /// @param token The revenue token.
    /// @param familyId Its market family.
    /// @param poolId Its market pool.
    /// @param seed The revenue tokens seeded.
    /// @param bridge The Fee Bridge, or zero.
    /// @param bridgeBps The share of pulled ETH dripped to LPs, in basis points.
    event MarketOpened(
        address indexed token,
        bytes32 indexed familyId,
        PoolId indexed poolId,
        uint256 seed,
        address bridge,
        uint16 bridgeBps
    );

    /// @notice The HookrLauncher families launch on.
    /// @return The pinned launcher.
    function launcher() external view returns (address);
    /// @notice The HookrFamilyLock the families are locked in.
    /// @return The pinned family lock.
    function lock() external view returns (address);
    /// @notice The Hookr root every market opens on and the leg rule reads.
    /// @return The pinned root.
    function root() external view returns (address);
    /// @notice The registry whose RULES admissions on `root` decide which Rules are admitted here: the launcher's.
    /// @return The launcher's registry.
    function registry() external view returns (address);
    /// @notice The HookrTreasury whose target the leg collector pays.
    /// @return The pinned treasury.
    function treasury() external view returns (address);
    /// @notice The HookrLegCollector every token's leg goes to.
    /// @return The token leg collector.
    function collector() external view returns (address);
    /// @notice The Fee Bridge factory, or zero for no bridges.
    /// @return The bridge factory, or zero.
    function bridgeFactory() external view returns (address);
    /// @notice The Uniswap v4 PoolManager.
    /// @return The v4 PoolManager.
    function poolManager() external view returns (address);
    /// @notice The Uniswap v4 PositionManager.
    /// @return The v4 position manager.
    function positionManager() external view returns (address);
    /// @notice The Uniswap v3 NonfungiblePositionManager.
    /// @return The v3 position manager.
    function positionManagerV3() external view returns (address);
    /// @notice The v4 position door factory; the caller approves it on the PositionManager.
    /// @return The v4 position door factory.
    function positionDoorFactory() external view returns (address);
    /// @notice The v3 position door factory; the caller approves it on the v3 manager.
    /// @return The v3 position door factory.
    function v3PositionDoorFactory() external view returns (address);
    /// @notice The FEEB adapter factory; the caller approves it on the pools.trade vault.
    /// @return The FEEB adapter factory.
    function feebAdapterFactory() external view returns (address);
    /// @notice The revenue token door factory; it creates the door, and the tokenizer moves the caller's inner
    ///      shares into it (the caller approves the tokenizer on the inner token).
    /// @return The revenue token door factory.
    function revenueTokenDoorFactory() external view returns (address);
    /// @notice The two code stores holding every revenue token's creation code.
    /// @return code0 The first creation-code chunk.
    /// @return code1 The second creation-code chunk.
    function tokenCode() external view returns (address code0, address code1);

    /// @notice Whether `rules` is admitted now: the registry holds a live RULES admission of it on `root`, its code
    ///      and configuration schema are the admitted ones, and it trusts `root`.
    /// @param rules The Rules implementation to check.
    /// @return Whether it has a valid live admission.
    function isAdmittedRules(address rules) external view returns (bool);
    /// @notice Whether `vault` is an admitted pools.trade vault.
    /// @param vault The pools.trade vault to check.
    /// @return Whether the vault is admitted.
    function isAdmittedVault(address vault) external view returns (bool);
    /// @notice Every admitted pools.trade vault.
    /// @return The admitted pools.trade vaults.
    function admittedVaults() external view returns (address[] memory);
    /// @notice Hookr's leg of a door whose stream does not pay Hookr through our hook: 500 basis points.
    /// @return The outside-source leg in basis points.
    function HOOKR_LEG_BPS_OUTSIDE() external view returns (uint16);
    /// @notice Hookr's leg of a door whose stream already pays Hookr through our hook: 0.
    /// @return The first-party leg in basis points.
    function HOOKR_LEG_BPS_HOOKR() external view returns (uint16);
    /// @notice The shortest family term, in parent blocks: 50,400 (seven days of 12-second blocks).
    /// @return The minimum family term in parent blocks.
    function MIN_TERM_BLOCKS() external view returns (uint64);
    /// @notice The shortest door term, in seconds: seven days.
    /// @return The minimum door term in seconds.
    function MIN_TERM_SECONDS() external view returns (uint64);
    /// @notice Most position NFTs one door takes: 64.
    /// @return The maximum position count per door.
    function MAX_POSITIONS() external view returns (uint256);
    /// @notice The `member` an `AdvisoryPayeeUnchecked` carries for the market: type(uint256).max.
    /// @return The market member sentinel.
    function MARKET_MEMBER() external view returns (uint256);

    /// @notice What was created for `token`; zero fields for a token this tokenizer did not make.
    /// @param token The revenue token to read.
    /// @return Its tokenization record, or an empty record.
    function tokenizations(address token) external view returns (Tokenization memory);
    /// @notice How many revenue tokens this tokenizer has made.
    /// @return The number of revenue tokens created.
    function tokenCount() external view returns (uint256);
    /// @notice The `i`-th revenue token made.
    /// @param i The zero-based token index.
    /// @return The revenue token at that index.
    function tokenAt(uint256 i) external view returns (address);
    /// @notice Up to `count` revenue tokens from `start`.
    /// @param start The first token index.
    /// @param count The maximum tokens to return.
    /// @return The requested token page.
    function tokens(uint256 start, uint256 count) external view returns (address[] memory);
    /// @notice How many streams `token` has.
    /// @param token The revenue token.
    /// @return The number of recorded streams.
    function streamCount(address token) external view returns (uint256);
    /// @notice Stream `i` of `token`, its end read live.
    /// @param token The revenue token.
    /// @param i The zero-based stream index.
    /// @return The stream with its current end.
    function streamAt(address token, uint256 i) external view returns (StreamRecord memory);
    /// @notice Up to `count` streams of `token` from `start`, their ends read live.
    /// @param token The revenue token.
    /// @param start The first stream index.
    /// @param count The maximum streams to return.
    /// @return The requested stream page.
    function streams(address token, uint256 start, uint256 count) external view returns (StreamRecord[] memory);

    /// @notice The revenue token `tokenize` called by `creator` with `t` creates: CREATE2 with salt
    ///      `keccak256(abi.encode(creator, t.termsHash))`, so a front end sets `royaltyTo` to it wherever
    ///      `royaltyBps` is nonzero and makes every source for that address first.
    /// @param creator The account that will call tokenize.
    /// @param t The token terms used for its address.
    /// @return The predicted revenue token.
    function predictToken(address creator, TokenTerms calldata t) external view returns (address);

    /// @notice Mints a revenue token from `s`: checks the terms, deploys the token, locks every stream and adds its
    ///      door, opens the market when `m.open`, mints the supply (the market seed included) and returns whatever
    ///      is left to the caller. `msg.value` is the launch's budgets and fee when there is a launch, plus the
    ///      launch fee when a market opens.
    /// @param t The token and distribution terms.
    /// @param s The streams and their locked terms.
    /// @param m The optional market terms.
    /// @return token The newly created revenue token.
    function tokenize(TokenTerms calldata t, StreamParams calldata s, MarketTerms calldata m)
        external
        payable
        returns (address token);

    /// @notice Adds the streams in `s` to `token`, a revenue token this tokenizer made: the stream manager may add
    ///      any of them and list new currencies; anyone may add the tokenizer's own door kinds when the token is
    ///      open. Each right is locked before its door is added. `msg.value` is a launch's budgets and fee, when
    ///      there is one.
    /// @param token The revenue token receiving the streams.
    /// @param s The streams and their locked terms.
    /// @return first The index of the first stream added.
    function addStreams(address token, StreamParams calldata s) external payable returns (uint256 first);

    /// @notice A market for `token` (predicted by `predictToken`, or live) on `rules` against `quote` (native ETH
    ///      or an ERC-20), as the live tokenizer fills it in; reverts `RulesNotAdmitted` unless `rules` is
    ///      admitted. The sorted pair decides the seed's side: with the token as currency1 the range lies at or
    ///      below the start price's tick, as currency0 strictly above it, so the seed is all revenue token for any
    ///      quote. Otherwise a pure function of its inputs; the caller may change any field.
    /// @param rules The admitted Rules for the market.
    /// @param token The revenue token, predicted or live.
    /// @param quote The other currency, native ETH or an ERC-20.
    /// @param sqrtPriceX96 The initial sqrt price of the sorted pair in Q64.96.
    /// @param seed The revenue token amount seeded.
    /// @return Default market terms for these inputs.
    function defaultMarket(address rules, address token, Currency quote, uint160 sqrtPriceX96, uint256 seed)
        external
        view
        returns (MarketTerms memory);

    /// @notice Per v4 position: whether its pool is on the root (no leg), whether its hook could block the door's
    ///      collection, and whether its pool holds `token` (predicted by `predictToken`, or live), and the
    ///      currencies the positions bring.
    /// @dev A position on a pool of the revenue token itself (its market, or any pool pairing it) is taken: its
    ///      door sends the fees on the token's side to 0xdead, since the token refuses its own shares and 0xdead
    ///      earns nothing, so only the other side reaches the holders. `holdsToken` lets the app say so before the
    ///      add.
    /// @param token The revenue token, predicted or live.
    /// @param tokenIds The v4 position NFTs to inspect.
    /// @return hookrPool Whether each position is on the pinned root.
    /// @return hookCanBlockCollection Whether each hook can block collection.
    /// @return holdsToken Whether each pool contains the revenue token.
    /// @return currencies The unique currencies in the inspected positions.
    function previewPositions(address token, uint256[] calldata tokenIds)
        external
        view
        returns (
            bool[] memory hookrPool,
            bool[] memory hookCanBlockCollection,
            bool[] memory holdsToken,
            Currency[] memory currencies
        );
}
