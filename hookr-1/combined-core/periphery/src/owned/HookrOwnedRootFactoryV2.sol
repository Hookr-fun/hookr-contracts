// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../interfaces/IHookrOwnedRoots.sol";
import {IHookrRootRegistrar} from "../interfaces/IHookrRootRegistrar.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrOwnedProfiles} from "../interfaces/IHookrOwnedProfiles.sol";
import {IHookrOwnedRootFactoryV2} from "../interfaces/IHookrOwnedRootFactoryV2.sol";
import {IHookrOwnedTemplate} from "../interfaces/IHookrOwnedTemplate.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrProtocolClaims} from "../interfaces/IHookrProtocolClaims.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {HookrOwnedConformance as C} from "../libraries/HookrOwnedConformance.sol";
import {HookrOwnedRootTypes as F} from "../libraries/HookrOwnedRootTypes.sol";
import {HookrFill} from "../../candidate-root-v2/src/core/HookrFill.sol";

/// @title HookrOwnedRootFactoryV2
/// @notice Owned-root factory v2: anyone deploys an own hook with any Hook Block of a live combined-core instance, in
///         one transaction and with no code in calldata (DESIGN 12 and 20.3, DECISIONS D33):
///         1. the profile checks of v1, its Rules the template: a live RULES admission of the combined core on the
///            shared root that pays this factory's treasury and answers to the shared root (D33a);
///         2. the allowed blocks inside the template's own, read from its runtime (D33d);
///         3. the salt namespaced by the caller and the address checked for the shared root's flags before any code
///            runs (v1's rule);
///         4. CREATE3 of root v2 from the root's code store, with the shared root's PoolManager, registry, router,
///            quoter and curated router, the shared lane module, `laneSource` (the shared root, or zero when the
///            profile leaves the lane out or the deployer opts out; DESIGN 20.2, L4-1) and `fill`: zero, or for a
///            deployer who picks a swap module (NC32) its HookrFill, after one read of the module's admission as a
///            RULES part under the template (NC39: live, its code the admitted code, IHookrSwapModule's schema); the
///            HookrFill of a module, gas limit and scope is deployed by the first root that needs it (CREATE2, zero
///            salt) and reused by every later one;
///         5. CREATE2 of the companion from the core's code stores, salted by the root as v1, with the template's
///            module table, recipient and floor read from the template, the owned root as its root, the allowed blocks
///            and the template as part scope, so every bind reads the template's brake keys and its RULES admission
///            (D33e) and the companion creates no keys;
///         6. the check that the companion's runtime is the template's outside its per-root, per-allowed and per-scope
///            immutables, which proves the template an instance of the pinned core;
///         7. the record, the registration with the template's admission terms (caps cut by the profile and the rule
///            mask), the profile's advisories and gates, and the owner of record as v1.
///         The deploy fee is the treasury's owned-root fee (D33l). There is no deployment cap: a fee-free cap could be
///         filled by anyone (launcher-connectors F1), and a deployment uses only its sender's salt.
/// @dev Root v2's and the core's creation code come from HookrCodeStore data contracts whose runtime codehashes and
///      reassembled creation code hashes the constructor checks; stores cannot change (EIP-6780), so a deploy reads
///      them unchecked. HookrFill's (2,340 bytes) is in this factory's own code: a store would cost each module deploy
///      a cold account (2,600 gas) for no other difference. The registry admits this factory through a timelocked
///      `SET_ROOT_FACTORY` pinned to its runtime codehash, which commits to every immutable below, the core layout
///      included, and to HookrFill's code. The factory holds no funds and has no owner.
contract HookrOwnedRootFactoryV2 is IHookrOwnedRootFactoryV2 {
    /// @inheritdoc IHookrOwnedRootFactoryV2
    uint256 public constant MAX_NAME_BYTES = 64;
    /// @inheritdoc IHookrOwnedRootFactoryV2
    bytes32 public constant SWAP_MODULE_SCHEMA = keccak256("IHookrSwapModule");
    /// @notice The gas the deploy fee's forward to the treasury's target gets, as v1.
    uint256 public constant FEE_FORWARD_GAS = 100_000;
    /// @dev keccak256("hookr.owned-root-factory-v2.transient.lock")
    bytes32 private constant LOCK = keccak256("hookr.owned-root-factory-v2.transient.lock");
    /// @dev CoreLayout.reads slots.
    uint256 private constant READ_RECAPTURE = 0;
    uint256 private constant READ_RECAPTURE_HASH = 1;
    uint256 private constant READ_CLAIMS = 2;
    uint256 private constant READ_BLOCK0 = 3;
    uint256 private constant READ_BINDER = 7;
    uint256 private constant READ_ALLOWED = 8;
    uint256 private constant READ_VIEW_SWAP = 9;

    /// @notice The PoolManager of the registry.
    IPoolManager public immutable poolManager;
    /// @notice The Hookr registry.
    IHookrRegistry public immutable registry;
    /// @notice The tier-1 profile book on the registry.
    IHookrOwnedProfiles public immutable profiles;
    /// @notice The shared root: the template root of every owned root, whose flags, router, quoter, curated router and
    ///         lane an owned root takes.
    address public immutable sharedRoot;
    /// @notice The router the shared root reports.
    address public immutable router;
    /// @notice The quoter the shared root reports.
    address public immutable quoter;
    /// @notice The curated router the shared root reports.
    address public immutable curatedRouter;
    /// @notice The treasury every companion pays.
    address public immutable treasury;
    /// @notice The one lane module every root v2 on this chain shares.
    address public immutable laneModule;
    /// @notice The shared root's permission flags, the low 14 bits of every owned root's address.
    uint160 public immutable rootClassFlags;
    /// @notice keccak256 of root v2's creation code, as reassembled from its stores.
    bytes32 public immutable rootCreationCodeHash;
    /// @notice keccak256 of the combined core's creation code, as reassembled from its stores.
    bytes32 public immutable coreCreationCodeHash;

    address private immutable rootStore0;
    address private immutable rootStore1;
    address private immutable coreStore0;
    address private immutable coreStore1;
    uint256 private immutable rootLength0;
    uint256 private immutable rootLength1;
    uint256 private immutable coreLength0;
    uint256 private immutable coreLength1;
    uint256 private immutable coreRuntimeLength;
    uint256 private immutable layoutReads;
    uint256 private immutable layoutMasks0;
    uint256 private immutable layoutMasks1;

    mapping(bytes32 namespacedSalt => bool) private _used;
    mapping(address root => OwnedRoot) private _records;
    mapping(address root => address) private _pendingOwner;
    address[] private _deployments;

    /// @dev The combined core's constructor argument, its HookrRules.Wire field for field.
    struct CoreWire {
        IPoolManager manager;
        IHookrRegistry registry;
        address recipient;
        address root;
        uint16 minShare;
        address recapture;
        bytes32 recaptureHash;
        address claims;
        bytes32 claimsHash;
        address[4] blocks;
        bytes32[4] blockHashes;
        address binder;
        bytes32 binderHash;
        bytes32 simulatorHash;
        uint8 allowed;
        address partScope;
    }

    /// @param registry_ The Hookr registry.
    /// @param profiles_ The tier-1 profile book on `registry_`.
    /// @param sharedRoot_ The shared root: a HookrRoot wired to `registry_` whose address carries its flags.
    /// @param treasury_ The protocol-fee recipient of every companion (Hookr's treasury), on the same PoolManager.
    /// @param laneModule_ The shared lane module root v2 takes, on the same PoolManager and registry.
    /// @param stores Root v2's two stores, then the core's two; a second store may be zero.
    /// @param storeHashes The runtime codehash of each store, zero for a zero store.
    /// @param rootCodeHash keccak256 of the reviewed root v2 creation code.
    /// @param coreCodeHash keccak256 of the combined-core creation code (without constructor arguments) exactly as the
    ///        core's own deployment sent it: the release build with HookrViewSwap linked at its deployed address and the
    ///        metadata of that build. A template is taken only when its runtime equals what these stores build, byte
    ///        for byte outside the masked immutables (`_matches`), so one factory serves one core build: a core rebuilt
    ///        with another library address or other metadata, even from the same source, needs a factory of its own.
    /// @param layout The core's runtime layout (IHookrOwnedRootFactoryV2.CoreLayout).
    constructor(
        IHookrRegistry registry_,
        IHookrOwnedProfiles profiles_,
        address sharedRoot_,
        address treasury_,
        address laneModule_,
        address[4] memory stores,
        bytes32[4] memory storeHashes,
        bytes32 rootCodeHash,
        bytes32 coreCodeHash,
        CoreLayout memory layout
    ) {
        if (
            address(registry_).code.length == 0 || address(profiles_).code.length == 0 || sharedRoot_.code.length == 0
                || treasury_.code.length == 0 || laneModule_.code.length == 0 || layout.runtimeLength == 0
                || layout.runtimeLength > 24_576
        ) revert InvalidWiring();
        IPoolManager manager = registry_.poolManager();
        uint160 flags = uint160(sharedRoot_) & Hooks.ALL_HOOK_MASK;
        IHookrRoot t = IHookrRoot(sharedRoot_);
        if (
            address(profiles_.registry()) != address(registry_) || address(t.registry()) != address(registry_)
                || address(t.poolManager()) != address(manager) || flags == 0
                || IHookrOwnedTemplate(sharedRoot_).PERMISSION_FLAGS() != flags
                || address(IHookrTreasury(treasury_).poolManager()) != address(manager)
                || address(IHookrRoot(laneModule_).poolManager()) != address(manager)
                || address(IHookrRoot(laneModule_).registry()) != address(registry_)
        ) revert InvalidWiring();
        uint256[4] memory lengths;
        for (uint256 i; i < 4; ++i) {
            address store = stores[i];
            if (store == address(0)) {
                // Only a second store may be empty.
                if (i % 2 == 0 || storeHashes[i] != bytes32(0)) revert InvalidWiring();
                continue;
            }
            if (store.codehash != storeHashes[i] || store.code.length < 2) revert InvalidWiring();
            lengths[i] = store.code.length - 1;
        }
        (rootStore0, rootStore1, coreStore0, coreStore1) = (stores[0], stores[1], stores[2], stores[3]);
        (rootLength0, rootLength1, coreLength0, coreLength1) = (lengths[0], lengths[1], lengths[2], lengths[3]);
        if (
            keccak256(_join(stores[0], lengths[0], stores[1], lengths[1], "")) != rootCodeHash
                || keccak256(_join(stores[2], lengths[2], stores[3], lengths[3], "")) != coreCodeHash
        ) revert InvalidWiring();
        poolManager = manager;
        registry = registry_;
        profiles = profiles_;
        sharedRoot = sharedRoot_;
        router = t.router();
        quoter = t.quoter();
        curatedRouter = t.curatedRouter();
        treasury = treasury_;
        laneModule = laneModule_;
        rootClassFlags = flags;
        rootCreationCodeHash = rootCodeHash;
        coreCreationCodeHash = coreCodeHash;
        coreRuntimeLength = layout.runtimeLength;
        layoutReads = layout.reads;
        layoutMasks0 = layout.masks[0];
        layoutMasks1 = layout.masks[1];
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function deploy(RootSelections calldata s, bytes32 salt)
        external
        payable
        returns (address root, address rules)
    {
        _lock();
        uint256 fee = IHookrTreasury(treasury).ownedRootFee();
        if (msg.value != fee) revert WrongFee(msg.value, fee);
        if (bytes(s.name).length > MAX_NAME_BYTES) revert NameTooLong(bytes(s.name).length);
        IHookrOwnedProfiles.Profile memory p = _checkedProfile(s);
        address template = p.rules;
        IHookrRegistry.Admission memory admission = _templateAdmission(template);
        uint8 own = _templateBlocks(template);
        if (s.allowedBlocks & ~own != 0) revert BlocksNotAllowed(s.allowedBlocks, own);
        bytes32 namespaced = _namespace(msg.sender, salt);
        if (_used[namespaced]) revert SaltUsed(msg.sender, salt);
        _used[namespaced] = true;
        root = CREATE3.getDeployed(namespaced);
        // Checked before any code runs: a salt not mined for the shared root's flags never deploys.
        if (uint160(root) & Hooks.ALL_HOOK_MASK != rootClassFlags) revert Hooks.HookAddressNotValid(root);
        bool lane = p.laneEnabled && !s.recaptureOff;
        address laneSource = lane ? sharedRoot : address(0);
        address fill = s.swapModule == address(0) ? address(0) : _fillOf(template, s.swapModule);
        bytes memory args =
            abi.encode(poolManager, registry, router, quoter, curatedRouter, laneModule, laneSource, fill);
        CREATE3.deploy(namespaced, _join(rootStore0, rootLength0, rootStore1, rootLength1, args), 0);
        rules = _deployCompanion(template, root, s.allowedBlocks);
        if (!_matches(template, rules)) revert CompanionMismatch(template, rules);
        admission.implementation = rules;
        admission.codeHash = rules.codehash;
        admission.caps = F.hardCaps(p.caps, s.ruleMask);
        OwnedRoot storage o = _records[root];
        (o.publicOpening, o.laneAllowed, o.allowedBlocks, o.profileVersion) =
            (s.publicOpening, lane, s.allowedBlocks, p.version);
        (o.rules, o.template, o.profileId, o.ruleMask) = (rules, template, s.profileId, s.ruleMask);
        _deployments.push(root);
        IHookrOwnedRoots(address(registry)).registerOwnedRoot(root, sharedRoot, template, admission, _copies(p));
        emit Deployed(root, rootCreationCodeHash, msg.sender, args, namespaced);
        emit RootDeployed(root, msg.sender, rules, template, laneSource, s);
        if (s.owner == msg.sender) {
            o.owner = msg.sender;
            emit RootOwnershipTransferred(root, address(0), msg.sender);
        } else {
            _pendingOwner[root] = s.owner;
            emit RootOwnershipTransferStarted(root, address(0), s.owner);
        }
        if (fee != 0) {
            address to = IHookrTreasury(treasury).target();
            (bool ok,) = to.call{value: fee, gas: FEE_FORWARD_GAS}("");
            if (!ok) revert FeeNotForwarded(to);
            emit DeployFeePaid(root, to, fee);
        }
        _unlock();
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function deployFee() external view returns (uint256) {
        return IHookrTreasury(treasury).ownedRootFee();
    }

    /// @inheritdoc IHookrRootRegistrar
    /// @dev One storage read; the registry asks it with a bounded static call for every new pool on `root`.
    function mayOpen(address root, address opener) external view returns (bool) {
        OwnedRoot storage o = _records[root];
        return !o.paused && (o.publicOpening || (o.owner != address(0) && opener == o.owner));
    }

    /// @inheritdoc IHookrRootRegistrar
    function rulesOf(address root) external view returns (address) {
        return _records[root].rules;
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function setPaused(address root, bool paused) external {
        OwnedRoot storage o = _owned(root);
        if (msg.sender != o.owner) revert NotRootOwner(root, msg.sender);
        o.paused = paused;
        emit RootPaused(root, paused);
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function transferRootOwnership(address root, address nominee) external {
        OwnedRoot storage o = _owned(root);
        if (msg.sender != o.owner) revert NotRootOwner(root, msg.sender);
        _pendingOwner[root] = nominee;
        emit RootOwnershipTransferStarted(root, msg.sender, nominee);
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function acceptRootOwnership(address root) external {
        OwnedRoot storage o = _owned(root);
        if (msg.sender != _pendingOwner[root]) revert NotRootOwner(root, msg.sender);
        address previous = o.owner;
        o.owner = msg.sender;
        delete _pendingOwner[root];
        emit RootOwnershipTransferred(root, previous, msg.sender);
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function pendingRootOwner(address root) external view returns (address) {
        return _pendingOwner[root];
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function ownedRoot(address root) external view returns (OwnedRoot memory) {
        return _records[root];
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    /// @dev The pool's declared caps are not compared: the root binds every pool at the lower of its declared caps and
    ///      the companion's admission.
    function ownedRootConforms(address root, PoolId id) external view returns (bool) {
        OwnedRoot storage o = _records[root];
        if (o.rules == address(0)) return false;
        HookrTypes.Caps memory any = HookrTypes.Caps(type(uint24).max, type(uint24).max, type(uint16).max);
        address[] memory advisories = profiles.profileAt(o.profileId, o.profileVersion).advisories;
        return C.poolFits(root, id, o.rules, advisories, any, o.ruleMask, o.laneAllowed);
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function companionMatchesTemplate(address template, address companion) external view returns (bool) {
        return _matches(template, companion);
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function templateBlocks(address template) external view returns (uint8) {
        return _templateBlocks(template);
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function computeAddress(address deployer, bytes32 salt) external view returns (address) {
        return CREATE3.getDeployed(_namespace(deployer, salt));
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function saltUsed(address deployer, bytes32 salt) external view returns (bool) {
        return _used[_namespace(deployer, salt)];
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function swapModuleFill(address module, uint256 gasLimit, address scope) external view returns (address) {
        return _create2Address(keccak256(_fillInit(module, gasLimit, scope)));
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function isFromFactory(address root) external view returns (bool) {
        return _records[root].rules != address(0);
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function allDeploymentsLength() external view returns (uint256) {
        return _deployments.length;
    }

    /// @inheritdoc IHookrOwnedRootFactoryV2
    function allDeployments(uint256 index) external view returns (address) {
        return _deployments[index];
    }

    /// @dev The profile the selections name, at the version they read, on the shared root, usable by the caller, with
    ///      the selections inside it, while the shared root takes new pools (v1's checks).
    function _checkedProfile(RootSelections calldata s) private view returns (IHookrOwnedProfiles.Profile memory p) {
        p = profiles.profile(s.profileId);
        if (p.version == 0) revert UnknownProfile(s.profileId);
        if (s.profileVersion != p.version) revert ProfileVersionMismatch(s.profileId, s.profileVersion, p.version);
        if (p.root != sharedRoot || !registry.rootOpen(sharedRoot)) revert InvalidTemplate(p.root);
        if (!p.publicOpening && msg.sender != p.owner) revert NotProfileOwner(s.profileId, msg.sender);
        if (s.owner == address(0)) revert InvalidOwner();
        if (s.ruleMask & ~p.ruleMask != 0) revert OutsideProfile(s.profileId);
        if (s.publicOpening && s.ruleMask & F.SOFT_FEATURES != F.SOFT_FEATURES) {
            revert SoftMaskNeedsOwnerOnly(s.ruleMask);
        }
    }

    /// @dev The template's live RULES admission on the shared root, for a template that still pays this factory's
    ///      treasury and answers to the shared root: the terms the companion's admission copies. Whether the template
    ///      is an instance of the pinned core is the companion check's (`_matches`).
    function _templateAdmission(address template) private view returns (IHookrRegistry.Admission memory a) {
        a = registry.admission(sharedRoot, template);
        if (
            a.kind != IHookrRegistry.Kind.RULES || a.implementation != template || template.codehash != a.codeHash
                || template.code.length != coreRuntimeLength
                || IHookrProtocolClaims(template).protocolRecipient() != treasury
                || IHookrRules(template).trustedRoot() != sharedRoot
        ) revert InvalidTemplate(template);
    }

    /// @dev The companion of `root`: CREATE2 with the root's address as salt (v1), from the core's stores, with the
    ///      template's module table and floor, the owned root, `allowed` and the template as part scope.
    function _deployCompanion(address template, address root, uint8 allowed) private returns (address rules) {
        CoreWire memory w;
        (w.manager, w.registry, w.recipient, w.root) = (poolManager, registry, treasury, root);
        w.minShare = IHookrOwnedTemplate(template).minProtocolShareBps();
        w.recapture = address(uint160(_word(template, READ_RECAPTURE)));
        w.recaptureHash = bytes32(_word(template, READ_RECAPTURE_HASH));
        w.claims = address(uint160(_word(template, READ_CLAIMS)));
        w.claimsHash = w.claims.codehash;
        for (uint256 i; i < 4; ++i) {
            address module = address(uint160(_word(template, READ_BLOCK0 + i)));
            w.blocks[i] = module;
            if (module != address(0)) w.blockHashes[i] = module.codehash;
        }
        w.binder = address(uint160(_word(template, READ_BINDER)));
        w.binderHash = w.binder.codehash;
        w.simulatorHash = address(uint160(_word(template, READ_VIEW_SWAP) >> 96)).codehash;
        w.allowed = allowed;
        w.partScope = template;
        bytes memory init = _join(coreStore0, coreLength0, coreStore1, coreLength1, abi.encode(w));
        bytes32 s = bytes32(uint256(uint160(root)));
        assembly ("memory-safe") {
            rules := create2(0, add(init, 32), mload(init), s)
        }
        if (rules == address(0)) revert CompanionNotDeployed(root);
    }

    /// @dev The HookrFill of `module` for a root of `template`. The module's admission is read once, here: a live RULES
    ///      part admission under the template (NC39; the registry answers an empty one for a module it does not admit
    ///      there, revoked or never admitted, or whose bond lapsed), its code still the code admitted and its schema
    ///      IHookrSwapModule's. The HookrFill takes the admission's gas limit and the template as the scope lane v2
    ///      reads the admission from at each new pool (NC34); it is deployed at its CREATE2 address unless a root built
    ///      earlier with the same module, gas limit and scope already did. Only this factory can deploy that address,
    ///      and only with this code and these arguments, so code there is that HookrFill.
    function _fillOf(address template, address module) private returns (address fill) {
        IHookrRegistry.Admission memory a = registry.admission(template, module);
        if (
            a.kind != IHookrRegistry.Kind.RULES || a.implementation != module
                || a.schemaHash != SWAP_MODULE_SCHEMA
                || module.codehash != a.codeHash
        ) revert InvalidSwapModule(module);
        bytes memory init = _fillInit(module, a.gasLimit, template);
        fill = _create2Address(keccak256(init));
        if (fill.code.length != 0) return fill;
        assembly ("memory-safe") {
            fill := create2(0, add(init, 32), mload(init), 0)
        }
        // HookrFill refuses a zero gas limit.
        if (fill == address(0)) revert InvalidSwapModule(module);
        emit SwapModuleFillDeployed(module, template, a.gasLimit, fill);
    }

    /// @dev HookrFill's creation code with its constructor arguments for `module`, `gasLimit` and `scope`.
    function _fillInit(address module, uint256 gasLimit, address scope) private view returns (bytes memory) {
        return bytes.concat(type(HookrFill).creationCode, abi.encode(poolManager, module, gasLimit, scope));
    }

    /// @dev The address CREATE2 from this factory with a zero salt gives creation code of hash `initHash`.
    function _create2Address(bytes32 initHash) private view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initHash)))));
    }

    /// @dev The template's `allowedBlocks`, the low byte of its word.
    function _templateBlocks(address template) private view returns (uint8) {
        return uint8(_word(template, READ_ALLOWED));
    }

    /// @dev The 32 bytes of `account`'s runtime at the `slot`th read site of the layout.
    function _word(address account, uint256 slot) private view returns (uint256 w) {
        uint256 offset = (layoutReads >> (slot * 16)) & 0xffff;
        assembly ("memory-safe") {
            extcodecopy(account, 0, offset, 32)
            w := mload(0)
        }
    }

    /// @dev Whether `companion` and `template` hold runtimes of the layout's length that hash alike with every mask site
    ///      of the layout zeroed in both. Both copies sit past the free memory pointer, which this does not move.
    function _matches(address template, address companion) private view returns (bool same) {
        uint256 n = coreRuntimeLength;
        if (template.code.length != n || companion.code.length != n) return false;
        uint256 m0 = layoutMasks0;
        uint256 m1 = layoutMasks1;
        assembly ("memory-safe") {
            let a := mload(0x40)
            let b := add(a, add(n, 32))
            extcodecopy(template, a, 0, n)
            extcodecopy(companion, b, 0, n)
            // Word 32 past each copy's end is zeroed so a site in the last 31 bytes cannot read past the copy.
            mstore(add(a, n), 0)
            mstore(add(b, n), 0)
            let list := m0
            for { let i := 0 } lt(i, 32) { i := add(i, 1) } {
                if eq(i, 16) { list := m1 }
                let site := and(shr(mul(mod(i, 16), 16), list), 0xffff)
                if iszero(site) { break }
                mstore(add(a, site), 0)
                mstore(add(b, site), 0)
            }
            same := eq(keccak256(a, n), keccak256(b, n))
        }
    }

    /// @dev The two stores' data, then `tail`, as one fresh bytes.
    function _join(address s0, uint256 n0, address s1, uint256 n1, bytes memory tail)
        private
        view
        returns (bytes memory out)
    {
        uint256 t = tail.length;
        out = new bytes(n0 + n1 + t);
        assembly ("memory-safe") {
            let p := add(out, 32)
            extcodecopy(s0, p, 1, n0)
            if n1 { extcodecopy(s1, add(p, n0), 1, n1) }
            mcopy(add(p, add(n0, n1)), add(tail, 32), t)
        }
    }

    /// @dev The shared root's admissions the owned root copies: the profile's advisories, then its gates.
    function _copies(IHookrOwnedProfiles.Profile memory p) private pure returns (address[] memory list) {
        uint256 n = p.advisories.length;
        list = new address[](n + p.gates.length);
        for (uint256 i; i < n; ++i) {
            list[i] = p.advisories[i];
        }
        for (uint256 i; i < p.gates.length; ++i) {
            list[n + i] = p.gates[i];
        }
    }

    /// @dev The record of a root this factory deployed.
    function _owned(address root) private view returns (OwnedRoot storage o) {
        o = _records[root];
        if (o.rules == address(0)) revert NotOwnedRoot(root);
    }

    /// @dev Under CREATE3 the address ignores the creation code, so the salt is bound to the account that deploys:
    ///      nobody else can take the address a deployer mined.
    function _namespace(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }

    function _lock() private {
        bytes32 slot = LOCK;
        uint256 entered;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
        if (entered != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    function _unlock() private {
        bytes32 slot = LOCK;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }
}
