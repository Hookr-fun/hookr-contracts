// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {EntryPointV07Code} from "../gasless/EntryPointV07Code.sol";
import {SysAccount, ISysEntryPoint} from "../invariant/SystemHelpers.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {LaneExecutorStub} from "../utils/LaneExecutorStub.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @dev A PoolManager locker that syncs `synced` inside its own unlock and then swaps, so the sync is its own and still
///      open while it swaps. It never settles: the controls below expect the swap to revert.
contract SyncThenSwapLocker is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function go(PoolKey calldata key, Currency synced, SwapParams calldata params) external {
        manager.unlock(abi.encode(key, synced, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert();
        (PoolKey memory key, Currency synced, SwapParams memory params) =
            abi.decode(data, (PoolKey, Currency, SwapParams));
        manager.sync(synced);
        manager.swap(key, params, "");
        return "";
    }
}

/// @notice SYS-01 (09-24 audit, gap-lens, Low): `PoolManager.sync` needs no unlock, so a sync left by an earlier call
///         in the same transaction, or by an earlier operation in the same ERC-4337 bundle, made every later burning
///         buy through HookrRouter revert, and a sponsored operation still paid its gas.
/// @dev Regression for the fix. HookrRoot refuses the Auto Burn take while the subject is synced
///      (`UnsupportedBurnSync`), since a take of a synced currency would corrupt its syncer's settlement; the root
///      cannot tell a stale sync from its caller's own, so that refusal stays. HookrRouter.unlockCallback and
///      HookrQuoter.simulate now clear a synced currency before they swap: neither has a sync of its own open there.
///      Exits and Launcher adds were never affected (SystemHandler `staleSyncThen`).
contract HookrRootStaleSyncBurningBuyTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    address internal constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address payable internal constant BUNDLER = payable(address(0xB0B));
    bytes32 internal constant USER_OP_EVENT =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");

    PoolKey private key;
    Currency private subject;

    function setUp() public {
        _setUpPeriphery();
        // A native-quoted pool with Auto Burn (100 bps): every exact-input buy burns subject.
        (, key,,) = _launch(true, true);
        subject = root.poolConfig(key.toId()).subject;
    }

    function _buy(uint128 amount) private view returns (IHookrRouter.Swap memory p) {
        p = _swap(key, true, true, amount);
    }

    /// @dev One transaction: a stranger's sync of the subject, then an ordinary router buy, which clears the sync and
    ///      burns as on any other buy.
    function testAStrangersSyncNoLongerBlocksABurningBuy() public {
        vm.prank(address(0xBAD5));
        manager.sync(subject);
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), Currency.unwrap(subject), "the subject is synced");
        uint256 deadBefore = subject.balanceOf(root.DEAD());
        uint256 heldBefore = subject.balanceOf(trader);
        IHookrRouter.Swap memory p = _buy(1e18);
        vm.prank(trader);
        (, uint256 amountOut) = router.swap{value: 1e18}(p, address(0), new uint256[](0));
        assertGt(amountOut, 0, "the buy cleared");
        assertEq(subject.balanceOf(trader) - heldBefore, amountOut, "and paid the trader");
        assertGt(subject.balanceOf(root.DEAD()), deadBefore, "with its burn");
    }

    /// @dev A quote in the same transaction runs as the buy would: its simulation clears the sync, the clearing reverts
    ///      with the simulation, and the router's buy then delivers exactly the quoted amounts.
    function testTheQuoteClearsTheSyncInsideItsSimulationOnly() public {
        vm.prank(address(0xBAD5));
        manager.sync(subject);
        IHookrRouter.Swap memory p = _buy(1e18);
        HookrTypes.ExecutionReceipt memory receipt = quoter.quote(p, trader);
        assertGt(receipt.subjectBurn, 0, "the quoted buy burns");
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), Currency.unwrap(subject), "the sync outlives the quote");
        vm.prank(trader);
        (uint256 amountIn, uint256 amountOut) = router.swap{value: 1e18}(p, address(0), new uint256[](0));
        assertEq(amountIn, receipt.inputAmount, "the buy pays the quoted input");
        assertEq(amountOut, receipt.outputAmount, "and delivers the quoted output");
    }

    /// @dev The root's refusal stands for a caller whose own sync of the subject is open while it buys: only the
    ///      router and the quoter, which never have one open at that point, clear it.
    function testTheRootStillRefusesABuyWhileItsCallersOwnSyncIsOpen() public {
        SyncThenSwapLocker locker = new SyncThenSwapLocker(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(root),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(IHookrRootState.UnsupportedBurnSync.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        locker.go(key, subject, SwapParams(true, -1e18, MIN_PRICE));
    }

    /// @dev One ERC-4337 bundle on the canonical v0.7 EntryPoint runtime: an attacker's operation syncs the subject,
    ///      and the victim's later router buy in the same bundle still clears and delivers.
    function testAnEarlierOperationInTheBundleNoLongerFailsTheVictimsBuy() public {
        vm.etch(EP, EntryPointV07Code.RUNTIME);
        assertEq(EP.codehash, EntryPointV07Code.CODEHASH);
        SysAccount attacker = new SysAccount(EP, address(this));
        SysAccount victim = new SysAccount(EP, address(this));
        vm.deal(address(attacker), 1 ether);
        vm.deal(address(victim), 2 ether);

        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _op(attacker, address(manager), 0, abi.encodeCall(manager.sync, (subject)));
        IHookrRouter.Swap memory p = _buy(1e18);
        p.recipient = address(victim);
        ops[1] = _op(victim, address(router), 1e18, abi.encodeCall(router.swap, (p, address(0), new uint256[](0))));

        vm.recordLogs();
        vm.prank(BUNDLER, BUNDLER);
        ISysEntryPoint(EP).handleOps{gas: 10_000_000}(ops, BUNDLER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_succeeded(logs, address(attacker)), "the attacker's sync operation succeeds");
        assertTrue(_succeeded(logs, address(victim)), "the victim's buy succeeds after it");
        assertGt(subject.balanceOf(address(victim)), 0, "and delivers the subject");
    }

    function _op(SysAccount who, address dest, uint256 value, bytes memory call)
        private
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(who);
        op.nonce = ISysEntryPoint(EP).getNonce(address(who), 0);
        op.callData = abi.encodeCall(SysAccount.execute, (dest, value, call));
        op.accountGasLimits = bytes32((uint256(200_000) << 128) | uint256(3_000_000));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
    }

    function _succeeded(Vm.Log[] memory logs, address sender) private pure returns (bool success) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != EP || logs[i].topics[0] != USER_OP_EVENT) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != sender) continue;
            (, success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
            return success;
        }
        revert("no UserOperationEvent");
    }
}

