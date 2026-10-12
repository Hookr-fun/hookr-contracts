// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice Fuzz over the tier-2 selections, the caps a profile gives its owned roots, the Rules a creator picks on
///         them, the treasury's Hookr minimum and the trade amounts.
contract OwnedRootsFuzzTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    HookrRoot internal owned;
    HookrRules internal companion;
    PoolKey internal ownedKey;

    function setUp() public {
        _setUpOwned();
        (owned, companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (, ownedKey,) = _launchAs(brand, address(owned), _nativeMember(address(companion), _rc(), 0));
    }

    function launchExternal(address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(stranger, rootAddr, m);
    }

    /// @notice A root's rule mask is accepted exactly when it is inside the profile's mask and, for a public root,
    ///         keeps every soft feature; the admission then caps the subject take at zero exactly when Auto Burn is
    ///         left out.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_selectionMaskAcceptedIffInsideTheProfileAndEnforceable(uint8 raw, bool publicOpening) public {
        bytes32 mask = bytes32(uint256(raw) & 63);
        bool inside = mask & ~F.ALL_FEATURES == 0;
        bool enforceable = !publicOpening || mask & F.SOFT_FEATURES == F.SOFT_FEATURES;
        bytes32 salt = _mine(trader);
        IHookrOwnedRootFactory.RootSelections memory sel = _selFor(templateProfile, trader, mask, publicOpening);
        uint256 fee = _fee(factory);
        vm.deal(trader, trader.balance + fee);
        if (!inside) {
            vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.OutsideProfile.selector, templateProfile));
        } else if (!enforceable) {
            vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.SoftMaskNeedsOwnerOnly.selector, mask));
        }
        vm.prank(trader);
        address r = _deployCall(factory, fee, sel, salt);
        if (!inside || !enforceable) return;
        IHookrOwnedRootFactory.OwnedRoot memory o = factory.ownedRoot(r);
        assertEq(o.ruleMask, mask);
        assertEq(o.publicOpening, publicOpening);
        IHookrRegistry.Admission memory a = registry.admission(r, o.rules);
        assertEq(a.caps.maxSubjectTakeBps, mask & F.AUTO_BURN == 0 ? 0 : 1000);
        assertEq(a.caps.maxLpFeePips, 600_000);
        assertEq(a.caps.maxQuoteTakePips, 200_000);
    }

    /// @notice The quoter's receipt is what the owned-root pool executes, both ways and both modes, with the
    ///         companion's ledger backed, the router holding nothing and the shared Rules' ledger untouched.
    function testFuzz_ownedPoolQuoteMatchesSwapAndLedgerStaysBacked(bool buy, bool exactInput, uint128 raw) public {
        uint128 amount = uint128(bound(raw, 1e9, 1e20));
        if (!buy) {
            (, uint256 got) = _trade(ownedKey, true, true, 5e20);
            amount = uint128(bound(raw, 1e9, got / 2));
        }
        IHookrRouter.Swap memory p = _swapParams(ownedKey, buy, exactInput, amount);
        HookrTypes.ExecutionReceipt memory q = quoter.quote(p, trader);
        uint256 protocolBefore = companion.claimable(ETH, address(hookrTreasury));
        (uint256 amountIn, uint256 amountOut) = _trade(ownedKey, buy, exactInput, amount);
        assertEq(amountIn, q.inputAmount);
        assertEq(amountOut, q.outputAmount);
        assertTrue(companion.accountingInvariant(ETH));
        assertEq(address(router).balance, 0);
        assertEq(HookrToken(Currency.unwrap(ownedKey.currency1)).balanceOf(address(router)), 0);
        assertGe(companion.claimable(ETH, address(hookrTreasury)), protocolBefore);
        assertEq(sharedRules.totalLiability(ETH), 0, "the shared ledger never moves on an owned-root trade");
    }

    /// @notice Whatever Rules a creator picks on an owned root, the executed fees stay inside the caps its profile gave
    ///         it: the companion's admission caps every pool at bind (HookrRules) and every swap (HookrRoot). A
    ///         configuration whose worst case does not fit is refused at bind, which this case allows.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_profileCapsBoundEveryExecutedFee(
        uint24 capLp,
        uint24 capQuote,
        uint16 capSubject,
        uint16 lpBps,
        uint16 burnBps,
        uint16 royaltyBps,
        uint16 shareBps,
        uint24 maxFee,
        uint128 raw
    ) public {
        HookrTypes.Caps memory caps = HookrTypes.Caps(
            uint24(bound(capLp, 3000, 600_000)), uint24(bound(capQuote, 0, 200_000)), uint16(bound(capSubject, 0, 1000))
        );
        (HookrRoot r, HookrRules rr, bytes32 id) = _rootWithCaps(caps, "caps");
        HookrTypes.RulesConfig memory c;
        c.lpBps = uint16(bound(lpBps, 0, 1000));
        c.burnBps = uint16(bound(burnBps, 0, 1000 - c.lpBps));
        c.protocolShareBps = uint16(bound(shareBps, PROTOCOL_FLOOR, 5000));
        if (c.lpBps != 0) {
            c.royaltyBps = uint16(bound(royaltyBps, 0, 1000));
            if (c.royaltyBps != 0) c.royaltyTo = royalty;
        }
        c.maxFeePips = uint24(bound(maxFee, 3000, 600_000));
        if (c.maxFeePips != 3000) c.dynamicFeeSens = DYNAMIC_FEE_SENS;
        IHookrLauncher.Member memory m = _nativeMember(address(rr), c, id);
        PoolKey memory key;
        try this.launchExternal(address(r), m) returns (bytes32, PoolKey memory k, address) {
            key = k;
        } catch {
            return;
        }
        uint128 amount = uint128(bound(raw, 1e12, 1e20));
        HookrTypes.ExecutionReceipt memory buyQ = quoter.quote(_swapParams(key, true, true, amount), trader);
        assertLe(buyQ.lpFeePips, caps.maxLpFeePips);
        assertLe(buyQ.quoteFee * 1e6, uint256(caps.maxQuoteTakePips) * buyQ.inputAmount + 1e6);
        assertLe(buyQ.subjectBurn * 1e4, uint256(caps.maxSubjectTakeBps) * (buyQ.outputAmount + buyQ.subjectBurn) + 1e4);
        (, uint256 got) = _trade(key, true, true, amount);
        HookrTypes.ExecutionReceipt memory sellQ =
            quoter.quote(_swapParams(key, false, true, uint128(got / 2 + 1)), trader);
        assertLe(sellQ.lpFeePips, caps.maxLpFeePips);
        assertLe(sellQ.quoteFee * 1e6, uint256(caps.maxQuoteTakePips) * sellQ.actualQuote + 1e6);
        assertEq(sellQ.subjectBurn, 0);
        assertTrue(rr.accountingInvariant(ETH));
    }

    /// @notice The success path of the cap fuzz, on an owned root wired as the release wires it: the companion pays the
    ///         Hookr treasury, so every pool (a Hookr token's) freezes the treasury's minimum (fuzzed from 0 to its
    ///         10,000 ceiling), and its quote take is at most `royalty + max(rule share, minimum)`. A configuration
    ///         built inside caps that admit that take always opens, and its executed fees stay inside them. No dynamic
    ///         fee: its bind-time bounds are the core's.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_configsBuiltInsideTheCapsOpenAndStayInside(
        uint24 capLp,
        uint24 capQuote,
        uint16 capSubject,
        uint16 lpBps,
        uint16 burnBps,
        uint16 royaltyBps,
        uint16 minPips,
        uint128 raw
    ) public {
        uint16 minFee = uint16(bound(minPips, 0, 10_000));
        _setTreasuryMinimum(false, minFee);
        HookrTypes.Caps memory caps = HookrTypes.Caps(
            uint24(bound(capLp, 3000, 600_000)),
            uint24(bound(capQuote, minFee, 200_000)),
            uint16(bound(capSubject, 0, 1000))
        );
        (HookrRoot r, HookrRules rr, bytes32 id) = _rootWithCaps(caps, "inside");
        HookrTypes.RulesConfig memory c;
        c.maxFeePips = 3000;
        c.protocolShareBps = PROTOCOL_FLOOR;
        uint256 sliceMax = caps.maxQuoteTakePips / 2 * 100 / PROTOCOL_FLOOR;
        uint256 burnMax = caps.maxSubjectTakeBps < 500 ? caps.maxSubjectTakeBps : 500;
        c.burnBps = uint16(bound(burnBps, 0, burnMax < sliceMax ? burnMax : sliceMax));
        uint256 lpRoom = (uint256(caps.maxLpFeePips) - 3000) / 100;
        if (lpRoom > 500) lpRoom = 500;
        c.lpBps = uint16(bound(lpBps, 0, lpRoom < sliceMax ? lpRoom : sliceMax));
        // The minimum binds only where nothing earns Hookr a share: here, a pool without LP Rewards and Auto Burn.
        uint256 bound_ = _earnsHookr(c, 3000) ? 0 : minFee;
        if (c.lpBps != 0) {
            uint256 lpSlice = (uint256(c.lpBps) * PROTOCOL_FLOOR + 99) / 100;
            uint256 lpNetPips = uint256(c.lpBps) * 100 - lpSlice;
            uint256 burnSlice = (uint256(c.burnBps) * PROTOCOL_FLOOR + 99) / 100;
            uint256 protocolTake = lpSlice + burnSlice;
            uint256 royaltyRoom = (uint256(caps.maxQuoteTakePips) - protocolTake) * 10_000 / lpNetPips;
            c.royaltyBps = uint16(bound(royaltyBps, 0, royaltyRoom < 1000 ? royaltyRoom : 1000));
            if (c.royaltyBps != 0) c.royaltyTo = royalty;
        }
        assertLe(_quoteTakeBound(c, 3000, bound_), caps.maxQuoteTakePips, "built inside the caps");
        (, PoolKey memory key,) = this.launchExternal(address(r), _nativeMember(address(rr), c, id));
        assertEq(IHookrRecaptureRules(address(rr)).minimumFee(key.toId()), bound_, "the pool froze the minimum");
        uint128 amount = uint128(bound(raw, 1e12, 1e20));
        HookrTypes.ExecutionReceipt memory q = quoter.quote(_swapParams(key, true, true, amount), trader);
        assertLe(q.lpFeePips, caps.maxLpFeePips);
        assertLe(q.quoteFee * 1e6, uint256(caps.maxQuoteTakePips) * q.inputAmount + 1e6);
        assertLe(q.subjectBurn * 1e4, uint256(caps.maxSubjectTakeBps) * (q.outputAmount + q.subjectBurn) + 1e4);
        uint256 before = rr.claimable(ETH, address(hookrTreasury));
        (, uint256 out) = _trade(key, true, true, amount);
        assertEq(out, q.outputAmount);
        assertGe(
            rr.claimable(ETH, address(hookrTreasury)) - before, q.inputAmount * bound_ / 1e6, "the minimum is paid"
        );
        assertTrue(rr.accountingInvariant(ETH));
    }

    /// @dev A public profile on the shared root at `caps` and a public owned root derived from it for the trader.
    function _rootWithCaps(HookrTypes.Caps memory caps, bytes32 salt)
        internal
        returns (HookrRoot r, HookrRules rr, bytes32 id)
    {
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.caps = caps;
        vm.prank(brand);
        id = book.writeProfile(salt, p);
        (r, rr) = _deployOwned(_selFor(id, trader, F.ALL_FEATURES, true));
    }
}
