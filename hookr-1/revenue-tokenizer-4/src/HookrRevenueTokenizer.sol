// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRevenueTokenizer} from "./interfaces/IHookrRevenueTokenizer.sol";
import {IHookrRevenueTokenizerSourcePins} from "./interfaces/IHookrRevenueTokenizerSourcePins.sol";
import {IHookrPositionNftDoorFactory} from "./interfaces/IHookrPositionNftDoorFactory.sol";
import {IHookrV3PositionNftDoorFactory} from "./interfaces/IHookrV3PositionNftDoorFactory.sol";
import {IHookrFeebAdapterFactory} from "./interfaces/IHookrFeebAdapterFactory.sol";
import {IHookrRevenueTokenDoorFactory} from "./interfaces/IHookrRevenueTokenDoorFactory.sol";
import {HookrLegCollector} from "./HookrLegCollector.sol";
import {HookrRevenueTokenizerStorage} from "./libraries/HookrRevenueTokenizerStorage.sol";
import {HookrRevenueTokenDeployer} from "./libraries/HookrRevenueTokenDeployer.sol";
import {HookrRevenueStreamEnds} from "./libraries/HookrRevenueStreamEnds.sol";
import {HookrRevenueStreams} from "./libraries/HookrRevenueStreams.sol";
import {HookrRevenueMarketOpener} from "./libraries/HookrRevenueMarketOpener.sol";
import {HookrRevenueDoorDeployer} from "./libraries/HookrRevenueDoorDeployer.sol";
import {HookrRevenueRulesAdmission} from "./libraries/HookrRevenueRulesAdmission.sol";

