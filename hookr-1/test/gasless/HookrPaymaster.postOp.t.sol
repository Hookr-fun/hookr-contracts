// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {IPaymaster} from "../../src/interfaces/external/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {GaslessToken, MockEntryPoint, MockRulesLedger} from "./GaslessMocks.sol";
import {EntryPointV07Code} from "./EntryPointV07Code.sol";
import {PaymasterFixtures} from "../utils/PaymasterFixtures.sol";

interface IEntryPointV07 {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function balanceOf(address account) external view returns (uint256);
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function depositTo(address account) external payable;
}

/// @dev HookrRules.protocolFeePaid's shape: a transient ledger keyed by payer and quote, monotonic in a transaction.
contract TransientRules {
    bytes32 internal constant TAG = keccak256("test.protocol.paid");

    function record(address payer, address quote, uint256 amount) external {
        bytes32 slot = keccak256(abi.encode(TAG, payer, quote));
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), amount))
        }
    }

    function protocolFeePaid(address payer, address quote) external view returns (uint256 amount) {
        bytes32 slot = keccak256(abi.encode(TAG, payer, quote));
        assembly ("memory-safe") {
            amount := tload(slot)
        }
    }
}

/// @dev Cheap for the admission probe (payer zero), then spends nearly its whole stipend for every real payer and
///      still reports a 1-wei fee, so every later step of the rebate path runs.
contract SlowRules {
    function protocolFeePaid(address payer, address) external view returns (uint256) {
        if (payer == address(0)) return 0;
        while (gasleft() > 1_000) {}
        return 1;
    }
}

/// @dev Succeeds inside the read stipend but costs more than the admission probe allows.
contract ExpensiveRules {
    function protocolFeePaid(address, address) external view returns (uint256 x) {
        assembly ("memory-safe") {
            x := add(add(sload(11), sload(12)), add(add(sload(13), sload(14)), sload(15)))
        }
    }
}

/// @dev The two views HookrRules reads from its trusted root at construction.
contract RootStub {
    address public immutable poolManager;
    address public immutable registry;

    constructor(address m, address r) {
        poolManager = m;
        registry = r;
    }
}

/// @dev The two compliance views the paymaster reads.
contract ScreenStandIn {
    enum Mode {
        HEALTHY,
        OUTAGE,
        BURN
    }

    Mode public mode;
    mapping(address => bool) public listed;

    function setMode(Mode m) external {
        mode = m;
    }

    function setListed(address a, bool v) external {
        listed[a] = v;
    }

    function isSanctionedLocal(address) external pure returns (bool) {
        return false;
    }

    function sanctionStatus(address wallet) external view returns (bool, bool) {
        if (mode == Mode.OUTAGE) return (false, true);
        if (mode == Mode.BURN) {
            uint256 i;
            while (gasleft() > 0) ++i;
        }
        return (listed[wallet], false);
    }
}

/// @dev Allowlisted call target: `pay` records a protocol fee for the caller, `ping` pays none.
contract FeeTarget {
    TransientRules public immutable rules;

    constructor(TransientRules r) {
        rules = r;
    }

    function ping() external {}

    function pay(uint256 fee) external {
        rules.record(msg.sender, address(0), fee);
    }
}

