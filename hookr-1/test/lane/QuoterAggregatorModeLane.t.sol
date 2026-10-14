// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrQuoter} from "../../src/interfaces/IHookrQuoter.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {IHookrSwapGate} from "../../src/interfaces/IHookrSwapGate.sol";
import {IHookrFamilyRouter} from "../../src/interfaces/IHookrFamilyRouter.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {HookrFamilyRouter} from "../../src/periphery/HookrFamilyRouter.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

interface IPermit2Lane {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IUniversalRouterLane {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Deploys the forwarder and the router it pins in one call, so the router's CREATE address is known before the
///      forwarder that names it exists, whatever the test's transaction model.
contract RelayPairDeployer {
    function deploy(address permit2, IHookrRegistry registry, IPoolManager manager)
        external
        returns (HookrForwarder fwd, HookrRouter router)
    {
        // This contract's second CREATE (nonce 2).
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), address(this), bytes1(0x02)))))
        );
        fwd = new HookrForwarder(permit2, address(registry), predicted);
        router = new HookrRouter(manager, registry, address(fwd));
        require(address(router) == predicted, "router prediction");
    }
}

/// @dev A direct PoolManager locker that passes its own hook data with the swap, the way a quote-mode flag would
///      travel.
contract LaneHookDataLocker is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) external {
        manager.unlock(abi.encode(key, params, hookData));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams, bytes));
        manager.swap(key, params, hookData);
        return "";
    }
}

/// @dev An admitted gate that vouches for whatever payer its caller names.
contract LaneOpenGate is IHookrSwapGate {
    function beforeUnlock(address, address, PoolKey calldata, bool, int256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHookrSwapGate.beforeUnlock.selector;
    }
}

