// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrComplianceGuard} from "../../src/compliance/HookrComplianceGuard.sol";
import {IHookrComplianceGuard} from "../../src/interfaces/IHookrComplianceGuard.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {ComplianceTestBase} from "../compliance/ComplianceTestBase.sol";
import {MockRootView} from "../mocks/MockRootView.sol";
import {MockLauncherView} from "../mocks/MockLauncherView.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @notice A launcher view with the launch-buy getter, settable per pool.
contract MockLaunchBuyLauncher {
    mapping(PoolId => bytes32) public poolFamily;
    mapping(bytes32 => address) public familyOwner;
    PoolId public launchBuyPool;

    function setFamily(PoolId id, bytes32 family, address owner) external {
        poolFamily[id] = family;
        familyOwner[family] = owner;
    }

    function setLaunchBuyPool(PoolId id) external {
        launchBuyPool = id;
    }
}

/// @notice A compliance source that permits everyone except while `launcher` has a launch buy swapping: the family
///         owner passes the launch add and is refused at the dev buy.
contract FlipCompliance {
    HookrLauncher internal immutable launcher;

    constructor(HookrLauncher l) {
        launcher = l;
    }

    function list(bytes32) external pure returns (IHookrCompliance.List memory) {
        return IHookrCompliance.List(true, false);
    }

    function check(bytes32, address, uint32, uint32) external view returns (IHookrCompliance.Decision) {
        return PoolId.unwrap(launcher.launchBuyPool()) == bytes32(0)
            ? IHookrCompliance.Decision.ALLOW
            : IHookrCompliance.Decision.NO_CREDENTIAL;
    }

    function sanctionStatus(address) external pure returns (bool, bool) {
        return (false, false);
    }
}

