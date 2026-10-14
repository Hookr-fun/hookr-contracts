// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Forwards the session read to a calendar until it is broken, then reverts.
contract BreakableCalendar {
    HookrSessionAdvisory internal immutable inner;
    bool public broken;

    constructor(HookrSessionAdvisory inner_) {
        inner = inner_;
    }

    function breakIt() external {
        broken = true;
    }

    function sessionAt(uint256 timestamp) external view returns (HookrMarketCalendar.Session memory) {
        require(!broken, "broken");
        return inner.sessionAt(timestamp);
    }
}

/// @notice HookrFeeAdvisory with session tiers on HookrRoot pools, through the real Root, Rules, Router and Quoter:
///         the keeper surcharge plus the session tier, clamped to the pool's cap and to the guard ceiling on buys; old
///         bind data unchanged; bind refusals; a broken calendar; gas.
contract HookrFeeAdvisoryTiersTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant ADMISSION_CAP = 50_000;
    uint32 internal constant ADVISORY_GAS = 200_000;
    // Fixture Rules: base 3000, LP Rewards 14,250 pips on buys.
    uint256 internal constant BUY_NATIVE = 17_250;
    uint256 internal constant SELL_NATIVE = 3000;
    uint24 internal constant REGULAR = 1000;
    uint24 internal constant PRE = 4000;
    uint24 internal constant AFTER = 6000;
    uint24 internal constant NIGHT = 10_000;
    uint24 internal constant CLOSED = 15_000;

    HookrSessionAdvisory internal session;
    BreakableCalendar internal breakable;
    HookrFeeAdvisory internal fee;
    HookrFeeAdvisory internal fragile;
    HookrFeeAdvisory internal plain;
    address internal keeper = address(0xBEEF);
    uint256 internal launches;

    function setUp() public {
        _setUpPeriphery();
        session = new HookrSessionAdvisory(address(this), 1 days);
        breakable = new BreakableCalendar(session);
        fee = _deployAdmitted(address(session));
        fragile = _deployAdmitted(address(breakable));
        plain = _deployAdmitted(address(0));
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fee.addKeeper(keeper);
        vm.warp(_ny(2026, 9, 28, 11, 0, 0, true));
    }

    // ---------------------------------------------------------------- helpers

    function _deployAdmitted(address calendar) internal returns (HookrFeeAdvisory m) {
        m = new HookrFeeAdvisory(address(this), 1 days, registry, calendar);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(m),
            codeHash: address(m).codehash,
            schemaHash: m.configSchemaHash(),
            caps: HookrTypes.Caps(ADMISSION_CAP, 0, 0),
            gasLimit: ADVISORY_GAS,
            phaseMask: 3,
            feeOnly: true,
            failOpen: true
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    function _ny(uint256 y, uint256 m, uint256 d, uint256 h, uint256 mi, uint256 sec, bool dst)
        internal
        pure
        returns (uint256)
    {
        return
            HookrMarketCalendar.dayOf(y, m, d) * 1 days + h * 1 hours + mi * 1 minutes + sec + (dst ? 4 : 5) * 1 hours;
    }

    function _cfg(uint24 cap, uint24 surcharge) internal pure returns (IHookrFeeAdvisory.Config memory) {
        return IHookrFeeAdvisory.Config({
            cap: cap, surcharge: surcharge, premium0: 0, premium1: 0, maxStep: 5000, minInterval: 60, maxTtl: 1 hours
        });
    }

    function _tiers() internal pure returns (HookrSessionTiers.Tiers memory) {
        return HookrSessionTiers.Tiers(REGULAR, PRE, AFTER, NIGHT, CLOSED, 0, 0, 0);
    }

    function _member(HookrFeeAdvisory m) internal returns (IHookrLauncher.Member memory member) {
        member = _member(Currency.wrap(address(tokenB)));
        // Tick spacings that divide the fixture's ±60,000 range, one per launch.
        int24[12] memory spacings = [int24(60), 100, 120, 150, 200, 240, 250, 300, 400, 480, 500, 600];
        member.tickSpacing = spacings[launches++ % 12];
        member.config.advisory = address(m);
        member.config.advisoryGasLimit = ADVISORY_GAS;
        member.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        member.config.advisoryFailOpen = true;
    }

    function _launchWith(IHookrLauncher.Member memory member, bytes memory data) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = member;
        bytes[] memory configs = new bytes[](1);
        configs[0] = data;
        (bytes32 family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _launchTiered(HookrFeeAdvisory m, IHookrFeeAdvisory.Config memory c, HookrSessionTiers.Tiers memory t)
        internal
        returns (PoolKey memory)
    {
        return _launchWith(_member(m), abi.encode(c, t));
    }

    function _lpFee(PoolKey memory key, bool buy) internal returns (uint256) {
        return quoter.quote(_swap(key, buy, true, 1e18), trader).lpFeePips;
    }

    function _trade(PoolKey memory key, bool buy, uint128 amount) internal returns (uint256 lpFee) {
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        lpFee = quoter.quote(p, trader).lpFeePips;
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    /// @dev `m`'s bind refuses with `reason`, which the root carries in ModuleCallReverted, or without data (the ABI
    ///      decoder's refusal of a value out of its type's range) when `reason` is empty, which the root reports as
    ///      ModuleCallFailed.
    function _expectBindRefused(HookrFeeAdvisory m, bytes memory reason) internal {
        vm.expectRevert(
            reason.length == 0
                ? abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallFailed.selector, address(m), IHookrAdvisory.bind.selector
                )
                : abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallReverted.selector, address(m), IHookrAdvisory.bind.selector, reason
                )
        );
    }

    function _invalidTiers(uint256 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, code);
    }

    function _invalidConfig() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrFeeAdvisory.InvalidConfig.selector);
    }

    /// @dev Warps to `t` and asserts the view, a quoted buy and an executed sell all carry `surcharge`.
    function _expectAt(PoolKey memory key, uint256 t, uint256 surcharge) internal {
        vm.warp(t);
        bool zeroForOne = _swap(key, false, true, 1).zeroForOne;
        assertEq(fee.surcharge(key.toId(), zeroForOne), surcharge, "view");
        assertEq(_lpFee(key, true), BUY_NATIVE + surcharge, "quoted buy");
        assertEq(_trade(key, false, 1e18), SELL_NATIVE + surcharge, "executed sell");
    }

    // ------------------------------------------------------------ keeper + session

    function testTiersAddToKeeperSurcharge() public {
        PoolKey memory key = _launchTiered(fee, _cfg(20_000, 1000), _tiers());
        PoolId id = key.toId();
        assertTrue(fee.poolState(id).tiered);
        IHookrFeeAdvisory.Session memory x = fee.sessionTiers(id);
        assertEq(x.closedPips, CLOSED);
        assertEq(x.cap, 20_000);
        _expectAt(key, _ny(2026, 9, 28, 11, 0, 0, true), 1000 + REGULAR);
        _expectAt(key, _ny(2026, 9, 28, 7, 0, 0, true), 1000 + PRE);
        _expectAt(key, _ny(2026, 9, 28, 17, 0, 0, true), 1000 + AFTER);
        _expectAt(key, _ny(2026, 9, 28, 22, 0, 0, true), 1000 + NIGHT);
        _expectAt(key, _ny(2026, 10, 3, 12, 0, 0, true), 1000 + CLOSED);
        _expectAt(key, _ny(2026, 11, 26, 12, 0, 0, false), 1000 + CLOSED);
        _expectAt(key, _ny(2026, 11, 27, 13, 30, 0, false), 1000 + AFTER);
        assertTrue(rules.accountingInvariant(Currency.wrap(address(tokenB))));
    }

    function testKeeperRepriceAddsAndCapClamps() public {
        PoolKey memory key = _launchTiered(fee, _cfg(20_000, 1000), _tiers());
        PoolId id = key.toId();
        vm.prank(keeper);
        fee.reprice(id, 6000, 0, 0, 1 hours);
        _expectAt(key, _ny(2026, 9, 28, 11, 0, 0, true), 6000 + REGULAR);
        _expectAt(key, _ny(2026, 9, 28, 11, 1, 0, true), 6000 + REGULAR);
        // 6,000 + 15,000 on a Saturday clamps to the 20,000 cap.
        vm.warp(_ny(2026, 10, 3, 11, 0, 0, true));
        vm.prank(keeper);
        fee.reprice(id, 6000, 0, 0, 1 hours);
        _expectAt(key, _ny(2026, 10, 3, 11, 30, 0, true), 20_000);
        // The keeper's own bounds are unchanged: it still cannot exceed the cap alone.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.AboveCap.selector, 20_001, 20_000));
        fee.reprice(id, 20_001, 0, 0, 1 hours);
    }

    function testGuardClampsTieredBuys() public {
        IHookrLauncher.Member memory m = _member(fee);
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        m.rules.snipeTaxPips = 50_000;
        // Guard native buy 54,750 plus the 50,000 admission maximum beside it.
        m.config.caps.maxLpFeePips = 104_750;
        PoolKey memory key = _launchWith(m, abi.encode(_cfg(ADMISSION_CAP, 40_000), _tiers()));
        vm.warp(_ny(2026, 10, 3, 12, 0, 0, true));
        // 40,000 + 15,000 clamps to the 50,000 cap, which is also the guard ceiling here.
        assertEq(_trade(key, true, 1e18), 104_750);
        assertEq(_trade(key, false, 1e18), SELL_NATIVE + ADMISSION_CAP);
        vm.roll(vm.getBlockNumber() + 100);
        assertEq(_trade(key, true, 1e18), BUY_NATIVE + ADMISSION_CAP);
        vm.warp(_ny(2026, 10, 5, 11, 0, 0, true));
        assertEq(_trade(key, true, 1e18), BUY_NATIVE + 40_000 + REGULAR);
    }

    // ------------------------------------------------------------ compatibility and refusals

    function testOldBindDataUnchanged() public {
        PoolKey memory key = _launchWith(_member(fee), abi.encode(_cfg(20_000, 1000)));
        PoolId id = key.toId();
        assertFalse(fee.poolState(id).tiered);
        assertEq(fee.sessionTiers(id).cap, 0);
        _expectAt(key, _ny(2026, 9, 28, 11, 0, 0, true), 1000);
        _expectAt(key, _ny(2026, 10, 3, 12, 0, 0, true), 1000);
        // An advisory without a calendar takes old data too.
        PoolKey memory k2 = _launchWith(_member(plain), abi.encode(_cfg(20_000, 1000)));
        assertEq(plain.surcharge(k2.toId(), true), 1000);
    }

    function testBindRefusesBadTiers() public {
        HookrSessionTiers.Tiers memory t = _tiers();
        // A tier above the pool's cap.
        t.closedPips = 20_001;
        _expectBindRefused(fee, _invalidTiers(3));
        _launchTiered(fee, _cfg(20_000, 1000), t);
        // Unknown flags, ramps longer than the shortest session.
        t = _tiers();
        t.flags = 2;
        _expectBindRefused(fee, _invalidTiers(1));
        _launchTiered(fee, _cfg(20_000, 1000), t);
        t = _tiers();
        (t.openRampSeconds, t.closeRampSeconds) = (12_000, 601);
        _expectBindRefused(fee, _invalidTiers(2));
        _launchTiered(fee, _cfg(20_000, 1000), t);
        // Empty tiers in the tiered format.
        HookrSessionTiers.Tiers memory empty;
        _expectBindRefused(fee, _invalidConfig());
        _launchTiered(fee, _cfg(20_000, 1000), empty);
        // Non-canonical encodings: a dirty high byte in a tier word, and trailing bytes.
        bytes memory dirty = abi.encode(_cfg(20_000, 1000), _tiers());
        dirty[224 + 4 * 32] = 0x01;
        _expectBindRefused(fee, "");
        _launchWith(_member(fee), dirty);
        _expectBindRefused(fee, _invalidConfig());
        _launchWith(_member(fee), bytes.concat(abi.encode(_cfg(20_000, 1000), _tiers()), bytes1(0)));
        // An advisory deployed without a calendar refuses tiers.
        _expectBindRefused(plain, abi.encodeWithSelector(IHookrFeeAdvisory.InvalidCalendar.selector, address(0)));
        _launchTiered(plain, _cfg(20_000, 1000), _tiers());
        // The keeper config is still checked first-class.
        _expectBindRefused(fee, _invalidConfig());
        _launchTiered(fee, _cfg(ADMISSION_CAP + 1, 1000), _tiers());
        // Tiers exactly at the cap bind.
        t = HookrSessionTiers.Tiers(20_000, 20_000, 20_000, 20_000, 20_000, 6300, 6300, 1);
        _launchTiered(fee, _cfg(20_000, 1000), t);
    }

    function testConstructorRefusesCalendarWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.InvalidCalendar.selector, address(0xCa1)));
        new HookrFeeAdvisory(address(this), 1 days, registry, address(0xCa1));
    }

    function testBrokenCalendarChargesHighestTier() public {
        PoolKey memory key = _launchTiered(fragile, _cfg(20_000, 1000), _tiers());
        vm.warp(_ny(2026, 9, 28, 11, 0, 0, true));
        assertEq(fragile.surcharge(key.toId(), true), 1000 + REGULAR);
        breakable.breakIt();
        assertEq(fragile.surcharge(key.toId(), true), 1000 + CLOSED);
        assertEq(_trade(key, false, 1e18), SELL_NATIVE + 1000 + CLOSED);
    }

    /// @dev The tiered surcharge is min(cap, keeper value + HookrSessionAdvisory's value for the same tiers).
    function testFuzzSurchargeIsKeeperPlusSession(uint256 timestamp, uint24 target, uint16 openRamp, uint16 closeRamp)
        public
    {
        timestamp = bound(timestamp, _ny(2026, 1, 1, 0, 0, 0, false), _ny(2032, 12, 31, 23, 0, 0, false));
        openRamp = uint16(bound(openRamp, 0, 6300));
        closeRamp = uint16(bound(closeRamp, 0, 6300));
        HookrSessionTiers.Tiers memory t =
            HookrSessionTiers.Tiers(REGULAR, PRE, AFTER, NIGHT, CLOSED, openRamp, closeRamp, 1);
        PoolKey memory key = _launchTiered(fee, _cfg(20_000, 1000), t);
        PoolId ref = PoolId.wrap(keccak256(abi.encode(timestamp, target)));
        session.bindPair(ref, type(uint24).max, 60_000, abi.encode(t));
        uint256 keeperValue = 1000;
        if (target % 2 == 1) {
            keeperValue = bound(target, 0, 6000);
            vm.prank(keeper);
            fee.reprice(key.toId(), uint24(keeperValue), 0, 0, 1 hours);
            timestamp = vm.getBlockTimestamp() + timestamp % 1 hours;
        }
        vm.warp(timestamp);
        uint256 expected = keeperValue + session.surchargeAt(address(this), ref, timestamp);
        if (expected > 20_000) expected = 20_000;
        assertEq(fee.surcharge(key.toId(), true), expected);
        assertEq(fee.surcharge(key.toId(), false), expected);
        assertEq(_lpFee(key, false), SELL_NATIVE + expected);
    }

    // --------------------------------------------------------------------- gas

    function testGasPerSwapWithTiers() public {
        PoolKey memory tiered = _launchTiered(fee, _cfg(20_000, 1000), _tiers());
        PoolKey memory untiered = _launchWith(_member(fee), abi.encode(_cfg(20_000, 1000)));
        _trade(tiered, true, 1e18);
        _trade(untiered, true, 1e18);
        uint256[3] memory times =
            [_ny(2026, 9, 29, 11, 0, 0, true), _ny(2026, 10, 3, 12, 0, 0, true), _ny(2031, 3, 4, 11, 0, 0, false)];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            IHookrRouter.Swap memory pt = _swap(tiered, true, true, 1e18);
            IHookrRouter.Swap memory pu = _swap(untiered, true, true, 1e18);
            _cool();
            vm.prank(trader);
            uint256 g = gasleft();
            router.swap(pu, address(0), new uint256[](0));
            uint256 untieredGas = g - gasleft();
            _cool();
            vm.prank(trader);
            g = gasleft();
            router.swap(pt, address(0), new uint256[](0));
            uint256 tieredGas = g - gasleft();
            console2.log("swap gas, fee advisory without tiers", untieredGas);
            console2.log("swap gas, fee advisory with tiers   ", tieredGas);
            console2.log("tiers overhead", tieredGas - untieredGas);
            assertLt(tieredGas - untieredGas, 12_000);
        }
    }

    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(root));
        vm.cool(address(rules));
        vm.cool(address(router));
        vm.cool(address(tokenA));
        vm.cool(address(tokenB));
        vm.cool(address(fee));
        vm.cool(address(session));
        vm.cool(address(registry));
    }
}