/// @dev Minimal v0.7 account with the SimpleAccount execute selector and no signature check.
contract TestAccount {
    address public immutable ep;

    constructor(address ep_) {
        ep = ep_;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missing) external returns (uint256) {
        require(msg.sender == ep, "ep");
        if (missing != 0) {
            (bool ok,) = payable(ep).call{value: missing}("");
            ok;
        }
        return 0;
    }

    function execute(address dest, uint256 value, bytes calldata data) external {
        require(msg.sender == ep, "ep");
        (bool ok, bytes memory r) = dest.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function approveToken(GaslessToken token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    receive() external payable {}
}

/// @notice Unit coverage of the fixes against a mock EntryPoint.
///         Audit findings F-001, F-002, F-005, F-017, F-052 and F-064.
contract HookrPaymasterPostOpUnitTest is PaymasterFixtures {
    MockEntryPoint internal ep;
    MockRulesLedger internal rules;
    ScreenStandIn internal screen;
    address internal constant ACCOUNT = address(0xACC);
    address internal constant ROUTER = address(0x4001);
    bytes4 internal constant ROUTE = 0x19b36adf;
    bytes4 internal constant APPROVE = 0x095ea7b3;

    function setUp() public {
        vm.warp(1_000_000);
        ep = new MockEntryPoint();
        rules = new MockRulesLedger();
        screen = new ScreenStandIn();
        usd = new GaslessToken();
        pm = new HookrPaymaster(address(ep), address(screen), OWNER, DELAY, TREASURY);
        _setPolicy(_policy(false, 1 ether));
        _allowCall(ROUTER, ROUTE);
        _addRules(address(rules));
        _setQuotes(new address[](1));
        _setToken(address(usd), _usdConfig(), USD_PER_ETH);
        _gov(keccak256("GRANT_KEEPER"), abi.encode(KEEPER));
        vm.prank(OWNER);
        pm.grantKeeper(KEEPER);
        _fundRebates(1 ether);
        vm.deal(address(this), 10 ether);
        pm.depositCredit{value: 1 ether}(ACCOUNT);
    }

    function _op(bytes memory callData, uint128 postOpGas, uint128 maxFeePerGas)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = ACCOUNT;
        op.callData = callData;
        op.accountGasLimits = bytes32(uint256(200_000));
        op.gasFees = bytes32(uint256(maxFeePerGas));
        op.paymasterAndData = abi.encodePacked(
            address(pm),
            uint128(100_000),
            postOpGas,
            uint8(0),
            address(0),
            uint128(1 ether),
            uint48(block.timestamp + 1 days)
        );
    }

    function _routeCall() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(0xb61d27f6, ROUTER, 0, abi.encodeWithSelector(ROUTE));
    }

    function _approveCall(address token, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(0xb61d27f6, token, 0, inner);
    }

    function _validate(PackedUserOperation memory op, uint256 maxCost) internal returns (bytes memory ctx) {
        vm.prank(address(ep));
        (ctx,) = pm.validatePaymasterUserOp(op, bytes32("h"), maxCost);
    }

    // ───────────── F-001 ─────────────

    function test_chargeCoversPostOpLimitTailAndPenalty() public {
        uint256 price = 1 gwei;
        bytes memory ctx = _validate(_op(_routeCall(), 240_000, uint128(price)), 0.01 ether);
        vm.prank(address(ep));
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, price);
        // execution gas limit = callGasLimit 200k + postOp 240k; penalty share 10%.
        uint256 expected = 0.001 ether + (240_000 + 10_000 + 44_000) * price;
        assertEq(pm.revenue(address(0)), expected, "charged");
        assertEq(pm.credit(ACCOUNT, address(0)), 1 ether - expected);
    }

    function test_maxFeePerGasAboveCapRefused() public {
        PackedUserOperation memory op = _op(_routeCall(), 240_000, 100 gwei + 1);
        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.FeePerGasAboveCap.selector, 100 gwei + 1, 100 gwei));
        pm.validatePaymasterUserOp(op, bytes32("h"), 0.01 ether);
        _validate(_op(_routeCall(), 240_000, 100 gwei), 0.01 ether);
    }

    function test_policyRequiresFeePerGasCap() public {
        IHookrPaymaster.Policy memory p = _policy(false, 1 ether);
        p.maxFeePerGasWei = 0;
        _gov(keccak256("SET_POLICY"), abi.encode(p));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.InvalidPolicy.selector, uint8(3)));
        pm.setPolicy(p);
    }

    function test_noFeeSkipsTheScreen() public {
        bytes memory ctx = _validate(_op(_routeCall(), 240_000, 1 gwei), 0.01 ether);
        vm.expectCall(address(screen), abi.encodeWithSelector(ScreenStandIn.sanctionStatus.selector), 0);
        vm.prank(address(ep));
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 1 gwei);
        assertEq(pm.rebateBudget(), 1 ether);
    }

    // ───────────── F-002 ─────────────

    function test_postOp_postOpFloorIs240k() public {
        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.PostOpGasOutOfRange.selector, 239_999, 240_000, 300_000));
        pm.validatePaymasterUserOp(_op(_routeCall(), 239_999, 1 gwei), bytes32("h"), 0.01 ether);
        _validate(_op(_routeCall(), 240_000, 1 gwei), 0.01 ether);
    }

    function test_postOp_rebateSkippedWhenGasShortSettlementStands() public {
        bytes memory ctx = _validate(_op(_routeCall(), 240_000, 1 gwei), 0.01 ether);
        rules.set(ACCOUNT, address(0), 0.004 ether);
        // Enough for settlement, not for a rules read plus the rest of the rebate path.
        vm.prank(address(ep));
        pm.postOp{gas: 150_000}(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 0);
        assertEq(pm.rebateBudget(), 1 ether, "no rebate");
        assertEq(pm.revenue(address(0)), 0.001 ether, "full charge booked");
        assertEq(pm.credit(ACCOUNT, address(0)), 1 ether - 0.001 ether, "refund booked");
    }

    function test_postOp_sweepUntrackedTakesOnlyTheExcess() public {
        // Tracked: native credit (1 ether) and token credit.
        usd.mint(address(this), 500e18);
        usd.approve(address(pm), type(uint256).max);
        pm.depositTokenCredit(address(usd), ACCOUNT, 500e18);
        usd.mint(address(pm), 7e18); // untracked token
        vm.deal(address(pm), address(pm).balance + 0.3 ether); // untracked native

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(0xBAD)));
        pm.sweepUntracked(address(usd));

        vm.startPrank(OWNER);
        pm.sweepUntracked(address(usd));
        pm.sweepUntracked(address(0));
        pm.sweepUntracked(address(usd)); // nothing left: a no-op
        vm.stopPrank();
        assertEq(usd.balanceOf(TREASURY), 7e18);
        assertEq(TREASURY.balance, 0.3 ether);
        assertEq(usd.balanceOf(address(pm)), pm.totalCredit(address(usd)) + pm.revenue(address(usd)));
        assertEq(address(pm).balance, pm.totalCredit(address(0)) + pm.revenue(address(0)));
        vm.prank(ACCOUNT);
        pm.withdrawCredit(address(usd), ACCOUNT, 500e18);
    }

    function test_postOp_addRebateRulesIsGasChecked() public {
        ExpensiveRules expensive = new ExpensiveRules();
        _gov(keccak256("ADD_REBATE_RULES"), abi.encode(address(expensive)));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.InvalidPolicy.selector, uint8(11)));
        pm.addRebateRules(address(expensive));
    }

    function test_postOp_hookrRulesPassesTheGasCheckedProbe() public {
        address manager = address(new GaslessToken());
        address registry = address(new GaslessToken());
        RootStub root = new RootStub(manager, registry);
        address real =
            deployCode("HookrRules.sol:HookrRules", abi.encode(manager, registry, TREASURY, address(root), uint16(0)));
        _addRules(real);
        assertEq(pm.rebateRules()[1], real);
    }

    // ───────────── F-005 ─────────────

    function test_rateMovesAreBoundedPerWindow() public {
        uint128 r = USD_PER_ETH * 95 / 100;
        vm.startPrank(KEEPER);
        pm.setRate(address(usd), r, 3_600);
        // A second 5% step inside the window compounds past the anchor bound.
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.RateStepTooLarge.selector, USD_PER_ETH, r * 95 / 100));
        pm.setRate(address(usd), r * 95 / 100, 3_600);
        // Moving back toward the anchor stays allowed.
        pm.setRate(address(usd), USD_PER_ETH * 105 / 100, 3_600);
        vm.warp(block.timestamp + 1 hours);
        // A new window anchors on the rate in force.
        pm.setRate(address(usd), USD_PER_ETH * 105 / 100 * 95 / 100, 3_600);
        vm.stopPrank();
    }

    /// The audit PoC walked 480 x -5% in one transaction; the second step now reverts.
    function test_keeperWalkReverts() public {
        uint128 r = USD_PER_ETH;
        vm.startPrank(KEEPER);
        r = r * 95 / 100;
        pm.setRate(address(usd), r, 3_600);
        uint256 walked = 1;
        for (uint256 i; i < 480; ++i) {
            try pm.setRate(address(usd), r * 95 / 100, 3_600) {
                r = r * 95 / 100;
                ++walked;
            } catch {
                break;
            }
        }
        vm.stopPrank();
        assertEq(walked, 1);
        assertEq(pm.rate(address(usd)).tokenPerEth, USD_PER_ETH * 95 / 100);
    }

    function test_setTokenResetsAnchorAndBoundsStep() public {
        _gov(keccak256("SET_TOKEN"), abi.encode(address(usd), _usdConfig(), uint128(1_000e18)));
        vm.prank(KEEPER);
        pm.setRate(address(usd), USD_PER_ETH * 95 / 100, 3_600); // opens a window anchored at USD_PER_ETH
        vm.prank(OWNER);
        pm.setToken(address(usd), _usdConfig(), 1_000e18);
        vm.prank(KEEPER);
        pm.setRate(address(usd), 1_050e18, 3_600); // same window, bounded against the new initial rate

        IHookrPaymaster.TokenConfig memory bad = _usdConfig();
        bad.maxRateStepBps = bad.markupBps;
        _gov(keccak256("SET_TOKEN"), abi.encode(address(usd), bad, USD_PER_ETH));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.InvalidTokenConfig.selector, uint8(5)));
        pm.setToken(address(usd), bad, USD_PER_ETH);
    }

    // ───────────── F-017 ─────────────

    function test_sourceOutageGetsNoRebate() public {
        uint256 s0 = vm.snapshotState();
        bytes memory ctx = _validate(_op(_routeCall(), 240_000, 0), 0.01 ether);
        rules.set(ACCOUNT, address(0), 0.004 ether);
        vm.prank(address(ep));
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 0);
        assertEq(pm.rebateBudget(), 1 ether - 0.001 ether, "healthy screen: rebated");
        vm.revertToState(s0);

        screen.setMode(ScreenStandIn.Mode.OUTAGE); // sanctionStatus = (false, true)
        ctx = _validate(_op(_routeCall(), 240_000, 0), 0.01 ether);
        rules.set(ACCOUNT, address(0), 0.004 ether);
        vm.prank(address(ep));
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 0);
        assertEq(pm.rebateBudget(), 1 ether, "outage: no rebate");
        assertEq(pm.revenue(address(0)), 0.001 ether);
    }

    // ───────────── F-052 ─────────────

    function test_fundRebatesIsRestricted() public {
        vm.deal(address(0xBAD), 1 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(0xBAD)));
        pm.fundRebates{value: 1 ether}();
        vm.deal(TREASURY, 1 ether);
        vm.prank(TREASURY);
        pm.fundRebates{value: 1 ether}();
        _fundRebates(1 ether);
        assertEq(pm.rebateBudget(), 3 ether);
    }

    // ───────────── F-064 ─────────────

    function test_approveNeedsAllowlistedTarget() public {
        _gov(keccak256("ALLOW_SPENDER"), abi.encode(SPENDER));
        vm.prank(OWNER);
        pm.allowApprovalSpender(SPENDER);
        address nft = address(0xF00D); // any contract exposing approve(address,uint256)
        bytes memory approveSpender = abi.encodeWithSelector(APPROVE, SPENDER, type(uint256).max);

        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.CallNotAllowed.selector, nft, APPROVE));
        pm.validatePaymasterUserOp(_op(_approveCall(nft, approveSpender), 240_000, 0), bytes32("h"), 0.01 ether);

        _allowCall(address(usd), APPROVE);
        _validate(_op(_approveCall(address(usd), approveSpender), 240_000, 0), 0.01 ether);

        // An allowed target still needs an allowed spender and the exact 68-byte encoding.
        bytes memory other = abi.encodeWithSelector(APPROVE, address(0xE71), type(uint256).max);
        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.ApprovalNotAllowed.selector, address(0xE71)));
        pm.validatePaymasterUserOp(_op(_approveCall(address(usd), other), 240_000, 0), bytes32("h"), 0.01 ether);
        bytes memory trailing = abi.encodePacked(approveSpender, uint256(0));
        vm.prank(address(ep));
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.ApprovalNotAllowed.selector, address(0)));
        pm.validatePaymasterUserOp(_op(_approveCall(address(usd), trailing), 240_000, 0), bytes32("h"), 0.01 ether);
    }
}