/// @title HookRevenue Tokenizer
/// @notice Locks fee rights and mints a fixed-supply revenue token whose holders share everything the rights earn, then
///         adds more streams to it at any time (IHookrRevenueTokenizer).
/// @dev Ownerless; every live dependency is fixed at construction. Which Rules a launch, a market or a RULES door may
///      use is not: it is whatever the launcher's registry admits on the root as RULES at the moment of the call
///      (HookrRevenueRulesAdmission), the same admission the root checks when it binds the pool, so a new Hookr core is
///      usable here as soon as its admission executes and a revoked one is refused at once. This contract only checks
///      its pins and dispatches:
///      `tokenize` and `addStreams` run in the linked HookrRevenueStreams by delegatecall with this call's calldata as
///      it arrived, so this contract decodes none of the stream terms; the market and the launches run in
///      HookrRevenueMarketOpener, the forwarder's creation and the position scan in HookrRevenueDoorDeployer, both
///      reached from the streams library. By delegatecall each acts as this tokenizer: the token's tokenizer, the
///      launches' owner, the forwarder's registrar and the door factories' one caller. The state every part shares
///      sits at one slot (HookrRevenueTokenizerStorage).
///
///      The revenue token's creation code is larger than a contract's runtime may be, so it lives in two
///      HookrRevenueTokenCode contracts; the tokenizer reads both and creates each token by CREATE2 from its own
///      address. The four door factories are deployed before this contract with its address predicted, each pinned to
///      it: the constructor refuses a factory that names another tokenizer or other pins.
///
///      The tokenizer holds nothing between calls: what a call pulls goes to the launcher or a door, refunds and
///      leftovers go back to the caller before the call returns, and the call reverts if any native balance is left.
contract HookrRevenueTokenizer is IHookrRevenueTokenizer {
    /// @notice The constructor's arguments.
    /// @param launcher The HookrLauncher families launch on.
    /// @param lock The HookrFamilyLock; its launcher must be `launcher`.
    /// @param root The Hookr root every market opens on, registered with the launcher's registry and naming it;
    ///        a Rules is usable while that registry admits it on this root.
    /// @param treasury The HookrTreasury the leg collector pays.
    /// @param vaults The admitted pools.trade vaults.
    /// @param bridgeFactory The Fee Bridge factory, or zero for no bridges.
    /// @param positionManager The Uniswap v4 PositionManager.
    /// @param positionManagerV3 The Uniswap v3 NonfungiblePositionManager.
    /// @param positionDoorFactory The v4 door factory, pinned to this tokenizer, `positionManager` and `root`.
    /// @param v3PositionDoorFactory The v3 door factory, pinned to this tokenizer and `positionManagerV3`.
    /// @param feebAdapterFactory The FEEB adapter factory, pinned to this tokenizer, `positionManager` and
    ///        `feebSplitterCodeHash`.
    /// @param revenueTokenDoorFactory The revenue token door factory, pinned to this tokenizer.
    /// @param ponsAdapterFactory The Pons adapter factory the state view marks sources of, or zero.
    /// @param dopplerAdapterFactory The Doppler (Long) adapter factory the state view marks sources of, or zero.
    /// @param tokenCode0 The HookrRevenueTokenCode holding the first half of the token's creation code.
    /// @param tokenCode1 The HookrRevenueTokenCode holding the second half.
    /// @param feebSplitterCodeHash The runtime code hash of a pools.trade fee splitter, which a FEEB adapter has
    ///        collect the NFT's position before it claims (IHookrFeebAdapter); the FEEB factory must name it.
    struct Config {
        address launcher;
        address lock;
        address root;
        address treasury;
        address[] vaults;
        address bridgeFactory;
        address positionManager;
        address positionManagerV3;
        address positionDoorFactory;
        address v3PositionDoorFactory;
        address feebAdapterFactory;
        address revenueTokenDoorFactory;
        address ponsAdapterFactory;
        address dopplerAdapterFactory;
        address tokenCode0;
        address tokenCode1;
        bytes32 feebSplitterCodeHash;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    uint16 public constant HOOKR_LEG_BPS_OUTSIDE = HookrRevenueStreams.LEG_OUTSIDE;
    /// @inheritdoc IHookrRevenueTokenizer
    uint16 public constant HOOKR_LEG_BPS_HOOKR = HookrRevenueStreams.LEG_HOOKR;
    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Seven days of 12-second parent blocks; a missed parent slot only makes the real term longer.
    uint64 public constant MIN_TERM_BLOCKS = HookrRevenueStreams.MIN_TERM_BLOCKS;
    /// @inheritdoc IHookrRevenueTokenizer
    uint64 public constant MIN_TERM_SECONDS = HookrRevenueStreams.MIN_TERM_SECONDS;
    /// @inheritdoc IHookrRevenueTokenizer
    uint256 public constant MAX_POSITIONS = HookrRevenueDoorDeployer.MAX_POSITIONS;
    /// @inheritdoc IHookrRevenueTokenizer
    uint256 public constant MARKET_MEMBER = HookrRevenueMarketOpener.MARKET_MEMBER;
    bool private transient _busy;

    /// @notice Refuses reentry while a tokenizer action is moving rights or funding.
    modifier nonReentrant() {
        if (_busy) revert Reentered();
        _busy = true;
        _;
        _busy = false;
    }

    /// @param c The pins, the admitted vaults, the factories and the token code.
    constructor(Config memory c) {
        if (
            c.launcher.code.length == 0 || c.lock.code.length == 0 || c.root.code.length == 0
                || c.treasury.code.length == 0 || IHookrFamilyLock(c.lock).launcher() != c.launcher
                || (c.bridgeFactory != address(0) && c.bridgeFactory.code.length == 0)
                || c.positionManager.code.length == 0 || c.positionManagerV3.code.length == 0
                || (c.ponsAdapterFactory != address(0) && c.ponsAdapterFactory.code.length == 0)
                || (c.dopplerAdapterFactory != address(0) && c.dopplerAdapterFactory.code.length == 0)
                || c.tokenCode0.code.length < 2 || c.tokenCode1.code.length < 2
        ) revert InvalidConfig();
        _checkFactories(c);
        HookrRevenueTokenizerStorage.Layout storage l = HookrRevenueTokenizerStorage.getLayout();
        HookrRevenueTokenizerStorage.Pins storage p = l.pins;
        p.launcher = c.launcher;
        p.lock = c.lock;
        p.root = c.root;
        address registry_ = address(IHookrLauncher(c.launcher).registry());
        if (
            registry_.code.length == 0 || !IHookrRegistry(registry_).isRoot(c.root)
                || address(IHookrRoot(c.root).registry()) != registry_
        ) revert InvalidConfig();
        p.registry = registry_;
        p.treasury = c.treasury;
        p.bridgeFactory = c.bridgeFactory;
        p.positionManager = c.positionManager;
        p.positionManagerV3 = c.positionManagerV3;
        p.positionDoorFactory = c.positionDoorFactory;
        p.v3PositionDoorFactory = c.v3PositionDoorFactory;
        p.feebAdapterFactory = c.feebAdapterFactory;
        p.revenueTokenDoorFactory = c.revenueTokenDoorFactory;
        p.ponsAdapterFactory = c.ponsAdapterFactory;
        p.dopplerAdapterFactory = c.dopplerAdapterFactory;
        p.tokenCode0 = c.tokenCode0;
        p.tokenCode1 = c.tokenCode1;
        address manager = address(IHookrLauncher(c.launcher).poolManager());
        if (manager.code.length == 0) revert InvalidConfig();
        p.poolManager = manager;
        for (uint256 i; i < c.vaults.length; ++i) {
            address v = c.vaults[i];
            if (v.code.length == 0 || l.admittedVaults[v]) revert VaultNotAdmitted(v);
            l.admittedVaults[v] = true;
            l.vaultList.push(v);
        }
        p.collector = address(new HookrLegCollector(c.treasury));
    }

    /// @dev Every factory has code and names this tokenizer; the position factories name the same managers (and the
    ///      v4 one the same root) as the tokenizer, and the FEEB factory the same v4 manager and splitter code hash.
    function _checkFactories(Config memory c) private view {
        if (
            c.positionDoorFactory.code.length == 0 || c.v3PositionDoorFactory.code.length == 0
                || c.feebAdapterFactory.code.length == 0 || c.revenueTokenDoorFactory.code.length == 0
        ) revert InvalidConfig();
        IHookrPositionNftDoorFactory v4 = IHookrPositionNftDoorFactory(c.positionDoorFactory);
        IHookrV3PositionNftDoorFactory v3 = IHookrV3PositionNftDoorFactory(c.v3PositionDoorFactory);
        if (
            v4.tokenizer() != address(this) || address(v4.positionManager()) != c.positionManager
                || v4.hookrRoot() != c.root || v3.tokenizer() != address(this)
                || address(v3.positionManager()) != c.positionManagerV3
                || IHookrRevenueTokenDoorFactory(c.revenueTokenDoorFactory).tokenizer() != address(this)
        ) revert InvalidConfig();
        IHookrFeebAdapterFactory feeb = IHookrFeebAdapterFactory(c.feebAdapterFactory);
        if (
            feeb.tokenizer() != address(this) || feeb.positionManager() != c.positionManager
                || feeb.splitterCodeHash() != c.feebSplitterCodeHash
        ) revert InvalidConfig();
    }

    /// @notice Takes the launcher's native refunds and the lock's acceptance payouts inside a call, and nothing else:
    ///         ETH sent between calls is refused, so no caller inherits a stranger's ETH with its refunds.
    receive() external payable {
        if (!_busy) revert InvalidFunding();
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function launcher() external view returns (address) {
        return _pins().launcher;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function lock() external view returns (address) {
        return _pins().lock;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function root() external view returns (address) {
        return _pins().root;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function registry() external view returns (address) {
        return _pins().registry;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function treasury() external view returns (address) {
        return _pins().treasury;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function collector() external view returns (address) {
        return _pins().collector;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function bridgeFactory() external view returns (address) {
        return _pins().bridgeFactory;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function poolManager() external view returns (address) {
        return _pins().poolManager;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function positionManager() external view returns (address) {
        return _pins().positionManager;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function positionManagerV3() external view returns (address) {
        return _pins().positionManagerV3;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function positionDoorFactory() external view returns (address) {
        return _pins().positionDoorFactory;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function v3PositionDoorFactory() external view returns (address) {
        return _pins().v3PositionDoorFactory;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function feebAdapterFactory() external view returns (address) {
        return _pins().feebAdapterFactory;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function revenueTokenDoorFactory() external view returns (address) {
        return _pins().revenueTokenDoorFactory;
    }

    /// @inheritdoc IHookrRevenueTokenizerSourcePins
    function ponsAdapterFactory() external view returns (address) {
        return _pins().ponsAdapterFactory;
    }

    /// @inheritdoc IHookrRevenueTokenizerSourcePins
    function dopplerAdapterFactory() external view returns (address) {
        return _pins().dopplerAdapterFactory;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokenCode() external view returns (address code0, address code1) {
        HookrRevenueTokenizerStorage.Pins storage p = _pins();
        return (p.tokenCode0, p.tokenCode1);
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function isAdmittedRules(address rules) public view returns (bool) {
        HookrRevenueTokenizerStorage.Pins storage p = _pins();
        return HookrRevenueRulesAdmission.admitted(p.registry, p.root, rules);
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function isAdmittedVault(address vault) external view returns (bool) {
        return HookrRevenueTokenizerStorage.getLayout().admittedVaults[vault];
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function admittedVaults() external view returns (address[] memory) {
        return HookrRevenueTokenizerStorage.getLayout().vaultList;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokenizations(address token) external view returns (Tokenization memory) {
        return HookrRevenueTokenizerStorage.getLayout().tokenizations[token];
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokenCount() external view returns (uint256) {
        return HookrRevenueTokenizerStorage.getLayout().tokens.length;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokenAt(uint256 i) external view returns (address) {
        return HookrRevenueTokenizerStorage.getLayout().tokens[i];
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function tokens(uint256 start, uint256 count) external view returns (address[] memory out) {
        address[] storage list = HookrRevenueTokenizerStorage.getLayout().tokens;
        uint256 n = list.length;
        if (start >= n) return out;
        if (count > n - start) count = n - start;
        out = new address[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = list[start + i];
        }
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function streamCount(address token) external view returns (uint256) {
        return HookrRevenueTokenizerStorage.getLayout().streams[token].length;
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function streamAt(address token, uint256 i) external view returns (StreamRecord memory) {
        return HookrRevenueStreamEnds.record(HookrRevenueTokenizerStorage.getLayout().streams[token][i]);
    }

    /// @inheritdoc IHookrRevenueTokenizer
    function streams(address token, uint256 start, uint256 count) external view returns (StreamRecord[] memory out) {
        HookrRevenueTokenizerStorage.Stream[] storage list = HookrRevenueTokenizerStorage.getLayout().streams[token];
        uint256 n = list.length;
        if (start >= n) return out;
        if (count > n - start) count = n - start;
        out = new StreamRecord[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = HookrRevenueStreamEnds.record(list[start + i]);
        }
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Checks no term: terms that `tokenize` would refuse still get an address, so a caller checks its terms
    ///      before it relies on the prediction.
    function predictToken(address creator, TokenTerms calldata t) external view returns (address) {
        HookrRevenueTokenizerStorage.Pins storage p = _pins();
        bytes memory code = HookrRevenueTokenDeployer.initCode(
            p.tokenCode0, p.tokenCode1, address(this), p.collector, t, p.poolManager
        );
        return
            HookrRevenueTokenDeployer.predict(address(this), HookrRevenueTokenDeployer.salt(creator, t.termsHash), code);
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Runs in the linked HookrRevenueStreams (`tokenize`), by delegatecall with this call's calldata as it
    ///      arrived. A revert is bubbled as is.
    function tokenize(TokenTerms calldata, StreamParams calldata, MarketTerms calldata)
        external
        payable
        nonReentrant
        returns (address token)
    {
        token = abi.decode(_delegate(HookrRevenueStreams.tokenize.selector), (address));
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Runs in the linked HookrRevenueStreams (`addStreams`), as `tokenize` does.
    function addStreams(address, StreamParams calldata) external payable nonReentrant returns (uint256 first) {
        first = abi.decode(_delegate(HookrRevenueStreams.addStreams.selector), (uint256));
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev A static call to the linked HookrRevenueMarketOpener (`defaultTerms`, pure), whose return data is this
    ///      function's own, once `rules` is admitted.
    function defaultMarket(address rules, address token, Currency quote, uint160 sqrtPriceX96, uint256 seed)
        external
        view
        returns (MarketTerms memory)
    {
        if (!isAdmittedRules(rules)) revert RulesNotAdmitted(rules);
        _static(
            address(HookrRevenueMarketOpener),
            abi.encodeWithSelector(
                HookrRevenueMarketOpener.defaultTerms.selector, rules, token, quote, sqrtPriceX96, seed
            )
        );
    }

    /// @inheritdoc IHookrRevenueTokenizer
    /// @dev Computed by the linked HookrRevenueDoorDeployer (`previewPositions`), given this call's calldata as it
    ///      arrived; its return data is this function's own.
    function previewPositions(address, uint256[] calldata)
        external
        view
        returns (bool[] memory, bool[] memory, bool[] memory, Currency[] memory)
    {
        _static(
            address(HookrRevenueDoorDeployer),
            abi.encodePacked(HookrRevenueDoorDeployer.previewPositions.selector, msg.data[4:])
        );
    }

    function _pins() private view returns (HookrRevenueTokenizerStorage.Pins storage) {
        return HookrRevenueTokenizerStorage.getLayout().pins;
    }

    /// @dev Delegatecalls the linked HookrRevenueStreams with this call's calldata under `selector` (an entry with the
    ///      same parameters in the same order) and returns its return data; a revert is bubbled as is.
    function _delegate(bytes4 selector) private returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(HookrRevenueStreams).delegatecall(abi.encodePacked(selector, msg.data[4:]));
        if (!ok) _bubble(ret);
    }

    /// @dev A static call of `data` on the linked library `lib` whose return data becomes this call's own. A revert is
    ///      bubbled as is. Never returns to its caller.
    function _static(address lib, bytes memory data) private view {
        (bool ok, bytes memory ret) = lib.staticcall(data);
        if (!ok) _bubble(ret);
        assembly ("memory-safe") {
            return(add(ret, 0x20), mload(ret))
        }
    }

    function _bubble(bytes memory ret) private pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}
