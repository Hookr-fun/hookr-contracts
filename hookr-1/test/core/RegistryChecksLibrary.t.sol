// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {VmSafe} from "forge-std/Vm.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRegistryChecks} from "../../src/libraries/HookrRegistryChecks.sol";
import {HookrRegistryStorage} from "../../src/libraries/HookrRegistryStorage.sol";
import {IHookrExternalHooks} from "../../src/interfaces/IHookrExternalHooks.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrReleased} from "../../src/base/HookrReleased.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";

/// @dev Reports the registry it names, which is all `registerFactoryRoot` asks of a root.
contract LayoutRootStub {
    address public immutable registry;

    constructor(address registry_) {
        registry = registry_;
    }
}

/// @dev A root factory as the registry sees it: code that registers roots.
contract LayoutFactoryStub {
    function register(HookrRegistry registry, address root, address advisory) external {
        registry.registerFactoryRoot(root, advisory);
    }
}

/// @dev Any contract with code: an advisory, a quote class witness or a settlement currency.
contract LayoutCodeStub {
    function totalSupply() external pure returns (uint256) {
        return 1;
    }
}

/// @notice The registry's checks run in the linked library HookrRegistryChecks, its timelock step and cold timelocked
///         writes in the linked library HookrRegistryAdmin, and its state lives in HookrRegistryStorage, with no change
///         to the registry's ABI or storage: every ERC-7201 namespace keeps its id and slot, every member its offset
///         (read raw with vm.load after the public paths write it), every external function, event and error its
///         selector, and every queue-time check and cold write runs by DELEGATECALL into a library.
contract RegistryChecksLibraryTest is PeripheryFixture {
    /// @dev `cast index-erc7201 hookr.registry`, `.quotes` and `.settlement`, as at r31-final.
    bytes32 internal constant STATE = 0x9a51922757df0ac456dcfdd975bdabe6e420440d7def07553f70853f8394c000;
    bytes32 internal constant QUOTES = 0x175b0de7591e7bf9ef1d59ff7d4b868a03b040c985a1c2a689968d473c83fb00;
    bytes32 internal constant SETTLEMENT = 0x17be4c484b454c9a7b115dda293e62b52c30147a635aa702a72cdd3caab2bb00;
    address internal guardianAccount = address(0x6A7D);
    address internal nominee = address(0x7E57);

    function setUp() public {
        _setUpPeriphery();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function _at(bytes32 base, uint256 offset) internal pure returns (bytes32) {
        return bytes32(uint256(base) + offset);
    }

    function _key(bytes32 slot, address key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _key(bytes32 slot, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _load(bytes32 slot) internal view returns (uint256) {
        return uint256(vm.load(address(registry), slot));
    }

    function _execute(bytes32 kind, bytes memory arguments) internal returns (bytes32 operation) {
        operation = registry.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
    }

    // ───────────────────────────── storage ─────────────────────────────

    /// Each namespace sits at the slot its ERC-7201 id names, in the storage library and in the registry's state.
    function test_namespaceSlotsDeriveFromTheirIds() public pure {
        assertEq(_erc7201("hookr.registry"), STATE);
        assertEq(_erc7201("hookr.registry.quotes"), QUOTES);
        assertEq(_erc7201("hookr.registry.settlement"), SETTLEMENT);
        assertEq(HookrRegistryStorage.SLOT, STATE);
        assertEq(HookrRegistryStorage.QUOTE_SLOT, QUOTES);
        assertEq(HookrRegistryStorage.SETTLEMENT_SLOT, SETTLEMENT);
        assertEq(HookrRegistryStorage.RECORDS_SLOT, _erc7201("hookr.registry.records"));
        assertEq(HookrRegistryStorage.BONDS_SLOT, _erc7201("hookr.registry.bonds"));
        assertEq(HookrRegistryStorage.OWNED_SLOT, _erc7201("hookr.registry.owned"));
    }

    /// Every member of `State` sits at its r31-final offset: the public paths write it and the raw slot reads it.
    function test_stateMembersKeepTheirOffsets() public {
        // 0 owner, 3 launchers, 4 roots, 5 admissions, 7 quotes, 8 quotePosition: written by the fixture.
        assertEq(_load(STATE), uint160(address(this)), "owner");
        assertEq(_load(_key(_at(STATE, 3), address(launcher))), 1, "launchers");
        assertEq(_load(_key(_at(STATE, 4), address(root))), 0x0101, "roots: registered, active");
        bytes32 a = _key(_key(_at(STATE, 5), address(root)), address(rules));
        assertEq(_load(a), uint256(uint160(address(rules))) << 8, "admission: kind RULES, implementation");
        assertEq(bytes32(_load(_at(a, 1))), address(rules).codehash, "admission: codeHash");
        assertEq(bytes32(_load(_at(a, 2))), rules.configSchemaHash(), "admission: schemaHash");
        assertEq(_load(_at(a, 3)), 600_000 | (200_000 << 24) | (1000 << 48), "admission: caps");
        assertEq(_load(_at(a, 4)), 2_000_000 | (3 << 32), "admission: gasLimit, phaseMask, feeOnly, failOpen");
        assertEq(_load(_at(STATE, 7)), 2, "quotes: length");
        assertEq(_load(keccak256(abi.encode(_at(STATE, 7)))), uint160(address(tokenA)), "quotes[0]");
        assertEq(_load(_key(_at(STATE, 8), address(tokenB))), 2, "quotePosition");

        // 1 pendingOwner and 2 readyAt.
        bytes32 operation = _execute(registry.TRANSFER_OWNER(), abi.encode(nominee));
        assertEq(_load(_key(_at(STATE, 2), operation)), registry.readyAt(operation), "readyAt");
        registry.transferOwnership(nominee);
        assertEq(_load(_at(STATE, 1)), uint160(nominee), "pendingOwner");
        assertEq(_load(_key(_at(STATE, 2), operation)), 0, "readyAt consumed");

        // 6 guardian with newMarketsPaused packed after it.
        _execute(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        registry.setGuardian(guardianAccount);
        vm.prank(guardianAccount);
        registry.pauseNewMarkets();
        assertEq(_load(_at(STATE, 6)), uint160(guardianAccount) | (1 << 160), "guardian, newMarketsPaused");
        _execute(registry.RESUME_NEW_MARKETS(), "");
        registry.resumeNewMarkets();

        // 9 rootFactories, 11 rootAdvisories, then 4 roots with the factory packed after the flags.
        LayoutFactoryStub factory = new LayoutFactoryStub();
        _execute(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        assertEq(bytes32(_load(_key(_at(STATE, 9), address(factory)))), address(factory).codehash, "rootFactories");
        address pairRoot = address(new LayoutRootStub(address(registry)));
        address advisory = address(new LayoutCodeStub());
        factory.register(registry, pairRoot, advisory);
        assertEq(_load(_key(_at(STATE, 11), pairRoot)), uint160(advisory), "rootAdvisories");
        assertEq(_load(_key(_at(STATE, 4), pairRoot)), 0x0101 | (uint256(uint160(address(factory))) << 32), "roots");

        // 10 revoked: a factory-scope admission revoked by the brake.
        IHookrRegistry.Admission memory pair = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: advisory,
            codeHash: advisory.codehash,
            schemaHash: keccak256("layout.advisory"),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 100_000,
            phaseMask: 1,
            feeOnly: true,
            failOpen: false
        });
        _execute(registry.ADMIT(), abi.encode(address(factory), pair));
        registry.admit(address(factory), pair);
        address[] memory revoked = new address[](1);
        revoked[0] = advisory;
        registry.revokeFactoryAdmissions(address(factory), revoked);
        assertEq(_load(_key(_key(_at(STATE, 10), address(factory)), advisory)), 1, "revoked");

        // 12 lanes and 13 laneSwitches.
        MockIdleExecutor executor = new MockIdleExecutor();
        bytes32 openLane = keccak256("OPEN_LANE");
        _execute(openLane, abi.encode(address(root), address(executor), address(executor).codehash, 600_000, 2_500));
        registry.openLaneOf(address(root), address(executor), address(executor).codehash, 600_000, 2_500);
        bytes32 lane = _key(_at(STATE, 12), address(root));
        assertEq(_load(lane), uint160(address(executor)) | (2_500 << 160), "lane: executor, partnerBps, closedAt");
        assertEq(bytes32(_load(_at(lane, 1))), address(executor).codehash, "lane: codeHash");
        bytes32 laneSwitch = _key(_key(_at(STATE, 13), address(root)), address(executor));
        assertEq(_load(laneSwitch), 1 | (600_000 << 8), "laneSwitch: on, gasCap, brakedAt");
        registry.stopExecutorLane(address(root), address(executor));
        assertEq(_load(laneSwitch), (600_000 << 8) | (vm.getBlockTimestamp() << 40), "laneSwitch: braked");
        registry.closeLaneOf(address(root));
        assertEq(_load(lane), vm.getBlockTimestamp() << 176, "lane: closedAt");

        // 4 roots: frozen and closed flags.
        registry.closeRoot(address(root));
        registry.freezeRoot(address(root));
        assertEq(_load(_key(_at(STATE, 4), address(root))), 0x01010101, "roots: frozen, closed");
    }

    /// `Records`, the external-hook namespace, sits at its own ERC-7201 slot: `hooks` at offset 0 (kind and bond
    /// reference packed in the record's first word, the codehash in its second) and `delistedAt` at offset 1.
    function test_recordsMembersSitAtTheirOffsets() public {
        bytes32 records = HookrRegistryStorage.RECORDS_SLOT;
        LayoutCodeStub hook = new LayoutCodeStub();
        LayoutCodeStub bond = new LayoutCodeStub();
        bytes32 kind = keccak256("RECORD_EXTERNAL_HOOK");
        bytes memory arguments =
            abi.encode(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(hook).codehash, address(bond));
        _execute(kind, arguments);
        registry.setExternalHook(
            address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(hook).codehash, address(bond)
        );
        bytes32 entry = _key(records, address(hook));
        assertEq(_load(entry), 2 | (uint256(uint160(address(bond))) << 8), "hooks: kind, bondRef");
        assertEq(bytes32(_load(_at(entry, 1))), address(hook).codehash, "hooks: codeHash");
        registry.dropSingleExternalHookRecordNow(address(hook));
        assertEq(_load(entry), 0, "hooks: withdrawn");
        assertEq(_load(_key(_at(records, 1), address(hook))), vm.getBlockTimestamp(), "delistedAt");
    }

    /// Every member of `QuoteState` and `Settlement` sits at its r31-final offset.
    function test_quoteAndSettlementMembersKeepTheirOffsets() public {
        LayoutCodeStub witness = new LayoutCodeStub();
        bytes32 classHash = address(witness).codehash;

        // QuoteState: 1 classes, 2 classPosition.
        _execute(keccak256("SET_QUOTE_CLASS"), abi.encode(classHash, address(witness)));
        registry.installQuoteClass(classHash, address(witness));
        assertEq(_load(_at(QUOTES, 1)), 1, "classes: length");
        assertEq(bytes32(_load(keccak256(abi.encode(_at(QUOTES, 1))))), classHash, "classes[0]");
        assertEq(_load(_key(_at(QUOTES, 2), classHash)), 1, "classPosition");

        // 0 anyQuote with anyQuoteStoppedAt packed after it.
        _execute(keccak256("ANY_QUOTE"), "");
        registry.authorizeAnyQuote();
        assertEq(_load(QUOTES), 1, "anyQuote");
        registry.dismissAnyQuoteNow();
        assertEq(_load(QUOTES), vm.getBlockTimestamp() << 8, "anyQuoteStoppedAt");

        // 3 classDroppedAt and 4 brakes.
        registry.dropWholeQuoteClass(classHash);
        assertEq(_load(_key(_at(QUOTES, 3), classHash)), vm.getBlockTimestamp(), "classDroppedAt");
        registry.brakeOneQuoteInstantly(address(witness));
        assertEq(_load(_key(_at(QUOTES, 4), address(witness))), 1 | (vm.getBlockTimestamp() << 8), "brakes");

        // Settlement: 0 currencies (native ETH seeded at construction), 1 position, 2 removedAt.
        assertEq(_load(SETTLEMENT), registry.settlementCurrencies().length, "currencies: length");
        assertEq(_load(keccak256(abi.encode(SETTLEMENT))), 0, "currencies[0] is native ETH");
        assertEq(_load(_key(_at(SETTLEMENT, 1), address(0))), 1, "position");
        LayoutCodeStub currency = new LayoutCodeStub();
        _execute(keccak256("ADD_SETTLEMENT"), abi.encode(address(currency)));
        registry.addSettlementCurrency(address(currency));
        uint256 length = registry.settlementCurrencies().length;
        assertEq(_load(_key(_at(SETTLEMENT, 1), address(currency))), length, "position of the addition");
        registry.removeSettlementCurrency(address(currency));
        assertEq(_load(_key(_at(SETTLEMENT, 2), address(currency))), vm.getBlockTimestamp(), "removedAt");
        assertEq(_load(SETTLEMENT), length - 1, "currencies: length after removal");
    }

    // ───────────────────────────── the library ─────────────────────────────

    /// Queue-time checks run by DELEGATECALL in the linked library, whose runtime is the compiled library unchanged: it
    /// has no call guard to fill in, since none of its external functions writes storage.
    function test_queueChecksRunInTheLinkedLibrary() public {
        bytes32 kind = registry.SET_LAUNCHER();
        bytes memory arguments = abi.encode(address(launcher), false);
        vm.startStateDiffRecording();
        registry.queue(kind, arguments);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        address library_;
        for (uint256 i; i < accesses.length; ++i) {
            // A DELEGATECALL keeps the registry's caller as the accessor.
            if (accesses[i].kind == VmSafe.AccountAccessKind.DelegateCall && accesses[i].account != address(registry)) {
                library_ = accesses[i].account;
            }
        }
        assertTrue(library_ != address(0), "no DELEGATECALL");
        assertEq(library_.code, vm.getDeployedCode("HookrRegistryChecks.sol:HookrRegistryChecks"));
    }

    /// @dev The registry's two linked libraries, told apart among the DELEGATECALLs `accesses` recorded: the checks
    ///      library by its compiled runtime, the admin library as the other one.
    function _libraries(VmSafe.AccountAccess[] memory accesses) internal view returns (address checks, address admin) {
        bytes32 checksCode = keccak256(vm.getDeployedCode("HookrRegistryChecks.sol:HookrRegistryChecks"));
        for (uint256 i; i < accesses.length; ++i) {
            address target = accesses[i].account;
            if (accesses[i].kind != VmSafe.AccountAccessKind.DelegateCall || target == address(registry)) continue;
            if (keccak256(target.code) == checksCode) checks = target;
            else admin = target;
        }
    }

    /// The timelock's consume step and the cold timelocked writes run by DELEGATECALL in the second linked library,
    /// HookrRegistryAdmin, which reaches the checks library the same way: both run on the registry's storage and log as
    /// the registry.
    function test_coldWritesRunInTheAdminLibrary() public {
        LayoutCodeStub advisory = new LayoutCodeStub();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: keccak256("layout.advisory"),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 100_000,
            phaseMask: 1,
            feeOnly: true,
            failOpen: false
        });
        _execute(registry.ADMIT(), abi.encode(address(root), a));
        vm.startStateDiffRecording();
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.ModuleAdmitted(address(root), address(advisory), IHookrRegistry.Kind.ADVISORY, a.codeHash);
        registry.admit(address(root), a);
        (address checks, address admin) = _libraries(vm.stopAndReturnStateDiff());
        assertTrue(checks != address(0), "the admission is checked in HookrRegistryChecks");
        assertTrue(admin != address(0) && admin != checks, "the admission is written in HookrRegistryAdmin");
        assertEq(registry.admission(address(root), address(advisory)).implementation, address(advisory));

        // Any other execution consumes its operation there as well.
        _execute(registry.SET_LAUNCHER(), abi.encode(address(launcher), false));
        vm.startStateDiffRecording();
        registry.setLauncher(address(launcher), false);
        (, address consumer) = _libraries(vm.stopAndReturnStateDiff());
        assertEq(consumer, admin, "the timelock step runs in HookrRegistryAdmin");
    }

    // ───────────────────────────── ABI ─────────────────────────────

    /// Every r31-final external function keeps its selector.
    function test_functionSelectorsAreUnchanged() public pure {
        bytes4[63] memory got = [
            HookrRegistry.freezeRoot.selector,
            HookrRegistry.reopenRoot.selector,
            HookrRegistry.removeGuardian.selector,
            HookrRegistry.cancelOwnershipTransfer.selector,
            HookrRegistry.quoteAssets.selector,
            HookrRegistry.retireRoot.selector,
            HookrRegistry.rootFrozen.selector,
            HookrRegistry.deactivateLauncher.selector,
            HookrRegistry.addSettlementCurrency.selector,
            HookrRegistry.guardian.selector,
            HookrRegistry.setLauncher.selector,
            HookrReleased.releaseId.selector,
            HookrRegistry.isRoot.selector,
            HookrRegistry.registerRoot.selector,
            HookrRegistry.rootClosed.selector,
            HookrRegistry.settlementCurrencies.selector,
            HookrRegistry.removeSettlementCurrency.selector,
            HookrRegistry.admit.selector,
            HookrRegistry.acceptOwnership.selector,
            HookrRegistry.admission.selector,
            HookrRegistry.isRootFactory.selector,
            HookrRegistry.isSettlementCurrency.selector,
            HookrRegistry.deactivateRootFactory.selector,
            HookrRegistry.queue.selector,
            HookrRegistry.setRootFactory.selector,
            HookrRegistry.setGuardian.selector,
            HookrRegistry.owner.selector,
            HookrRegistry.operationHash.selector,
            HookrRegistry.readyAt.selector,
            HookrRegistry.rootFactoryCodeHash.selector,
            HookrRegistry.cancel.selector,
            HookrRegistry.expiresAt.selector,
            HookrRegistry.pauseNewMarkets.selector,
            HookrRegistry.newMarketsPaused.selector,
            HookrRegistry.rootFactoryOf.selector,
            HookrRegistry.pendingOwner.selector,
            HookrRegistry.isQuote.selector,
            HookrRegistry.rootOpen.selector,
            HookrRegistry.resumeNewMarkets.selector,
            HookrRegistry.transferOwnership.selector,
            HookrRegistry.setQuote.selector,
            HookrRegistry.closeRoot.selector,
            HookrRegistry.isLauncher.selector,
            HookrRegistry.registerFactoryRoot.selector,
            HookrRegistry.isRevokedAdmission.selector,
            HookrRegistry.tuneExecutorLane.selector,
            HookrRegistry.closeLaneOf.selector,
            HookrRegistry.openLaneOf.selector,
            HookrRegistry.executorLane.selector,
            HookrRegistry.revokeFactoryAdmissions.selector,
            HookrRegistry.rootStatus.selector,
            HookrRegistry.stopExecutorLane.selector,
            HookrRegistry.startExecutorLaneAt.selector,
            HookrRegistry.activeLaneOf.selector,
            HookrRegistry.openQuoteTerms.selector,
            HookrRegistry.dismissAnyQuoteNow.selector,
            HookrRegistry.installQuoteClass.selector,
            HookrRegistry.brakeOneQuoteInstantly.selector,
            HookrRegistry.dropWholeQuoteClass.selector,
            HookrRegistry.authorizeAnyQuote.selector,
            HookrRegistry.quoteIsBraked.selector,
            HookrRegistry.reopenSingleQuote.selector,
            HookrRegistry.badgeForQuote.selector
        ];
        bytes4[63] memory want = [
            bytes4(0x0033f183),
            0x12fcbff7,
            0x1a42390a,
            0x23452b9c,
            0x24164d0d,
            0x25cabbc7,
            0x2a064e03,
            0x32a7c620,
            0x3657762c,
            0x452a9320,
            0x4be27441,
            0x4d78d40b,
            0x557a6403,
            0x56e963a8,
            0x5ac25772,
            0x610b7b39,
            0x61345f8f,
            0x688110fc,
            0x79ba5097,
            0x79ddfd47,
            0x7b55096b,
            0x811ca688,
            0x83163682,
            0x85305e9b,
            0x887554d1,
            0x8a0dac4a,
            0x8da5cb5b,
            0x8f29d3de,
            0xbea20801,
            0xc2cea14b,
            0xc4d252f5,
            0xc582da00,
            0xd6ce472f,
            0xdab0f33b,
            0xdd429648,
            0xe30c3978,
            0xea2ee072,
            0xf006f691,
            0xf1d018b8,
            0xf2fde38b,
            0xf4415c2a,
            0xf8557b4a,
            0xfa275e11,
            0xfabcfc67,
            0xfbd205e3,
            0xfc171686,
            0xfd609b8c,
            0xfdaecc0e,
            0xfdc2869d,
            0xfe668571,
            0xfe7c1750,
            0xff110bd8,
            0xff365c4e,
            0xff3d3cf9,
            0xff5548fb,
            0xff77ad19,
            0xff8e991c,
            0xff9ba469,
            0xff9e2845,
            0xffbc13d6,
            0xffbf0083,
            0xffe33423,
            0xfffc6bc2
        ];
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], want[i]);
        }
    }

    /// The public constants and immutables keep their getters and values.
    function test_constantGettersAreUnchanged() public view {
        assertEq(registry.SET_LAUNCHER(), keccak256("SET_LAUNCHER"));
        assertEq(registry.REGISTER_ROOT(), keccak256("REGISTER_ROOT"));
        assertEq(registry.RETIRE_ROOT(), keccak256("RETIRE_ROOT"));
        assertEq(registry.ADMIT(), keccak256("ADMIT"));
        assertEq(registry.TRANSFER_OWNER(), keccak256("TRANSFER_OWNER"));
        assertEq(registry.SET_GUARDIAN(), keccak256("SET_GUARDIAN"));
        assertEq(registry.SET_QUOTE(), keccak256("SET_QUOTE"));
        assertEq(registry.RESUME_NEW_MARKETS(), keccak256("RESUME_NEW_MARKETS"));
        assertEq(registry.REOPEN_ROOT(), keccak256("REOPEN_ROOT"));
        assertEq(registry.SET_ROOT_FACTORY(), keccak256("SET_ROOT_FACTORY"));
        assertEq(registry.RULES_MIN_GAS_LIMIT(), 2_000_000);
        assertEq(registry.MIN_DELAY(), 30 minutes);
        assertEq(registry.MAX_DELAY(), 30 days);
        assertEq(registry.GRACE_PERIOD(), 14 days);
        assertEq(address(registry.poolManager()), address(manager));
        assertEq(registry.delay(), 1 days);
    }

    /// Every r31-final event keeps its topic and every error its selector, and the library raises the registry's
    /// errors.
    function test_eventsAndErrorsAreUnchanged() public pure {
        bytes32[29] memory topics = [
            IHookrRegistry.NewMarketsResumed.selector,
            IHookrRegistry.RootRegistered.selector,
            IHookrRegistry.OwnershipTransferCancelled.selector,
            IHookrRegistry.OperationExecuted.selector,
            IHookrRegistry.RootSealed.selector,
            IHookrRegistry.QuoteBraked.selector,
            IHookrRegistry.NewMarketsPaused.selector,
            IHookrLanes.LaneClosed.selector,
            IHookrRegistry.QuoteSet.selector,
            IHookrRegistry.OwnershipTransferStarted.selector,
            IHookrRegistry.RootClosed.selector,
            IHookrLanes.SettlementCurrencySet.selector,
            IHookrRegistry.AnyQuoteSet.selector,
            IHookrRegistry.LauncherSet.selector,
            IHookrRegistry.RootFactorySet.selector,
            IHookrRegistry.OwnershipTransferred.selector,
            IHookrRegistry.LauncherDeactivated.selector,
            IHookrRegistry.ModuleAdmitted.selector,
            IHookrRegistry.RootReopened.selector,
            IHookrRegistry.OperationQueued.selector,
            IHookrRegistry.GuardianSet.selector,
            IHookrRegistry.QuoteClassDropped.selector,
            IHookrLanes.LaneOpened.selector,
            IHookrRegistry.OperationCancelled.selector,
            IHookrRegistry.FactoryRootRegistered.selector,
            IHookrLanes.ExecutorLaneSet.selector,
            IHookrRegistry.AdmissionRevoked.selector,
            IHookrRegistry.QuoteClassSet.selector,
            IHookrRegistry.RootRetired.selector
        ];
        bytes32[29] memory wantTopics = [
            bytes32(0x01ef01c4e5c410b4acec6bdfc874d4f497db397bffdc6817d5a91cb835821016),
            0x05a966c402eedb8edc406601970811c17eb7d4a5eaa27d12d1f2aa0588458fbd,
            0x0ef3ae3c61450215beca833f02d7858a638ab836d06ae02febbe77a656cab62a,
            0x1277662f4b42b8a4069e99fb5e41ce8919d3c621156090ac08fb11adbcec66f9,
            0x1b573c450f8478836fc4f9d8bb70f3387a67294f3dfd41a622dc9d2cd6d70984,
            0x1b8f8cb33af21076088cb92bfbfb7c0cc9db49e30f2f18d880a4fbd8a8ce802a,
            0x1e4dd7ba3da9bea27b9262f8acbdce06e624d46da7d11e39012f4cff048bfe48,
            0x1efb5e1bf9a673c6d4ec59bc021522fe92f4b08d9044ed77a17fb62bc469490e,
            0x2fd766e8660e78cf98b863a195c8ebca9f689626f7c4ad3747172f9585a28bba,
            0x38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e22700,
            0x47a60dfc167c8718acfc4b40bb44803306c51261abc25cef119f49e5af8f8697,
            0x658d8c9488ba01c4544e885148039cb90e260859e4476f04106a4eeb1cd88028,
            0x65f3e580513769b922ad4ff2e66f86b8f3d671ec7a097aef1cddc0625414a21b,
            0x6eda20c7812dd626fd295b968b0f20a22cbaa98b4596c1207468cc4b1266bb69,
            0x78894eabf6c3ac0d03758803e388e0028fe0ebddb9567d06769d995c21c9f16c,
            0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0,
            0x978eb98635480c1b9e49252edfa00c32078b232d7bd0b5f69f73e57d3bd3997a,
            0x9b365e25f69aa8e1ac0adab33f1894cd95aad68389f377673a9ba040d451abd7,
            0xa1628ff2c7a49a049681c424dd5c419a6a663655c017dd872410bb46e8b9bc8d,
            0xb9215bf420b88697a19752a87fed717a5fa7e1000f318fcdd7a028123a7397ac,
            0xc3ce29e3ab42e524b6f6f1b4d3674898d503ee3577a64ac87b555904ebc14138,
            0xc6a60bad0207a7ac76faedf4225d2a75b33260ce660609f31f4c013b4c89b4b2,
            0xcc1855a4dfdc3eba10918b6784c3cd525b8f6c826d965c67df938000c72882a2,
            0xcf0f63b97f3387253cbc0bde884f975df77e39184dc3280c2c81be495f58eef4,
            0xd5bfff7f3558aeb9111935018972930b84f2987ee8f2d8e99e1be815dbf8e51d,
            0xe37b74c0475c4f01cf7ab7be8983dc7e202d250cded8f8c8bae1de77c001ad5a,
            0xf1facad858fd4cefe535a05cab8e16b50740baa5eedf4f6c10fbbaca644c9bbd,
            0xfbfd168c5a7cb2a429815fe10e0eb51966ac572dc4d913a63e87b7070105604d,
            0xfce72d961b2626240c4a353af9038eac32c3812337ebd39b3f90a37f318e9f85
        ];
        for (uint256 i; i < topics.length; ++i) {
            assertEq(topics[i], wantTopics[i]);
        }
        bytes4[26] memory errors = [
            IHookrRegistry.NotReady.selector,
            IHookrRegistry.AlreadyActive.selector,
            IHookrRegistry.LaneQueuedBeforeClose.selector,
            IHookrRegistry.RootNotClosed.selector,
            IHookrRegistry.UnknownOperation.selector,
            IHookrRegistry.QuoteClassActive.selector,
            IHookrRegistry.InvalidDelay.selector,
            IHookrRegistry.InvalidRoot.selector,
            IHookrRegistry.DelegatedAccount.selector,
            IHookrRegistry.QueuedBeforeBrake.selector,
            IHookrRegistry.AlreadyQueued.selector,
            IHookrRegistry.QuoteNotBraked.selector,
            IHookrRegistry.Unauthorized.selector,
            IHookrRegistry.NonCanonicalArguments.selector,
            IHookrRegistry.NotAContract.selector,
            IHookrRegistry.InvalidLane.selector,
            IHookrRegistry.RootFrozen.selector,
            IHookrRegistry.CodeHashMismatch.selector,
            IHookrRegistry.MarketsPaused.selector,
            IHookrRegistry.InvalidAdmission.selector,
            IHookrRegistry.AnyQuoteActive.selector,
            IHookrRegistry.OperationExpired.selector,
            IHookrRegistry.AlreadyAdmitted.selector,
            IHookrRegistry.NewMarketsNotPaused.selector,
            IHookrRegistry.NotQueued.selector,
            IHookrRegistry.InvalidAddress.selector
        ];
        bytes4[26] memory wantErrors = [
            bytes4(0x08feb567),
            0x0e1f74ff,
            0x11ba7eac,
            0x276b342b,
            0x367250c6,
            0x3c611650,
            0x4fbe5dba,
            0x504570e3,
            0x517768b2,
            0x6c64b19a,
            0x7ac71869,
            0x7cf621e4,
            0x82b42900,
            0x89d22f70,
            0x8a8b41ec,
            0x98856187,
            0x9bce7758,
            0xa74ed9c0,
            0xa85bd1de,
            0xb26fca82,
            0xbf1380b5,
            0xc8f8797b,
            0xdd523181,
            0xe48698a9,
            0xe58aa1e7,
            0xe6c4247b
        ];
        for (uint256 i; i < errors.length; ++i) {
            assertEq(errors[i], wantErrors[i]);
        }
        // The library raises its own copies of the registry's errors: each has the registry's selector, so a revert
        // from the library decodes against the registry's ABI.
        bytes4[17] memory raised = [
            HookrRegistryChecks.InvalidAddress.selector,
            HookrRegistryChecks.UnknownOperation.selector,
            HookrRegistryChecks.NonCanonicalArguments.selector,
            HookrRegistryChecks.InvalidRoot.selector,
            HookrRegistryChecks.RootFrozen.selector,
            HookrRegistryChecks.AlreadyAdmitted.selector,
            HookrRegistryChecks.InvalidAdmission.selector,
            HookrRegistryChecks.NotAContract.selector,
            HookrRegistryChecks.DelegatedAccount.selector,
            HookrRegistryChecks.NewMarketsNotPaused.selector,
            HookrRegistryChecks.RootNotClosed.selector,
            HookrRegistryChecks.CodeHashMismatch.selector,
            HookrRegistryChecks.AlreadyActive.selector,
            HookrRegistryChecks.InvalidLane.selector,
            HookrRegistryChecks.QuoteClassActive.selector,
            HookrRegistryChecks.AnyQuoteActive.selector,
            HookrRegistryChecks.QuoteNotBraked.selector
        ];
        bytes4[17] memory declared = [
            IHookrRegistry.InvalidAddress.selector,
            IHookrRegistry.UnknownOperation.selector,
            IHookrRegistry.NonCanonicalArguments.selector,
            IHookrRegistry.InvalidRoot.selector,
            IHookrRegistry.RootFrozen.selector,
            IHookrRegistry.AlreadyAdmitted.selector,
            IHookrRegistry.InvalidAdmission.selector,
            IHookrRegistry.NotAContract.selector,
            IHookrRegistry.DelegatedAccount.selector,
            IHookrRegistry.NewMarketsNotPaused.selector,
            IHookrRegistry.RootNotClosed.selector,
            IHookrRegistry.CodeHashMismatch.selector,
            IHookrRegistry.AlreadyActive.selector,
            IHookrRegistry.InvalidLane.selector,
            IHookrRegistry.QuoteClassActive.selector,
            IHookrRegistry.AnyQuoteActive.selector,
            IHookrRegistry.QuoteNotBraked.selector
        ];
        for (uint256 i; i < raised.length; ++i) {
            assertEq(raised[i], declared[i]);
        }
    }
}
