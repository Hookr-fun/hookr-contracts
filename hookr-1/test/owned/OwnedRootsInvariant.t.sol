// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrOwnedRootFactory} from "../../src/owned/HookrOwnedRootFactory.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice Drives self-serve deployments (public and owner-only, with and without Auto Burn, each paying the fee), pool
///         opens by whoever may open them, trades, the owners' pauses, the registry's close brake and the treasury's
///         collections by provenance, across owned roots and the shared root.
contract OwnedRootsHandler is Test {
    Currency internal constant ETH = Currency.wrap(address(0));
    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;

    HookrRegistry public immutable registry;
    HookrOwnedRootFactory public immutable factory;
    IHookrOwnedProfiles public immutable book;
    HookrLauncher public immutable launcher;
    HookrRouter public immutable router;
    HookrTreasury public immutable treasury;
    bytes32 public immutable profileId;
    address public immutable operator;
    address public trader = address(0x7A7A);
    address[3] public brands;
    mapping(address => bytes32[]) internal salts;
    mapping(address => uint256) internal nextSalt;
    address[] public roots;
    PoolKey[] internal pools;
    mapping(address => bool) public closed;
    mapping(address => bool) public paused;
    uint256 public nonce;
    uint256 public deploys;
    uint256 public opens;
    uint256 public trades;
    uint256 public feesPaid;
    uint256 public collected;

    constructor(
        HookrRegistry registry_,
        HookrOwnedRootFactory factory_,
        HookrLauncher launcher_,
        HookrRouter router_,
        HookrTreasury treasury_,
        bytes32 profileId_,
        address[3] memory brands_,
        bytes32[][3] memory salts_,
        PoolKey memory sharedPool
    ) {
        registry = registry_;
        factory = factory_;
        book = factory_.profiles();
        launcher = launcher_;
        router = router_;
        treasury = treasury_;
        profileId = profileId_;
        operator = registry_.owner();
        brands = brands_;
        for (uint256 i; i < 3; ++i) {
            salts[brands_[i]] = salts_[i];
            vm.deal(brands_[i], 1e30);
        }
        vm.deal(trader, 1e30);
        pools.push(sharedPool);
    }

    function rootsLength() external view returns (uint256) {
        return roots.length;
    }

    /// @dev A brand deploys a root of its own from the standard profile, paying the fee.
    function deploy(uint256 brandSeed, bool noBurn, bool ownerOnly) external {
        address brand = brands[brandSeed % 3];
        uint256 k = nextSalt[brand];
        if (k >= salts[brand].length) return;
        nextSalt[brand] = k + 1;
        IHookrOwnedRootFactory.RootSelections memory sel = IHookrOwnedRootFactory.RootSelections({
            profileId: profileId,
            profileVersion: book.profile(profileId).version,
            ruleMask: noBurn ? F.SOFT_FEATURES : F.ALL_FEATURES,
            publicOpening: !ownerOnly,
            owner: brand
        });
        uint256 fee = factory.deployFee();
        vm.prank(brand);
        address r = factory.deploy{value: fee}(
            type(HookrRoot).creationCode, type(HookrRules).creationCode, sel, salts[brand][k]
        );
        roots.push(r);
        feesPaid += fee;
        ++deploys;
    }

    /// @dev Someone opens a pool on an owned root: anyone on a public root, its owner on an owner-only one; never on a
    ///      root the registry closed or its owner paused.
    function open(uint256 rootSeed, address someone) external {
        if (roots.length == 0) return;
        address r = roots[rootSeed % roots.length];
        if (closed[r] || paused[r]) return;
        IHookrOwnedRootFactory.OwnedRoot memory o = factory.ownedRoot(r);
        HookrTypes.RulesConfig memory c;
        c.maxFeePips = 3000;
        c.protocolShareBps = 2500;
        if (o.ruleMask & F.LP_REWARDS != 0) c.lpBps = 200;
        if (o.ruleMask & F.AUTO_BURN != 0) c.burnBps = 100;
        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
        ms[0].quote = ETH;
        ms[0].tickSpacing = 60;
        ms[0].sqrtPriceX96 = uint160(1 << 96);
        ms[0].tickLower = -60_000;
        ms[0].tickUpper = 60_000;
        ms[0].liquidity = 1e22;
        ms[0].amount0Max = 1e22;
        ms[0].amount1Max = 1e22;
        ms[0].config.rules = o.rules;
        ms[0].config.baseLpFeePips = 3000;
        ms[0].config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        ms[0].config.rulesGasLimit = 2_000_000;
        ms[0].rules = c;
        // Any account without code except the trader, whose sells must stay small (an opener receives the new token's
        // unused supply), and except forge's console address, which has no code but refuses the launcher's refund.
        address opener = someone.code.length == 0 && uint160(someone) > 1024 && someone != trader
            && someone != address(0x000000000000000000636F6e736F6c652e6c6f67)
            ? someone
            : address(0x0FE7);
        if (!o.publicOpening) opener = o.owner;
        vm.deal(opener, opener.balance + 1e22);
        vm.prank(opener);
        (bytes32 family,) = launcher.launch{value: 1e22}(
            IHookrLauncher.Token(address(0), "I", "I", 1e27, bytes32(++nonce)), r, ms, block.timestamp
        );
        pools.push(launcher.position(family, 0).key);
        ++opens;
    }

    function trade(uint256 poolSeed, bool buy, uint256 amountSeed) external {
        PoolKey memory key = pools[poolSeed % pools.length];
        HookrToken subject = HookrToken(Currency.unwrap(key.currency1));
        uint256 amount;
        if (buy) {
            amount = bound(amountSeed, 1e9, 1e20);
        } else {
            uint256 held = subject.balanceOf(trader);
            if (held < 2e9) return;
            amount = bound(amountSeed, 1e9, held / 2 < 1e20 ? held / 2 : 1e20);
            vm.prank(trader);
            subject.approve(address(router), type(uint256).max);
        }
        IHookrRouter.Swap memory p = IHookrRouter.Swap(
            key, buy, -int128(uint128(amount)), 1, buy ? MIN_PRICE : MAX_PRICE, trader, block.timestamp
        );
        vm.prank(trader);
        router.swap{value: buy ? amount : 0}(p, address(0), new uint256[](0));
        ++trades;
    }

    /// @dev The owner of record pauses, or resumes, new pools on its root.
    function pause(uint256 rootSeed, bool on) external {
        if (roots.length == 0) return;
        address r = roots[rootSeed % roots.length];
        vm.prank(factory.ownedRoot(r).owner);
        factory.setPaused(r, on);
        paused[r] = on;
    }

    /// @dev The registry's instant brake on one owned root.
    function close(uint256 rootSeed) external {
        if (roots.length == 0) return;
        address r = roots[rootSeed % roots.length];
        if (closed[r]) return;
        vm.prank(operator);
        registry.closeRoot(r);
        closed[r] = true;
    }

    /// @dev Anyone collects the treasury's claim from a root's companion: admitted by provenance on the first
    ///      collection.
    function collect(uint256 rootSeed) external {
        if (roots.length == 0) return;
        address companion = factory.rulesOf(roots[rootSeed % roots.length]);
        collected += treasury.collect(companion, ETH);
    }
}

