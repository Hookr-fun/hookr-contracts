// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {RulesData} from "../utils/RulesData.sol";

/// @notice The Anti-Snipe decay: storage layout, the launch timestamp on every launch path, the curve over its whole
///         domain, the pool caps at every second, the advisory guard room and the timestamp edges.
contract SnipeDecayCapsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant RULES_SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    bytes32 internal constant SKIP_TAKEN = bytes32(uint256(1));

    function setUp() public {
        _setUpPeriphery();
    }

    // ------------------------------------------------------------------ helpers

    function _snipe(Currency quote, int24 spacing, uint24 start, uint24 floor, uint16 decay)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m = _member(quote);
        m.tickSpacing = spacing;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 1000);
        m.rules.snipeTaxPips = start;
        m.rules.snipeFloorPips = floor;
        m.rules.snipeDecaySeconds = decay;
    }

    function _launch1(IHookrLauncher.Member memory m) internal returns (PoolKey memory) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (bytes32 family,) = launcher.launch{value: Currency.unwrap(m.quote) == address(0) ? 1e24 : 0}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    function _slot(PoolId id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(PoolId.unwrap(id), RULES_SLOT)));
    }

    function _launchedAt(PoolId id) internal view returns (uint256) {
        return uint256(vm.load(address(rules), bytes32(_slot(id)))) >> 224;
    }

    function _ctx(PoolKey memory key, Currency quote, bool buy)
        internal
        view
        returns (HookrTypes.SwapContext memory x)
    {
        x.id = key.toId();
        x.sender = trader;
        x.payer = trader;
        x.beneficiary = trader;
        x.subject = Currency.wrap(address(tokenA));
        x.quote = quote;
        x.authenticated = true;
        x.isBuy = buy;
        x.exactInput = true;
        x.zeroForOne = buy == (Currency.unwrap(key.currency0) == Currency.unwrap(quote));
        x.amountSpecified = -1e18;
        x.sqrtPriceLimitX96 = x.zeroForOne ? MIN_PRICE : MAX_PRICE;
        x.baseLpFeePips = 3000;
    }

    function _quote(PoolKey memory key, Currency quote) internal returns (HookrTypes.FeeQuote memory q) {
        vm.prank(address(root));
        q = rules.beforeSwap(_ctx(key, quote, true));
    }

    function _ref(uint256 start, uint256 floor, uint256 d, uint256 e) internal pure returns (uint256) {
        if (d == 0) return start;
        if (e >= d) return floor;
        return floor + (start - floor) * (d - e) / d;
    }

    // ------------------------------------------------------------------ storage layout

    /// Bound slot 0 carries launchedAt in its top 4 bytes; the config still spans exactly three slots and every
    /// field sits where the packed layout puts it.
    function testStorageLayoutPacksBothNewFields() public {
        IHookrLauncher.Member memory m = _snipe(Currency.wrap(address(0)), 60, 500_000, 10_000, 120);
        m.rules.maxBuyQuoteAmount = type(uint128).max - 7;
        m.rules.royaltyBps = 100;
        m.rules.lpBps = 50;
        m.rules.royaltyTo = address(0xCAFE);
        m.rules.dynamicFeeSens = 5;
        m.rules.maxFeePips = 90_000;
        vm.warp(1_900_000_123);
        PoolKey memory key = _launch1(m);
        uint256 p = _slot(key.toId());
        uint256 w0 = uint256(vm.load(address(rules), bytes32(p)));
        assertEq(w0 >> 224, 1_900_000_123, "launchedAt in the top 4 bytes of slot 0");
        assertEq(uint24(w0), 3000, "baseFeePips");
        assertEq(address(uint160(w0 >> 64)), address(launcher), "liquidityOwner");
        uint256 c0 = uint256(vm.load(address(rules), bytes32(p + 1)));
        assertEq(uint40(c0), m.rules.guardEndBlock, "guardEndBlock");
        assertEq(uint24(c0 >> 40), 90_000, "maxFeePips");
        assertEq(uint24(c0 >> 64), 500_000, "snipeTaxPips");
        assertEq(uint24(c0 >> 88), 10_000, "snipeFloorPips");
        assertEq(uint16(c0 >> 112), 120, "snipeDecaySeconds");
        assertEq(uint16(c0 >> 128), 5, "dynamicFeeSens");
        assertEq(uint16(c0 >> 160), 50, "lpBps");
        assertEq(uint16(c0 >> 192), 100, "royaltyBps");
        assertEq(uint16(c0 >> 208), 2500, "protocolShareBps");
        assertEq(c0 >> 224, 0, "potEveryNBuys fills the top 4 bytes: the first config slot is exactly 32 bytes");
        assertEq(uint256(vm.load(address(rules), bytes32(p + 2))), type(uint128).max - 7, "maxBuy | potMin");
        assertEq(address(uint160(uint256(vm.load(address(rules), bytes32(p + 3))))), address(0xCAFE), "royaltyTo");
        assertEq(uint256(vm.load(address(rules), bytes32(p + 4))), 0, "no fifth slot");
        assertEq(rules.removalLockedUntil(key.toId()), m.rules.guardEndBlock, "removal lock reads guardEndBlock");
    }

    // ------------------------------------------------------------------ launch paths

    /// launch, a multi-member family, a later launch and launchAdvised all stamp the bind's block.timestamp, and
    /// the decay starts at the first liquidity (same transaction).
    function testLaunchedAtOnEveryLaunchPath() public {
        vm.warp(1_800_000_000);
        // A two-member family: ETH and tokenB quotes, one transaction.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _snipe(Currency.wrap(address(0)), 60, 400_000, 0, 600);
        members[1] = _snipe(Currency.wrap(address(tokenB)), 60, 400_000, 0, 600);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory k0 = launcher.position(family, 0).key;
        PoolKey memory k1 = launcher.position(family, 1).key;
        assertEq(_launchedAt(k0.toId()), 1_800_000_000, "member 0");
        assertEq(_launchedAt(k1.toId()), 1_800_000_000, "member 1");
        assertGt(manager_liquidity(k0), 0, "liquidity in the launch transaction");

        // A later launch on another spacing stamps its own time.
        vm.warp(1_800_000_777);
        vm.roll(vm.getBlockNumber() + 3);
        PoolKey memory k2 = _launch1(_snipe(Currency.wrap(address(0)), 120, 400_000, 0, 600));
        assertEq(_launchedAt(k2.toId()), 1_800_000_777, "later launch");
        assertEq(_quote(k2, Currency.wrap(address(0))).lpFeeSurchargePips, 300_000, "later pool starts at the top");
        assertLt(_quote(k0, Currency.wrap(address(0))).lpFeeSurchargePips, 300_000, "the earlier pool keeps decaying");

        // launchAdvised with an admitted HookrFeeAdvisory.
        HookrFeeAdvisory fee = _admitFee();
        vm.warp(1_800_001_000);
        IHookrLauncher.Member memory m = _snipe(Currency.wrap(address(0)), 240, 400_000, 0, 600);
        m.config.advisory = address(fee);
        m.config.advisoryGasLimit = 200_000;
        m.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        m.config.advisoryFailOpen = true;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        IHookrLauncher.Member[] memory one = new IHookrLauncher.Member[](1);
        one[0] = m;
        bytes[] memory cfgs = new bytes[](1);
        cfgs[0] = abi.encode(
            IHookrFeeAdvisory.Config({
                cap: 20_000,
                surcharge: 20_000,
                premium0: 0,
                premium1: 0,
                maxStep: 5000,
                minInterval: 60,
                maxTtl: 1 hours
            })
        );
        (bytes32 fam2,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
            address(root),
            one,
            cfgs,
            vm.getBlockTimestamp()
        );
        PoolKey memory k3 = launcher.position(fam2, 0).key;
        assertEq(_launchedAt(k3.toId()), 1_800_001_000, "launchAdvised");

        // The advisory sizes its guard room from snipeTaxPips (the start), so every decayed buy still fits the cap.
        for (uint256 t; t <= 700; t += 70) {
            vm.warp(1_800_001_000 + t);
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(trader);
            router.swap{value: 1e17}(_swap(k3, true, true, 1e17), address(0), new uint256[](0));
        }
    }

    /// An existing-token SKIP_TAKEN launch skips a member whose pool exists: that pool keeps its original
    /// launchedAt (no rebind, no reset of the decay).
    function testSkipTakenKeepsTheOriginalLaunchTime() public {
        vm.warp(1_800_000_000);
        PoolKey memory first = _launch1(_snipe(Currency.wrap(address(0)), 60, 400_000, 0, 600));
        vm.warp(1_800_000_500);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _snipe(Currency.wrap(address(0)), 60, 400_000, 0, 600);
        members[1] = _snipe(Currency.wrap(address(tokenB)), 60, 400_000, 0, 600);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, SKIP_TAKEN), address(root), members, vm.getBlockTimestamp()
        );
        assertEq(_launchedAt(first.toId()), 1_800_000_000, "skipped member keeps its launch time");
        assertEq(_launchedAt(launcher.position(family, 1).key.toId()), 1_800_000_500, "new member");
    }

    // ------------------------------------------------------------------ curve domain

    /// The quote equals the reference for every start/floor/duration the validator admits and every elapsed time up
    /// to 2^40 s: no overflow, no revert, never above the start or below the floor. The launch age is taken modulo
    /// 2^32 and an age in the top half (over 68 years, far past any guard) reads as a clock behind the launch.
    function testFuzzCurveWholeDomain(uint24 start, uint24 floor, uint16 decay, uint40 elapsed, uint16 share) public {
        start = uint24(bound(start, 0, 597_000));
        // A decay needs floor < start; no decay needs a zero floor.
        decay = uint16(bound(decay, 0, start == 0 ? 0 : 3600));
        floor = decay == 0 ? 0 : uint24(bound(floor, 0, start - 1));
        share = uint16(bound(share, 0, 5000));
        IHookrLauncher.Member memory m = _snipe(Currency.wrap(address(0)), 60, start, floor, decay);
        m.rules.protocolShareBps = share;
        // The fixture's admission quote cap is 200,000 pips.
        vm.assume(uint256(start) * share / 10_000 <= 200_000);
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launch1(m);
        vm.warp(t0 + elapsed);
        HookrTypes.FeeQuote memory q = _quote(key, Currency.wrap(address(0)));
        uint256 age = uint256(elapsed) % 2 ** 32;
        uint256 snipe = _ref(start, floor, decay, age >= 2 ** 31 ? 0 : age);
        assertEq(uint256(q.lpFeeSurchargePips) + q.quoteTakePips, snipe, "total");
        assertEq(q.quoteTakePips, snipe * share / 10_000, "protocol slice of the decayed tax");
        assertLe(snipe, start);
        assertGe(snipe, floor);
    }

    // ------------------------------------------------------------------ caps at every second

    /// @dev maxFeePips at `sens` and `share`: the 3,000 base plus a span growing with the sensitivity, 20,000 a step, up
    ///      to the widest the reach bound admits there (HookrDynamicFee.withinReach); the base alone at zero.
    function _spanFor(uint8 sens, uint16 share) internal pure returns (uint24) {
        if (sens == 0) return 3000;
        uint256 widest = RulesData.maxDynamicFeeSpan(sens, share, 3000);
        uint256 span = uint256(sens) * 20_000;
        return uint24(3000 + (span < widest ? span : widest));
    }

    /// With the tightest pool caps Rules accepts (the I-12 mirror), a real buy at any second of the decay, with a
    /// dynamic fee, LP Rewards, royalty and burn, never trips the Root's cap checks.
    function testFuzzTightCapsHoldThroughTheDecay(
        uint24 start,
        uint24 floor,
        uint16 decay,
        uint16 elapsed,
        uint8 sens,
        uint16 share,
        uint128 amount
    ) public {
        start = uint24(bound(start, 1, 500_000));
        floor = uint24(bound(floor, 0, start - 1));
        decay = uint16(bound(decay, 1, 3600));
        share = uint16(bound(share, 0, 5000));
        sens = uint8(bound(sens, 0, 10));
        amount = uint128(bound(amount, 1e12, 5e20));
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        m.tickSpacing = 200;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 1000);
        m.rules.snipeTaxPips = start;
        m.rules.snipeFloorPips = floor;
        m.rules.snipeDecaySeconds = decay;
        m.rules.protocolShareBps = share;
        m.rules.dynamicFeeSens = sens;
        m.rules.maxFeePips = _spanFor(sens, share);
        HookrTypes.Caps memory c = _rulesCaps(m.rules, 3000);
        vm.assume(c.maxQuoteTakePips <= 200_000);
        m.config.caps = c;
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey memory key = _launch1(m);
        vm.warp(t0 + bound(elapsed, 0, 2 * uint256(decay)));
        vm.prank(trader);
        router.swap{value: amount}(_swap(key, true, true, amount), address(0), new uint256[](0));
        assertTrue(rules.accountingInvariant(Currency.wrap(address(0))));
    }

    // ------------------------------------------------------------------ timestamp edges

    /// A block timestamp below launchedAt (unreachable on chain, possible in a simulation that overrides the block
    /// timestamp) reads as the launch: the full start rate, no revert.
    function testTimestampBeforeLaunchQuotesTheStart() public {
        vm.warp(1_800_000_000);
        PoolKey memory key = _launch1(_snipe(Currency.wrap(address(0)), 60, 400_000, 0, 600));
        vm.warp(1_799_999_999);
        assertEq(_quote(key, Currency.wrap(address(0))).lpFeeSurchargePips, 300_000, "one second before the launch");
        vm.warp(1_700_000_000);
        assertEq(_quote(key, Currency.wrap(address(0))).lpFeeSurchargePips, 300_000, "long before the launch");
        // A flat pool never reads the timestamp.
        PoolKey memory flat = _launch1(_snipe(Currency.wrap(address(0)), 120, 400_000, 0, 0));
        vm.warp(1_700_000_000);
        assertEq(_quote(flat, Currency.wrap(address(0))).lpFeeSurchargePips, 300_000);
    }

    /// uint32 launchedAt wraps in 2106: a pool bound after 2^32 s stores its launch time modulo 2^32, and the launch
    /// age is taken modulo 2^32 too, so the decay runs exactly as before the wrap.
    function testLaunchAfter2106StillDecays() public {
        uint256 t0 = uint256(type(uint32).max) + 100;
        vm.warp(t0);
        PoolKey memory key = _launch1(_snipe(Currency.wrap(address(0)), 60, 400_000, 10_000, 600));
        assertEq(_launchedAt(key.toId()), 99, "stored modulo 2^32");
        HookrTypes.FeeQuote memory q = _quote(key, Currency.wrap(address(0)));
        assertEq(uint256(q.lpFeeSurchargePips) + q.quoteTakePips, 400_000, "start in the launch block");
        vm.warp(t0 + 300);
        q = _quote(key, Currency.wrap(address(0)));
        assertEq(uint256(q.lpFeeSurchargePips) + q.quoteTakePips, 205_000, "halfway");
        vm.warp(t0 + 600);
        q = _quote(key, Currency.wrap(address(0)));
        assertEq(uint256(q.lpFeeSurchargePips) + q.quoteTakePips, 10_000, "floor at the end of the decay");
        // A pool launched just before the wrap keeps decaying across it.
        vm.warp(uint256(type(uint32).max) - 99);
        PoolKey memory across = _launch1(_snipe(Currency.wrap(address(0)), 120, 400_000, 10_000, 600));
        vm.warp(uint256(type(uint32).max) + 201);
        q = _quote(across, Currency.wrap(address(0)));
        assertEq(uint256(q.lpFeeSurchargePips) + q.quoteTakePips, 205_000, "halfway, across the wrap");
    }

    // ------------------------------------------------------------------ support

    function manager_liquidity(PoolKey memory key) internal view returns (uint128 l) {
        (bool ok, bytes memory ret) =
            address(manager).staticcall(abi.encodeWithSignature("extsload(bytes32)", _poolLiquiditySlot(key.toId())));
        require(ok);
        l = uint128(uint256(abi.decode(ret, (bytes32))));
    }

    function _poolLiquiditySlot(PoolId id) internal pure returns (bytes32) {
        // StateLibrary: POOLS_SLOT = 6, LIQUIDITY_OFFSET = 3.
        return bytes32(uint256(keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(uint256(6))))) + 3);
    }

    function _admitFee() internal returns (HookrFeeAdvisory f) {
        f = new HookrFeeAdvisory(address(this), 1 days, registry, address(0));
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(f),
            codeHash: address(f).codehash,
            schemaHash: f.configSchemaHash(),
            caps: HookrTypes.Caps(50_000, 0, 0),
            gasLimit: 200_000,
            phaseMask: 3,
            feeOnly: true,
            failOpen: true
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev Copy of the I-12 mirror of HookrRules._validate's tightest caps.
    function _rulesCaps(HookrTypes.RulesConfig memory c, uint24 baseLpFeePips)
        internal
        pure
        returns (HookrTypes.Caps memory)
    {
        uint256 bps = 10_000;
        uint256 share = c.protocolShareBps;
        // The protocol's share of each slice in pips, rounded up; the burn left in whole bps, rounded down.
        uint256 lpSlice = (uint256(c.lpBps) * share + 99) / 100;
        uint256 lpNet = uint256(c.lpBps) * 100 - lpSlice;
        uint256 royaltyPips = lpNet * c.royaltyBps / bps;
        uint256 burnSlice = (uint256(c.burnBps) * share + 99) / 100;
        uint256 lpReward = lpNet - royaltyPips;
        uint256 take = lpSlice + royaltyPips + burnSlice;
        uint256 burnBps = (uint256(c.burnBps) * 100 - burnSlice) / 100;
        uint256 base = baseLpFeePips;
        uint256 span = uint256(c.maxFeePips) - base;
        uint256 room = 600_000 - base - lpReward;
        uint256 dynamicFee = span > room ? room : span;
        uint256 snipe = c.snipeTaxPips;
        if (snipe > room - dynamicFee) snipe = room - dynamicFee;
        uint256 slice = dynamicFee * share / bps + snipe * share / bps;
        uint256 maximumLp = base + lpReward + dynamicFee + snipe - slice;
        if (span + c.snipeTaxPips > room && share != 0) {
            slice = (dynamicFee + snipe) * share / bps;
            uint256 minimumSlice = slice == 0 ? 0 : slice - 1;
            maximumLp = base + lpReward + dynamicFee + snipe - minimumSlice;
        }
        if (maximumLp < c.maxFeePips) maximumLp = c.maxFeePips;
        uint256 maximumQuote = slice + take;
        if (span * share / bps > maximumQuote) maximumQuote = span * share / bps;
        return HookrTypes.Caps(uint24(maximumLp), uint24(maximumQuote), uint16(burnBps));
    }
}