/// @notice Fixes checked against the real EntryPoint v0.7 runtime, with the touched accounts cooled before every
///         bundle so storage and account access is priced cold, as for a lone op on chain.
///         Audit findings F-001 and F-002.
contract HookrPaymasterPostOpEntryPointTest is PaymasterFixtures {
    address internal constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address payable internal constant BUNDLER = payable(address(0xB0B));
    bytes32 internal constant POST_OP_REVERT_REASON = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    uint128 internal constant PVG = 60_000;
    uint128 internal constant VGL = 150_000;
    uint128 internal constant CGL = 200_000;
    uint128 internal constant PM_VGL = 250_000;
    uint128 internal constant FLOOR = 240_000;
    uint256 internal constant FEE = 0.0005 ether;

    ScreenStandIn internal screen;
    TransientRules internal rulesA;
    TransientRules internal rulesB;
    FeeTarget internal target;
    TestAccount internal bob;
    TestAccount internal alice;

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.etch(EP, EntryPointV07Code.RUNTIME);
        assertEq(EP.codehash, EntryPointV07Code.CODEHASH);
        screen = new ScreenStandIn();
        pm = new HookrPaymaster(EP, address(screen), OWNER, DELAY, TREASURY);
        usd = new GaslessToken();
        rulesA = new TransientRules();
        rulesB = new TransientRules();
        target = new FeeTarget(rulesA);
        _setPolicy(_policy(true, 0.05 ether));
        _allowCall(address(target), FeeTarget.ping.selector);
        _allowCall(address(target), FeeTarget.pay.selector);
        _setToken(address(usd), _usdConfig(), USD_PER_ETH);
        _gov(keccak256("GRANT_KEEPER"), abi.encode(KEEPER));
        vm.prank(OWNER);
        pm.grantKeeper(KEEPER);
        _fundRebates(10 ether);
        vm.deal(address(this), 100 ether);
        IEntryPointV07(EP).depositTo{value: 10 ether}(address(pm));

        bob = new TestAccount(EP);
        alice = new TestAccount(EP);
        pm.depositCredit{value: 1 ether}(address(bob));
        pm.depositCredit{value: 1 ether}(address(alice));
        usd.mint(address(bob), 100_000e18);
        usd.mint(address(alice), 100_000e18);
        bob.approveToken(usd, address(pm));
        alice.approveToken(usd, address(pm));
    }

    /// @dev 2 Rules x 4 quotes: the configuration caps.
    function _maxConfig(address a, address b) internal {
        _addRules(a);
        _addRules(b);
        address[] memory q = new address[](4);
        q[1] = address(usd);
        q[2] = address(0xC0FFEE01);
        q[3] = address(0xC0FFEE02);
        _setQuotes(q);
        _refreshRate();
    }

    function _refreshRate() internal {
        vm.prank(KEEPER);
        pm.setRate(address(usd), USD_PER_ETH, 3_600);
    }

    function _op(TestAccount who, bytes memory inner, uint8 mode, uint128 postOpGas, uint256 price)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(who);
        op.nonce = IEntryPointV07(EP).getNonce(address(who), 0);
        op.callData = abi.encodeWithSelector(TestAccount.execute.selector, address(target), uint256(0), inner);
        op.accountGasLimits = bytes32((uint256(VGL) << 128) | uint256(CGL));
        op.preVerificationGas = PVG;
        op.gasFees = bytes32((price << 128) | price);
        op.paymasterAndData = abi.encodePacked(
            address(pm),
            PM_VGL,
            postOpGas,
            mode,
            mode == 0 ? address(0) : address(usd),
            type(uint128).max,
            uint48(block.timestamp + 1 days)
        );
    }

    function _cool() internal {
        vm.cool(address(pm));
        vm.cool(EP);
        vm.cool(address(rulesA));
        vm.cool(address(rulesB));
        vm.cool(address(screen));
        vm.cool(address(usd));
        vm.cool(address(target));
        vm.cool(address(bob));
        vm.cool(address(alice));
        vm.cool(BUNDLER);
    }

    /// @return postOpReverted true when the EntryPoint reported a postOp revert for the op.
    function _run(PackedUserOperation memory op) internal returns (bool postOpReverted) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        _cool();
        vm.recordLogs();
        vm.prank(BUNDLER, BUNDLER);
        IEntryPointV07(EP).handleOps{gas: 5_000_000}(ops, BUNDLER);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == EP && logs[i].topics[0] == POST_OP_REVERT_REASON) postOpReverted = true;
        }
    }

    function _unbooked(address token) internal view returns (uint256) {
        uint256 held = token == address(0) ? address(pm).balance : usd.balanceOf(address(pm));
        return held - pm.totalCredit(token) - pm.revenue(token);
    }

    /// @dev What the EntryPoint deposit paid for the op beyond the charge booked and the rebate granted.
    function _undercharge(TestAccount who, bytes memory inner, uint128 postOpGas) internal returns (int256) {
        // The highest op gas price the cost cap admits for this gas shape.
        uint256 price = uint256(0.05 ether) / (PVG + VGL + CGL + PM_VGL + postOpGas);
        uint256 dep0 = IEntryPointV07(EP).balanceOf(address(pm));
        uint256 rev0 = pm.revenue(address(0));
        uint256 budget0 = pm.rebateBudget();
        assertFalse(_run(_op(who, inner, 0, postOpGas, price)), "postOp settles");
        uint256 depositPaid = dep0 - IEntryPointV07(EP).balanceOf(address(pm));
        uint256 accounted = (pm.revenue(address(0)) - rev0) + (budget0 - pm.rebateBudget());
        return int256(depositPaid) - int256(accounted);
    }

    // ───────────── fee attribution across ops and paymasters ─────────────

    function _opVia(HookrPaymaster p, TestAccount who, bytes memory inner, uint256 nonce)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(who);
        op.nonce = nonce;
        op.callData = abi.encodeWithSelector(TestAccount.execute.selector, address(target), uint256(0), inner);
        op.accountGasLimits = bytes32((uint256(VGL) << 128) | uint256(CGL));
        op.preVerificationGas = PVG;
        op.gasFees = bytes32((uint256(20 gwei) << 128) | uint256(20 gwei));
        op.paymasterAndData = abi.encodePacked(
            address(p), PM_VGL, FLOOR, uint8(0), address(0), type(uint128).max, uint48(block.timestamp + 1 days)
        );
    }

    /// @dev A second funded paymaster listing the same Rules ledger, configured like `pm`.
    function _secondPaymaster() internal returns (HookrPaymaster b) {
        HookrPaymaster a = pm;
        b = new HookrPaymaster(EP, address(screen), OWNER, DELAY, TREASURY);
        pm = b;
        _setPolicy(_policy(true, 0.05 ether));
        _allowCall(address(target), FeeTarget.pay.selector);
        _addRules(address(rulesA));
        _setQuotes(new address[](1));
        _fundRebates(10 ether);
        IEntryPointV07(EP).depositTo{value: 10 ether}(address(b));
        b.depositCredit{value: 1 ether}(address(alice));
        pm = a;
    }

    /// Why at most one funded paymaster may list a Rules ledger: each paymaster keeps its own attribution record. In
    /// one bundle the same account pays a fee through the first paymaster and then through the second; the second
    /// cannot see the first's record and rebates both fees. With rebateBps at most 50%, two paymasters together
    /// rebate at most the whole fee.
    function test_twoFundedPaymastersOnOneRules_secondRebatesBothFees() public {
        _addRules(address(rulesA));
        _setQuotes(new address[](1));
        HookrPaymaster b = _secondPaymaster();
        uint256 budgetA = pm.rebateBudget();
        uint256 budgetB = b.rebateBudget();
        uint256 nonce = IEntryPointV07(EP).getNonce(address(alice), 0);
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _opVia(pm, alice, abi.encodeCall(FeeTarget.pay, (FEE)), nonce);
        ops[1] = _opVia(b, alice, abi.encodeCall(FeeTarget.pay, (FEE)), nonce + 1);
        _cool();
        vm.prank(BUNDLER, BUNDLER);
        IEntryPointV07(EP).handleOps{gas: 5_000_000}(ops, BUNDLER);
        assertEq(budgetA - pm.rebateBudget(), FEE / 2, "first paymaster: its own fee");
        assertEq(budgetB - b.rebateBudget(), FEE, "second paymaster: both fees");
        assertLe(budgetA - pm.rebateBudget() + budgetB - b.rebateBudget(), 2 * FEE, "at most the fees paid");
    }

    /// The same bundle through one paymaster rebates each fee once.
    function test_onePaymaster_rebatesEachFeeOnceAcrossOps() public {
        _addRules(address(rulesA));
        _setQuotes(new address[](1));
        uint256 budget = pm.rebateBudget();
        uint256 nonce = IEntryPointV07(EP).getNonce(address(alice), 0);
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _opVia(pm, alice, abi.encodeCall(FeeTarget.pay, (FEE)), nonce);
        ops[1] = _opVia(pm, alice, abi.encodeCall(FeeTarget.pay, (FEE)), nonce + 1);
        _cool();
        vm.prank(BUNDLER, BUNDLER);
        IEntryPointV07(EP).handleOps{gas: 5_000_000}(ops, BUNDLER);
        assertEq(budget - pm.rebateBudget(), FEE, "one rebate per fee");
    }

    // ───────────── F-001 ─────────────

    /// A self-bundled op at the highest price the cost cap admits never costs the deposit more than it books, in
    /// the heaviest read configuration with cold state, with and without a protocol fee, at both postOp limits.
    function test_selfBundledOpNeverUndercharged() public {
        _addRules(address(rulesA));
        _addRules(address(rulesB));
        address[] memory q = new address[](4);
        q[1] = address(0xC0FFEE00);
        q[2] = address(0xC0FFEE01);
        q[3] = address(0xC0FFEE02);
        _setQuotes(q);
        uint128[2] memory limits = [FLOOR, uint128(300_000)];
        for (uint256 i; i < 2; ++i) {
            assertLe(_undercharge(alice, abi.encodeCall(FeeTarget.ping, ()), limits[i]), 0, "no fee");
            assertLe(_undercharge(alice, abi.encodeCall(FeeTarget.pay, (2)), limits[i]), 0, "first rebate");
            vm.warp(block.timestamp + 60);
            assertLe(_undercharge(alice, abi.encodeCall(FeeTarget.pay, (2)), limits[i]), 0, "repeat rebate");
            vm.warp(block.timestamp + 1 days);
        }
    }

    // ───────────── F-002 ─────────────

    /// The worst ledger state (2 x 4, new token account, first op of the UTC day, revenue swept, no token credit
    /// outstanding, a screen that burns its whole stipend) settles at the floor with balanced books.
    function test_postOp_coldWorstStateSettlesAtFloor() public {
        _maxConfig(address(rulesA), address(rulesB));
        assertFalse(_run(_op(bob, abi.encodeCall(FeeTarget.pay, (FEE)), 1, 300_000, 20 gwei)), "bob token");
        assertFalse(_run(_op(bob, abi.encodeCall(FeeTarget.pay, (FEE)), 0, 300_000, 20 gwei)), "bob credit");
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 5);
        _refreshRate();
        vm.startPrank(OWNER);
        pm.withdrawRevenue(address(usd), pm.revenue(address(usd)));
        pm.withdrawRevenue(address(0), pm.revenue(address(0)));
        vm.stopPrank();
        uint256 bobUsd = pm.credit(address(bob), address(usd));
        vm.prank(address(bob));
        pm.withdrawCredit(address(usd), address(bob), bobUsd);
        assertEq(pm.totalCredit(address(usd)), 0);
        screen.setMode(ScreenStandIn.Mode.BURN);

        uint256 s0 = vm.snapshotState();
        assertFalse(_run(_op(alice, abi.encodeCall(FeeTarget.pay, (FEE)), 1, FLOOR, 20 gwei)), "token op");
        assertEq(_unbooked(address(usd)), 0, "usd books");
        vm.revertToState(s0);
        TestAccount carol = new TestAccount(EP);
        pm.depositCredit{value: 1 ether}(address(carol));
        assertFalse(_run(_op(carol, abi.encodeCall(FeeTarget.pay, (FEE)), 0, FLOOR, 20 gwei)), "credit op");
        assertEq(_unbooked(address(0)), 0, "native books");
        assertEq(_unbooked(address(usd)), 0, "usd books");
    }

    /// The gate still pays rebates from cold state: 1 Rules x 1 quote at the floor, and the caps at POST_OP_GAS_MAX.
    function test_postOp_rebatePaidWhenPostOpGasSuffices() public {
        _addRules(address(rulesA));
        address[] memory one = new address[](1);
        _setQuotes(one);
        _refreshRate();
        uint256 budget0 = pm.rebateBudget();
        assertFalse(_run(_op(alice, abi.encodeCall(FeeTarget.pay, (FEE)), 1, FLOOR, 20 gwei)), "token op");
        assertLt(pm.rebateBudget(), budget0, "1 x 1 rebated at the floor");

        _addRules(address(rulesB));
        address[] memory q = new address[](4);
        q[1] = address(usd);
        q[2] = address(0xC0FFEE01);
        q[3] = address(0xC0FFEE02);
        _setQuotes(q);
        _refreshRate();
        budget0 = pm.rebateBudget();
        assertFalse(_run(_op(bob, abi.encodeCall(FeeTarget.pay, (FEE)), 1, 300_000, 20 gwei)), "token op");
        assertLt(pm.rebateBudget(), budget0, "2 x 4 rebated at the postOp maximum");
    }

    /// Admitted Rules that spend their whole read stipend and still report a fee, with a healthy or a stipend-burning
    /// screen, cannot starve settlement at the floor: the rebate is skipped and the charge and refund are booked.
    function test_postOp_slowRulesCannotStarveSettlement() public {
        SlowRules slowA = new SlowRules();
        SlowRules slowB = new SlowRules();
        _maxConfig(address(slowA), address(slowB));
        uint256 budget0 = pm.rebateBudget();
        for (uint256 i; i < 2; ++i) {
            if (i == 1) screen.setMode(ScreenStandIn.Mode.BURN);
            vm.cool(address(slowA));
            vm.cool(address(slowB));
            assertFalse(_run(_op(alice, abi.encodeCall(FeeTarget.ping, ()), 1, FLOOR, 20 gwei)), "token op");
            vm.cool(address(slowA));
            vm.cool(address(slowB));
            assertFalse(_run(_op(alice, abi.encodeCall(FeeTarget.ping, ()), 0, FLOOR, 20 gwei)), "credit op");
        }
        assertEq(pm.rebateBudget(), budget0, "no rebate");
        assertEq(_unbooked(address(usd)), 0, "usd books");
        assertEq(_unbooked(address(0)), 0, "native books");
        assertGt(pm.revenue(address(usd)), 0, "token charge booked");
        assertGt(pm.revenue(address(0)), 0, "credit charge booked");
    }
}