/// @notice Invariants of owned roots under random self-serve deployments, opens, trades, pauses, closes and
///         collections.
contract OwnedRootsInvariantTest is OwnedRootsFixture {
    OwnedRootsHandler internal handler;
    uint256 internal targetStart;
    address internal executor;

    function setUp() public {
        _setUpOwned();
        // The shared root's lane is open, so every owned root carries a braked copy of it.
        executor = address(new InvariantIdleExecutor());
        registry.queue(
            keccak256("OPEN_LANE"),
            abi.encode(address(root), executor, executor.codehash, uint32(600_000), uint16(2_500))
        );
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.openLaneOf(address(root), executor, executor.codehash, 600_000, 2_500);
        (, PoolKey memory sharedPool,) = _launchAs(trader, address(root), _nativeMember(address(sharedRules), _rc(), 0));
        address[3] memory brands = [address(0xA1A1), address(0xA2A2), address(0xA3A3)];
        bytes32[][3] memory salts;
        for (uint256 i; i < 3; ++i) {
            salts[i] = new bytes32[](3);
            uint256 start = uint256(uint160(brands[i])) << 64;
            for (uint256 j; j < 3; ++j) {
                salts[i][j] = _mineFor(address(factory), brands[i], start);
                start = uint256(salts[i][j]) + 1;
            }
        }
        handler = new OwnedRootsHandler(
            registry, factory, launcher, router, hookrTreasury, templateProfile, brands, salts, sharedPool
        );
        targetStart = TARGET.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = OwnedRootsHandler.deploy.selector;
        selectors[1] = OwnedRootsHandler.open.selector;
        selectors[2] = OwnedRootsHandler.open.selector;
        selectors[3] = OwnedRootsHandler.trade.selector;
        selectors[4] = OwnedRootsHandler.trade.selector;
        selectors[5] = OwnedRootsHandler.trade.selector;
        selectors[6] = OwnedRootsHandler.pause.selector;
        selectors[7] = OwnedRootsHandler.close.selector;
        selectors[8] = OwnedRootsHandler.collect.selector;
        selectors[9] = OwnedRootsHandler.collect.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice allDeployments is exactly the set of roots the handler deployed; each is an owned root of this factory
    ///         on the shared template, registered frozen with its companion as its only RULES admission, at the class
    ///         flags, with the template's lane copied braked.
    function invariant_enumerationIsTheRegisteredSetAndEachRootIsFrozen() public view {
        uint256 n = factory.allDeploymentsLength();
        assertEq(n, handler.rootsLength());
        assertEq(n, handler.deploys());
        IHookrOwnedRoots o = IHookrOwnedRoots(address(registry));
        for (uint256 i; i < n; ++i) {
            address r = factory.allDeployments(i);
            assertEq(r, handler.roots(i));
            assertTrue(registry.isRoot(r));
            assertTrue(o.isOwnedRoot(r));
            assertEq(o.ownedRootTemplate(r), address(root));
            assertEq(o.ownedRegistrarForRoot(r), address(factory));
            assertEq(registry.rootFactoryOf(r), address(0));
            assertTrue(registry.rootFrozen(r));
            assertEq(uint160(r) & Hooks.ALL_HOOK_MASK, CLASS);
            address companion = factory.rulesOf(r);
            assertEq(registry.admission(r, companion).implementation, companion);
            assertEq(registry.admission(r, address(sharedRules)).implementation, address(0));
            assertEq(HookrRules(companion).trustedRoot(), r);
            assertEq(HookrRules(companion).protocolRecipient(), address(hookrTreasury));
            assertEq(HookrRules(companion).minProtocolShareBps(), PROTOCOL_FLOOR);
            (address active,,,) = IHookrLanes(address(registry)).activeLaneOf(r);
            assertEq(active, address(0), "the copied lane stays braked: no timelocked opening ran");
            (bool on, uint32 cap) = IHookrLanes(address(registry)).executorLane(r, executor);
            assertFalse(on);
            assertEq(cap, 600_000);
        }
    }

    /// @notice Every Rules ledger, shared and owned, is backed by PoolManager claims.
    function invariant_everyLedgerIsBacked() public view {
        assertTrue(sharedRules.accountingInvariant(ETH));
        uint256 n = factory.allDeploymentsLength();
        for (uint256 i; i < n; ++i) {
            assertTrue(HookrRules(factory.rulesOf(factory.allDeployments(i))).accountingInvariant(ETH));
        }
    }

    /// @notice The owned-root surface custodies nothing, and the treasury's target received exactly every deploy fee
    ///         and every collection.
    function invariant_noCustodyAndEveryWeiReachesTheTarget() public view {
        assertEq(address(factory).balance, 0);
        assertEq(address(book).balance, 0);
        assertEq(address(lens).balance, 0);
        assertEq(address(registry).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(address(launcher).balance, 0);
        assertEq(address(hookrTreasury).balance, 0);
        assertEq(TARGET.balance - targetStart, handler.feesPaid() + handler.collected());
    }

    /// @notice A closed owned root stays closed to new pools, a paused one opens for nobody, and the shared root is
    ///         never touched.
    function invariant_brakesHoldAndTheSharedRootIsUnchanged() public view {
        IHookrOwnedRoots o = IHookrOwnedRoots(address(registry));
        uint256 n = factory.allDeploymentsLength();
        for (uint256 i; i < n; ++i) {
            address r = factory.allDeployments(i);
            if (handler.closed(r)) assertFalse(registry.rootOpen(r));
            if (handler.paused(r)) {
                address owner_ = factory.ownedRoot(r).owner;
                assertFalse(factory.mayOpen(r, owner_));
                assertFalse(o.rootOpenFor(r, owner_));
            }
        }
        assertTrue(registry.rootOpen(address(root)));
        assertFalse(registry.rootFrozen(address(root)));
        assertFalse(o.isOwnedRoot(address(root)));
        assertEq(registry.admission(address(root), address(sharedRules)).codeHash, address(sharedRules).codehash);
        (address active,,,) = IHookrLanes(address(registry)).activeLaneOf(address(root));
        assertEq(active, executor);
    }

    function afterInvariant() public view {
        assertLe(handler.deploys(), 9);
        console2.log("deploys", handler.deploys(), "opens", handler.opens());
        console2.log("trades", handler.trades(), "collected", handler.collected());
    }
}

/// @notice A lane executor that does nothing on each lane call.
contract InvariantIdleExecutor {
    function executeArbitrage(PoolKey calldata, address) external pure returns (uint256) {
        return 0;
    }
}
