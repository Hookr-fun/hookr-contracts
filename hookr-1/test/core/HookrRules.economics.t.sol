// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @dev ERC-20 whose issuer can switch on a transfer fee.
contract FeeSwitchToken {
    string public name = "Fee Switch";
    string public symbol = "FSW";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public feeBps;
    address public immutable issuer;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint256 supply) {
        issuer = msg.sender;
        balanceOf[msg.sender] = supply;
        totalSupply = supply;
    }

    function setFee(uint256 bps) external {
        require(msg.sender == issuer, "issuer");
        feeBps = bps;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        balanceOf[f] -= a;
        uint256 fee = a * feeBps / 10_000;
        balanceOf[to] += a - fee;
        totalSupply -= fee;
        emit Transfer(f, to, a - fee);
    }
}

/// @notice Audit findings F-015, F-033, F-034, F-041 and F-061.
contract RulesEconomicsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpPeriphery();
    }

    function _subjectAndQuote() internal view returns (address subject, Currency quote) {
        bool aFirst = address(tokenA) < address(tokenB);
        subject = aFirst ? address(tokenA) : address(tokenB);
        quote = Currency.wrap(aFirst ? address(tokenB) : address(tokenA));
    }

    function _open(IHookrLauncher.Member memory m, address subject) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(subject, "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _dynamicFeePool(int24 spacing) internal returns (PoolKey memory key, Currency quote) {
        address subject;
        (subject, quote) = _subjectAndQuote();
        IHookrLauncher.Member memory m = _member(quote);
        m.tickSpacing = spacing;
        m.rules.maxFeePips = 100_000;
        m.rules.dynamicFeeSens = 5;
        key = _open(m, subject);
    }

    function _trade(IHookrRouter.Swap memory p) internal returns (uint256 input, uint256 output) {
        vm.prank(trader, trader);
        (input, output) = router.swap(p, address(0), new uint256[](0));
    }

    // ------------------------------------------------------------------------------------------ F-034

    /// F-034: an exact-output sell credited the protocol nothing, so cost-minimising routers chose it.
    function testExactOutputSellPaysTheProtocolDynamicFeeShare() public {
        (PoolKey memory key, Currency quote) = _dynamicFeePool(60);
        uint256 p0 = rules.claimable(quote, protocol);
        (, uint256 quoteOut) = _trade(_swap(key, false, false, 4e22));
        assertEq(quoteOut, 4e22, "seller nets exactly the requested output");
        assertGt(rules.claimable(quote, protocol) - p0, 0, "exact-output sell pays the protocol");
        assertTrue(rules.accountingInvariant(quote));
    }

    /// Twin fresh dynamic fee pools: the exact-output sell for the exact-input sell's output now pays about the same
    /// protocol fee and costs the seller about the same subject.
    function testExactOutputSellIsNoLongerTheCheaperRoute() public {
        (PoolKey memory a, Currency quote) = _dynamicFeePool(60);
        (PoolKey memory b,) = _dynamicFeePool(120);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 p0 = rules.claimable(quote, protocol);
        (uint256 inA, uint256 outA) = _trade(_swap(a, false, true, 5e22));
        uint256 protoA = rules.claimable(quote, protocol) - p0;
        vm.roll(vm.getBlockNumber() + 1);
        p0 = rules.claimable(quote, protocol);
        (uint256 inB, uint256 outB) = _trade(_swap(b, false, false, uint128(outA)));
        uint256 protoB = rules.claimable(quote, protocol) - p0;
        emit log_named_uint("exact-in  sell: subject in", inA);
        emit log_named_uint("exact-in  sell: protocol", protoA);
        emit log_named_uint("exact-out sell: subject in", inB);
        emit log_named_uint("exact-out sell: protocol", protoB);
        assertEq(outB, outA);
        assertGt(protoA, 0);
        assertApproxEqRel(protoB, protoA, 0.05e18, "protocol share within 5%");
        assertApproxEqRel(inB, inA, 0.01e18, "seller cost within 1%");
    }

    // ------------------------------------------------------------------------------------------ F-033

    function _admitRules(HookrRules r) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(r),
            codeHash: address(r).codehash,
            schemaHash: r.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// F-033: nothing on chain stopped a launch with protocolShareBps = 0.
    function testMinimumProtocolShareEnforcedAtBind() public {
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        new HookrRules(manager, registry, protocol, address(root), 5_001);
        HookrRules floored = new HookrRules(manager, registry, protocol, address(root), 1_000);
        assertEq(floored.minProtocolShareBps(), 1_000);
        _admitRules(floored);
        (address subject, Currency quote) = _subjectAndQuote();
        IHookrLauncher.Member memory m = _member(quote);
        m.config.rules = address(floored);
        m.rules.protocolShareBps = 999;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        vm.expectRevert();
        launcher.launch(
            IHookrLauncher.Token(subject, "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        m.rules.protocolShareBps = 1_000;
        _open(m, subject);
    }

    // ------------------------------------------------------------------------------------------ F-015

    /// F-015: once a quote issuer switched on a transfer fee, every Rules claim in that quote was unpayable.
    function testClaimsLeaveAsErc6909WhileTheQuoteChargesAFee() public {
        FeeSwitchToken fsw = new FeeSwitchToken(1e30);
        fsw.approve(address(launcher), type(uint256).max);
        fsw.transfer(trader, 1e27);
        vm.prank(trader);
        fsw.approve(address(router), type(uint256).max);
        _catalogQuote(address(fsw));
        Currency quote = Currency.wrap(address(fsw));
        PoolKey memory key = _open(_member(quote), address(tokenA));
        _trade(_swap(key, true, true, 1e22));
        uint256 owed = rules.claimable(quote, royalty);
        assertGt(owed, 0);
        fsw.setFee(10);
        vm.prank(royalty);
        vm.expectRevert(IHookrRulesState.ClaimFailed.selector);
        rules.claim(quote);
        uint256 liabilities = rules.totalLiability(quote);
        vm.prank(royalty);
        assertEq(rules.claimAsClaims(quote, address(0xBEEF)), owed);
        assertEq(manager.balanceOf(address(0xBEEF), quote.toId()), owed, "delivered as PoolManager claims");
        assertEq(rules.claimable(quote, royalty), 0);
        assertEq(rules.totalLiability(quote), liabilities - owed);
        assertTrue(rules.accountingInvariant(quote));
        vm.prank(royalty);
        vm.expectRevert(IHookrRulesState.NothingToClaim.selector);
        rules.claimAsClaims(quote, address(0xBEEF));
        vm.startPrank(protocol);
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimAsClaims(quote, address(rules));
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        rules.claimAsClaims(quote, address(manager));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------ F-061

    /// F-061: FeesAllocated omitted the advisory fee, so a zero-fee advisory pool looked unreconciled.
    function testFeesAllocatedCarriesTheAdvisoryFee() public {
        address recipient = address(0xADF);
        FixedAdvice a = new FixedAdvice(
            HookrTypes.Advice(0, 2_000, recipient, false), HookrTypes.Advice(0, 0, address(0), false), false, false
        );
        IHookrRegistry.Admission memory ad = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(a),
            codeHash: address(a).codehash,
            schemaHash: a.configSchemaHash(),
            caps: HookrTypes.Caps(0, 2_000, 0),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), ad));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), ad);
        (address subject, Currency quote) = _subjectAndQuote();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote);
        members[0].config.advisory = address(a);
        members[0].config.advisoryGasLimit = 2_000_000;
        members[0].config.advisoryPhases = 1;
        bytes[] memory configs = new bytes[](1);
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(subject, "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(family, 0).key;
        vm.recordLogs();
        _trade(_swap(key, false, true, 1e21));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FeesAllocated(bytes32,address,uint256,uint256,uint256,address,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != topic) continue;
            (,,, address advisoryRecipient, uint256 advisoryFee) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, address, uint256));
            assertEq(advisoryRecipient, recipient);
            assertEq(advisoryFee, rules.claimable(quote, recipient));
            assertGt(advisoryFee, 0);
            found = true;
        }
        assertTrue(found, "FeesAllocated emitted");
    }

    // ------------------------------------------------------------------------------------------ F-041

    /// F-041: fee floors favour the trader by under one unit, and on a full exact-input fill the floor is what
    /// makes the refund exactly zero. The fixture member's buy quote take is 8,250 pips.
    function testFuzz_fullFillBuyRoundsTheFeeDownAndRefundsNothing(uint128 amount) public {
        amount = uint128(bound(amount, 10, 1e22));
        (address subject, Currency quote) = _subjectAndQuote();
        PoolKey memory key = _open(_member(quote), subject);
        HookrTypes.ExecutionReceipt memory r = quoter.quote(_swap(key, true, true, amount), trader);
        assertEq(r.quoteRefund, 0, "full fill refunds nothing");
        assertEq(r.inputAmount, amount, "the whole specified input is spent");
        assertEq(r.quoteFee, uint256(amount) * 8_250 / 1e6, "fee is the floor of the rate");
        assertEq(r.actualQuote + r.quoteFee, amount);
        uint256 liabilities = rules.totalLiability(quote);
        _trade(_swap(key, true, true, amount));
        assertEq(rules.totalLiability(quote) - liabilities, r.quoteFee);
        assertEq(manager.balanceOf(address(rules), quote.toId()), rules.totalLiability(quote));
    }
}