/// @notice HookrQuoter's aggregator quote mode on an arb recapture pool, with the release's shape: the real 4663
///         PoolManager, Universal Router 2.1.1 (the root's curated router) and Permit2 runtimes, a router with its
///         forwarder, and the two-venue executor recapturing against a hookless reference venue in both phases.
///         Isolated (the lane profile's `isolate = true`), so every top-level call is its own transaction, as the
///         lane's transient frames need. (1) With the before-phase moving the price, the detailed quote and the
///         V4Quoter shape equal HookrRouter execution to the wei in all four shapes, and the quoted trader claim is
///         execution's RecaptureSplit traderAmount; the V4Quoter shape from the Universal Router's address equals its
///         execution; (2) gasEstimate is logged beside execution's gas; (3) a quote leaves no state; (4) every
///         executing path (the router's swap, the forwarder's relayed swapFor, the router's gated swapGated, every leg
///         of a HookrFamilyRouter trade, the Universal Router, a direct PoolManager locker) runs both arb recapture
///         phases around the swap, and a locker's quote-mode flag in hook data is refused.
contract QuoterAggregatorModeLaneTest is LaneFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant POOL_SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal constant RELAYER = address(0xE1A);
    uint128 internal constant AMOUNT = 2e22;

    address internal ur;
    address internal permit2;
    address internal owner;
    HookrForwarder internal fwd;
    TwoVenueExecutor internal arb;
    PoolKey internal key;
    Currency internal subject;

    /// @dev Universal Router 2.1.1's SWAP_EXACT_IN_SINGLE parameters.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @dev What the quotes and the execution of one shape returned.
    struct Observed {
        HookrTypes.ExecutionReceipt receipt;
        uint256 claim;
        uint256 detailedGas;
        uint256 single;
        uint256 singleGas;
        uint256 amountIn;
        uint256 amountOut;
        uint256 executionGas;
        Vm.Log[] logs;
    }

    function setUp() public {
        _parentClock();
        vm.chainId(4663);
        vm.etch(Chain4663Code.POOL_MANAGER_ADDRESS, Chain4663Code.POOL_MANAGER);
        vm.etch(Chain4663Code.UNIVERSAL_ROUTER_ADDRESS, Chain4663Code.UNIVERSAL_ROUTER);
        vm.etch(Chain4663Code.PERMIT2_ADDRESS, Chain4663Code.PERMIT2);
        ur = Chain4663Code.UNIVERSAL_ROUTER_ADDRESS;
        permit2 = Chain4663Code.PERMIT2_ADDRESS;
        _deployReleaseShape(IPoolManager(Chain4663Code.POOL_MANAGER_ADDRESS));
        _setUpLaneActors();
        arb = _twoVenueExecutor(1e22);
        _openLane(address(arb));
        key = _openRecapture(ETH);
        _seedReference(key);
        subject = _subjectOf(key);
        owner = vm.addr(OWNER_PK);
        HookrToken(Currency.unwrap(subject)).transfer(owner, 1e26);
        vm.prank(owner);
        HookrToken(Currency.unwrap(subject)).approve(permit2, type(uint256).max);
    }

    /// @dev PeripheryFixture's stack with the release's wiring: the router pins a forwarder and the root curates the
    ///      Universal Router.
    function _deployReleaseShape(IPoolManager pm) internal {
        manager = pm;
        registry = new HookrRegistry(address(this), manager, _registryDelay());
        (fwd, router) = new RelayPairDeployer().deploy(permit2, registry, manager);
        quoter = new HookrQuoter(manager, registry);
        launcher = new HookrLauncher(manager, registry);
        root = _deployRoot();
        rules = new HookrRules(manager, registry, protocol, address(root), _minProtocolShareBps());
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(root), address(root).codehash));
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(launcher), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(root), address(root).codehash);
        registry.setLauncher(address(launcher), true);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(rules),
            codeHash: address(rules).codehash,
            schemaHash: rules.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        _deployTokens();
    }

    function _deployRoot() internal returns (HookrRoot) {
        bytes memory args = abi.encode(manager, registry, address(router), address(quoter), ur);
        bytes32 initHash = keccak256(abi.encodePacked(type(HookrRoot).creationCode, args));
        for (uint256 i;; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x2acc) {
                return new HookrRoot{salt: bytes32(i)}(manager, registry, address(router), address(quoter), ur);
            }
        }
    }

    function _deployTokens() internal {
        tokenA = new HookrToken("Token A", "TA", 1e30, address(this));
        tokenB = new HookrToken("Token B", "TB", 1e30, address(this));
        registry.queue(registry.SET_QUOTE(), abi.encode(address(tokenA), true));
        registry.queue(registry.SET_QUOTE(), abi.encode(address(tokenB), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(address(tokenA), true);
        registry.setQuote(address(tokenB), true);
        tokenA.approve(address(launcher), type(uint256).max);
        tokenB.approve(address(launcher), type(uint256).max);
        tokenA.transfer(trader, 1e27);
        tokenB.transfer(trader, 1e27);
        vm.startPrank(trader);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.deal(address(this), 1e30);
        vm.deal(trader, 1e28);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Moves the reference venue 3% away from the pool, on the side that the next swap's before-phase arb
    ///      recapture closes against the pool's price and the swap of direction `buy` then reopens: the subject 3%
    ///      cheaper there before a buy, 3% dearer before a sell. The after-phase therefore runs against the trader's
    ///      own move, which is what earns the trader its claim. (ETH is the quote and currency0: the price is subject
    ///      per ETH.)
    function _gap(bool buy) internal {
        if (buy) {
            _moveReference(key, 1.03e18);
        } else {
            uint160 target = uint160(Math.sqrt(uint256(0.97e18) * 1e18) * (1 << 96) / 1e18);
            mover.directSwap(_ref(key), true, -int256(1e26), target);
        }
    }

    function _single(bool buy, address from) internal view returns (IHookrQuoter.QuoteExactSingleParams memory) {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, buy, true, AMOUNT, from);
        return IHookrQuoter.QuoteExactSingleParams(key, p.zeroForOne, AMOUNT, "");
    }

    /// @dev The detailed quote and the V4Quoter shape for the whale, then the whale's router execution, at one state.
    function _observe(bool buy, bool exactInput) internal returns (Observed memory o) {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, buy, exactInput, AMOUNT, whale);
        (o.receipt, o.claim, o.detailedGas) = quoter.quoteDetailed(p, whale);
        IHookrQuoter.QuoteExactSingleParams memory s =
            IHookrQuoter.QuoteExactSingleParams(key, p.zeroForOne, AMOUNT, "");
        vm.prank(whale);
        (o.single, o.singleGas) = exactInput ? quoter.quoteExactInputSingle(s) : quoter.quoteExactOutputSingle(s);
        uint256 value = buy ? (exactInput ? AMOUNT : p.amountBound) : 0;
        vm.recordLogs();
        vm.prank(whale);
        (o.amountIn, o.amountOut) = router.swap{value: value}(p, address(0), new uint256[](0));
        o.executionGas = vm.lastCallGas().gasTotalUsed;
        o.logs = vm.getRecordedLogs();
    }

    /// @dev The index of the first PoolManager Swap event in `logs` of `locker` on the pool, or the largest uint256.
    function _swapOf(Vm.Log[] memory logs, address locker) internal view returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (
                l.emitter == address(manager) && l.topics.length == 3 && l.topics[0] == POOL_SWAP
                    && l.topics[1] == PoolId.unwrap(key.toId()) && l.topics[2] == bytes32(uint256(uint160(locker)))
            ) return i;
        }
        return type(uint256).max;
    }

    /// @dev The one lane event (CorrectionSucceeded or CorrectionFailed) of `phase` on the pool, and how many there are.
    function _phase(Vm.Log[] memory logs, uint8 phase) internal view returns (uint256 index, uint256 count) {
        index = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (
                l.emitter != address(root) || l.topics.length < 3 || (l.topics[0] != SUCCEEDED && l.topics[0] != FAILED)
            ) {
                continue;
            }
            if (l.topics[1] != PoolId.unwrap(key.toId()) || uint256(l.topics[2]) != phase) continue;
            if (index == type(uint256).max) index = i;
            ++count;
        }
    }

    /// @dev Both arb recapture phases ran around the swap `locker` made on the pool: one before-phase event, then the
    ///      PoolManager's Swap event of that locker on the pool, then one after-phase event.
    function _assertBothPhasesAround(Vm.Log[] memory logs, address locker, string memory path) internal view {
        (uint256 before_, uint256 beforeCount) = _phase(logs, 1);
        (uint256 after_, uint256 afterCount) = _phase(logs, 2);
        uint256 swapAt = _swapOf(logs, locker);
        assertEq(beforeCount, 1, path);
        assertEq(afterCount, 1, path);
        assertLt(swapAt, type(uint256).max, path);
        assertLt(before_, swapAt, string.concat(path, ": the before-phase runs before the swap"));
        assertGt(after_, swapAt, string.concat(path, ": the after-phase runs after it"));
    }

    /// @dev No storage write in `accesses` outlived its frame, no call moved value, and at least one write was
    ///      reverted (the simulated swap's).
    function _assertNoSurvivingWrite(Vm.AccountAccess[] memory accesses) internal pure {
        uint256 reverted;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory a = accesses[i];
            if (!a.reverted) assertEq(a.value, 0, "no value moved");
            for (uint256 j; j < a.storageAccesses.length; ++j) {
                Vm.StorageAccess memory w = a.storageAccesses[j];
                if (!w.isWrite) continue;
                if (w.reverted) {
                    ++reverted;
                } else {
                    assertEq(w.newValue, w.previousValue, "a storage write survived a quote");
                }
            }
        }
        assertGt(reverted, 0, "the simulated swap wrote state that its frame reverted");
    }

    /// @dev The owner's signed intent: a sell of AMOUNT subject for ETH (the forwarder relays ERC-20 input only).
    function _intent(uint256 nonce) internal view returns (IHookrForwarder.HookrSwapIntent memory i) {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, false, true, AMOUNT, owner);
        i.key = key;
        i.zeroForOne = p.zeroForOne;
        i.amountSpecified = p.amountSpecified;
        i.amountBound = 1;
        i.sqrtPriceLimitX96 = p.sqrtPriceLimitX96;
        i.recipient = owner;
        i.relayer = RELAYER;
        i.relayerFee = 1e15;
        i.campaigns = new uint256[](0);
        i.nonce = nonce;
        i.deadline = vm.getBlockTimestamp() + 1000;
    }

    function _sign(IHookrForwarder.HookrSwapIntent memory i) internal view returns (bytes memory) {
        (address token, uint256 amount,) = fwd.pullOf(i);
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                fwd.WITNESS_TYPE_STRING()
            )
        );
        bytes32 tp = keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 structHash =
            keccak256(abi.encode(typeHash, tp, address(fwd), fwd.permit2Nonce(i.nonce), i.deadline, fwd.hashIntent(i)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2Lane(permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The whale's Universal Router 2.1.1 V4_SWAP of AMOUNT ETH in for the subject: SWAP_EXACT_IN_SINGLE,
    ///      SETTLE_ALL paid from the call's value, TAKE_ALL. Returns the subject received.
    function _urBuy() internal returns (uint256 received) {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, AMOUNT, whale);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, p.zeroForOne, AMOUNT, 1, 0, ""));
        params[1] = abi.encode(ETH, uint256(AMOUNT));
        params[2] = abi.encode(subject, uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        uint256 before = HookrToken(Currency.unwrap(subject)).balanceOf(whale);
        vm.prank(whale, whale);
        IUniversalRouterLane(ur).execute{value: AMOUNT}(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        received = HookrToken(Currency.unwrap(subject)).balanceOf(whale) - before;
    }

    // ───────────────────────────── (1) and (2) quotes equal execution ─────────────────────────────

    /// @dev Shape `c` (bit 0 a sell, bit 1 an exact output) after the reference moved: both phases recapture, and the
    ///      quotes equal execution and its trader credit.
    function _laneShape(uint256 c) internal {
        (bool buy, bool exactInput) = (c & 1 == 0, c & 2 == 0);
        uint256 snap = vm.snapshotState();
        _gap(buy);
        Observed memory o = _observe(buy, exactInput);
        Outcome memory phases = _outcome(o.logs);
        Splits memory t = _splits(o.logs);
        assertGt(phases.pushedBefore, 0, "the before-phase recaptured");
        assertGt(phases.pushedAfter, 0, "the after-phase recaptured");
        assertLt(
            _swapOf(o.logs, address(arb)),
            _swapOf(o.logs, address(router)),
            "the before-phase's leg moved the pool's price ahead of the swap"
        );
        assertEq(o.receipt.inputAmount, o.amountIn, "quoted input");
        assertEq(o.receipt.outputAmount, o.amountOut, "quoted output");
        assertEq(o.single, exactInput ? o.amountOut : o.amountIn, "V4Quoter shape");
        assertGt(t.trader, 0, "the after-phase credited the trader");
        assertEq(o.claim, t.trader, "the quoted trader claim is RecaptureSplit's traderAmount");
        assertEq(t.lastTrader, whale);
        console2.log("lane", buy ? "buy" : "sell", exactInput ? "exact in" : "exact out");
        console2.log("  gasEstimate detailed, single; router execution", o.detailedGas, o.singleGas, o.executionGas);
        console2.log("  trader claim", o.claim);
        vm.revertToState(snap);
    }

    function test_laneBuyExactInputQuotesEqualExecution() public {
        _laneShape(0);
    }

    function test_laneSellExactInputQuotesEqualExecution() public {
        _laneShape(1);
    }

    function test_laneBuyExactOutputQuotesEqualExecution() public {
        _laneShape(2);
    }

    function test_laneSellExactOutputQuotesEqualExecution() public {
        _laneShape(3);
    }

    /// The V4Quoter shape quoted from the Universal Router's address, the address that locks the PoolManager there,
    /// equals the Universal Router's execution on the lane pool, both phases included.
    function test_laneSingleQuoteFromTheUniversalRouterEqualsItsExecution() public {
        _gap(true);
        vm.prank(ur);
        (uint256 quoted,) = quoter.quoteExactInputSingle(_single(true, ur));
        vm.recordLogs();
        uint256 received = _urBuy();
        Outcome memory phases = _outcome(vm.getRecordedLogs());
        assertGt(phases.pushedBefore, 0);
        assertEq(received, quoted, "Universal Router output equals the quote");
    }

    // ───────────────────────────── (3) no state ─────────────────────────────

    /// The quotes of a lane pool whose both phases recapture leave every account's storage and balances as they were:
    /// pool, root, Rules, executor and claims.
    function test_laneQuotesLeaveNoState() public {
        _gap(true);
        uint256 claimBefore = rules.claimable(ETH, whale);
        vm.startStateDiffRecording();
        quoter.quoteDetailed(_swapParams(key, ETH, true, true, AMOUNT, whale), whale);
        vm.prank(whale);
        quoter.quoteExactInputSingle(_single(true, whale));
        vm.prank(whale);
        quoter.quoteExactOutputSingle(_single(false, whale));
        _assertNoSurvivingWrite(vm.stopAndReturnStateDiff());
        assertEq(rules.claimable(ETH, whale), claimBefore);
        assertEq(arb.root(), address(root));
    }

    // ───────────────────────────── (4) no executing path honours a quote mode ─────────────────────────────

    /// HookrRouter.swap runs both phases around the swap.
    function test_routerSwapRunsBothPhases() public {
        _gap(true);
        vm.recordLogs();
        _buy(key, ETH, whale, AMOUNT);
        _assertBothPhasesAround(vm.getRecordedLogs(), address(router), "router swap");
    }

    /// The forwarder's relayed path (HookrRouter.swapFor) runs both phases around the swap.
    function test_relayedSwapForRunsBothPhases() public {
        _gap(false);
        IHookrForwarder.HookrSwapIntent memory i = _intent(1);
        bytes memory sig = _sign(i);
        vm.recordLogs();
        vm.prank(RELAYER);
        (, uint256 out) = fwd.execute(i, owner, sig);
        assertGt(out, 0);
        _assertBothPhasesAround(vm.getRecordedLogs(), address(router), "relayed swapFor");
    }

    /// HookrRouter.swapGated runs both phases around the swap; its gate's data never reaches the root, and the
    /// after-phase credits the trader's share to the vouched payer, never the funder, exactly as the detailed quote
    /// for that payer reports it.
    function test_gatedSwapRunsBothPhasesAndCreditsThePayer() public {
        LaneOpenGate gate = new LaneOpenGate();
        ReleaseWiring.admitAfterDelay(registry, address(root), ReleaseWiring.gateAdmission(address(gate), 50_000));
        _nextBlock();
        _gap(true);
        address payer = address(0xB0B);
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, AMOUNT, whale);
        (HookrTypes.ExecutionReceipt memory quoted, uint256 quotedClaim,) = quoter.quoteDetailed(p, payer);
        uint256 payerClaim = rules.claimable(ETH, payer);
        uint256 whaleClaim = rules.claimable(ETH, whale);
        vm.recordLogs();
        vm.prank(whale);
        (uint256 amountIn, uint256 amountOut) = router.swapGated{value: AMOUNT}(
            p, payer, address(gate), abi.encode(keccak256("hookr.quote.mode")), address(0), new uint256[](0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertBothPhasesAround(logs, address(router), "gated swapGated");
        Splits memory t = _splits(logs);
        assertGt(t.trader, 0, "the after-phase credited a trader");
        assertEq(t.lastTrader, payer, "the vouched payer is the trader");
        assertEq(rules.claimable(ETH, payer) - payerClaim, t.trader, "the payer's claim");
        assertEq(rules.claimable(ETH, whale), whaleClaim, "never the funder's");
        assertEq(amountIn, quoted.inputAmount, "quoted input");
        assertEq(amountOut, quoted.outputAmount, "quoted output");
        assertEq(quotedClaim, t.trader, "quoted trader claim");
    }

    /// @dev Makes the subject 3% cheaper on `member`'s reference venue than in the pool, so the before-phase of a buy
    ///      on the member recaptures and the after-phase runs against the buyer's own move.
    function _cheapenReference(PoolKey memory member) internal {
        if (Currency.unwrap(member.currency1) == Currency.unwrap(_subjectOf(member))) {
            _moveReference(member, 1.03e18);
        } else {
            uint160 target = uint160(Math.sqrt(uint256(0.97e18) * 1e18) * (1 << 96) / 1e18);
            mover.directSwap(_ref(member), true, -int256(1e26), target);
        }
    }

    /// @dev Both arb recapture phases ran around the swap `locker` made on `pool`: one before-phase event, the
    ///      PoolManager's Swap event, one after-phase event, in that order.
    function _assertBothPhasesOn(Vm.Log[] memory logs, PoolKey memory pool, address locker, string memory path)
        internal
        view
    {
        bytes32 id = PoolId.unwrap(pool.toId());
        (uint256 before_, uint256 after_, uint256 swapAt) = (type(uint256).max, type(uint256).max, type(uint256).max);
        (uint256 beforeCount, uint256 afterCount) = (0, 0);
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (
                l.emitter == address(manager) && l.topics.length == 3 && l.topics[0] == POOL_SWAP && l.topics[1] == id
                    && l.topics[2] == bytes32(uint256(uint160(locker))) && swapAt == type(uint256).max
            ) swapAt = i;
            if (
                l.emitter != address(root) || l.topics.length < 3 || (l.topics[0] != SUCCEEDED && l.topics[0] != FAILED)
                    || l.topics[1] != id
            ) continue;
            if (uint256(l.topics[2]) == 1) {
                if (before_ == type(uint256).max) before_ = i;
                ++beforeCount;
            } else {
                if (after_ == type(uint256).max) after_ = i;
                ++afterCount;
            }
        }
        assertEq(beforeCount, 1, path);
        assertEq(afterCount, 1, path);
        assertLt(before_, swapAt, string.concat(path, ": the before-phase runs before the swap"));
        assertGt(after_, swapAt, string.concat(path, ": the after-phase runs after it"));
    }

    /// Every leg of a HookrFamilyRouter trade runs through HookrRouter.swapGated, so both phases run around each leg's
    /// member swap: a two-member arb recapture family (quoted in ETH and tokenB) bought with ETH, the tokenB leg
    /// converting through a hookless ETH and tokenB pool; each leg's after-phase credits the trader, the family
    /// router's caller, and the family router keeps nothing.
    function test_familyRouterLegsRunBothPhases() public {
        HookrFamilyRouter fam = new HookrFamilyRouter(router, IHookrLauncherView(address(launcher)), permit2);
        ReleaseWiring.admitAfterDelay(registry, address(root), ReleaseWiring.gateAdmission(address(fam), 100_000));
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](2);
        m[0] = _laneMember(ETH, _laneRules(false), _recaptureOnlyRc());
        m[1] = _laneMember(Currency.wrap(address(tokenB)), _laneRules(false), _recaptureOnlyRc());
        HookrToken s2 = _newSubject();
        (bytes32 family, PoolKey[] memory keys) = _launchAs(creator, s2, m);
        _seedReference(keys[0]);
        _seedReference(keys[1]);
        PoolKey memory conversion = PoolKey(ETH, Currency.wrap(address(tokenB)), 500, 10, IHooks(address(0)));
        seeder.seed{value: 1e24}(conversion, SQRT_ONE, -60_000, 60_000, 1e24);
        _nextBlock();
        _cheapenReference(keys[0]);
        _cheapenReference(keys[1]);

        IHookrFamilyRouter.FamilyTrade memory t;
        t.familyId = family;
        t.input = ETH;
        t.output = Currency.wrap(address(s2));
        t.legs = new IHookrFamilyRouter.Leg[](2);
        t.legs[0].key = keys[0];
        t.legs[0].amountIn = 1e22;
        t.legs[0].minOut = 1;
        t.legs[1].key = keys[1];
        t.legs[1].conversion = conversion;
        t.legs[1].amountIn = 1e22;
        t.legs[1].minOut = 1;
        t.recipient = whale;
        t.deadline = vm.getBlockTimestamp() + 1000;
        uint256 claimBefore = rules.claimable(ETH, whale) + rules.claimable(Currency.wrap(address(tokenB)), whale);
        vm.recordLogs();
        vm.prank(whale);
        (uint256 amountIn, uint256 amountOut) = fam.trade{value: 2e22}(t, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(amountIn, 2e22);
        assertGt(amountOut, 0);
        _assertBothPhasesOn(logs, keys[0], address(router), "first leg");
        _assertBothPhasesOn(logs, keys[1], address(router), "second leg");
        Splits memory splits = _splits(logs);
        assertGt(splits.trader, 0, "the after-phases credited a trader");
        assertEq(splits.lastTrader, whale, "the family router's caller is the trader");
        assertGt(rules.claimable(ETH, whale) + rules.claimable(Currency.wrap(address(tokenB)), whale), claimBefore);
        assertEq(address(fam).balance, 0);
        assertEq(tokenB.balanceOf(address(fam)), 0);
        assertEq(s2.balanceOf(address(fam)), 0);
    }

    /// The Universal Router runs both phases around the swap.
    function test_universalRouterRunsBothPhases() public {
        _gap(true);
        vm.recordLogs();
        assertGt(_urBuy(), 0);
        _assertBothPhasesAround(vm.getRecordedLogs(), ur, "Universal Router");
    }

    /// A direct PoolManager locker runs both phases around the swap.
    function test_directLockerRunsBothPhases() public {
        _gap(true);
        Actor locker = _newActor();
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, AMOUNT, address(locker));
        vm.recordLogs();
        locker.directSwap(key, p.zeroForOne, p.amountSpecified, p.sqrtPriceLimitX96);
        _assertBothPhasesAround(vm.getRecordedLogs(), address(locker), "direct locker");
    }

    /// A direct locker carrying hook data, whatever its encoding (a flag byte, a true word, a tagged word), is refused by
    /// the root with InvalidHookData before either phase or any charge: there is no quote mode to signal.
    function test_aLockersQuoteFlagIsRefusedBeforeEitherPhase() public {
        _gap(true);
        LaneHookDataLocker locker = new LaneHookDataLocker(manager);
        IHookrRouter.Swap memory p = _swapParams(key, ETH, true, true, AMOUNT, address(locker));
        SwapParams memory params = SwapParams(p.zeroForOne, p.amountSpecified, p.sqrtPriceLimitX96);
        bytes[3] memory flags = [bytes(hex"01"), abi.encode(true), abi.encode(keccak256("hookr.quote.mode"))];
        bytes memory refused = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(IHookrRootEvents.InvalidHookData.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(refused);
            locker.swap(key, params, flags[i]);
        }
    }
}
