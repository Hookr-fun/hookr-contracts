// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {IPaymaster} from "../../src/interfaces/external/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {GaslessToken, MockRulesLedger} from "../gasless/GaslessMocks.sol";
import {EntryPointV07Code} from "../gasless/EntryPointV07Code.sol";
import {IPermit2Bench, GasBenchFixture} from "../utils/GasBenchFixture.sol";
import {GasMeasure} from "../utils/GasMeasure.sol";

/// @notice Per-transaction gas bench. Each measured call is its own top-level call; run it with
///         `forge test --isolate --match-path test/bench/GasBench.t.sol -vv` for per-transaction totals (intrinsic
///         gas, cold access and refunds included). The totals are committed in snapshots/GasBench.json, and the bench
///         step of CI fails when one differs (see GasMeasure).
contract GasBench is GasBenchFixture, GasMeasure {
    HookrFeeAdvisory internal advisory;
    /// @dev The fee-only pool's Rules with HookrFeeAdvisory (fail-closed, 500-pip surcharge, 1,000-pip cap).
    PoolKey internal advisedKey;
    /// @dev The full pool's Rules with the same advisory.
    PoolKey internal advisedFullKey;

    function setUp() public override {
        super.setUp();
        advisory = new HookrFeeAdvisory(address(this), 30 minutes, registry, address(0));
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: advisory.configSchemaHash(),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 200_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        advisedKey = _launchAdvised(Currency.wrap(address(quoteFee)), false);
        advisedFullKey = _launchAdvised(Currency.wrap(address(quoteFull)), true);
    }

    function _launchAdvised(Currency quote, bool full) internal returns (PoolKey memory) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote, 120, full);
        members[0].config.advisory = address(advisory);
        members[0].config.advisoryGasLimit = 200_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        bytes[] memory configs = new bytes[](1);
        configs[0] = abi.encode(IHookrFeeAdvisory.Config(1000, 500, 0, 0, 5000, 60, 1 hours));
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    // ───────────────────────────── Universal Router ─────────────────────────────

    function test_gas_ur_fee_buy() public {
        _warm(feeKey);
        _urSwap(feeKey, true, 1e21);
        _measure("ur.fee.buy");
    }

    function test_gas_ur_fee_sell() public {
        _warm(feeKey);
        _urSwap(feeKey, false, 1e21);
        _measure("ur.fee.sell");
    }

    function test_gas_ur_full_buy() public {
        _warm(fullKey);
        _urSwap(fullKey, true, 1e21);
        _measure("ur.full.buy");
    }

    function test_gas_ur_full_sell() public {
        _warm(fullKey);
        _urSwap(fullKey, false, 1e21);
        _measure("ur.full.sell");
    }

    function test_gas_ur_advised_buy() public {
        _warm(advisedKey);
        _urSwap(advisedKey, true, 1e21);
        _measure("ur.advised.buy");
    }

    function test_gas_ur_advised_sell() public {
        _warm(advisedKey);
        _urSwap(advisedKey, false, 1e21);
        _measure("ur.advised.sell");
    }

    function test_gas_ur_advisedFull_buy() public {
        _warm(advisedFullKey);
        _urSwap(advisedFullKey, true, 1e21);
        _measure("ur.advisedFull.buy");
    }

    function test_gas_ur_advisedFull_sell() public {
        _warm(advisedFullKey);
        _urSwap(advisedFullKey, false, 1e21);
        _measure("ur.advisedFull.sell");
    }

    // ───────────────────────────── Hookr Router ─────────────────────────────

    function test_gas_router_fee_buy() public {
        _warm(feeKey);
        _routerSwap(feeKey, true, 1e21);
        _measure("router.fee.buy");
    }

    function test_gas_router_fee_sell() public {
        _warm(feeKey);
        _routerSwap(feeKey, false, 1e21);
        _measure("router.fee.sell");
    }

    function test_gas_router_full_buy() public {
        _warm(fullKey);
        _routerSwap(fullKey, true, 1e21);
        _measure("router.full.buy");
    }

    function test_gas_router_full_sell() public {
        _warm(fullKey);
        _routerSwap(fullKey, false, 1e21);
        _measure("router.full.sell");
    }

    function test_gas_router_advised_buy() public {
        _warm(advisedKey);
        _routerSwap(advisedKey, true, 1e21);
        _measure("router.advised.buy");
    }

    function test_gas_router_advised_sell() public {
        _warm(advisedKey);
        _routerSwap(advisedKey, false, 1e21);
        _measure("router.advised.sell");
    }

    function test_gas_router_advisedFull_buy() public {
        _warm(advisedFullKey);
        _routerSwap(advisedFullKey, true, 1e21);
        _measure("router.advisedFull.buy");
    }

    function test_gas_router_advisedFull_sell() public {
        _warm(advisedFullKey);
        _routerSwap(advisedFullKey, false, 1e21);
        _measure("router.advisedFull.sell");
    }

    // ───────────────────────────── relayed (Forwarder, real Permit2) ─────────────────────────────

    function test_gas_relayed_fee_buy() public {
        _warm(feeKey);
        _relayed(feeKey, true, 1e21, 2);
        _measure("relayed.fee.buy");
    }

    function test_gas_relayed_fee_sell() public {
        _warm(feeKey);
        _relayed(feeKey, false, 1e21, 2);
        _measure("relayed.fee.sell");
    }

    function test_gas_relayed_full_buy() public {
        _warm(fullKey);
        _relayed(fullKey, true, 1e21, 2);
        _measure("relayed.full.buy");
    }

    // ───────────────────────────── rewarded (program receipt) ─────────────────────────────

    /// @dev An Immediate points program on `key`'s pool, in a fresh HookrPrograms that trusts the router.
    function _campaign(PoolKey memory key) internal returns (HookrPrograms e, uint256[] memory ids) {
        e = new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        P.Terms memory t;
        t.mode = P.Mode.Immediate;
        t.start = uint64(vm.getBlockTimestamp());
        t.end = uint64(vm.getBlockTimestamp() + 1 days);
        t.pointBudget = 1e30;
        t.walletPointCap = 1e30;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("authenticated-router-user-swap");
        t.name = "Receipts";
        t.pointDecimals = 18;
        P.Scope[] memory s = new P.Scope[](1);
        s[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(root.poolConfig(key.toId()).quote),
            1,
            1,
            0,
            0
        );
        ids = new uint256[](1);
        ids[0] = e.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
    }

    function _rewardedSwap(PoolKey memory key, bool buy, uint128 amount, HookrPrograms e, uint256[] memory ids)
        internal
    {
        IHookrRouter.Swap memory p = _params(key, buy, amount);
        vm.prank(trader);
        router.swap(p, address(e), ids);
    }

    /// @dev Steady state: the pool warmed and the trader's points in the program already nonzero.
    function _rewardedRow(PoolKey memory key, string memory label) internal {
        (HookrPrograms e, uint256[] memory ids) = _campaign(key);
        _warm(key);
        _rewardedSwap(key, true, 1e21, e, ids);
        _nextBlock();
        _rewardedSwap(key, true, 1e21, e, ids);
        _measure(label);
    }

    function test_gas_router_fee_rewarded_buy() public {
        _rewardedRow(feeKey, "router.fee.rewarded.buy");
    }

    function test_gas_router_full_rewarded_buy() public {
        _rewardedRow(fullKey, "router.full.rewarded.buy");
    }

    // ───────────────────────────── launches and liquidity ─────────────────────────────

    function test_gas_launch_1member() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quotes[0])), 60, true);
        launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        _measure("launch.1member");
    }

    function test_gas_launch_8member() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](8);
        for (uint256 i; i < 8; ++i) {
            members[i] = _member(Currency.wrap(address(quotes[i])), 60, true);
        }
        launcher.launch(
            IHookrLauncher.Token(address(0), "New", "NEW", 1e27, bytes32(uint256(2))),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        _measure("launch.8member");
    }

    /// @dev A new-token member against ETH opening at price 1, its band [-60,000, 0] holding 99.9% of the 1e27 supply
    ///      in subject, guarded with a 50% Snipe, a 1e22 per-block cap and a 25% protocol share; `full` adds dynamic
    ///      fees, Auto Burn, LP Rewards and royalty as in the full pool.
    function _newTokenMembers(bytes32 salt, bool full)
        internal
        view
        returns (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members)
    {
        t = IHookrLauncher.Token(address(0), "New", "NEW", 1e27, salt);
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)), 60, full);
        members[0].tickLower = -60_000;
        members[0].tickUpper = 0;
        uint160 lower = TickMath.getSqrtPriceAtTick(-60_000);
        members[0].liquidity = LiquidityAmounts.getLiquidityForAmount1(lower, SQRT_ONE, 1e27) / 1000 * 999;
        members[0].amount0Max = 0;
        members[0].amount1Max = 1e27;
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
        members[0].rules.snipeTaxPips = 500_000;
        members[0].rules.maxBuyQuoteAmount = 1e22;
    }

    function test_gas_launch_newToken_1member() public {
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) =
            _newTokenMembers(bytes32(uint256(7)), false);
        launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        _measure("launch.newToken.1member");
    }

    /// @dev The launch above followed, in its own transaction, by a Hookr router buy of the dev buy's size.
    function test_gas_launch_newToken_1member_thenRouterBuy() public {
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) =
            _newTokenMembers(bytes32(uint256(7)), false);
        (bytes32 family,) = launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        PoolKey memory key = launcher.position(family, 0).key;
        IHookrRouter.Swap memory p =
            IHookrRouter.Swap(key, true, -1e21, 1, MIN_PRICE, trader, vm.getBlockTimestamp() + 1000);
        vm.prank(trader);
        router.swap{value: 1e21}(p, address(0), new uint256[](0));
        _measure("launch.newToken.1member.firstRouterBuy");
    }

    function test_gas_launch_newToken_1member_devBuy() public {
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) =
            _newTokenMembers(bytes32(uint256(7)), false);
        launcher.launchWithBuy{value: 1e21}(
            t, address(root), members, new bytes[](1), IHookrLauncher.DevBuy(0, 1e21, 1, 0), vm.getBlockTimestamp()
        );
        _measure("launch.newToken.1member.devBuy");
    }

    function test_gas_launch_newToken_1member_full() public {
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) =
            _newTokenMembers(bytes32(uint256(7)), true);
        launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        _measure("launch.newToken.1member.full");
    }

    function test_gas_launch_newToken_1member_devBuy_full() public {
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) =
            _newTokenMembers(bytes32(uint256(7)), true);
        launcher.launchWithBuy{value: 1e21}(
            t, address(root), members, new bytes[](1), IHookrLauncher.DevBuy(0, 1e21, 1, 0), vm.getBlockTimestamp()
        );
        _measure("launch.newToken.1member.devBuy.full");
    }

    function test_gas_addLiquidity() public {
        _warm(fullKey);
        launcher.addLiquidity(fullFamily, 0, 1e21, 1e24, 1e24, vm.getBlockTimestamp());
        _measure("liquidity.add");
    }

    function test_gas_removeLiquidity() public {
        _warm(fullKey);
        launcher.withdraw(fullFamily, 0, 1e21, 1, 1, address(this), vm.getBlockTimestamp());
        _measure("liquidity.remove");
    }

    function test_gas_collectFees() public {
        _warm(fullKey);
        launcher.withdraw(fullFamily, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        _measure("liquidity.collect");
    }
}

