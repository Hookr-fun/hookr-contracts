// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrLaunchFee} from "hookr/interfaces/IHookrLaunchFee.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {IHookrRevenueTokenizer} from "./interfaces/IHookrRevenueTokenizer.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";
import {IHookrFamilyForwarder} from "./interfaces/IHookrFamilyForwarder.sol";
import {IHookrRulesDoor} from "./interfaces/IHookrRulesDoor.sol";
import {IPositionManagerDoor} from "./interfaces/IPositionManagerDoor.sol";
import {IBeneficiaryVault} from "./interfaces/external/IBeneficiaryVault.sol";
import {HookrRevenueTokenDeployer} from "./libraries/HookrRevenueTokenDeployer.sol";
import {HookrRevenueDoorDeployer} from "./libraries/HookrRevenueDoorDeployer.sol";
import {HookrRevenueMarketOpener} from "./libraries/HookrRevenueMarketOpener.sol";
import {HookrRevenueStreams} from "./libraries/HookrRevenueStreams.sol";
import {HookrV3DoorFactoryDeployer} from "./libraries/HookrV3DoorFactoryDeployer.sol";
import {HookrLegCollector} from "./HookrLegCollector.sol";
import {HookrPositionNftDoorFactory} from "./HookrPositionNftDoorFactory.sol";

