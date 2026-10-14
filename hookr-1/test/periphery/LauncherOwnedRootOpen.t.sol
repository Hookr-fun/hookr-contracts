// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {MockOwnedRootFactory} from "../mocks/MockOwnedRootFactory.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";

/// @dev Launches as its caller would: the launcher's caller is this contract, whatever account calls it.
contract LaunchRelay {
    function launch(HookrLauncher launcher, address root, IHookrLauncher.Member[] calldata members, address subject)
        external
        payable
    {
        IERC20Like(subject).approve(address(launcher), type(uint256).max);
        launcher.launch{value: msg.value}(
            IHookrLauncher.Token(subject, "", "", 0, bytes32(0)), root, members, block.timestamp
        );
    }
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice The launcher opens a family only when the registry's rootOpenFor(root, caller) holds (owned roots decision
///         4): on a root that is not owned that is rootOpen, so every launch behaves as before; on an owned root the
///         registry also asks the root's factory (IHookrRootRegistrar.mayOpen) for the launcher's own caller, so a
///         public owned root opens for anyone, an owner-only one for its owner only, a root its owner paused for
///         nobody, and a factory answer that reverts, is short, long or dirty, or burns the probe's gas closes it. The
///         registry's brakes close every root as before. Owned roots here come from L1's MockOwnedRootFactory, which
///         registers an unmodified HookrRoot through the registry's registrar entry; the real factory repeats these
///         cases after the merge.
contract LauncherOwnedRootOpenTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    address internal guardian = address(0x6A7D);
    address internal brand = address(0xB4A9D);
    address internal stranger = address(0x5757);
    MockOwnedRootFactory internal factory;
    uint256 internal nextSalt = 1 << 128;
    int24 internal nextSpacing = 10;

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        factory = new MockOwnedRootFactory(IHookrOwnedRoots(address(registry)));
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        address[3] memory launchers = [brand, stranger, address(this)];
        for (uint256 i; i < launchers.length; ++i) {
            tokenA.transfer(launchers[i], 1e27);
            vm.deal(launchers[i], 1e27);
            vm.prank(launchers[i]);
            tokenA.approve(address(launcher), type(uint256).max);
        }
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev An unmodified HookrRoot at a fresh CREATE2 address carrying the root's permission flags.
    function _deployRoot() internal returns (HookrRoot r) {
        bytes32 initHash = ReleaseWiring.rootInitHash(manager, registry, address(router), address(quoter), address(0));
        uint256 counter = ReleaseWiring.mineSalt(address(this), initHash, ReleaseWiring.ROOT_FLAGS, nextSalt);
        nextSalt = counter + 1;
        r = new HookrRoot{salt: bytes32(counter)}(manager, registry, address(router), address(quoter), address(0));
    }

    /// @dev Registers a fresh owned root through the mock factory, owned by `brand`, with its companion Rules taking
    ///      the template Rules' RULES terms.
    function _register(bool ownerOnly) internal returns (address r, address companion) {
        HookrRoot owned = _deployRoot();
        HookrRules rulesOf = new HookrRules(manager, registry, protocol, address(owned), 0);
        IHookrRegistry.Admission memory a = registry.admission(address(root), address(rules));
        a.implementation = address(rulesOf);
        a.codeHash = address(rulesOf).codehash;
        factory.register(address(owned), address(root), address(rules), a, new address[](0), brand, ownerOnly);
        return (address(owned), address(rulesOf));
    }

    /// @dev One native-quote member of tokenA with the Rules `companion`, at a tick spacing no earlier launch used, so
    ///      every launch here opens a fresh pool, over the widest range within ticks -60,000 to 60,000 that spacing
    ///      aligns.
    function _members(address companion) internal returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.rules = companion;
        int24 spacing = nextSpacing;
        members[0].tickSpacing = spacing;
        members[0].tickLower = -(60_000 / spacing) * spacing;
        members[0].tickUpper = (60_000 / spacing) * spacing;
        nextSpacing += 10;
    }

    function _launchAs(address caller, address r, address companion) internal returns (bytes32 family) {
        IHookrLauncher.Member[] memory members = _members(companion);
        vm.prank(caller);
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), r, members, vm.getBlockTimestamp()
        );
    }

    function _expectRefusedAs(address caller, address r, address companion) internal {
        IHookrLauncher.Member[] memory members = _members(companion);
        vm.prank(caller);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), r, members, vm.getBlockTimestamp()
        );
    }

    /// @dev launchFamily's input for one member on `r`, with no knobs, buys or opening check.
    function _family(address r, address companion) internal returns (IHookrLauncher.LaunchParams memory p) {
        p.token = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        p.root = r;
        p.members = _members(companion);
        p.knobs = new IHookrLauncher.MemberKnobs[](1);
        p.advisoryConfigs = new bytes[](1);
        p.maxRetainedBps = 10_000;
        p.deadline = vm.getBlockTimestamp();
    }

    // ───────────────────────────── roots that are not owned ─────────────────────────────

    /// The shared root opens for every caller, as before: rootOpenFor equals rootOpen there, and the launcher asks the
    /// registry exactly rootOpenFor(root, caller).
    function test_aRootThatIsNotOwnedOpensForEveryCaller() public {
        address[3] memory callers = [brand, stranger, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            assertEq(registry.rootOpenFor(address(root), callers[i]), registry.rootOpen(address(root)));
            vm.expectCall(
                address(registry), abi.encodeCall(IHookrOwnedRoots.rootOpenFor, (address(root), callers[i])), 1
            );
            bytes32 family = _launchAs(callers[i], address(root), address(rules));
            assertEq(launcher.familyOwner(family), callers[i]);
        }
    }

    /// The registry's brakes close the shared root and owned roots alike, for every caller.
    function test_registryBrakesCloseEveryRoot() public {
        (address owned, address companion) = _register(false);
        vm.prank(guardian);
        registry.pauseNewMarkets();
        _expectRefusedAs(brand, address(root), address(rules));
        _expectRefusedAs(brand, owned, companion);
        _expectRefusedAs(stranger, owned, companion);
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.resumeNewMarkets();
        _launchAs(stranger, owned, companion);

        vm.prank(guardian);
        registry.closeRoot(owned);
        _expectRefusedAs(brand, owned, companion);
        _launchAs(brand, address(root), address(rules));
    }

    // ───────────────────────────── owned roots ─────────────────────────────

    /// A public owned root opens for anyone, its owner included.
    function test_aPublicOwnedRootOpensForAnyone() public {
        (address owned, address companion) = _register(false);
        bytes32 family = _launchAs(stranger, owned, companion);
        assertEq(launcher.familyOwner(family), stranger);
        assertEq(address(launcher.position(family, 0).key.hooks), owned);
        family = _launchAs(brand, owned, companion);
        assertEq(launcher.familyOwner(family), brand);
    }

    /// An owner-only owned root opens for its owner only: a stranger is refused although rootOpen, which the launcher
    /// asked before, reads open for the root.
    function test_anOwnerOnlyOwnedRootOpensForItsOwnerOnly() public {
        (address owned, address companion) = _register(true);
        assertTrue(registry.rootOpen(owned), "rootOpen alone would let a stranger in");
        assertFalse(registry.rootOpenFor(owned, stranger));
        _expectRefusedAs(stranger, owned, companion);
        _expectRefusedAs(address(this), owned, companion);
        bytes32 family = _launchAs(brand, owned, companion);
        assertEq(launcher.familyOwner(family), brand);
    }

    /// launchFamily asks the same question for its caller.
    function test_launchFamilyAsksTheRootForItsCaller() public {
        (address owned, address companion) = _register(true);
        IHookrLauncher.LaunchParams memory p = _family(owned, companion);
        vm.prank(stranger);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.launchFamily{value: 1e24}(p);
        p = _family(owned, companion);
        vm.prank(brand);
        (bytes32 family,,) = launcher.launchFamily{value: 1e24}(p);
        assertEq(launcher.familyOwner(family), brand);
    }

    /// The opener is the launcher's own caller, never the transaction's origin: the owner calling through a contract
    /// is that contract, refused on an owner-only root, and a stranger whose transaction the owner originated is
    /// refused too.
    function test_theOpenerIsTheLaunchersCaller() public {
        (address owned, address companion) = _register(true);
        LaunchRelay relay = new LaunchRelay();
        tokenA.transfer(address(relay), 1e27);
        IHookrLauncher.Member[] memory members = _members(companion);
        vm.prank(brand, brand);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        relay.launch{value: 1e24}(launcher, owned, members, address(tokenA));

        members = _members(companion);
        vm.prank(stranger, brand);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), owned, members, vm.getBlockTimestamp()
        );
    }

    /// A root its owner paused opens for nobody until the owner lifts the pause.
    function test_aPausedOwnedRootOpensForNobody() public {
        (address owned, address companion) = _register(false);
        factory.setPaused(owned, true);
        _expectRefusedAs(brand, owned, companion);
        _expectRefusedAs(stranger, owned, companion);
        factory.setPaused(owned, false);
        _launchAs(stranger, owned, companion);
    }

    /// A factory answer that reverts, is short, long or dirty, or burns the probe's gas reads as closed, for the owner
    /// too; a clean answer opens the root again.
    function test_aBadRegistrarAnswerClosesTheRoot() public {
        (address owned, address companion) = _register(false);
        MockOwnedRootFactory.Answer[5] memory bad = [
            MockOwnedRootFactory.Answer.REVERT,
            MockOwnedRootFactory.Answer.SHORT,
            MockOwnedRootFactory.Answer.LONG,
            MockOwnedRootFactory.Answer.DIRTY,
            MockOwnedRootFactory.Answer.BURN
        ];
        for (uint256 i; i < bad.length; ++i) {
            factory.setAnswer(bad[i]);
            assertTrue(registry.rootOpen(owned));
            _expectRefusedAs(brand, owned, companion);
            _expectRefusedAs(stranger, owned, companion);
        }
        factory.setAnswer(MockOwnedRootFactory.Answer.POLICY);
        _launchAs(stranger, owned, companion);
    }

    /// A deactivated factory stops registering roots, not answering for them: its roots keep their opening policy.
    function test_aDeactivatedFactoryStillAnswersForItsRoots() public {
        (address publicRoot, address publicRules) = _register(false);
        (address ownerOnly, address ownerRules) = _register(true);
        vm.prank(guardian);
        registry.deactivateRootFactory(address(factory));
        _launchAs(stranger, publicRoot, publicRules);
        _expectRefusedAs(stranger, ownerOnly, ownerRules);
        _launchAs(brand, ownerOnly, ownerRules);
    }
}
