// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrAdvisoryFeeCounter} from "../../src/interfaces/IHookrAdvisoryFeeCounter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";
import {RulesData} from "../utils/RulesData.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice HookrRules count each pool's advisory fees (IHookrAdvisoryFeeCounter.advisoryFeeCredited, served from the
///         Rules' fallback by their HookrRecapture module): every quote take a pool's admitted advisory charges on its
///         swaps (settleSwap), in the pool's quote, cumulative and never reduced. A revenue vault whose Rules claim also
///         holds other credits (another pool's advisory fees, a royalty naming it) books a pool's revenue from the
///         counter: at most the counter less what it booked for the pool (builder-attribution's M-01, option b). An
///         arb recapture executor leg's take (settleLeg) is not counted, so the lane's gas does not grow. A swap with no
///         advisory fee never reads or writes the counter; a taxed swap writes it once, measured below.
contract AdvisoryFeeCounterTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    /// @dev HookrRules' storage root, erc7201:hookr.rules; the counter is State's twelfth field.
    bytes32 internal constant RULES_SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    uint256 internal constant COUNTER_FIELD = 11;
    address internal constant VAULT = address(0x7A017);
    address internal constant OTHER_VAULT = address(0x7A018);
    uint24 internal constant TAX_PIPS = 30_000;

    Currency internal quote;
    FixedAdvice internal taxed;
    FixedAdvice internal taxedAfter;
    FixedAdvice internal surchargeOnly;

    struct Paid {
        uint256 advisoryFee;
        uint256 royalty;
        address recipient;
        uint256 allocations;
    }

    function setUp() public {
        _setUpPeriphery();
        quote = Currency.wrap(address(tokenB));
        HookrTypes.Advice memory none;
        taxed = new FixedAdvice(HookrTypes.Advice(0, TAX_PIPS, VAULT, false), none, false, false);
        taxedAfter = new FixedAdvice(none, HookrTypes.Advice(0, TAX_PIPS / 2, OTHER_VAULT, false), false, false);
        surchargeOnly = new FixedAdvice(HookrTypes.Advice(5_000, 0, address(0), false), none, false, false);
        _admit(address(taxed));
        _admit(address(taxedAfter));
        _admit(address(surchargeOnly));
    }

    // ------------------------------------------------------------------ helpers

    function _counter() internal view returns (IHookrAdvisoryFeeCounter) {
        return IHookrAdvisoryFeeCounter(address(rules));
    }

    /// @dev Admits `advisory` on the root for both phases: up to 10,000 pips of LP fee and 100,000 of quote take.
    function _admit(address advisory) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: advisory,
            codeHash: advisory.codehash,
            schemaHash: FixedAdvice(advisory).configSchemaHash(),
            caps: HookrTypes.Caps(10_000, 100_000, 0),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev A fresh subject held by this test and the trader, approved for the launcher and the router.
    function _subject() internal returns (HookrToken s) {
        s = new HookrToken("S", "S", 1e30, address(this));
        s.approve(address(launcher), type(uint256).max);
        s.transfer(trader, 1e27);
        vm.prank(trader);
        s.approve(address(router), type(uint256).max);
    }

    /// @dev One tokenB-quoted pool of a fresh subject with the fixture's rules (LP Rewards, Auto Burn and a royalty
    ///      to `royaltyTo`), asked by `advisory` in `phases` (none when zero).
    function _pool(address advisory, uint8 phases, address royaltyTo) internal returns (PoolKey memory) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote);
        members[0].rules.royaltyTo = royaltyTo;
        if (advisory != address(0)) {
            members[0].config.advisory = advisory;
            members[0].config.advisoryGasLimit = 2_000_000;
            members[0].config.advisoryPhases = phases;
        }
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(_subject()), "", "", 0, bytes32(0)),
            address(root),
            members,
            new bytes[](1),
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    /// @dev One swap as the trader in the next block; what the Rules' FeesAllocated said of it.
    function _trade(PoolKey memory key, bool buy, bool exactInput, uint128 amount) internal returns (Paid memory p) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        IHookrRouter.Swap memory s = _swap(key, buy, exactInput, amount);
        vm.recordLogs();
        vm.prank(trader);
        router.swap(s, address(0), new uint256[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != IHookrRulesEvents.FeesAllocated.selector) {
                continue;
            }
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()), "allocated on the pool");
            (, p.royalty,, p.recipient, p.advisoryFee) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, address, uint256));
            ++p.allocations;
        }
        assertEq(p.allocations, 1, "one settlement");
    }

    function _counterSlot(PoolKey memory key) internal pure returns (bytes32) {
        return _counterSlot(key.toId());
    }

    function _counterSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, uint256(RULES_SLOT) + COUNTER_FIELD));
    }

    /// @dev Fails if `slot` is among `slots`.
    function _assertUntouched(bytes32[] memory slots, bytes32 slot, string memory what) internal pure {
        for (uint256 i; i < slots.length; ++i) {
            assertTrue(slots[i] != slot, what);
        }
    }

    // ------------------------------------------------------------------ the counter

    /// Every swap shape of a taxed pool adds exactly its FeesAllocated advisory fee, nonzero, to the pool's counter;
    /// the counter is the sum, and the advisory's recipient was credited exactly that.
    function test_counter_addsEveryAdvisoryFeeOfThePool() public {
        PoolKey memory key = _pool(address(taxed), HookrTypes.BEFORE_SWAP, royalty);
        assertEq(_counter().advisoryFeeCredited(key.toId()), 0, "nothing before the first swap");
        bool[4] memory buys = [true, false, true, false];
        bool[4] memory exacts = [true, true, false, false];
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 before = _counter().advisoryFeeCredited(key.toId());
            Paid memory p = _trade(key, buys[i], exacts[i], 1e18);
            assertGt(p.advisoryFee, 0, "a taxed swap");
            assertEq(p.recipient, VAULT);
            assertEq(_counter().advisoryFeeCredited(key.toId()) - before, p.advisoryFee, "this swap's advisory fee");
            sum += p.advisoryFee;
        }
        assertEq(_counter().advisoryFeeCredited(key.toId()), sum, "the sum of the pool's advisory fees");
        assertEq(rules.claimable(quote, VAULT), sum, "what the recipient was credited");
        assertEq(uint256(vm.load(address(rules), _counterSlot(key))), sum, "erc7201:hookr.rules, field 11");
    }

    /// The counter is per pool and counts advisory fees only: the vault's Rules claim also grows by another pool's
    /// advisory fees and by a royalty that names it, which no counter takes, so booking each pool's revenue from its
    /// counter splits the vault's claim exactly (M-01). A claim paid out leaves the counters as they are.
    function test_counter_isPerPoolAndCountsOnlyAdvisoryFees() public {
        PoolKey memory a = _pool(address(taxed), HookrTypes.BEFORE_SWAP, royalty);
        PoolKey memory b = _pool(address(taxed), HookrTypes.BEFORE_SWAP, VAULT);
        uint256 feesA;
        uint256 feesB;
        uint256 royaltyB;
        for (uint256 i; i < 3; ++i) {
            feesA += _trade(a, true, true, 1e18).advisoryFee;
            Paid memory p = _trade(b, true, true, 2e18);
            feesB += p.advisoryFee;
            royaltyB += p.royalty;
            feesA += _trade(a, false, true, 5e17).advisoryFee;
        }
        assertGt(royaltyB, 0, "the royalty names the vault");
        assertEq(_counter().advisoryFeeCredited(a.toId()), feesA, "pool a: its own advisory fees");
        assertEq(_counter().advisoryFeeCredited(b.toId()), feesB, "pool b: its own, not the royalty");
        assertEq(rules.claimable(quote, VAULT), feesA + feesB + royaltyB, "the vault's claim holds all three");
        vm.prank(VAULT);
        rules.claim(quote);
        assertEq(rules.claimable(quote, VAULT), 0);
        assertEq(_counter().advisoryFeeCredited(a.toId()), feesA, "a claim leaves the counter");
        assertEq(_counter().advisoryFeeCredited(b.toId()), feesB);
    }

    /// An after-phase take (the root admits one on an exact-input sell and an exact-output buy, the shapes whose quote
    /// side is settled after the swap) counts as the before-phase's does, credited to the after-phase's recipient.
    function test_counter_addsAnAfterPhaseTake() public {
        PoolKey memory key = _pool(address(taxedAfter), HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP, royalty);
        Paid memory p = _trade(key, false, true, 1e18);
        assertGt(p.advisoryFee, 0);
        assertEq(p.recipient, OTHER_VAULT);
        assertEq(_counter().advisoryFeeCredited(key.toId()), p.advisoryFee);
        uint256 first = p.advisoryFee;
        p = _trade(key, true, false, 1e18);
        assertGt(p.advisoryFee, 0);
        assertEq(p.recipient, OTHER_VAULT);
        assertEq(_counter().advisoryFeeCredited(key.toId()), first + p.advisoryFee, "both takes");
        assertEq(rules.claimable(quote, OTHER_VAULT), _counter().advisoryFeeCredited(key.toId()));
    }

    /// A swap whose advisory takes no quote, and every swap shape on a pool without an advisory, neither reads nor
    /// writes the counter's slot: those swaps run exactly the code they ran before the counter.
    function test_counter_isNotReadOrWrittenWithoutATake() public {
        PoolKey memory feeOnly = _pool(address(surchargeOnly), HookrTypes.BEFORE_SWAP, royalty);
        PoolKey memory plain = _pool(address(0), 0, royalty);
        PoolKey[2] memory keys = [feeOnly, plain];
        bool[4] memory buys = [true, false, true, false];
        bool[4] memory exacts = [true, true, false, false];
        for (uint256 k; k < 2; ++k) {
            for (uint256 i; i < 4; ++i) {
                vm.record();
                Paid memory p = _trade(keys[k], buys[i], exacts[i], 1e18);
                (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(rules));
                assertEq(p.advisoryFee, 0);
                _assertUntouched(reads, _counterSlot(keys[k]), "no counter read");
                _assertUntouched(writes, _counterSlot(keys[k]), "no counter write");
            }
            assertEq(_counter().advisoryFeeCredited(keys[k].toId()), 0);
        }
    }

    /// An arb recapture executor leg's advisory take (IHookrLaneRules.settleLeg, from the root) is credited to the
    /// advice's recipient and reported by FeesAllocated, but the counter stays where the pool's swaps left it: called
    /// here as the root does, on a pool bound with arb recapture.
    function test_counter_leavesAnExecutorLegsTakeOut() public {
        PoolKey memory key = _bindRecapturePool(address(taxed));
        vm.store(address(rules), _counterSlot(key), bytes32(uint256(5)));
        vm.record();
        vm.expectEmit(true, true, true, true, address(rules));
        emit IHookrRulesEvents.FeesAllocated(key.toId(), quote, 0, 0, 0, VAULT, 7e15);
        vm.prank(address(root));
        uint256 credited = IHookrLaneRules(address(rules)).settleLeg(key.toId(), VAULT, 7e15);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(rules));
        assertEq(credited, 7e15);
        assertEq(rules.claimable(quote, VAULT), 7e15, "the leg's take is credited");
        _assertUntouched(reads, _counterSlot(key), "no counter read");
        _assertUntouched(writes, _counterSlot(key), "no counter write");
        assertEq(_counter().advisoryFeeCredited(key.toId()), 5, "the counter as the swaps left it");
    }

    /// An unbound pool reads zero, and the counter answers only through the Rules: the module refuses to run on its
    /// own address.
    function test_counter_unboundPoolsAndTheModuleItself() public {
        assertEq(_counter().advisoryFeeCredited(PoolId.wrap(bytes32(uint256(1)))), 0);
        (bool ok, bytes memory out) = address(rules).staticcall(abi.encodeWithSignature("recaptureModule()"));
        assertTrue(ok);
        (address module,) = abi.decode(out, (address, bytes32));
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        IHookrAdvisoryFeeCounter(module).advisoryFeeCredited(PoolId.wrap(bytes32(uint256(1))));
    }

    /// @dev Binds a tokenB-quoted pool of a fresh subject with arb recapture on these Rules directly, as the root does
    ///      at initialization, with `advisory` in its config.
    function _bindRecapturePool(address advisory) internal returns (PoolKey memory key) {
        HookrToken s = _subject();
        (Currency c0, Currency c1) =
            address(s) < address(tokenB) ? (Currency.wrap(address(s)), quote) : (quote, Currency.wrap(address(s)));
        key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        HookrTypes.PoolConfig memory pc = _member(quote).config;
        pc.subject = Currency.wrap(address(s));
        pc.quote = quote;
        pc.liquidityOwner = address(this);
        pc.advisory = advisory;
        HookrTypes.RulesConfig memory c;
        c.maxFeePips = 3000;
        c.protocolShareBps = 2500;
        HookrTypes.RecaptureConfig memory rc;
        rc.on = true;
        rc.traderBps = 2_500;
        rc.lpBps = 7_500;
        rc.releaseBlocks = 36_000;
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(key.toId()));
        vm.prank(address(root));
        rules.bind(key, pc, RulesData.lane(c, 0, rc));
        vm.clearMockedCalls();
    }

    // ------------------------------------------------------------------ gas

    /// The counter's cost on a taxed swap, cold as at the start of a transaction. Two twin taxed pools (fresh subjects
    /// on the same side of the quote) take their first swap after another taxed pool's first swap wrote every slot the
    /// pools share (the recipient's, the royalty's and the protocol's claims, the quote's liabilities); twin c's
    /// counter slot was set beforehand, so the two first swaps differ only in the counter's store: from zero on b, from
    /// nonzero on c. That is 17,100 when each swap is its own transaction (--isolate, as on chain: 22,100 against
    /// 5,000) and 19,900 inside one test transaction, where c's preset slot already counts as written in it (22,100
    /// against 2,200). Logged for the gas tables with a later taxed swap and two swaps that never touch the counter
    /// (an advisory without a take, no advisory); the same swaps measured without the counter give the delta.
    function test_gas_taxedSwapWithTheCounter() public {
        PoolKey memory a = _pool(address(taxed), HookrTypes.BEFORE_SWAP, royalty);
        PoolKey memory plain = _pool(address(surchargeOnly), HookrTypes.BEFORE_SWAP, royalty);
        PoolKey memory b = _pool(address(taxed), HookrTypes.BEFORE_SWAP, royalty);
        PoolKey memory c = _twin(b);
        PoolKey memory unadvised = _pool(address(0), 0, royalty);
        _coldSwapGas(a);
        _coldSwapGas(plain);
        _coldSwapGas(unadvised);
        vm.store(address(rules), _counterSlot(c), bytes32(uint256(1)));
        uint256 firstTaxed = _coldSwapGas(b);
        uint256 firstTaxedCounted = _coldSwapGas(c);
        uint256 laterTaxed = _coldSwapGas(b);
        uint256 untaxed = _coldSwapGas(plain);
        uint256 noAdvisory = _coldSwapGas(unadvised);
        console2.log("cold taxed buy, the pool's first", firstTaxed);
        console2.log("cold taxed buy, the pool's first, its counter already written", firstTaxedCounted);
        console2.log("cold taxed buy, later", laterTaxed);
        console2.log("cold buy, advisory without a take", untaxed);
        console2.log("cold buy, no advisory", noAdvisory);
        uint256 store = firstTaxed - firstTaxedCounted;
        assertTrue(store == 17_100 || store == 19_900, "the counter's store from zero, and nothing else");
        assertGt(_counter().advisoryFeeCredited(b.toId()), 0);
    }

    /// @dev A pool like `_pool(taxed, ...)` whose fresh subject sits on the same side of the quote as `key`'s.
    function _twin(PoolKey memory key) internal returns (PoolKey memory twin) {
        bool subjectFirst = Currency.unwrap(key.currency1) == address(tokenB);
        do {
            twin = _pool(address(taxed), HookrTypes.BEFORE_SWAP, royalty);
        } while ((Currency.unwrap(twin.currency1) == address(tokenB)) != subjectFirst);
    }

    function _coldSwapGas(PoolKey memory key) internal returns (uint256 used) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        IHookrRouter.Swap memory s = _swap(key, true, true, 1e18);
        address subject = Currency.unwrap(root.poolConfig(key.toId()).subject);
        address[9] memory touched = [
            address(manager),
            address(root),
            address(rules),
            address(router),
            address(registry),
            address(taxed),
            address(surchargeOnly),
            address(tokenB),
            subject
        ];
        for (uint256 i; i < touched.length; ++i) {
            vm.cool(touched[i]);
        }
        vm.prank(trader);
        router.swap(s, address(0), new uint256[](0));
        used = vm.lastCallGas().gasTotalUsed;
    }
}
