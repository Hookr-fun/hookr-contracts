// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrSwapGate} from "../../src/interfaces/IHookrSwapGate.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {IHookrEngagementReceiptSink} from "../../src/interfaces/IHookrEngagementReceiptSink.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";
import {MockModuleBond} from "../mocks/MockModuleBond.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";

/// @dev A gate that vouches for the (caller, payer) pairs a test allows, each as many times as it has tickets, and
///      records every call it is asked: the arguments' digest, the count and the gas it entered with.
contract RecordingGate is IHookrSwapGate {
    mapping(address caller => mapping(address payer => uint256)) public tickets;
    bytes32 public lastCall;
    uint256 public calls;
    uint256 public entryGas;

    function allow(address caller, address payer, uint256 count) external {
        tickets[caller][payer] = count;
    }

    function beforeUnlock(
        address caller,
        address payer,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata data
    ) external returns (bytes4) {
        uint256 entry = gasleft();
        uint256 left = tickets[caller][payer];
        require(left != 0, "no vouch");
        tickets[caller][payer] = left - 1;
        lastCall = keccak256(abi.encode(msg.sender, caller, payer, key, zeroForOne, amountSpecified, data));
        entryGas = entry;
        ++calls;
        return IHookrSwapGate.beforeUnlock.selector;
    }
}

/// @dev A gate that answers every call the same bad way: a revert, another selector, the selector with dirty low
///      bytes, a short or a long return, or a loop that burns all of its gas.
contract BadAnswerGate is IHookrSwapGate {
    enum Mode {
        REVERT,
        OTHER,
        DIRTY,
        SHORT,
        LONG,
        BURN
    }

    Mode public mode;

    function setMode(Mode next) external {
        mode = next;
    }

    function beforeUnlock(address, address, PoolKey calldata, bool, int256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        Mode m = mode;
        bytes4 selector = IHookrSwapGate.beforeUnlock.selector;
        if (m == Mode.REVERT) revert("refused");
        if (m == Mode.BURN) {
            while (true) {}
        }
        if (m == Mode.OTHER) return bytes4(keccak256("vouch()"));
        if (m == Mode.DIRTY) {
            assembly ("memory-safe") {
                mstore(0, or(selector, 1))
                return(0, 32)
            }
        }
        if (m == Mode.SHORT) {
            assembly ("memory-safe") {
                mstore(0, selector)
                return(0, 31)
            }
        }
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(32, 0)
            return(0, 64)
        }
    }
}

/// @dev A gate that, asked to vouch, tries every router entry point and records each one's revert, then vouches.
contract ReenteringGate is IHookrSwapGate {
    IHookrRouter public immutable router;
    bytes4[4] public refused;
    bool public attempted;

    constructor(IHookrRouter router_) {
        router = router_;
    }

    function beforeUnlock(address, address payer, PoolKey calldata key, bool zeroForOne, int256, bytes calldata)
        external
        returns (bytes4)
    {
        IHookrRouter.Swap memory p = IHookrRouter.Swap(
            key,
            zeroForOne,
            -1e18,
            1,
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
            payer,
            block.timestamp
        );
        bytes[4] memory calls = [
            abi.encodeCall(IHookrRouter.swap, (p, address(0), new uint256[](0))),
            abi.encodeCall(IHookrRouter.swapGated, (p, payer, address(this), "", address(0), new uint256[](0))),
            abi.encodeCall(IHookrRouter.swapFor, (p, payer, 0, address(0), address(0), new uint256[](0))),
            abi.encodeCall(HookrRouter.sweep, (Currency.wrap(address(0)), payer))
        ];
        for (uint256 i; i < 4; ++i) {
            (bool ok, bytes memory reason) = address(router).call(calls[i]);
            require(!ok, "reentry succeeded");
            refused[i] = bytes4(reason);
        }
        attempted = true;
        return IHookrSwapGate.beforeUnlock.selector;
    }
}

/// @dev An advisory that rejects every swap whose authenticated payer it lists, the way a compliance screen refuses a
///      listed identity.
contract PayerScreen is IHookrAdvisory {
    mapping(address payer => bool) public listed;

    function list(address payer, bool value) external {
        listed[payer] = value;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.payer.screen");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory a) {
        a.reject = listed[x.payer];
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory a)
    {}
}