/// @notice Paymaster bench: each EntryPoint callback is its own top-level call from the EntryPoint address, so with
///         --isolate every measurement is a cold transaction. The fee ledger is a storage mock, so the fee survives
///         into postOp's transaction. Totals are committed in snapshots/PaymasterGasBench.json.
contract PaymasterGasBench is GasMeasure {
    address internal constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant OWNER = address(0xA0);
    address internal constant TREASURY = address(0x7E);
    address internal constant KEEPER = address(0x4E);
    address internal constant ACCOUNT = address(0xACC);
    address internal constant TARGET = address(0x4001);
    bytes4 internal constant ROUTE = 0x19b36adf;

    HookrPaymaster internal pm;
    GaslessToken internal usd;
    MockRulesLedger internal rulesA;
    MockRulesLedger internal rulesB;

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.etch(EP, EntryPointV07Code.RUNTIME);
        usd = new GaslessToken();
        rulesA = new MockRulesLedger();
        rulesB = new MockRulesLedger();
        pm = _deploy();
        _gov(
            keccak256("SET_POLICY"),
            abi.encode(IHookrPaymaster.Policy(5_000, 0.01 ether, 0.05 ether, false, 1 ether, 0.05 ether, 100 gwei))
        );
        vm.prank(OWNER);
        pm.setPolicy(IHookrPaymaster.Policy(5_000, 0.01 ether, 0.05 ether, false, 1 ether, 0.05 ether, 100 gwei));
        _gov(keccak256("ALLOW_CALL"), abi.encode(TARGET, ROUTE, false));
        vm.prank(OWNER);
        pm.allowCall(TARGET, ROUTE, false);
        IHookrPaymaster.TokenConfig memory cfg = IHookrPaymaster.TokenConfig(true, false, 1_100, 500, 3_600);
        _gov(keccak256("SET_TOKEN"), abi.encode(address(usd), cfg, uint128(3_000e18)));
        vm.prank(OWNER);
        pm.setToken(address(usd), cfg, 3_000e18);
        _gov(keccak256("ADD_REBATE_RULES"), abi.encode(address(rulesA)));
        vm.prank(OWNER);
        pm.addRebateRules(address(rulesA));
        _gov(keccak256("GRANT_KEEPER"), abi.encode(KEEPER));
        vm.prank(OWNER);
        pm.grantKeeper(KEEPER);
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        pm.fundRebates{value: 1 ether}();
        vm.deal(address(this), 10 ether);
        pm.depositCredit{value: 1 ether}(ACCOUNT);
        usd.mint(ACCOUNT, 1_000_000e18);
        vm.prank(ACCOUNT);
        usd.approve(address(pm), type(uint256).max);
        // Steady state: the day's rebate words, revenue and the account's token balance at the paymaster are nonzero.
        address[] memory one = new address[](1);
        _quotes(one);
        _settle(0, 0.004 ether);
        _settle(1, 0.004 ether);
    }

    function _deploy() internal returns (HookrPaymaster) {
        return new HookrPaymaster(EP, address(0), OWNER, 30 minutes, TREASURY);
    }

    function _gov(bytes32 kind, bytes memory args) internal {
        vm.prank(OWNER);
        pm.queue(kind, args);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
    }

    function _quotes(address[] memory q) internal {
        _gov(keccak256("SET_REBATE_QUOTES"), abi.encode(q));
        vm.prank(OWNER);
        pm.setRebateQuotes(q);
        vm.prank(KEEPER);
        pm.setRate(address(usd), 3_000e18, 3_600);
    }

    function _op(uint8 mode) internal view returns (PackedUserOperation memory op) {
        op.sender = ACCOUNT;
        op.callData = abi.encodeWithSelector(0xb61d27f6, TARGET, 0, abi.encodeWithSelector(ROUTE));
        op.accountGasLimits = bytes32(uint256(200_000));
        op.gasFees = bytes32(uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(
            address(pm),
            uint128(100_000),
            uint128(240_000),
            mode,
            mode == 0 ? address(0) : address(usd),
            type(uint128).max,
            uint48(vm.getBlockTimestamp() + 1 days)
        );
    }

    function _validate(uint8 mode) internal returns (bytes memory ctx) {
        vm.prank(EP);
        (ctx,) = pm.validatePaymasterUserOp(_op(mode), bytes32("h"), 0.01 ether);
    }

    function _settle(uint8 mode, uint256 fee) internal {
        bytes memory ctx = _validate(mode);
        rulesA.set(ACCOUNT, address(0), fee);
        vm.prank(EP);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 1 gwei);
    }

    function test_gas_paymaster_validate_credit() public {
        vm.prank(EP);
        pm.validatePaymasterUserOp(_op(0), bytes32("h"), 0.01 ether);
        _measure("paymaster.validate.credit");
    }

    function test_gas_paymaster_validate_token() public {
        vm.prank(EP);
        pm.validatePaymasterUserOp(_op(1), bytes32("h"), 0.01 ether);
        _measure("paymaster.validate.token");
    }

    function test_gas_paymaster_postOp_credit_noFee() public {
        bytes memory ctx = _validate(0);
        rulesA.set(ACCOUNT, address(0), 0);
        vm.prank(EP);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 1 gwei);
        _measure("paymaster.postOp.credit.noFee");
    }

    function test_gas_paymaster_postOp_credit_rebate() public {
        bytes memory ctx = _validate(0);
        rulesA.set(ACCOUNT, address(0), 0.004 ether);
        uint256 budget = pm.rebateBudget();
        vm.prank(EP);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 1 gwei);
        _measure("paymaster.postOp.credit.rebate");
        assertLt(pm.rebateBudget(), budget, "rebated");
    }

    function test_gas_paymaster_postOp_token_rebate() public {
        bytes memory ctx = _validate(1);
        rulesA.set(ACCOUNT, address(0), 0.004 ether);
        uint256 budget = pm.rebateBudget();
        vm.prank(EP);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 1 gwei);
        _measure("paymaster.postOp.token.rebate");
        assertLt(pm.rebateBudget(), budget, "rebated");
    }

    /// @dev The read caps: 2 Rules x 4 quotes.
    function test_gas_paymaster_postOp_credit_rebate_2x4() public {
        _gov(keccak256("ADD_REBATE_RULES"), abi.encode(address(rulesB)));
        vm.prank(OWNER);
        pm.addRebateRules(address(rulesB));
        address[] memory q = new address[](4);
        q[1] = address(usd);
        q[2] = address(0xC0FFEE01);
        q[3] = address(0xC0FFEE02);
        _quotes(q);
        bytes memory ctx = _validate(0);
        rulesA.set(ACCOUNT, address(0), 0.004 ether);
        uint256 budget = pm.rebateBudget();
        vm.prank(EP);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 1 gwei);
        _measure("paymaster.postOp.credit.rebate.2x4");
        assertLt(pm.rebateBudget(), budget, "rebated");
    }
}