/// @title Hookr Multi-stream Revenue Tokenizer (HookRevenue Tokenizer)
/// @notice Lock-to-mint in one transaction: locks a fee right and mints a fixed-supply revenue token whose holders share
///         everything the right earns. Four ways in (a new Hookr launch, an existing pools.trade token's Fee
///         Beneficiary NFT, a new Hookr pool for a token the caller does not own, a bundle of Uniswap v4 position NFTs
///         locked in a door) and the revenue token's own market opened at mint in the same call, its family locked to the
///         same forwarder.
/// @dev Ownerless. Every live dependency is pinned at construction. Hookr's leg of a supply, when there is one, is
///      minted to one HookrLegCollector this constructor deploys: nothing when the tokenized stream already pays Hookr
///      through our hook (a Hookr launch, a new Hookr pool, position NFTs that all sit on the root: Hook Block fees and
///      arb recapture), 5% of the shares when it does not (a pools.trade Fee Beneficiary NFT, a position off the
///      root, a v3 position, any source). The leg's basis points are constants, fixed per way at tokenize time and
///      recorded with the token; nothing can change them. The position-NFT
///      door factory is deployed here too, pinned to this tokenizer, so a door the tokenizer creates pulls the NFTs from
///      the creator and returns them to the creator. The tokenizer holds nothing between calls: budgets it pulls go to
///      the launcher, refunds and dev-bought subject go back to the caller before the call returns, and the call
///      reverts if any native balance is left. Five external libraries, linked at deploy as the release's own are,
///      hold what would not fit here: HookrRevenueTokenDeployer (the revenue token's creation code), HookrRevenueDoorDeployer
///      (the forwarder's and the adapter's), HookrRevenueMarketOpener (the market launch and the bridge),
///      HookrRevenueStreams (the whole of way 5, `tokenizeStreams`, which this contract only dispatches to with its
///      calldata as it arrived) and HookrV3DoorFactoryDeployer (the v3 door factory's creation code, deployed from
///      the constructor). By delegatecall every one of them acts as this tokenizer.
///
///      Hook Blocks: every block the registry admits binds on a tokenized launch exactly as on a normal one, on a
///      family member and on the market alike. Tax + Conversion's creator payout is pinned to the revenue token
///      (`AdvisoryRecipientMismatch` otherwise); any other block admitted to take quote pays its own payee, which the
///      tokenizer cannot read, so it emits `AdvisoryPayeeUnchecked` and the app shows where that cut goes.
///
///      Order of a launch: the revenue token's address is predicted (CREATE2 through HookrRevenueTokenDeployer), the family
///      launches with that address as every pool's `royaltyTo`, then the token is deployed (its assets, the launch's
///      subject among them, now all have code), the forwarder is deployed, the family is handed to the lock for the
///      forwarder, the token is sealed (doors, mint, bridge) and the market opens. The seal and the lock are in the
///      same transaction, so no share exists before its income is locked behind it.
contract HookrRevenueTokenizer is IHookrRevenueTokenizer {
    /// @inheritdoc IHookrRevenueTokenizer
    uint16 public constant HOOKR_LEG_BPS_OUTSIDE = 500;
    /// @inheritdoc IHookrRevenueTokenizer
    uint16 public constant HOOKR_LEG_BPS_HOOKR = 0;
    /// @dev The revenue token's own bounds (HookrIncomeLedger, HookrIncomeSync), checked here before the token exists;
    ///      the token answers the same figures, and test/HookrRevenueTokenizer.bounds.t.sol holds the two together.
    uint256 internal constant MAX_ASSETS = 4;
    uint16 internal constant MAX_BRIDGE_BPS = 2_000;
    uint16 internal constant MAX_TIP_BPS = 100;
    uint32 internal constant DEFAULT_STREAM_SECONDS = 7 days;
    uint32 internal constant MIN_STREAM_SECONDS = 1 days;
    uint32 internal constant MAX_STREAM_SECONDS = 14 days;
    /// @dev Most members a launcher family has.
    uint256 internal constant MAX_MEMBERS = 8;
    /// @dev Gas stipend of a RULES door: one `claim(currency)` on a HookrRules.
    uint32 internal constant RULES_DOOR_GAS = 250_000;
    /// @dev Gas stipend of a FORWARDER door before its members.
    uint32 internal constant FORWARDER_DOOR_BASE_GAS = 200_000;
    /// @dev Gas a FORWARDER door gets per family member it pulls.
    uint32 internal constant FORWARDER_DOOR_MEMBER_GAS = 400_000;
    /// @dev Gas stipend of a FEEB door: one `claim` on a pools.trade vault and the forward.
    uint32 internal constant FEEB_DOOR_GAS = 300_000;
    /// @dev Gas stipend of a POSITIONS door before its positions: the door's floor before a collection
    ///      (HookrPositionNftDoor.COLLECT_GAS_FLOOR, 1,643,809), every asset's forward at its cap (MAX_ASSETS x
    ///      HookrPositionNftDoor.FORWARD_GAS, 1,200,000) and the door's own work, so one collection that burns its whole
    ///      cap still leaves every forward its full gas.
    uint32 internal constant POSITIONS_DOOR_BASE_GAS = 2_900_000;
    /// @dev Gas a POSITIONS door gets per position it collects (a live Hookr collection runs about 25,000 to 131,000).
    uint32 internal constant POSITIONS_DOOR_POSITION_GAS = 160_000;
    /// @inheritdoc IHookrRevenueTokenizer
    uint256 public constant MAX_POSITIONS = 64;
    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Seven days of 12-second parent blocks; a missed parent slot only makes the real term longer.
    uint64 public constant MIN_TERM_BLOCKS = 50_400;
    /// @inheritdoc IHookrRevenueTokenizer
    uint64 public constant MIN_TERM_SECONDS = 7 days;
    uint64 internal constant FOREVER = type(uint64).max;
    /// @inheritdoc IHookrRevenueTokenizer
    uint8 public constant WAY_NEW_LAUNCH = 1;
    /// @inheritdoc IHookrRevenueTokenizer
    uint8 public constant WAY_FEEB = 2;
    /// @inheritdoc IHookrRevenueTokenizer
    uint8 public constant WAY_EXISTING_POOL = 3;
    /// @inheritdoc IHookrRevenueTokenizer
    uint8 public constant WAY_POSITIONS = 4;
    /// @inheritdoc IHookrRevenueTokenizer
    uint8 public constant WAY_STREAMS = 5;
    /// @inheritdoc IHookrRevenueTokenizer
    uint256 public constant MARKET_MEMBER = type(uint256).max;
    Currency internal constant NATIVE = Currency.wrap(address(0));

    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable launcher;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable lock;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable root;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable treasury;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable collector;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable bridgeFactory;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable poolManager;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable positionManager;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable doorFactory;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable positionManagerV3;
    /// @inheritdoc IHookrRevenueTokenizer
    address public immutable v3DoorFactory;

    mapping(address rules => bool) internal _admittedRules;
    mapping(address vault => bool) internal _admittedVaults;
    address[] internal _rulesList;
    address[] internal _vaultList;
    mapping(address token => Tokenization) internal _tokenizations;
    /// @dev Every revenue token created, in order: one push per tokenization, so an app lists them without a log scan.
    address[] internal _tokens;
    bool private transient _busy;

    /// @dev One tokenization's working state, shared by the entry points and their helpers.
    struct Build {
        address creator;
        uint8 way;
        address subject;
        uint256 subjectOut;
        address token;
        address forwarder;
        address adapter;
        address door;
        bytes32 familyId;
        bytes32 marketFamilyId;
        uint64 unlockBlock;
        uint32 streamSeconds;
        uint16 legBps;
        uint256 leg;
        uint256 seed;
        uint256 fee;
        address bridge;
        uint16 bridgeBps;
        Currency[] currencies;
    }

    modifier nonReentrant() {
        if (_busy) revert Reentered();
        _busy = true;
        _;
        _busy = false;
    }

    /// @param launcher_ The HookrLauncher families launch on.
    /// @param lock_ The HookrFamilyLock; its launcher must be `launcher_`.
    /// @param root_ The Hookr root every market opens on; every admitted Rules must trust it.
    /// @param rules_ The admitted Rules a member may bind: the live HookrRules and the whole-pot Rules.
    /// @param treasury_ The HookrTreasury the leg collector pays.
    /// @param vaults_ The admitted pools.trade vaults.
    /// @param bridgeFactory_ The Fee Bridge v2 factory, or zero to allow no bridge.
    /// @param positionManager_ The Uniswap v4 PositionManager whose NFTs a door locks; the door factory is deployed
    ///        here for it, pinned to this tokenizer.
    /// @param positionManagerV3_ The Uniswap v3 NonfungiblePositionManager whose NFTs a v3 door locks; the v3 door
    ///        factory is deployed here for it through HookrV3DoorFactoryDeployer, pinned to this tokenizer.
    constructor(
        address launcher_,
        address lock_,
        address root_,
        address[] memory rules_,
        address treasury_,
        address[] memory vaults_,
        address bridgeFactory_,
        address positionManager_,
        address positionManagerV3_
    ) {
        if (
            launcher_.code.length == 0 || lock_.code.length == 0 || root_.code.length == 0 || treasury_.code.length == 0
                || IHookrFamilyLock(lock_).launcher() != launcher_ || rules_.length == 0
                || (bridgeFactory_ != address(0) && bridgeFactory_.code.length == 0)
                || positionManager_.code.length == 0 || positionManagerV3_.code.length == 0
        ) revert InvalidConfig();
        launcher = launcher_;
        lock = lock_;
        root = root_;
        treasury = treasury_;
        bridgeFactory = bridgeFactory_;
        positionManager = positionManager_;
        positionManagerV3 = positionManagerV3_;
        IPoolManager manager = IHookrLauncher(launcher_).poolManager();
        if (address(manager).code.length == 0) revert InvalidConfig();
        poolManager = address(manager);
        for (uint256 i; i < rules_.length; ++i) {
            address r = rules_[i];
            if (r.code.length == 0 || IHookrRulesDoor(r).trustedRoot() != root_ || _admittedRules[r]) {
                revert RulesNotAdmitted(r);
            }
            _admittedRules[r] = true;
            _rulesList.push(r);
        }
        for (uint256 i; i < vaults_.length; ++i) {
            address v = vaults_[i];
            if (v.code.length == 0 || _admittedVaults[v]) revert VaultNotAdmitted(v);
            _admittedVaults[v] = true;
            _vaultList.push(v);
        }
        collector = address(new HookrLegCollector(treasury_));
        doorFactory =
            address(new HookrPositionNftDoorFactory(IPositionManagerDoor(positionManager_), root_, address(this)));
        v3DoorFactory = HookrV3DoorFactoryDeployer.deploy(positionManagerV3_);
    }

    /// @notice Takes the launcher's native refunds and the lock's acceptance payout inside a tokenization, and nothing
    ///         else: ETH sent between calls is refused, so the next creator never inherits a stranger's ETH with its
    ///         refunds. Nothing stays here.
    receive() external payable {
        if (!_busy) revert InvalidFunding();
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function isAdmittedRules(address rules) external view returns (bool) {
        return _admittedRules[rules];
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function isAdmittedVault(address vault) external view returns (bool) {
        return _admittedVaults[vault];
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function admittedRules() external view returns (address[] memory) {
        return _rulesList;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function admittedVaults() external view returns (address[] memory) {
        return _vaultList;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokenizations(address token) external view returns (Tokenization memory) {
        return _tokenizations[token];
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokenAt(uint256 i) external view returns (address) {
        return _tokens[i];
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev A static call to the linked HookrRevenueMarketOpener (`defaultTerms` is pure, so the library takes it
    ///      directly), whose return data is this function's own: the terms are encoded once, by the library, and the
    ///      decoder and re-encoder of a struct of three structs stay out of this contract's runtime. A revert is
    ///      bubbled as is.
    function defaultMarket(uint160 sqrtPriceX96, uint256 seed) external view returns (MarketTerms memory) {
        _static(
            address(HookrRevenueMarketOpener),
            abi.encodeWithSelector(HookrRevenueMarketOpener.defaultTerms.selector, _rulesList[0], sqrtPriceX96, seed)
        );
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Computed by the linked HookrRevenueStreams (`predict`), given this call's calldata as it arrived.
    function predictStreamToken(address, TokenTerms calldata) external view returns (address) {
        _static(address(HookrRevenueStreams), _forwarded(HookrRevenueStreams.predict.selector));
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Computed by the linked HookrRevenueStreams (`streamsOf`) from the token's doors, given this call's
    ///      calldata as it arrived; its return data is this function's own.
    function streamsOf(address) external view returns (StreamRecord[] memory) {
        _static(address(HookrRevenueStreams), _forwarded(HookrRevenueStreams.streamsOf.selector));
    }

    // ------------------------------------------------------------------ way 5

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev The whole way runs in the linked HookrRevenueStreams: `tokenize`, by delegatecall with this call's
    ///      calldata as it arrived, so this contract decodes nothing of the stream terms, then `record`, which
    ///      writes what `tokenize` returned into this contract's record and token list (the library takes the two
    ///      as storage references) and emits `Tokenized`, as `_finish` does for the other ways. A revert is bubbled
    ///      as is.
    function tokenizeStreams(StreamParams calldata, TokenTerms calldata, LockTerms calldata, MarketTerms calldata)
        external
        payable
        nonReentrant
        returns (address token)
    {
        (bool ok, bytes memory ret) =
            address(HookrRevenueStreams).delegatecall(_forwarded(HookrRevenueStreams.tokenize.selector));
        if (!ok) _bubble(ret);
        token = HookrRevenueStreams.record(_tokenizations, _tokens, ret);
    }

    /// @dev This call's calldata with its selector swapped for `selector`: what a library entry with the same
    ///      parameters, in the same order, decodes as the caller's own arguments.
    function _forwarded(bytes4 selector) private pure returns (bytes memory) {
        return abi.encodePacked(selector, msg.data[4:]);
    }

    /// @dev Reverts with `ret` as is.
    function _bubble(bytes memory ret) private pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /// @notice The revenue token `launchAndTokenize(p, t, ...)` called by `creator` would create: what every member's
    ///         `royaltyTo` must name (with a nonzero royalty). A pure function of the creator, the terms and the
    ///         launch's currencies, so a front end fills it in before the call.
    function predictRevenueToken(address creator, IHookrLauncher.LaunchParams calldata p, TokenTerms calldata t)
        external
        view
        returns (address)
    {
        address subject = p.token.existing == address(0)
            ? IHookrLauncher(launcher).predictToken(address(this), p.token)
            : p.token.existing;
        Build memory b;
        b.streamSeconds = t.streamSeconds == 0 ? DEFAULT_STREAM_SECONDS : t.streamSeconds;
        return HookrRevenueTokenDeployer.predict(
            _tokenArgs(t, _familyAssets(p, subject, t.extraAssets), b), _salt(creator, t.termsHash), poolManager
        );
    }

    // ------------------------------------------------------------------ ways 1 and 3

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev `msg.value` must be exactly every native budget (the native member's maximum plus its dev buy) plus the
    ///      launch fee, plus the launch fee again when a market opens, as the launcher itself demands exactness.
    function launchAndTokenize(
        IHookrLauncher.LaunchParams calldata p,
        TokenTerms calldata t,
        LockTerms calldata l,
        MarketTerms calldata m
    ) external payable nonReentrant returns (address, address, bytes32, bytes32, address, uint256) {
        // The pools are on our hook, so Hookr is paid by the stream itself: no leg.
        Build memory b = _begin(t, l.unlockBlock, m, true, HOOKR_LEG_BPS_HOOKR);
        uint256 n = p.members.length;
        if (n == 0 || n > MAX_MEMBERS || p.advisoryConfigs.length != n) revert InvalidTerms();
        bool isNew = p.token.existing == address(0);
        b.way = isNew ? WAY_NEW_LAUNCH : WAY_EXISTING_POOL;
        address subject = isNew ? IHookrLauncher(launcher).predictToken(address(this), p.token) : p.token.existing;
        HookrRevenueTokenDeployer.TokenArgs memory a = _tokenArgs(t, _familyAssets(p, subject, t.extraAssets), b);
        bytes32 salt = _salt(msg.sender, t.termsHash);
        b.token = HookrRevenueTokenDeployer.predict(a, salt, poolManager);

        // Every member binds admitted Rules with its royalty pointed at the token's future address (the caller
        // pre-fills `royaltyTo` from `predictRevenueToken`), or no royalty at all; a member's Hook Block binds as on any
        // launch, with Tax + Conversion's creator payout pinned to the token and any other quote-taking block
        // reported (HookrRevenueDoorDeployer.checkAdvisory). Then the funding and the launch.
        address[] memory rulesList = new address[](n + 1);
        for (uint256 i; i < n; ++i) {
            IHookrLauncher.Member calldata member = p.members[i];
            if (!_admittedRules[member.config.rules]) revert RulesNotAdmitted(member.config.rules);
            if (member.rules.royaltyTo != (member.rules.royaltyBps != 0 ? b.token : address(0))) revert InvalidTerms();
            if (member.config.advisory != address(0)) {
                HookrRevenueDoorDeployer.checkAdvisory(
                    launcher, root, member.config.advisory, p.advisoryConfigs[i], b.token, i
                );
            }
            rulesList[i] = member.config.rules;
        }
        (b.familyId, b.subject, b.subjectOut, b.currencies) =
            HookrRevenueMarketOpener.launch(launcher, _launchParams(), subject, b.token, b.fee, m.open);
        if (b.subject != subject) revert InvalidConfig();

        // The token (its assets all have code now), the forwarder, the lock.
        if (HookrRevenueTokenDeployer.deploy(a, salt, poolManager) != b.token) revert InvalidConfig();
        b.forwarder = HookrRevenueDoorDeployer.deployForwarder(b.token, lock);
        _lockFamily(b, b.familyId);

        // Doors: one RULES door per distinct member Rules (and the market's), then the forwarder.
        if (m.open) rulesList[n] = m.config.rules;
        _seal(b, t, m, _doors(rulesList, m.open ? n + 1 : n, b.forwarder, m.open ? n + 1 : n, _noDoor()));
        if (m.open) _openMarket(b, m);
        _finish(b, t.supply);
        return (b.token, b.forwarder, b.familyId, b.marketFamilyId, b.subject, b.subjectOut);
    }

    // ------------------------------------------------------------------ way 2

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev `msg.value` is the launch fee when a market opens, nothing otherwise.
    function tokenizeFeeb(
        address vault,
        uint256 tokenId,
        TokenTerms calldata t,
        LockTerms calldata l,
        MarketTerms calldata m
    ) external payable nonReentrant returns (address, address, address, bytes32) {
        if (!_admittedVaults[vault]) revert VaultNotAdmitted(vault);
        // A pools.trade right pays Hookr nothing on its own: the outside leg.
        Build memory b = _begin(t, l.unlockBlock, m, false, HOOKR_LEG_BPS_OUTSIDE);
        b.way = WAY_FEEB;
        if (msg.value != (m.open ? b.fee : 0)) revert InvalidFunding();
        HookrRevenueTokenDeployer.TokenArgs memory a = _tokenArgs(t, _feebAssets(t.extraAssets), b);
        b.token = HookrRevenueTokenDeployer.deploy(a, _salt(msg.sender, t.termsHash), poolManager);

        // The adapter takes the NFT for good; the holder approved this tokenizer.
        b.adapter = HookrRevenueDoorDeployer.deployAdapter(b.token, vault, tokenId);
        IBeneficiaryVault(vault).transferFrom(msg.sender, b.adapter, tokenId);
        address owner = IBeneficiaryVault(vault).ownerOf(tokenId);
        if (owner != b.adapter) revert NotNftOwner(vault, tokenId, owner);
        _finishSingleDoor(b, t, m, IHookrRevenueToken.Door(IHookrRevenueToken.DoorKind.FEEB, b.adapter, FEEB_DOOR_GAS));
        return (b.token, b.adapter, b.forwarder, b.marketFamilyId);
    }

    // ------------------------------------------------------------------ way 4

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev `msg.value` is the launch fee when a market opens, nothing otherwise. The door's own term is `p.unlockAt`
    ///      (seconds; type(uint64).max for good) and is held to `MIN_TERM_SECONDS` here as the other ways hold their
    ///      unlock block to `MIN_TERM_BLOCKS`; `l.unlockBlock` locks the market's family when one opens, under the
    ///      block rule. The token is deployed before the door, so the door is born naming the real token; then the
    ///      factory, pinned to this tokenizer, pulls every NFT from the creator (who approved the factory before, or
    ///      signed the permits applied first), records the creator as each one's depositor and activates the door,
    ///      and the door is checked to be the factory's, the token's and active before it is sealed in as a source.
    function tokenizePositions(
        PositionTerms calldata p,
        TokenTerms calldata t,
        LockTerms calldata l,
        MarketTerms calldata m
    ) external payable nonReentrant returns (address, address, address, bytes32) {
        _checkTerm(p.unlockAt, uint64(block.timestamp) + MIN_TERM_SECONDS);
        (bool allHookr, Currency[] memory assets) = HookrRevenueDoorDeployer.reportPositions(
            positionManager, root, p.tokenIds, t.extraAssets, MAX_POSITIONS, MAX_ASSETS
        );
        Build memory b = _begin(t, l.unlockBlock, m, false, allHookr ? HOOKR_LEG_BPS_HOOKR : HOOKR_LEG_BPS_OUTSIDE);
        b.way = WAY_POSITIONS;
        if (msg.value != (m.open ? b.fee : 0)) revert InvalidFunding();
        b.token =
            HookrRevenueTokenDeployer.deploy(_tokenArgs(t, assets, b), _salt(msg.sender, t.termsHash), poolManager);
        b.door = HookrRevenueDoorDeployer.createDoor(doorFactory, positionManager, b.token, p, t.termsHash);
        _finishSingleDoor(
            b,
            t,
            m,
            IHookrRevenueToken.Door(
                IHookrRevenueToken.DoorKind.POSITIONS,
                b.door,
                POSITIONS_DOOR_BASE_GAS + POSITIONS_DOOR_POSITION_GAS * uint32(p.tokenIds.length)
            )
        );
        return (b.token, b.door, b.forwarder, b.marketFamilyId);
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Computed by the linked HookrRevenueDoorDeployer (`previewPositions`, a view the library takes directly,
    ///      given this call's calldata as it arrived; it reads this tokenizer's pins as `msg.sender`) and its return
    ///      data returned as is, as `defaultMarket` does: the encoders stay out of this runtime.
    function previewPositions(uint256[] calldata, Currency[] calldata)
        external
        view
        returns (uint16, Currency[] memory, bool[] memory, bool[] memory)
    {
        _static(address(HookrRevenueDoorDeployer), _forwarded(HookrRevenueDoorDeployer.previewPositions.selector));
    }

    /// @dev A static call of `data` on the linked library `lib` whose return data becomes this call's own: the
    ///      encoders and decoders of what the libraries answer stay out of this runtime. A revert is bubbled as is.
    ///      Never returns to its caller.
    function _static(address lib, bytes memory data) private view {
        (bool ok, bytes memory ret) = lib.staticcall(data);
        if (!ok) _bubble(ret);
        assembly ("memory-safe") {
            return(add(ret, 0x20), mload(ret))
        }
    }

    /// @dev The tail ways (2) and (4) share: a forwarder and the market's Rules door when a market opens, the seal with
    ///      `first` (the adapter or the door) ahead of them, the market, and the finish with leftover ETH and unspent
    ///      seed returned to the creator.
    function _finishSingleDoor(
        Build memory b,
        TokenTerms calldata t,
        MarketTerms calldata m,
        IHookrRevenueToken.Door memory first
    ) private {
        address[] memory rulesList = new address[](1);
        if (m.open) {
            b.forwarder = HookrRevenueDoorDeployer.deployForwarder(b.token, lock);
            rulesList[0] = m.config.rules;
        }
        _seal(b, t, m, _doors(rulesList, m.open ? 1 : 0, b.forwarder, 1, first));
        if (m.open) _openMarket(b, m);
        b.currencies = _ownCurrencies(b.token);
        _finish(b, t.supply);
    }

    // ------------------------------------------------------------------ checks

    /// @dev The checks every way shares, and the figures they fix: the Hookr leg (`legBps` of the supply, rounded
    ///      down; nothing is minted to the collector when that is zero), the market seed, the release period, the
    ///      unlock block (forever, or at least `MIN_TERM_BLOCKS` from now) and the launch fee read live. `needLock` is
    ///      false for a right whose lock only matters with a market (a FEEB right, a position-NFT door): with no market
    ///      no family is locked, and the record's unlock block is zero. The creator's recipients must take exactly what
    ///      is left after the leg and the seed: the seed comes out of the creator's side.
    function _begin(TokenTerms calldata t, uint64 unlockBlock, MarketTerms calldata m, bool needLock, uint16 legBps)
        private
        view
        returns (Build memory b)
    {
        uint256 supply = t.supply;
        uint256 leg = supply * legBps / 10_000;
        uint32 stream = t.streamSeconds == 0 ? DEFAULT_STREAM_SECONDS : t.streamSeconds;
        if (
            supply == 0 || supply > type(uint128).max || stream < MIN_STREAM_SECONDS || stream > MAX_STREAM_SECONDS
                || t.tipBps > MAX_TIP_BPS || t.termsHash == bytes32(0)
        ) revert InvalidTerms();
        uint256 n = t.recipients.length;
        if (n == 0 || n != t.amounts.length) revert InvalidTerms();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (t.recipients[i] == address(0) || t.amounts[i] == 0) revert InvalidTerms();
            sum += t.amounts[i];
        }
        uint256 seed;
        if (m.open) {
            _checkMarket(m);
            seed = m.seed;
        }
        uint256 expected = supply > leg + seed ? supply - leg - seed : 0;
        if (expected == 0 || sum != expected) revert MintMismatch(sum, expected);
        bool locksFamily = needLock || m.open;
        if (locksFamily) _checkTerm(unlockBlock, uint64(block.number) + MIN_TERM_BLOCKS);
        b.creator = msg.sender;
        b.legBps = legBps;
        b.leg = leg;
        b.seed = seed;
        b.streamSeconds = stream;
        b.unlockBlock = locksFamily ? unlockBlock : 0;
        (b.fee,,,,) = IHookrLaunchFee(launcher).launchFee();
    }

    /// @dev A term is forever (type(uint64).max) or at least `minimum`, the clock plus the way's floor; anything
    ///      shorter, the current block or second included, is `TermTooShort(given, minimum)`.
    function _checkTerm(uint64 given, uint64 minimum) private pure {
        if (given != FOREVER && given < minimum) revert TermTooShort(given, minimum);
    }

    /// @dev A market's terms the tokenizer decides on: admitted Rules, a seed, and a bridge slice only with a factory
    ///      and within the token's bound. The opener checks the range and the liquidity.
    function _checkMarket(MarketTerms calldata m) private view {
        if (!_admittedRules[m.config.rules]) revert RulesNotAdmitted(m.config.rules);
        if (m.seed == 0) revert InvalidMarket();
        if (m.bridgeBps != 0 && (bridgeFactory == address(0) || m.bridgeBps > MAX_BRIDGE_BPS)) revert InvalidMarket();
    }

    // ------------------------------------------------------------------ assets

    /// @dev Native ETH, every member's quote, the subject and the creator's extras, each once, at most `MAX_ASSETS`.
    function _familyAssets(IHookrLauncher.LaunchParams calldata p, address subject, Currency[] calldata extra)
        private
        pure
        returns (Currency[] memory)
    {
        uint256 n = p.members.length;
        Currency[] memory list = new Currency[](n + 2 + extra.length);
        list[0] = NATIVE;
        uint256 count = 1;
        for (uint256 i; i < n; ++i) {
            count = _addAsset(list, count, p.members[i].quote);
        }
        count = _addAsset(list, count, Currency.wrap(subject));
        for (uint256 i; i < extra.length; ++i) {
            count = _addAsset(list, count, extra[i]);
        }
        return _trim(list, count);
    }

    /// @dev Native ETH and the creator's extras (for a FEEB right: HOOKR, if its side ever pays out).
    function _feebAssets(Currency[] calldata extra) private pure returns (Currency[] memory) {
        Currency[] memory list = new Currency[](1 + extra.length);
        list[0] = NATIVE;
        uint256 count = 1;
        for (uint256 i; i < extra.length; ++i) {
            count = _addAsset(list, count, extra[i]);
        }
        return _trim(list, count);
    }

    function _addAsset(Currency[] memory list, uint256 count, Currency c) private pure returns (uint256) {
        for (uint256 i; i < count; ++i) {
            if (list[i] == c) return count;
        }
        list[count] = c;
        return count + 1;
    }

    function _trim(Currency[] memory list, uint256 count) private pure returns (Currency[] memory assets) {
        if (count > MAX_ASSETS) revert TooManyAssets(count);
        assets = new Currency[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = list[i];
        }
    }

    function _tokenArgs(TokenTerms calldata t, Currency[] memory assets, Build memory b)
        private
        pure
        returns (HookrRevenueTokenDeployer.TokenArgs memory a)
    {
        a.name = t.name;
        a.symbol = t.symbol;
        a.supply = t.supply;
        a.assets = assets;
        a.streamSeconds = b.streamSeconds;
        a.tipBps = t.tipBps;
        a.termsHash = t.termsHash;
    }

    /// @dev A revenue token's CREATE2 salt: the creator and the terms hash, so the token's address is known before the
    ///      call and a creator never reuses a terms hash (the second deploy would collide and revert).
    function _salt(address creator, bytes32 termsHash) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, termsHash));
    }

    // ------------------------------------------------------------------ launch

    /// @dev The bytes `p` arrived in: this call's first argument, so its encoding runs from its head offset to the
    ///      second argument's, and that encoding is what this contract itself decoded and checked. The launch forwards
    ///      it as is (HookrRevenueMarketOpener.launch), which spares this contract the re-encoder of a struct of nested
    ///      arrays, alone far past the runtime size limit. A slice out of bounds reverts here; a slice that is not a
    ///      `LaunchParams` fails to decode there.
    function _launchParams() private pure returns (bytes calldata) {
        uint256 start = 4 + uint256(bytes32(msg.data[4:36]));
        uint256 end = 4 + uint256(bytes32(msg.data[36:68]));
        return msg.data[start:end];
    }

    // ------------------------------------------------------------------ lock, doors, seal, market

    /// @dev Hands family `familyId` to the lock for the forwarder until the unlock block and registers it there,
    ///      returning to the creator. The lock's acceptance pays this tokenizer the fees the family earned so far (a
    ///      dev buy's LP parts); they go back to the creator with the refunds.
    function _lockFamily(Build memory b, bytes32 familyId) private {
        IHookrLauncher(launcher).transferFamily(familyId, lock, 0);
        IHookrFamilyLock(lock).lock(familyId, b.forwarder, b.unlockBlock);
        IHookrFamilyForwarder(b.forwarder).register(familyId, b.creator);
    }

    /// @dev The door list: `first` when its target is set (a FEEB adapter or a position-NFT door, with its kind and
    ///      stipend), one RULES door per distinct address in `rulesList[0..rulesCount)`, a FORWARDER door for `members`
    ///      members when `forwarder` is set.
    function _doors(
        address[] memory rulesList,
        uint256 rulesCount,
        address forwarder,
        uint256 members,
        IHookrRevenueToken.Door memory first
    ) private pure returns (IHookrRevenueToken.Door[] memory doors) {
        address[] memory distinct = new address[](rulesCount);
        uint256 k;
        for (uint256 i; i < rulesCount; ++i) {
            address r = rulesList[i];
            bool seen;
            for (uint256 j; j < k; ++j) {
                if (distinct[j] == r) seen = true;
            }
            if (!seen) distinct[k++] = r;
        }
        uint256 count = k + (forwarder != address(0) ? 1 : 0) + (first.target != address(0) ? 1 : 0);
        doors = new IHookrRevenueToken.Door[](count);
        uint256 d;
        if (first.target != address(0)) doors[d++] = first;
        for (uint256 i; i < k; ++i) {
            doors[d++] = IHookrRevenueToken.Door(IHookrRevenueToken.DoorKind.RULES, distinct[i], RULES_DOOR_GAS);
        }
        if (forwarder != address(0)) {
            doors[d] = IHookrRevenueToken.Door(
                IHookrRevenueToken.DoorKind.FORWARDER,
                forwarder,
                FORWARDER_DOOR_BASE_GAS + FORWARDER_DOOR_MEMBER_GAS * uint32(members)
            );
        }
    }

    /// @dev No first door: the RULES and FORWARDER doors alone.
    function _noDoor() private pure returns (IHookrRevenueToken.Door memory d) {}

    /// @dev What a way without a launched family can hold at the end: leftover ETH and unspent market seed.
    function _ownCurrencies(address token) private pure returns (Currency[] memory cs) {
        cs = new Currency[](2);
        cs[0] = NATIVE;
        cs[1] = Currency.wrap(token);
    }

    /// @dev Makes the bridge when the market asks for one, then seals: the doors, the creator's recipients, the Hookr
    ///      leg to the collector when there is one, and the market seed to this tokenizer, which the market launch
    ///      takes. A zero leg or seed gets no entry: the token refuses a zero-amount mint.
    function _seal(
        Build memory b,
        TokenTerms calldata t,
        MarketTerms calldata m,
        IHookrRevenueToken.Door[] memory doors
    ) private {
        if (m.open && m.bridgeBps != 0) _openBridge(b, m);
        uint256 n = t.recipients.length;
        uint256 extra = (b.leg != 0 ? 1 : 0) + (b.seed != 0 ? 1 : 0);
        address[] memory recipients = new address[](n + extra);
        uint256[] memory amounts = new uint256[](n + extra);
        for (uint256 i; i < n; ++i) {
            recipients[i] = t.recipients[i];
            amounts[i] = t.amounts[i];
        }
        if (b.leg != 0) {
            recipients[n] = collector;
            amounts[n] = b.leg;
            ++n;
        }
        if (b.seed != 0) {
            recipients[n] = address(this);
            amounts[n] = b.seed;
        }
        IHookrRevenueToken(b.token).seal(IHookrRevenueToken.Seal(doors, recipients, amounts, b.bridge, b.bridgeBps));
    }

    /// @dev The market's Fee Bridge v2, made before the seal records it (HookrRevenueMarketOpener.makeBridge).
    function _openBridge(Build memory b, MarketTerms calldata m) private {
        b.bridge = HookrRevenueMarketOpener.makeBridge(launcher, root, bridgeFactory, b.token, m);
        b.bridgeBps = m.bridgeBps;
    }

    /// @dev Opens the revenue token's own market (HookrRevenueMarketOpener.open): the market's Hook Block, when it binds one,
    ///      is held to the rule a launch member's is held to (as `MARKET_MEMBER`, with the empty bind data the market
    ///      launch sends), then the seed this tokenizer holds from the seal and the launch fee go into one ETH-quoted
    ///      pool whose family is locked for the same forwarder, the family is registered on the forwarder returning to
    ///      the creator, and unspent seed comes back here for the creator. The event's `seed` is what the market
    ///      position took: the seed minted less what came back.
    function _openMarket(Build memory b, MarketTerms calldata m) private {
        (bytes32 familyId, PoolId poolId, uint256 placed) = HookrRevenueMarketOpener.open(
            HookrRevenueMarketOpener.Market(launcher, lock, root, b.token, b.forwarder, b.unlockBlock, b.fee), m
        );
        b.marketFamilyId = familyId;
        IHookrFamilyForwarder(b.forwarder).register(familyId, b.creator);
        emit MarketOpened(b.token, familyId, poolId, placed, b.bridge, b.bridgeBps);
    }

    /// @dev Returns everything left here to the creator (the launcher's refunds, dev-bought subject, the fees a lock's
    ///      acceptance paid, unspent seed), requires an empty native balance, records (the record and one push on the
    ///      token list) and emits. Way 5 does the same in HookrRevenueStreams.record.
    function _finish(Build memory b, uint256 supply) private {
        Currency[] memory cs = b.currencies;
        for (uint256 i; i < cs.length; ++i) {
            uint256 held = HookrSettlement.balance(cs[i], address(this));
            if (held != 0) HookrSettlement.send(cs[i], b.creator, held);
        }
        if (address(this).balance != 0) revert InvalidFunding();
        _tokenizations[b.token] = Tokenization(
            b.creator, b.way, b.forwarder, b.adapter, b.door, b.familyId, b.marketFamilyId, b.unlockBlock, b.legBps
        );
        _tokens.push(b.token);
        emit Tokenized(
            b.token,
            b.creator,
            b.way,
            b.forwarder,
            b.adapter,
            b.door,
            b.familyId,
            b.marketFamilyId,
            supply,
            b.unlockBlock,
            b.legBps
        );
    }
}