/// @notice DB-02, guard unit. HookrComplianceGuard admits one unauthenticated swap: the launch buy, an exact-input
///         buy its pool's launcher sends while launchBuyPool() names that pool. It screens the family owner, and
///         explainSwap agrees with beforeSwap in every case.
contract LauncherDevBuyLaunchBuyGuardTest is ComplianceTestBase {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant FAMILY = keccak256("family");
    HookrComplianceGuard internal guard;
    MockRootView internal root;
    MockLaunchBuyLauncher internal launcher;
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");
    PoolKey internal key;
    PoolId internal id;

    function setUp() public override {
        super.setUp();
        guard = new HookrComplianceGuard(address(compliance));
        root = new MockRootView(address(0));
        launcher = new MockLaunchBuyLauncher();
        key = PoolKey(
            Currency.wrap(address(0x1000)), Currency.wrap(address(0x2000)), 0x800000, 60, IHooks(address(root))
        );
        id = key.toId();
        launcher.setFamily(id, FAMILY, creator);
        _attest(creator, 1);
        HookrTypes.PoolConfig memory pc;
        pc.subject = key.currency1;
        pc.quote = key.currency0;
        pc.advisory = address(guard);
        pc.liquidityOwner = address(launcher);
        pc.advisoryGasLimit = 200_000;
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP;
        vm.prank(address(root));
        guard.bind(
            key, pc, abi.encode(IHookrComplianceGuard.Terms({listId: LIST, requireAll: 1, blockAny: 0, flags: 1}))
        );
    }

    function _ctx(address sender, bool isBuy, bool exactInput) internal view returns (HookrTypes.SwapContext memory x) {
        x.id = id;
        x.sender = sender;
        x.payer = sender;
        x.beneficiary = sender;
        x.subject = key.currency1;
        x.quote = key.currency0;
        x.isBuy = isBuy;
        x.exactInput = exactInput;
        x.amountSpecified = exactInput ? -1e18 : int256(1e18);
    }

    function _expect(
        HookrTypes.SwapContext memory x,
        bool wantAllowed,
        IHookrComplianceGuard.Reason wantReason,
        IHookrCompliance.Decision wantDecision
    ) internal {
        vm.prank(address(root));
        HookrTypes.Advice memory advice = guard.beforeSwap(x);
        (bool allowed, IHookrComplianceGuard.Reason reason, IHookrCompliance.Decision decision) =
            guard.explainSwap(address(root), x);
        assertEq(advice.reject, !allowed, "beforeSwap and explainSwap agree");
        assertEq(allowed, wantAllowed, "allowed");
        assertEq(uint8(reason), uint8(wantReason), "reason");
        assertEq(uint8(decision), uint8(wantDecision), "decision");
    }

    function test_launchBuyScreensTheFamilyOwner() public {
        launcher.setLaunchBuyPool(id);
        _expect(
            _ctx(address(launcher), true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        launcher.setFamily(id, FAMILY, stranger);
        _expect(
            _ctx(address(launcher), true, true),
            false,
            IHookrComplianceGuard.Reason.LAUNCH_BUY,
            IHookrCompliance.Decision.NO_CREDENTIAL
        );
        _attest(stranger, 1);
        _sanction(stranger, true);
        _expect(
            _ctx(address(launcher), true, true),
            false,
            IHookrComplianceGuard.Reason.LAUNCH_BUY,
            IHookrCompliance.Decision.SANCTIONED
        );
        launcher.setFamily(id, FAMILY, address(0));
        _expect(
            _ctx(address(launcher), true, true),
            false,
            IHookrComplianceGuard.Reason.LAUNCH_BUY,
            IHookrCompliance.Decision.NO_CREDENTIAL
        );
    }

    /// @notice Everything else unauthenticated stays UNAUTHENTICATED: the launcher outside its launch buy, on another
    ///         pool, selling or buying exact output, and any other sender while the launch buy runs.
    function test_everyOtherUnauthenticatedSwapIsRefused() public {
        IHookrComplianceGuard.Reason u = IHookrComplianceGuard.Reason.UNAUTHENTICATED;
        IHookrCompliance.Decision a = IHookrCompliance.Decision.ALLOW;
        _expect(_ctx(address(launcher), true, true), false, u, a);
        launcher.setLaunchBuyPool(PoolId.wrap(bytes32(uint256(1))));
        _expect(_ctx(address(launcher), true, true), false, u, a);
        launcher.setLaunchBuyPool(id);
        _expect(_ctx(address(launcher), false, true), false, u, a);
        _expect(_ctx(address(launcher), true, false), false, u, a);
        _expect(_ctx(stranger, true, true), false, u, a);
        _expect(_ctx(creator, true, true), false, u, a);
    }

    /// @notice A launcher without the launch-buy getter gets no launch buy past the guard.
    function test_launcherWithoutGetterIsRefused() public {
        MockLauncherView old = new MockLauncherView();
        PoolKey memory k2 = key;
        k2.tickSpacing = 120;
        PoolId id2 = k2.toId();
        old.setFamily(id2, FAMILY, creator);
        HookrTypes.PoolConfig memory pc;
        pc.subject = k2.currency1;
        pc.quote = k2.currency0;
        pc.advisory = address(guard);
        pc.liquidityOwner = address(old);
        pc.advisoryGasLimit = 200_000;
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP;
        vm.prank(address(root));
        guard.bind(
            k2, pc, abi.encode(IHookrComplianceGuard.Terms({listId: LIST, requireAll: 1, blockAny: 0, flags: 1}))
        );
        HookrTypes.SwapContext memory x = _ctx(address(old), true, true);
        x.id = id2;
        _expect(x, false, IHookrComplianceGuard.Reason.UNAUTHENTICATED, IHookrCompliance.Decision.ALLOW);
    }
}

/// @notice DB-02, integration: HookrLauncher, HookrRoot, HookrRules and HookrComplianceGuard on one PoolManager. A
///         permitted owner's dev buy passes; a guard whose source refuses the owner only at the swap rejects the dev
///         buy from beforeSwap, after the launch add passed.
contract LauncherDevBuyComplianceTest is DevBuyFixture, ComplianceTestBase {
    using PoolIdLibrary for PoolKey;

    Currency internal constant ETH = Currency.wrap(address(0));
    HookrComplianceGuard internal guard;

    function setUp() public override {
        ComplianceTestBase.setUp();
        _setUpPeriphery();
        guard = new HookrComplianceGuard(address(compliance));
        _admit(address(guard));
    }

    function _admit(address advisory) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: advisory,
            codeHash: advisory.codehash,
            schemaHash: HookrComplianceGuard(advisory).configSchemaHash(),
            caps: HookrTypes.Caps(0, 0, 0),
            gasLimit: 200_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    function _guarded(address advisory)
        internal
        returns (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members, bytes[] memory configs)
    {
        address subject;
        (t, subject) = _newToken(ETH, false);
        members = _one(subject, ETH);
        members[0].config.advisory = advisory;
        members[0].config.advisoryGasLimit = 200_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        configs = new bytes[](1);
        configs[0] = abi.encode(IHookrComplianceGuard.Terms({listId: LIST, requireAll: 1, blockAny: 0, flags: 1}));
    }

    function test_permittedOwnerDevBuyPasses() public {
        _attest(address(this), 1);
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members, bytes[] memory configs) =
            _guarded(address(guard));
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e22, 1, 0);
        vm.expectCall(address(guard), abi.encodeWithSelector(HookrComplianceGuard.beforeSwap.selector));
        (bytes32 family, address subject, uint256 out) =
            launcher.launchWithBuy{value: buy.quoteIn}(t, address(root), members, configs, buy, vm.getBlockTimestamp());
        assertGt(out, 0);
        assertGe(IERC20(subject).balanceOf(address(this)), out);
        assertEq(root.poolConfig(_id(family, 0)).advisory, address(guard));
    }

    /// @notice An owner the guard refuses cannot launch at all: its add is screened first.
    function test_unpermittedOwnerIsRefusedAtTheAdd() public {
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members, bytes[] memory configs) =
            _guarded(address(guard));
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e22, 1, 0);
        vm.expectRevert(
            _hookError(
                IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(IHookrRootState.SwapRejected.selector)
            )
        );
        launcher.launchWithBuy{value: buy.quoteIn}(t, address(root), members, configs, buy, vm.getBlockTimestamp());
    }

    /// @notice The swap branch decides on its own: with a source that refuses the owner only while the dev buy swaps,
    ///         the add passes and the root rejects the dev buy in beforeSwap.
    function test_devBuyRejectedFromBeforeSwap() public {
        HookrComplianceGuard flip = new HookrComplianceGuard(address(new FlipCompliance(launcher)));
        _admit(address(flip));
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members, bytes[] memory configs) =
            _guarded(address(flip));
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e22, 1, 0);
        uint256 snap = vm.snapshotState();
        vm.expectRevert(
            _hookError(IHooks.beforeSwap.selector, abi.encodeWithSelector(IHookrRootState.SwapRejected.selector))
        );
        launcher.launchWithBuy{value: buy.quoteIn}(t, address(root), members, configs, buy, vm.getBlockTimestamp());
        vm.revertToState(snap);
        // The same family launches without the dev buy: the add alone passes the same guard.
        launcher.launchAdvised(t, address(root), members, configs, vm.getBlockTimestamp());
    }

    /// @notice After the launch, a Launcher-less unauthenticated buy on the guarded pool is still refused.
    function test_directUnauthenticatedBuyStillRefused() public {
        _attest(address(this), 1);
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members, bytes[] memory configs) =
            _guarded(address(guard));
        (bytes32 family,,) = launcher.launchWithBuy{value: 1e22}(
            t, address(root), members, configs, IHookrLauncher.DevBuy(0, 1e22, 1, 0), vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(family, 0).key;
        HookrTypes.SwapContext memory x;
        x.id = key.toId();
        x.sender = address(launcher);
        x.payer = address(launcher);
        x.beneficiary = address(launcher);
        x.isBuy = true;
        x.exactInput = true;
        (bool allowed, IHookrComplianceGuard.Reason reason,) = guard.explainSwap(address(root), x);
        assertFalse(allowed, "no launch buy outside launchWithBuy");
        assertEq(uint8(reason), uint8(IHookrComplianceGuard.Reason.UNAUTHENTICATED));
    }
}