/// @notice Off-market fees on HookrRoot. Four fee-only pools on one quote token, told apart by tick spacing: no
///         advisory, HookrFeeAdvisory without tiers, HookrSessionAdvisory, and HookrFeeAdvisory with session tiers. Every
///         advised pool charges 500 pips in regular hours (the tiered pool as a 200-pip keeper default plus a 300-pip
///         tier), measured on Tuesday 2026-09-29 at 11:00 New York. Same method as GasBench.
contract GasBenchSession is GasBenchFixture, GasMeasure {
    HookrSessionAdvisory internal session;
    HookrFeeAdvisory internal tiered;
    PoolKey internal plainKey;
    PoolKey internal untieredKey;
    PoolKey internal sessionKey;
    PoolKey internal tieredKey;

    function setUp() public override {
        super.setUp();
        session = new HookrSessionAdvisory(address(this), 30 minutes);
        tiered = new HookrFeeAdvisory(address(this), 30 minutes, registry, address(session));
        _admit(address(session), session.configSchemaHash(), 150_000);
        _admit(address(tiered), tiered.configSchemaHash(), 200_000);
        HookrToken q = _quote();
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(address(q), true);
        IHookrFeeAdvisory.Config memory keeper = IHookrFeeAdvisory.Config(1000, 200, 0, 0, 5000, 60, 1 hours);
        plainKey = _launch(q, 60, address(0), 0, "");
        untieredKey = _launch(
            q, 120, address(tiered), 200_000, abi.encode(IHookrFeeAdvisory.Config(1000, 500, 0, 0, 5000, 60, 1 hours))
        );
        sessionKey = _launch(q, 200, address(session), 150_000, abi.encode(_tiers(500, 800, 800, 1000, 1000)));
        tieredKey = _launch(q, 240, address(tiered), 200_000, abi.encode(keeper, _tiers(300, 600, 600, 800, 800)));
        vm.warp(HookrMarketCalendar.dayOf(2026, 9, 29) * 1 days + 15 hours);
    }

    function _tiers(uint24 regular, uint24 pre, uint24 afterHours, uint24 night, uint24 closed)
        internal
        pure
        returns (HookrSessionTiers.Tiers memory)
    {
        return HookrSessionTiers.Tiers(regular, pre, afterHours, night, closed, 0, 0, 0);
    }

    function _admit(address module, bytes32 schema, uint32 gasLimit) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: module,
            codeHash: module.codehash,
            schemaHash: schema,
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: gasLimit,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev A catalog quote funded and approved like the standing quotes.
    function _quote() internal returns (HookrToken t) {
        t = new HookrToken("Quote S", "QS", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        t.transfer(trader, 1e27);
        t.transfer(owner, 1e27);
        vm.startPrank(trader);
        t.approve(address(router), type(uint256).max);
        t.approve(permit2, type(uint256).max);
        IPermit2Bench(permit2).approve(address(t), ur, type(uint160).max, type(uint48).max);
        vm.stopPrank();
        vm.prank(owner);
        t.approve(permit2, type(uint256).max);
        registry.queue(registry.SET_QUOTE(), abi.encode(address(t), true));
    }

    function _launch(HookrToken quote, int24 spacing, address module, uint32 gasLimit, bytes memory data)
        internal
        returns (PoolKey memory)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quote)), spacing, false);
        bytes32 family;
        if (module == address(0)) {
            (family,) = launcher.launch(
                IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
                address(root),
                members,
                vm.getBlockTimestamp()
            );
            return launcher.position(family, 0).key;
        }
        members[0].config.advisory = module;
        members[0].config.advisoryGasLimit = gasLimit;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        bytes[] memory configs = new bytes[](1);
        configs[0] = data;
        (family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    function _ur(PoolKey memory key, bool buy, string memory label) internal {
        _warm(key);
        _urSwap(key, buy, 1e21);
        _measure(label);
    }

    function _router(PoolKey memory key, bool buy, string memory label) internal {
        _warm(key);
        _routerSwap(key, buy, 1e21);
        _measure(label);
    }

    function test_gas_ur_offPlain_buy() public {
        _ur(plainKey, true, "ur.offPlain.buy");
    }

    function test_gas_ur_offPlain_sell() public {
        _ur(plainKey, false, "ur.offPlain.sell");
    }

    function test_gas_ur_offFee_buy() public {
        _ur(untieredKey, true, "ur.offFee.buy");
    }

    function test_gas_ur_offFee_sell() public {
        _ur(untieredKey, false, "ur.offFee.sell");
    }

    function test_gas_ur_session_buy() public {
        _ur(sessionKey, true, "ur.session.buy");
    }

    function test_gas_ur_session_sell() public {
        _ur(sessionKey, false, "ur.session.sell");
    }

    function test_gas_ur_feeTiers_buy() public {
        _ur(tieredKey, true, "ur.feeTiers.buy");
    }

    function test_gas_ur_feeTiers_sell() public {
        _ur(tieredKey, false, "ur.feeTiers.sell");
    }

    function test_gas_router_offPlain_buy() public {
        _router(plainKey, true, "router.offPlain.buy");
    }

    function test_gas_router_offPlain_sell() public {
        _router(plainKey, false, "router.offPlain.sell");
    }

    function test_gas_router_offFee_buy() public {
        _router(untieredKey, true, "router.offFee.buy");
    }

    function test_gas_router_offFee_sell() public {
        _router(untieredKey, false, "router.offFee.sell");
    }

    function test_gas_router_session_buy() public {
        _router(sessionKey, true, "router.session.buy");
    }

    function test_gas_router_session_sell() public {
        _router(sessionKey, false, "router.session.sell");
    }

    function test_gas_router_feeTiers_buy() public {
        _router(tieredKey, true, "router.feeTiers.buy");
    }

    function test_gas_router_feeTiers_sell() public {
        _router(tieredKey, false, "router.feeTiers.sell");
    }

    /// @dev Every advised pool charges base 3,000 + 500 pips in regular hours; on Saturday the session pool charges its
    ///      1,000-pip closed tier and the tiered pool 200 + 800.
    function test_sessionFeesCharged() public {
        assertEq(quoter.quote(_params(plainKey, true, 1e18), trader).lpFeePips, 3000);
        assertEq(quoter.quote(_params(untieredKey, true, 1e18), trader).lpFeePips, 3500);
        assertEq(quoter.quote(_params(sessionKey, true, 1e18), trader).lpFeePips, 3500);
        assertEq(quoter.quote(_params(tieredKey, true, 1e18), trader).lpFeePips, 3500);
        vm.warp(HookrMarketCalendar.dayOf(2026, 10, 3) * 1 days + 16 hours);
        assertEq(quoter.quote(_params(untieredKey, true, 1e18), trader).lpFeePips, 3500);
        assertEq(quoter.quote(_params(sessionKey, true, 1e18), trader).lpFeePips, 4000);
        assertEq(quoter.quote(_params(tieredKey, true, 1e18), trader).lpFeePips, 4000);
    }
}

