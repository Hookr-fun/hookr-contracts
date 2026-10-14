// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice The Hookr minimum on owned roots: every companion pays the Hookr treasury and every pool the launcher
///         opens is a Hookr token's, so every owned-root pool freezes the treasury's minimum at bind. The owned root
///         adds nothing to it and cannot drop it: the minimum is the Rules', the profile's caps must admit
///         `royalty + minimum` or the pool does not open, and a pool with a minimum is never fee-only. This suite's
///         copy of the Rules' quote-take bound (`_quoteTakeBound`) is checked against HookrRules itself.
contract OwnedRootsMinimumFeeTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    HookrRoot internal owned;
    HookrRules internal companion;

    function setUp() public {
        _setUpOwned();
        (owned, companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
    }

    function launchExternal(address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(stranger, rootAddr, m);
    }

    /// @notice A plain owned-root pool freezes the default 1,000 pips, is not fee-only, and pays Hookr exactly 0.1% of
    ///         a 1 ETH buy and at least 0.1% of a sell's quote, all of it to the treasury's claim.
    function test_plainOwnedPoolFreezesTheDefaultMinimumAndPaysIt() public {
        assertEq(hookrTreasury.minFeePips(false), hookrTreasury.DEFAULT_MIN_FEE_PIPS());
        (, PoolKey memory key,) = _launchAs(stranger, address(owned), _nativeMember(address(companion), _plainRc(), 0));
        PoolId id = key.toId();
        assertEq(IHookrRecaptureRules(address(companion)).minimumFee(id), 1000, "frozen at bind");
        assertEq(companion.feeOnlyFrom(id), 0, "a pool with a minimum is never fee-only");

        uint256 before = companion.claimable(ETH, address(hookrTreasury));
        HookrTypes.ExecutionReceipt memory buyQ = quoter.quote(_swapParams(key, true, true, 1 ether), trader);
        _trade(key, true, true, 1 ether);
        uint256 buyPaid = companion.claimable(ETH, address(hookrTreasury)) - before;
        assertEq(buyPaid, 0.001 ether, "exactly the minimum of a 1 ETH buy");
        assertEq(buyQ.quoteFee, buyPaid);

        (, uint256 got) = _trade(key, true, true, 5 ether);
        before = companion.claimable(ETH, address(hookrTreasury));
        HookrTypes.ExecutionReceipt memory sellQ = quoter.quote(_swapParams(key, false, true, uint128(got)), trader);
        _trade(key, false, true, uint128(got));
        uint256 sellPaid = companion.claimable(ETH, address(hookrTreasury)) - before;
        assertEq(sellQ.quoteFee, sellPaid);
        assertGe(sellPaid, sellQ.actualQuote * 1000 / 1e6, "at least the minimum of the sell's quote");
        assertTrue(companion.accountingInvariant(ETH));
        // The treasury collects it.
        uint256 owed = companion.claimable(ETH, address(hookrTreasury));
        assertEq(_collect(address(companion)), owed);
    }

    /// @notice An owned-root pool whose Rules already give Hookr more than the minimum on a buy pays no top-up.
    function test_rulesAboveTheMinimumPayNoTopUpOnABuy() public {
        (, PoolKey memory key,) = _launchAs(stranger, address(owned), _nativeMember(address(companion), _rc(), 0));
        uint256 before = companion.claimable(ETH, address(hookrTreasury));
        _trade(key, true, true, 1 ether);
        // lpSlice ceil(200 x 2500 / 100) = 5,000 and burnSlice ceil(100 x 2500 / 100) = 2,500 pips of the 1 ETH spend.
        assertEq(companion.claimable(ETH, address(hookrTreasury)) - before, 0.0075 ether);
    }

    /// @notice A profile's caps are its owned roots' admission caps, and the Rules bind a pool only when they admit
    ///         `royalty + minimum`: a profile capping the quote take at 999 pips opens no Hookr token pool at the
    ///         default minimum, one at 1,000 does.
    function test_profileCapsBelowTheMinimumOpenNoPool() public {
        (HookrRoot tight, HookrRules tightRules) = _ownedWithQuoteCap(999, "tight", trader);
        IHookrLauncher.Member memory m = _nativeMember(address(tightRules), _plainRc(), 0);
        vm.expectRevert(_bindRefusal(address(tightRules)));
        this.launchExternal(address(tight), m);
        (HookrRoot exact, HookrRules exactRules) = _ownedWithQuoteCap(1000, "exact", stranger);
        (, PoolKey memory key,) = this.launchExternal(address(exact), _nativeMember(address(exactRules), _plainRc(), 0));
        assertEq(IHookrRecaptureRules(address(exactRules)).minimumFee(key.toId()), 1000);
    }

    /// @notice The minimum freezes at bind on owned-root pools like every other term: lowering the rate to 0 reaches
    ///         only pools bound after it, and raising it to the 1% ceiling leaves the earlier pools where they were.
    function test_minimumFreezesAtBindAndTheRecaptureRateIsSeparate() public {
        (, PoolKey memory a,) = _launchAs(stranger, address(owned), _nativeMember(address(companion), _plainRc(), 0));
        _setTreasuryMinimum(false, 0);
        (, PoolKey memory b,) = _launchAs(stranger, address(owned), _nativeMember(address(companion), _plainRc(), 0));
        _setTreasuryMinimum(false, 10_000);
        (, PoolKey memory c,) = _launchAs(stranger, address(owned), _nativeMember(address(companion), _plainRc(), 0));
        IHookrRecaptureRules r = IHookrRecaptureRules(address(companion));
        assertEq(r.minimumFee(a.toId()), 1000);
        assertEq(r.minimumFee(b.toId()), 0);
        assertEq(r.minimumFee(c.toId()), 10_000);
        assertEq(companion.feeOnlyFrom(a.toId()), 0);
        assertGt(companion.feeOnlyFrom(b.toId()), 0, "no minimum and no rules: fee-only");
        assertEq(companion.feeOnlyFrom(c.toId()), 0);
        assertEq(hookrTreasury.minFeePips(true), 1000, "the recapture rate did not move");
    }

    /// @notice Differential: this suite's copies of the Rules' quote-take bound and of the rule that binds the minimum
    ///         only where nothing else earns Hookr a share decide exactly when HookrRules binds a pool on an owned root
    ///         without a dynamic fee, over the minimum (0 to 10,000), the quote cap, LP Rewards, Auto Burn, royalty and
    ///         the protocol share; with a dynamic fee, every pool above the bound is refused. When it binds, the pool
    ///         froze that minimum and a buy pays the treasury at least it.
    /// forge-config: default.fuzz.runs = 96
    function testFuzz_quoteTakeBoundMatchesHookrRules(
        uint16 minPips,
        uint24 capQuote,
        uint16 lpBps,
        uint16 burnBps,
        uint16 royaltyBps,
        uint16 shareBps,
        uint24 maxFee,
        uint128 raw
    ) public {
        uint16 minFee = uint16(bound(minPips, 0, 10_000));
        _setTreasuryMinimum(false, minFee);
        HookrTypes.RulesConfig memory c;
        c.lpBps = uint16(bound(lpBps, 0, 1000));
        c.burnBps = uint16(bound(burnBps, 0, 1000 - c.lpBps));
        c.protocolShareBps = uint16(bound(shareBps, PROTOCOL_FLOOR, 5000));
        if (c.lpBps != 0) {
            c.royaltyBps = uint16(bound(royaltyBps, 0, 1000));
            if (c.royaltyBps != 0) c.royaltyTo = royalty;
        }
        if (maxFee & 1 == 0) {
            c.lpBps = c.lpBps % 21;
            if (c.lpBps == 0) (c.royaltyBps, c.royaltyTo) = (0, address(0));
            c.burnBps = c.burnBps % 5;
        } else {
            c.maxFeePips = uint24(bound(maxFee, 3000, 600_000));
        }
        if (c.maxFeePips == 0) c.maxFeePips = 3000;
        if (c.maxFeePips != 3000) c.dynamicFeeSens = DYNAMIC_FEE_SENS;
        // The minimum binds only on a pool whose rules earn Hookr no pip of any swap.
        uint256 bound_ = _earnsHookr(c, 3000) ? 0 : minFee;
        uint256 predicted = _quoteTakeBound(c, 3000, bound_);
        uint256 lo = predicted > 64 ? predicted - 64 : 0;
        uint256 hi = predicted + 64 > 200_000 ? 200_000 : predicted + 64;
        if (lo > hi) lo = hi;
        IHookrLauncher.Member memory m = _nativeMember(address(companion), c, 0);
        m.config.caps.maxQuoteTakePips = uint24(bound(capQuote, lo, hi));
        bool opens;
        PoolKey memory key;
        try this.launchExternal(address(owned), m) returns (bytes32, PoolKey memory k, address) {
            opens = true;
            key = k;
        } catch {}
        bool fits = predicted <= m.config.caps.maxQuoteTakePips;
        if (c.dynamicFeeSens == 0) {
            assertEq(opens, fits, "this suite's bound is the Rules' bound");
        } else if (!fits) {
            // A dynamic fee pool can also be refused at bind for bounds of the core's own that this suite does not
            // copy (the dynamic fee's reach), so only the quote bound's refusals are compared.
            assertFalse(opens, "a dynamic fee pool above the quote bound never opens");
        }
        if (!opens) return;
        assertEq(IHookrRecaptureRules(address(companion)).minimumFee(key.toId()), bound_);
        uint128 amount = uint128(bound(raw, 1e12, 1e20));
        HookrTypes.ExecutionReceipt memory q = quoter.quote(_swapParams(key, true, true, amount), trader);
        uint256 before = companion.claimable(ETH, address(hookrTreasury));
        _trade(key, true, true, amount);
        uint256 paid = companion.claimable(ETH, address(hookrTreasury)) - before;
        assertGe(paid, q.inputAmount * bound_ / 1e6, "Hookr is paid at least the minimum it bound");
        assertLe(q.quoteFee * 1e6, uint256(m.config.caps.maxQuoteTakePips) * q.inputAmount + 1e6);
        assertTrue(companion.accountingInvariant(ETH));
    }

    /// @dev A public profile on the shared root with the quote take capped at `capQuote`, and an owned root derived
    ///      from it for `owner_`.
    function _ownedWithQuoteCap(uint24 capQuote, bytes32 salt, address owner_)
        internal
        returns (HookrRoot r, HookrRules rr)
    {
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.caps = HookrTypes.Caps(600_000, capQuote, 1000);
        vm.prank(brand);
        bytes32 id = book.writeProfile(salt, p);
        (r, rr) = _deployOwned(_selFor(id, owner_, F.ALL_FEATURES, true));
    }
}
