// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {PairRootFixture} from "./PairRootFixture.sol";

/// @dev HookrFeeAdvisory with session tiers behind factory-deployed pair roots, swapped through the real PoolManager:
///      keeper surcharge plus session tier per direction, clamped to the pool's cap; old bind data; bind refusals.
contract PairRootFeeTiersTest is PairRootFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant ROOT_CAP = 30_000;
    uint24 internal constant REGULAR = 1_000;
    uint24 internal constant PRE = 4_000;
    uint24 internal constant AFTER = 6_000;
    uint24 internal constant NIGHT = 10_000;
    uint24 internal constant CLOSED = 20_000;

    HookrSessionAdvisory internal session;
    HookrFeeAdvisory internal fee;
    HookrFeeAdvisory internal plain;
    address internal keeper = address(0xBEEF);
    uint24 internal base = 3_000;

    function setUp() public {
        _setUpFactory();
        session = new HookrSessionAdvisory(address(this), 1 days);
        fee = new HookrFeeAdvisory(address(this), 1 days, IHookrRegistry(address(registry)), address(session));
        plain = new HookrFeeAdvisory(address(this), 1 days, IHookrRegistry(address(registry)), address(0));
        _admitPairAdvisory(registry, address(factory), address(fee));
        _admitPairAdvisory(registry, address(factory), address(plain));
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fee.addKeeper(keeper);
        vm.warp(_ny(2026, 9, 29, 11, 0, 0, true));
    }

    function _ny(uint256 y, uint256 m, uint256 d, uint256 h, uint256 mi, uint256 sec, bool dst)
        internal
        pure
        returns (uint256)
    {
        return
            HookrMarketCalendar.dayOf(y, m, d) * 1 days + h * 1 hours + mi * 1 minutes + sec + (dst ? 4 : 5) * 1 hours;
    }

    function _cfg(uint24 cap, uint24 surcharge, uint24 p0, uint24 p1)
        internal
        pure
        returns (IHookrFeeAdvisory.Config memory)
    {
        return IHookrFeeAdvisory.Config({
            cap: cap, surcharge: surcharge, premium0: p0, premium1: p1, maxStep: 5_000, minInterval: 60, maxTtl: 1 hours
        });
    }

    function _tiers() internal pure returns (HookrSessionTiers.Tiers memory) {
        return HookrSessionTiers.Tiers(REGULAR, PRE, AFTER, NIGHT, CLOSED, 0, 0, 0);
    }

    /// @dev Each call uses a new base fee, so each deployment has its own salt and pool.
    function _params(address module, uint32 gasLimit) internal returns (IHookrPairRoot.Params memory p) {
        (Currency c0, Currency c1) = _erc();
        p = _plain(c0, c1, ++base);
        p.maxLpFeePips = base + ROOT_CAP;
        p.advisory = module;
        p.advisoryCapPips = ROOT_CAP;
        p.advisoryGasLimit = gasLimit;
    }

    function _deployWith(IHookrPairRoot.Params memory p, bytes memory data) internal returns (PoolKey memory key) {
        bytes32 salt = _mine(deployer, p);
        vm.prank(deployer);
        (address r,) = factory.deploy(salt, p, SQRT_ONE, data);
        key = HookrPairRoot(r).poolKey();
        _fund(key);
    }

    function _expectDeployRevert(IHookrPairRoot.Params memory p, bytes memory data, bytes memory reason) internal {
        bytes32 salt = _mine(deployer, p);
        vm.prank(deployer);
        vm.expectRevert(reason);
        factory.deploy(salt, p, SQRT_ONE, data);
    }

    /// @dev Warps to `t` and asserts the view and executed swaps in both directions of the last deployed pool.
    function _expectAt(PoolKey memory key, uint256 t, uint256 s0, uint256 s1) internal {
        vm.warp(t);
        PoolId id = key.toId();
        uint256 b = base;
        assertEq(fee.surcharge(id, true), s0, "view 0->1");
        assertEq(fee.surcharge(id, false), s1, "view 1->0");
        assertEq(_swapFee(key, true, -1e15, ""), b + s0, "swap 0->1");
        assertEq(_swapFee(key, false, -1e15, ""), b + s1, "swap 1->0");
    }

    function test_tiersAddPerDirection() public {
        PoolKey memory key =
            _deployWith(_params(address(fee), fee.MIN_TIERED_GAS()), abi.encode(_cfg(25_000, 400, 100, 0), _tiers()));
        PoolId id = key.toId();
        assertTrue(fee.poolState(id).tiered);
        assertEq(fee.sessionTiers(id).cap, 25_000);
        _expectAt(key, _ny(2026, 9, 29, 11, 0, 0, true), 500 + REGULAR, 400 + REGULAR);
        _expectAt(key, _ny(2026, 9, 29, 5, 0, 0, true), 500 + PRE, 400 + PRE);
        _expectAt(key, _ny(2026, 9, 29, 18, 0, 0, true), 500 + AFTER, 400 + AFTER);
        _expectAt(key, _ny(2026, 9, 29, 23, 0, 0, true), 500 + NIGHT, 400 + NIGHT);
        _expectAt(key, _ny(2026, 10, 4, 12, 0, 0, true), 500 + CLOSED, 400 + CLOSED);
        // A keeper target adds to the tier and the sum clamps to the pool's 25,000 cap.
        vm.prank(keeper);
        fee.reprice(id, 5_000, 0, 200, 1 hours);
        _expectAt(key, _ny(2026, 10, 4, 12, 1, 0, true), 25_000, 25_000);
        vm.warp(_ny(2026, 10, 5, 11, 0, 0, true));
        vm.prank(keeper);
        fee.reprice(id, 5_000, 0, 200, 1 hours);
        _expectAt(key, _ny(2026, 10, 5, 11, 1, 0, true), 5_000 + REGULAR, 5_200 + REGULAR);
    }

    function test_oldBindDataUnchanged() public {
        PoolKey memory key =
            _deployWith(_params(address(fee), fee.MIN_PAIR_GAS()), abi.encode(_cfg(25_000, 400, 100, 0)));
        assertFalse(fee.poolState(key.toId()).tiered);
        _expectAt(key, _ny(2026, 9, 29, 11, 0, 0, true), 500, 400);
        _expectAt(key, _ny(2026, 10, 4, 12, 0, 0, true), 500, 400);
        key = _deployWith(_params(address(plain), plain.MIN_PAIR_GAS()), abi.encode(_cfg(25_000, 400, 100, 0)));
        assertEq(plain.surcharge(key.toId(), true), 500);
    }

    function test_bindRefusals() public {
        bytes memory invalid = abi.encodeWithSelector(IHookrFeeAdvisory.InvalidConfig.selector);
        bytes memory data = abi.encode(_cfg(25_000, 400, 0, 0), _tiers());
        // Tiers need MIN_TIERED_GAS of advisory gas.
        _expectDeployRevert(_params(address(fee), fee.MIN_TIERED_GAS() - 1), data, invalid);
        // A tier above the pool's cap, unknown flags, over-long ramps, empty tiers.
        HookrSessionTiers.Tiers memory t = _tiers();
        t.closedPips = 25_001;
        _expectDeployRevert(
            _params(address(fee), 60_000),
            abi.encode(_cfg(25_000, 400, 0, 0), t),
            abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, 3)
        );
        t = _tiers();
        t.flags = 4;
        _expectDeployRevert(
            _params(address(fee), 60_000),
            abi.encode(_cfg(25_000, 400, 0, 0), t),
            abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, 1)
        );
        t = _tiers();
        (t.openRampSeconds, t.closeRampSeconds) = (12_600, 1);
        _expectDeployRevert(
            _params(address(fee), 60_000),
            abi.encode(_cfg(25_000, 400, 0, 0), t),
            abi.encodeWithSelector(HookrSessionTiers.InvalidTiers.selector, 2)
        );
        HookrSessionTiers.Tiers memory empty;
        _expectDeployRevert(_params(address(fee), 60_000), abi.encode(_cfg(25_000, 400, 0, 0), empty), invalid);
        // Trailing bytes and an advisory without a calendar.
        _expectDeployRevert(_params(address(fee), 60_000), bytes.concat(data, bytes1(0)), invalid);
        _expectDeployRevert(
            _params(address(plain), 60_000),
            data,
            abi.encodeWithSelector(IHookrFeeAdvisory.InvalidCalendar.selector, address(0))
        );
        // The pool's cap still has to fit the root's cap.
        _expectDeployRevert(_params(address(fee), 60_000), abi.encode(_cfg(ROOT_CAP + 1, 400, 0, 0), _tiers()), invalid);
    }

    function test_foreignCallerRefused() public {
        PoolKey memory key = _deployWith(_params(address(fee), 60_000), abi.encode(_cfg(25_000, 400, 0, 0), _tiers()));
        vm.expectRevert(abi.encodeWithSelector(IHookrFeeAdvisory.UnknownPool.selector, key.toId()));
        fee.surchargeForSwap(key.toId(), true, -1, 0, "", address(0));
        vm.prank(address(key.hooks));
        assertEq(fee.surchargeForSwap(key.toId(), true, -1, 0, "", address(0)), 400 + REGULAR);
    }

    /// @dev The advisory's gas on the tiered pool fits the minimum it demands, with the calendar cold, in an appended
    ///      year read from storage.
    function test_tieredSurchargeFitsMinimumGas() public {
        uint16[] memory closed = new uint16[](1);
        closed[0] = 101;
        uint16[] memory early = new uint16[](0);
        session.queue(session.APPEND_YEAR(), abi.encode(uint16(2031), closed, early));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        session.appendYear(2031, closed, early);
        PoolKey memory key = _deployWith(_params(address(fee), 60_000), abi.encode(_cfg(25_000, 400, 0, 0), _tiers()));
        vm.warp(_ny(2031, 12, 31, 21, 0, 0, false));
        vm.cool(address(fee));
        vm.cool(address(session));
        vm.prank(address(key.hooks));
        uint256 g = gasleft();
        uint24 s = fee.surchargeForSwap{gas: 60_000}(key.toId(), true, -1, 0, "", address(0));
        uint256 used = g - gasleft();
        assertEq(s, 400 + NIGHT);
        assertLt(used, 30_000);
    }
}