/// @notice Anti-Snipe buys during the launch guard. Four pools on the fee-only quote, told apart by tick spacing, each
///         with a 50% Snipe tax, a 25% protocol share and no other rule: flat and decaying to 1% over 120 s, each with
///         no buy cap and with a 1e22 cap per parent block.
///         Measured 36 s after launch, when the decaying tax is 35.30%. Same method as GasBench.
contract GasBenchSnipe is GasBenchFixture, GasMeasure {
    PoolKey internal flatKey;
    PoolKey internal decayKey;
    PoolKey internal flatCappedKey;
    PoolKey internal decayCappedKey;

    function setUp() public override {
        super.setUp();
        flatKey = _launchSnipe(120, 0, 0, 0);
        decayKey = _launchSnipe(200, 10_000, 120, 0);
        flatCappedKey = _launchSnipe(240, 0, 0, 1e22);
        decayCappedKey = _launchSnipe(300, 10_000, 120, 1e22);
    }

    function _launchSnipe(int24 spacing, uint24 floor, uint16 decay, uint128 cap) internal returns (PoolKey memory) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quoteFee)), spacing, false);
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
        members[0].rules.snipeTaxPips = 500_000;
        members[0].rules.snipeFloorPips = floor;
        members[0].rules.snipeDecaySeconds = decay;
        members[0].rules.maxBuyQuoteAmount = cap;
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    function test_gas_router_snipeFlat_buy() public {
        _warm(flatKey);
        _routerSwap(flatKey, true, 1e21);
        _measure("router.snipeFlat.buy");
    }

    function test_gas_router_snipeFlat_sell() public {
        _warm(flatKey);
        _routerSwap(flatKey, false, 1e21);
        _measure("router.snipeFlat.sell");
    }

    function test_gas_router_snipeDecay_buy() public {
        _warm(decayKey);
        _routerSwap(decayKey, true, 1e21);
        _measure("router.snipeDecay.buy");
    }

    function test_gas_ur_snipeFlat_buy() public {
        _warm(flatKey);
        _urSwap(flatKey, true, 1e21);
        _measure("ur.snipeFlat.buy");
    }

    function test_gas_ur_snipeDecay_buy() public {
        _warm(decayKey);
        _urSwap(decayKey, true, 1e21);
        _measure("ur.snipeDecay.buy");
    }

    function test_gas_router_snipeFlatCapped_buy() public {
        _warm(flatCappedKey);
        _routerSwap(flatCappedKey, true, 1e21);
        _measure("router.snipeFlatCapped.buy");
    }

    function test_gas_router_snipeDecayCapped_buy() public {
        _warm(decayCappedKey);
        _routerSwap(decayCappedKey, true, 1e21);
        _measure("router.snipeDecayCapped.buy");
    }

    function test_gas_ur_snipeFlatCapped_buy() public {
        _warm(flatCappedKey);
        _urSwap(flatCappedKey, true, 1e21);
        _measure("ur.snipeFlatCapped.buy");
    }

    function test_gas_ur_snipeDecayCapped_buy() public {
        _warm(decayCappedKey);
        _urSwap(decayCappedKey, true, 1e21);
        _measure("ur.snipeDecayCapped.buy");
    }

    /// @dev 36 s after launch the decaying pool charges 10,000 + 490,000 * 84 / 120 = 353,000 pips of Snipe, 75% of it
    ///      as LP fee; the flat pool still charges 500,000.
    function test_snipeCharged() public {
        _warm(decayKey);
        assertEq(quoter.quote(_params(flatKey, true, 1e18), trader).lpFeePips, 3000 + 375_000);
        assertEq(quoter.quote(_params(decayKey, true, 1e18), trader).lpFeePips, 3000 + 353_000 - 88_250);
    }
}