/// @notice SYS-01 on a pool whose arb recapture lane is on: the lane refuses to run its frame while any currency is
///         synced (`SyncPending`), which reverts the swap. A stale sync of an unrelated currency therefore used to fail
///         every router swap on such a pool; the router now clears it first and the lane runs.
/// @dev The lane's executor is a stand-in with no `executeArbitrage`, so each frame fails open (`CorrectionFailed`) and
///      the swap goes on; that event shows the lane ran past its sync check.
contract HookrRootStaleSyncLanePoolTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    bytes32 internal constant FAILED = keccak256("CorrectionFailed(bytes32,uint8,address,bytes4)");
    /// @dev WTH's production share, at which every stand-in lane opens.
    uint16 internal constant PARTNER_BPS = 2_500;

    PoolKey private key;
    Currency private stray;

    function setUp() public {
        _setUpPeriphery();
        ArbSysKit.install(vm, ArbSysKit.L2_BASE, vm.getBlockNumber());
        LaneExecutorStub exec = new LaneExecutorStub(PARTNER_BPS);
        registry.queue(
            OPEN_LANE, abi.encode(address(root), address(exec), address(exec).codehash, uint32(600_000), PARTNER_BPS)
        );
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, 600_000, PARTNER_BPS);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        (members[0].recapture,) = IHookrRecaptureRules(address(rules)).recaptureDefaults();
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        // A currency outside the pool: any synced currency stops the lane.
        stray = Currency.wrap(address(tokenB));
    }

    /// @dev One transaction: a stranger's sync of a currency outside the pool, then a router buy on the lane pool, which
    ///      clears the sync and runs the lane.
    function testAStrangersSyncNoLongerBlocksASwapOnALanePool() public {
        vm.prank(address(0xBAD5));
        manager.sync(stray);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        vm.recordLogs();
        vm.prank(trader);
        (, uint256 amountOut) = router.swap{value: 1e18}(p, address(0), new uint256[](0));
        assertGt(amountOut, 0, "the swap cleared");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 frames;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(root) && logs[i].topics[0] == FAILED) ++frames;
        }
        assertGt(frames, 0, "the lane ran its frame past the sync check");
    }

    /// @dev The lane's refusal stands for a caller whose own sync is open while it swaps.
    function testTheLaneStillRefusesASwapWhileItsCallersOwnSyncIsOpen() public {
        SyncThenSwapLocker locker = new SyncThenSwapLocker(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(root),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IHookrLaneEvents.SyncPending.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        locker.go(key, stray, SwapParams(true, -1e18, MIN_PRICE));
    }
}