/// @notice HookrRouter.swapGated on the real 4663 PoolManager, Universal Router 2.1.1 and Permit2 runtimes: a GATE
///         admission of the pool's own root vouches for a payer before the unlock, and the swap then runs with that
///         payer as its identity (hook data, receipt, Programs participant, the root's advisories and Rules claims)
///         and the caller as funder. Inert until a queued ADMIT of kind GATE executes; a gate admitted on another root,
///         of another kind, revoked, unbonded or with other code is refused; the gate runs with exactly its admitted
///         gas under the router's reentrancy lock, answers once per swap, and only a clean selector word vouches;
///         `data` reaches the gate, never the root; swap and swapFor never ask a gate and keep their selectors.
contract RouterSwapGatedTest is GasBenchFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    uint32 internal constant GATE_GAS = 150_000;

    address internal funder = address(0xF0DE);
    address internal payer = address(0xB0B);
    address internal recipient = address(0xCAFE);
    address internal guardian = address(0x6A7D);
    RecordingGate internal gate;

    function setUp() public override {
        super.setUp();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
        address[2] memory spenders = [funder, payer];
        for (uint256 i; i < 2; ++i) {
            subject.transfer(spenders[i], 1e26);
            quoteFee.transfer(spenders[i], 1e26);
            quoteFull.transfer(spenders[i], 1e26);
            vm.deal(spenders[i], 1e26);
            vm.startPrank(spenders[i]);
            subject.approve(address(router), type(uint256).max);
            quoteFee.approve(address(router), type(uint256).max);
            quoteFull.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        gate = new RecordingGate();
        _admitGate(address(gate), GATE_GAS);
        gate.allow(funder, payer, type(uint256).max);
        _warm(feeKey);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _admitGate(address implementation, uint32 gasLimit) internal {
        _admitOn(address(root), ReleaseWiring.gateAdmission(implementation, gasLimit));
    }

    function _admitOn(address scope, IHookrRegistry.Admission memory a) internal {
        ReleaseWiring.admitAfterDelay(registry, scope, a);
    }

    /// @dev A buy of `amount` quote on `key`, paid to `recipient`, with a deadline a day ahead so that a test waiting
    ///      out a queue's delay can still send it.
    function _buy(PoolKey memory key, uint128 amount) internal view returns (IHookrRouter.Swap memory p) {
        p = _params(key, true, amount);
        p.recipient = recipient;
        p.deadline = vm.getBlockTimestamp() + 1 days;
    }

    function _gated(IHookrRouter.Swap memory p, address gate_, bytes memory data)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        vm.prank(funder);
        return router.swapGated(p, payer, gate_, data, address(0), new uint256[](0));
    }

    function _expectGated(IHookrRouter.Swap memory p, address gate_, bytes memory reason) internal {
        vm.prank(funder);
        vm.expectRevert(reason);
        router.swapGated(p, payer, gate_, "", address(0), new uint256[](0));
    }

    function _notAdmitted(address gate_) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRouter.GateNotAdmitted.selector, address(root), gate_);
    }

    /// @dev One native-quote pool of the fixture's subject at `spacing`, fee-only.
    function _launchNative(int24 spacing) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)), spacing, false);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @dev An unmodified HookrRoot at a fresh CREATE2 address with the root's flags, registered by REGISTER_ROOT.
    function _secondRoot() internal returns (HookrRoot r) {
        bytes32 initHash = ReleaseWiring.rootInitHash(manager, registry, address(router), address(quoter), ur);
        uint256 counter = ReleaseWiring.mineSalt(address(this), initHash, ReleaseWiring.ROOT_FLAGS, 1 << 100);
        r = new HookrRoot{salt: bytes32(counter)}(manager, registry, address(router), address(quoter), ur);
        ReleaseWiring.queueRoot(registry, address(r));
        ReleaseWiring.waitDelay(registry);
        ReleaseWiring.registerRoot(registry, address(r));
    }

    // ───────────────────────────── surface ─────────────────────────────

    /// swapGated is declared on IHookrRouter with HookrRouter's selector; swap, swapFor and IHookrSwapGate keep theirs.
    function test_selectors() public pure {
        assertEq(IHookrRouter.swapGated.selector, HookrRouter.swapGated.selector);
        assertEq(
            IHookrRouter.swapGated.selector,
            bytes4(
                keccak256(
                    "swapGated(((address,address,uint24,int24,address),bool,int128,uint128,uint160,address,uint256),address,address,bytes,address,uint256[])"
                )
            )
        );
        assertEq(IHookrRouter.swap.selector, bytes4(0x19b36adf));
        assertEq(IHookrRouter.swapFor.selector, bytes4(0x28672da5));
        assertEq(
            IHookrSwapGate.beforeUnlock.selector,
            bytes4(keccak256("beforeUnlock(address,address,(address,address,uint24,int24,address),bool,int256,bytes)"))
        );
    }

    // ───────────────────────────── inert until admitted ─────────────────────────────

    /// Every gate is refused until its queued ADMIT of kind GATE executes: queued, matured or cancelled, swapGated
    /// refuses it and never calls it; once admitted it vouches.
    function test_everyGateIsRefusedBeforeItsAdmissionExecutes() public {
        RecordingGate fresh = new RecordingGate();
        fresh.allow(funder, payer, 1);
        IHookrRouter.Swap memory p = _buy(feeKey, 1e20);
        _expectGated(p, address(fresh), _notAdmitted(address(fresh)));
        IHookrRegistry.Admission memory a = ReleaseWiring.gateAdmission(address(fresh), GATE_GAS);
        bytes32 operation = registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        _expectGated(p, address(fresh), _notAdmitted(address(fresh)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        _expectGated(p, address(fresh), _notAdmitted(address(fresh)));
        registry.cancel(operation);
        _expectGated(p, address(fresh), _notAdmitted(address(fresh)));
        assertEq(fresh.calls(), 0, "a gate that is not admitted is never called");
        _admitOn(address(root), a);
        (, uint256 out) = _gated(_buy(feeKey, 1e20), address(fresh), "");
        assertGt(out, 0);
        assertEq(fresh.calls(), 1);
    }

    // ───────────────────────────── identity ─────────────────────────────

    /// The funder pays the input, the recipient receives the output, the payer's balances do not move, and the swap
    /// equals a plain swap's amounts from the same state; the gate is asked once with the swap's own arguments.
    function test_theCallerFundsAndThePayerIsTheIdentity() public {
        IHookrRouter.Swap memory p = _buy(feeKey, 1e21);
        uint256 snap = vm.snapshotState();
        vm.prank(funder);
        (uint256 plainIn, uint256 plainOut) = router.swap(p, address(0), new uint256[](0));
        vm.revertToState(snap);

        uint256 funderQuote = quoteFee.balanceOf(funder);
        uint256 payerQuote = quoteFee.balanceOf(payer);
        uint256 recipientSubject = subject.balanceOf(recipient);
        bytes memory data = hex"c0ffee";
        vm.expectEmit(true, true, true, true, address(router));
        emit IHookrRouter.SwapExecuted(feeKey.toId(), payer, recipient, plainIn, plainOut);
        vm.expectEmit(true, true, true, true, address(router));
        emit IHookrRouter.SwapGated(feeKey.toId(), payer, address(gate), funder);
        (uint256 amountIn, uint256 amountOut) = _gated(p, address(gate), data);
        assertEq(amountIn, plainIn, "same input as a plain swap");
        assertEq(amountOut, plainOut, "same output as a plain swap");
        assertEq(funderQuote - quoteFee.balanceOf(funder), amountIn, "the funder paid");
        assertEq(quoteFee.balanceOf(payer), payerQuote, "the payer paid nothing");
        assertEq(subject.balanceOf(recipient) - recipientSubject, amountOut, "the recipient received");
        assertEq(gate.calls(), 1);
        assertEq(
            gate.lastCall(),
            keccak256(
                abi.encode(address(router), funder, payer, feeKey, p.zeroForOne, int256(p.amountSpecified), data)
            ),
            "the gate saw the caller, payer, key, direction, amount and data"
        );
    }

    /// The receipt names the payer: an engagement sink records it as the participant, and HookrPrograms credits the
    /// payer's points, never the funder's.
    function test_programsCreditThePayer() public {
        HookrPrograms programs =
            new HookrPrograms(manager, address(router), address(this), 10_000, address(new HookrReferralRegistry()));
        P.Terms memory t;
        t.mode = P.Mode.Immediate;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = 1000;
        t.walletPointCap = 1000;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("gated");
        t.name = "Gated";
        t.metadataURI = "ipfs://gated";
        t.pointDecimals = 18;
        P.Scope[] memory s = new P.Scope[](1);
        PoolId id = feeKey.toId();
        s[0] = P.Scope(address(root), PoolId.unwrap(id), root.policyHash(id), address(quoteFee), 1, 1e15, 0, 0);
        uint256 program = programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        vm.warp(t.start);
        uint256[] memory ids = new uint256[](1);
        ids[0] = program;
        vm.recordLogs();
        vm.prank(funder);
        (uint256 amountIn,) = router.swapGated(_buy(feeKey, 1e21), payer, address(gate), "", address(programs), ids);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(programs.points(program, payer), 0, "the payer earned the points");
        assertEq(programs.points(program, funder), 0, "the funder earned nothing");
        uint256 accepted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(programs) && logs[i].topics[0] == IHookrPrograms.ExecutionAccepted.selector)
            {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(payer))), "the receipt's participant is the payer");
                IHookrEngagementReceiptSink.EngagementReceipt memory r =
                    abi.decode(abi.decode(logs[i].data, (bytes)), (IHookrEngagementReceiptSink.EngagementReceipt));
                assertEq(r.participant, payer);
                assertEq(r.poolId, PoolId.unwrap(id));
                ++accepted;
            }
        }
        assertEq(accepted, 1);
        assertGt(amountIn, 0);
    }

    /// The root's advisories screen the payer: a listed payer is rejected whoever funds it, and a listed funder can
    /// fund an unlisted payer's swap, since the funder is not the swap's identity.
    function test_advisoriesScreenThePayerNotTheFunder() public {
        PayerScreen screen = new PayerScreen();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(screen),
            codeHash: address(screen).codehash,
            schemaHash: screen.configSchemaHash(),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        _admitOn(address(root), a);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quotes[0])), 60, false);
        members[0].config.advisory = address(screen);
        members[0].config.advisoryGasLimit = 100_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        bytes[] memory configs = new bytes[](1);
        configs[0] = hex"01";
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(family, 0).key;
        quotes[0].transfer(funder, 1e26);
        vm.prank(funder);
        quotes[0].approve(address(router), type(uint256).max);

        screen.list(payer, true);
        vm.prank(funder);
        vm.expectRevert();
        router.swapGated(_buy(key, 1e20), payer, address(gate), "", address(0), new uint256[](0));
        screen.list(payer, false);
        screen.list(funder, true);
        (, uint256 out) = _gated(_buy(key, 1e20), address(gate), "");
        assertGt(out, 0, "the listed funder funded the unlisted payer's swap");
        vm.prank(funder);
        vm.expectRevert();
        router.swap(_buy(key, 1e20), address(0), new uint256[](0));
    }

    /// Rules claims name the payer: a partial fill's refund of the reserved quote take is credited to the payer's
    /// claim, the funder's claim does not move, and the funder pays only the input the swap used.
    function test_rulesClaimsCreditThePayer() public {
        IHookrRouter.Swap memory p = _buy(fullKey, 1e26);
        Currency quote = Currency.wrap(address(quoteFull));
        uint256 payerClaim = rules.claimable(quote, payer);
        uint256 funderClaim = rules.claimable(quote, funder);
        uint256 funderQuote = quoteFull.balanceOf(funder);
        (uint256 amountIn,) = _gated(p, address(gate), "");
        assertLt(amountIn, 1e26, "a partial fill");
        assertGt(rules.claimable(quote, payer) - payerClaim, 0, "the refund is the payer's claim");
        assertEq(rules.claimable(quote, funder), funderClaim, "never the funder's");
        assertEq(funderQuote - quoteFull.balanceOf(funder), amountIn);
    }

    /// Native input: the call's value is the swap's maximum input, the funder pays it and nothing stays in the router.
    function test_nativeInput() public {
        PoolKey memory key = _launchNative(30);
        IHookrRouter.Swap memory p = _buy(key, 1e20);
        assertEq(Currency.unwrap(p.zeroForOne ? key.currency0 : key.currency1), address(0));
        vm.prank(funder);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swapGated{value: 1e20 - 1}(p, payer, address(gate), "", address(0), new uint256[](0));
        uint256 funderBefore = funder.balance;
        uint256 payerBefore = payer.balance;
        vm.prank(funder);
        (uint256 amountIn, uint256 amountOut) =
            router.swapGated{value: 1e20}(p, payer, address(gate), "", address(0), new uint256[](0));
        assertEq(amountIn, 1e20);
        assertGt(amountOut, 0);
        assertEq(funderBefore - funder.balance, 1e20);
        assertEq(payer.balance, payerBefore);
        assertEq(address(router).balance, 0);
    }

    // ───────────────────────────── the admission ─────────────────────────────

    /// Only a GATE admission of the pool's own root vouches: a gate admitted on another registered root, the pool's
    /// Rules (a RULES admission) and an ADVISORY admission of a gate contract are each refused before any call.
    function test_onlyAGateAdmissionOfThePoolsOwnRootVouches() public {
        RecordingGate elsewhere = new RecordingGate();
        elsewhere.allow(funder, payer, 1);
        HookrRoot other = _secondRoot();
        _admitOn(address(other), ReleaseWiring.gateAdmission(address(elsewhere), GATE_GAS));
        assertEq(uint8(registry.admission(address(other), address(elsewhere)).kind), uint8(IHookrRegistry.Kind.GATE));
        IHookrRouter.Swap memory p = _buy(feeKey, 1e20);
        _expectGated(p, address(elsewhere), _notAdmitted(address(elsewhere)));

        _expectGated(p, address(rules), _notAdmitted(address(rules)));

        RecordingGate advisoryKind = new RecordingGate();
        advisoryKind.allow(funder, payer, 1);
        IHookrRegistry.Admission memory a = ReleaseWiring.gateAdmission(address(advisoryKind), GATE_GAS);
        a.kind = IHookrRegistry.Kind.ADVISORY;
        a.schemaHash = keccak256("test.advisory");
        a.phaseMask = HookrTypes.BEFORE_SWAP;
        _admitOn(address(root), a);
        _expectGated(p, address(advisoryKind), _notAdmitted(address(advisoryKind)));
        assertEq(elsewhere.calls() + advisoryKind.calls(), 0);
    }

    /// The module brake withdraws a gate at once: a revoked gate is refused, while the pool keeps trading through
    /// swap and the forwarder's swapFor.
    function test_aRevokedGateStopsVouchingAtOnce() public {
        _gated(_buy(feeKey, 1e20), address(gate), "");
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(gate));
        _expectGated(_buy(feeKey, 1e20), address(gate), _notAdmitted(address(gate)));
        _routerSwap(feeKey, true, 1e20);
        _nextBlock();
        (, uint256 out) = _relayed(feeKey, true, 1e20, 7);
        assertGt(out, 0);
    }

    /// A gate whose bond no longer covers it reads as unadmitted and is refused; covered again, it vouches again.
    function test_aGateItsBondNoLongerCoversIsRefused() public {
        MockModuleBond bond = new MockModuleBond();
        bond.setCovered(address(root), address(gate), true);
        registry.queue(SET_ADMISSION_BOND, abi.encode(address(root), address(gate), address(bond)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.pinModuleBondFor(address(root), address(gate), address(bond));
        _gated(_buy(feeKey, 1e20), address(gate), "");
        bond.setCovered(address(root), address(gate), false);
        _expectGated(_buy(feeKey, 1e20), address(gate), _notAdmitted(address(gate)));
        bond.setCovered(address(root), address(gate), true);
        _gated(_buy(feeKey, 1e20), address(gate), "");
    }

    /// A gate whose runtime code changed after its admission is refused before it is called.
    function test_aGateWhoseCodeChangedIsRefused() public {
        uint256 calls = gate.calls();
        vm.etch(address(gate), address(new BadAnswerGate()).code);
        _expectGated(
            _buy(feeKey, 1e20),
            address(gate),
            abi.encodeWithSelector(IHookrRouter.GateCodeChanged.selector, address(gate))
        );
        vm.etch(address(gate), address(new RecordingGate()).code);
        assertEq(gate.calls(), calls, "the restored code reads the same storage");
        _gated(_buy(feeKey, 1e20), address(gate), "");
    }

    /// A zero payer or a zero gate is refused before anything is read.
    function test_zeroPayerOrGateIsRefused() public {
        IHookrRouter.Swap memory p = _buy(feeKey, 1e20);
        vm.prank(funder);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swapGated(p, address(0), address(gate), "", address(0), new uint256[](0));
        vm.prank(funder);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swapGated(p, payer, address(0), "", address(0), new uint256[](0));
    }

    // ───────────────────────────── the gate's answer ─────────────────────────────

    /// Only a clean 32-byte word equal to beforeUnlock's selector vouches: a revert, another selector, the selector
    /// with dirty low bytes, a short or long return and a gate that burns all of its gas are each refused.
    function test_onlyACleanSelectorWordVouches() public {
        BadAnswerGate bad = new BadAnswerGate();
        _admitGate(address(bad), GATE_GAS);
        BadAnswerGate.Mode[6] memory modes = [
            BadAnswerGate.Mode.REVERT,
            BadAnswerGate.Mode.OTHER,
            BadAnswerGate.Mode.DIRTY,
            BadAnswerGate.Mode.SHORT,
            BadAnswerGate.Mode.LONG,
            BadAnswerGate.Mode.BURN
        ];
        for (uint256 i; i < modes.length; ++i) {
            bad.setMode(modes[i]);
            _expectGated(
                _buy(feeKey, 1e20),
                address(bad),
                abi.encodeWithSelector(IHookrRouter.GateRefused.selector, address(bad))
            );
        }
    }

    /// The gate runs with exactly its admitted gas, and a call that cannot give it all of that gas is refused before
    /// the gate runs.
    function test_theGateRunsWithItsAdmittedGas() public {
        _gated(_buy(feeKey, 1e20), address(gate), "");
        uint256 entry = gate.entryGas();
        assertLe(entry, GATE_GAS, "never more than admitted");
        assertGt(entry, GATE_GAS - 3_000, "all of it, less the gate's own dispatch");
        uint256 calls = gate.calls();
        IHookrRouter.Swap memory p = _buy(feeKey, 1e20);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.InsufficientGateGas.selector, address(gate)));
        router.swapGated{gas: 120_000}(p, payer, address(gate), "", address(0), new uint256[](0));
        assertEq(gate.calls(), calls);
    }

    /// One vouch serves one swap: the router asks the gate on every gated swap, so a gate that vouched once refuses
    /// the next identical swap.
    function test_oneVouchServesOneSwap() public {
        RecordingGate once = new RecordingGate();
        _admitGate(address(once), GATE_GAS);
        once.allow(funder, payer, 1);
        _gated(_buy(feeKey, 1e20), address(once), "");
        _expectGated(
            _buy(feeKey, 1e20), address(once), abi.encodeWithSelector(IHookrRouter.GateRefused.selector, address(once))
        );
        assertEq(once.calls(), 1);
    }

    /// A gate vouches only for the pairs it means to: a caller naming another account as payer, or a payer the gate
    /// vouches for under another caller, is refused.
    function test_aGateCannotBeMadeToVouchForAnotherPayer() public {
        address attacker = address(0xBAD);
        quoteFee.transfer(attacker, 1e26);
        vm.startPrank(attacker);
        quoteFee.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.GateRefused.selector, address(gate)));
        router.swapGated(_buy(feeKey, 1e20), payer, address(gate), "", address(0), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.GateRefused.selector, address(gate)));
        router.swapGated(_buy(feeKey, 1e20), attacker, address(gate), "", address(0), new uint256[](0));
        vm.stopPrank();
    }

    /// The gate runs under the router's reentrancy lock: swap, swapGated, swapFor and sweep each refuse it, and the
    /// gated swap then completes.
    function test_aGateCannotReenterTheRouter() public {
        ReenteringGate reentering = new ReenteringGate(router);
        _admitGate(address(reentering), 200_000);
        (, uint256 out) = _gated(_buy(feeKey, 1e20), address(reentering), "");
        assertGt(out, 0);
        assertTrue(reentering.attempted());
        assertEq(reentering.refused(0), IHookrRouter.Reentered.selector, "swap");
        assertEq(reentering.refused(1), IHookrRouter.Reentered.selector, "swapGated");
        assertEq(reentering.refused(2), bytes4(IHookrRouter.NotForwarder.selector), "swapFor");
        assertEq(reentering.refused(3), IHookrRouter.Reentered.selector, "sweep");
    }

    // ───────────────────────────── a stale sync ─────────────────────────────

    /// A sync a stranger left earlier in the same transaction fails no gated swap (SYS-01): swapGated runs the swap
    /// through HookrRouter.unlockCallback, which clears it, so a gated buy on the burning pool clears and burns as an
    /// ungated one does. Left in place, the sync would make the root refuse the Auto Burn take (UnsupportedBurnSync).
    function test_aStaleSyncFailsNoGatedSwap() public {
        vm.prank(address(0xBAD5));
        manager.sync(Currency.wrap(address(subject)));
        assertEq(
            Currency.unwrap(TransientStateLibrary.getSyncedCurrency(manager)), address(subject), "the subject is synced"
        );
        uint256 deadBefore = subject.balanceOf(root.DEAD());
        (, uint256 out) = _gated(_buy(fullKey, 1e20), address(gate), "");
        assertGt(out, 0, "the gated buy cleared");
        assertGt(subject.balanceOf(root.DEAD()), deadBefore, "with its burn");
    }

    // ───────────────────────────── the other entry points ─────────────────────────────

    /// swap and the forwarder's swapFor (with its relayer fee) never ask a gate, even one admitted on the pool's root,
    /// and run as before.
    function test_swapAndSwapForNeverAskAGate() public {
        uint256 calls = gate.calls();
        vm.recordLogs();
        _routerSwap(feeKey, true, 1e20);
        _nextBlock();
        uint256 relayerBefore = quoteFee.balanceOf(RELAYER) + subject.balanceOf(RELAYER);
        (, uint256 out) = _relayed(feeKey, true, 1e20, 9);
        assertGt(out, 0);
        assertGt(quoteFee.balanceOf(RELAYER) + subject.balanceOf(RELAYER), relayerBefore, "the relayer fee is paid");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != IHookrRouter.SwapGated.selector);
        }
        assertEq(gate.calls(), calls, "no gate asked");
    }

    /// `data` reaches the gate and never the root: a kilobyte of it leaves the swap's hook data the router's own 128
    /// bytes, so the root takes the swap.
    function test_dataReachesTheGateNotTheRoot() public {
        bytes memory data = new bytes(1000);
        for (uint256 i; i < data.length; ++i) {
            data[i] = bytes1(uint8(i));
        }
        IHookrRouter.Swap memory p = _buy(feeKey, 1e20);
        (, uint256 out) = _gated(p, address(gate), data);
        assertGt(out, 0);
        assertEq(
            gate.lastCall(),
            keccak256(abi.encode(address(router), funder, payer, feeKey, p.zeroForOne, int256(p.amountSpecified), data))
        );
    }

    /// The gated path's cost over a plain swap of the same shape: the admission read and the gate's call.
    function test_gasOfAGatedSwap() public {
        IHookrRouter.Swap memory p = _buy(feeKey, 1e20);
        uint256 snap = vm.snapshotState();
        vm.prank(funder);
        router.swap(p, address(0), new uint256[](0));
        uint256 plain = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
        _gated(p, address(gate), "");
        uint256 gated = vm.lastCallGas().gasTotalUsed;
        console2.log("router swap gas, plain and gated", plain, gated);
        assertGt(gated, plain);
    }
}
