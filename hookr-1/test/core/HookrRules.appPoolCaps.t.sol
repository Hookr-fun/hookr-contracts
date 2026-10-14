// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";

/// I-12 (app side): the periphery, the member configurations and the caps the Rules accept, shared by
/// AppPoolCapsTest and AppPoolCapsFuzzTest.
abstract contract AppPoolCapsFixture is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function _config(uint256 which)
        internal
        view
        returns (IHookrLauncher.Member memory m, HookrTypes.Caps memory caps)
    {
        m = _member(Currency.wrap(address(0)));
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.potBps = 0;
        m.rules.potEveryNBuys = 0;
        m.rules.potMinBuyQuote = 0;
        m.rules.protocolShareBps = 0;
        if (which == 0) {
            // App default launch: 0.3% base, nothing else.
            caps = HookrTypes.Caps(3000, 0, 0);
        } else if (which == 1) {
            // Test case a: base 0.3%, dynamic fee max 10% sens 5, protocol 25%, LP 2%, burn 1%.
            m.rules.maxFeePips = 100_000;
            m.rules.dynamicFeeSens = 5;
            m.rules.protocolShareBps = 2500;
            m.rules.lpBps = 200;
            m.rules.burnBps = 100;
            caps = HookrTypes.Caps(100_000, 31_750, 75);
        } else if (which == 2) {
            // Clipped dynamic fee + anti-snipe: base 0.3%, dynamic fee 7.5% sens 10 (the widest span the reach bound
            // admits there), snipe 55%, protocol 30%.
            m.rules.maxFeePips = 75_000;
            m.rules.dynamicFeeSens = 10;
            m.rules.snipeTaxPips = 550_000;
            m.rules.guardEndBlock = uint40(block.number + 10);
            m.rules.protocolShareBps = 3000;
            caps = HookrTypes.Caps(420_901, 179_100, 0);
        } else {
            // Test case c: base 1%, snipe 5%, protocol 20%. The pot (3% every 10) is refused since OD-1.
            m.config.baseLpFeePips = 10_000;
            m.rules.maxFeePips = 10_000;
            m.rules.snipeTaxPips = 50_000;
            m.rules.guardEndBlock = uint40(block.number + 10);
            m.rules.protocolShareBps = 2000;
            caps = HookrTypes.Caps(50_000, 10_000, 0);
        }
        // The pinned numbers above are what the app's poolCaps() must produce; they must equal the mirror.
        HookrTypes.Caps memory mirror = _rulesCaps(m.rules, m.config.baseLpFeePips);
        require(
            mirror.maxLpFeePips == caps.maxLpFeePips && mirror.maxQuoteTakePips == caps.maxQuoteTakePips
                && mirror.maxSubjectTakeBps == caps.maxSubjectTakeBps,
            "pinned caps differ from the HookrRules._validate mirror"
        );
    }

    /// @dev Exact mirror of HookrRules._validate / _buyParts after the economics fix (I-04, OD-1, OD-2): the
    ///      tightest pool caps Rules accepts. LP cap bounds the whole native LP fee (base + LP Rewards + dynamic fee +
    ///      Snipe LP share); the quote cap is the larger of the buy take (protocol LP-Reward slice, royalty, burn
    ///      slice, dynamic fee/Snipe protocol slice) and the exact-input sell dynamic fee slice; the subject cap is the net burn.
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

    // Tick spacings that divide the fixture's +/-60,000 range, one per launch.
    int24[16] internal spacings = [int24(60), 50, 40, 30, 48, 75, 80, 100, 20, 24, 25, 120, 125, 150, 200, 240];

    function _launchWith(IHookrLauncher.Member memory m, uint256 salt) internal returns (bytes32 family) {
        m.tickSpacing = spacings[salt];
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// True when the launch succeeds; fails the test unless a refusal comes from Rules.bind.
    function _tryLaunch(IHookrLauncher.Member memory m, uint256 salt) internal returns (bool ok) {
        m.tickSpacing = spacings[salt];
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        try launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        ) returns (
            bytes32, address
        ) {
            ok = true;
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSignature(
                    "ModuleCallReverted(address,bytes4,bytes)",
                    address(rules),
                    bytes4(0x7733c476),
                    abi.encodeWithSignature("InvalidConfig()")
                ),
                "refusal must come from Rules.bind (InvalidConfig in _validate)"
            );
        }
    }
}

/// I-12 (app side): the caps the app's poolCaps() computes for a member (the numbers pinned in
/// the app's I-12 test) are accepted by the real
/// HookrRules._validate, one pip or bps less on any nonzero cap is refused, and swaps at the
/// fee extremes still settle under them. The pinned numbers changed with the economics fix (I-04, OD-1, OD-2):
/// the app test's pins and the app's poolCaps() must be updated to AppPoolCapsFixture._rulesCaps.
contract AppPoolCapsTest is AppPoolCapsFixture {
    function testAppCapsAreExactlyTheTightestAccepted() public {
        for (uint256 i; i < 4; ++i) {
            (IHookrLauncher.Member memory m, HookrTypes.Caps memory caps) = _config(i);
            uint256 salt = i * 4;
            if (caps.maxLpFeePips > m.config.baseLpFeePips) {
                m.config.caps = HookrTypes.Caps(caps.maxLpFeePips - 1, caps.maxQuoteTakePips, caps.maxSubjectTakeBps);
                assertFalse(_tryLaunch(m, salt + 1), "LP cap one pip lower must be refused");
            }
            if (caps.maxQuoteTakePips > 0) {
                m.config.caps = HookrTypes.Caps(caps.maxLpFeePips, caps.maxQuoteTakePips - 1, caps.maxSubjectTakeBps);
                assertFalse(_tryLaunch(m, salt + 2), "quote cap one pip lower must be refused");
            }
            if (caps.maxSubjectTakeBps > 0) {
                m.config.caps = HookrTypes.Caps(caps.maxLpFeePips, caps.maxQuoteTakePips, caps.maxSubjectTakeBps - 1);
                assertFalse(_tryLaunch(m, salt + 3), "subject cap one bps lower must be refused");
            }
            m.config.caps = caps;
            bytes32 family = _launchWith(m, salt);
            PoolKey memory key = launcher.position(family, 0).key;
            // Largest fees: a big exact-input buy (dynamic fee to its maximum, anti-snipe active in 2 and 3)
            // and an exact-input sell; both must settle under the tight caps.
            vm.startPrank(trader);
            router.swap{value: 2e23}(_swap(key, true, true, 2e23), address(0), new uint256[](0));
            router.swap(_swap(key, false, true, 1e21), address(0), new uint256[](0));
            if (i < 2) router.swap{value: 1e25}(_swap(key, true, false, 1e20), address(0), new uint256[](0));
            vm.stopPrank();
        }
    }

    /// The royalty branch of the mirror, on the fixture default (LP 2%, royalty 5%, burn 1%, protocol 25%).
    function testMirrorIsTightestWithRoyalty() public {
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        HookrTypes.Caps memory caps = _rulesCaps(m.rules, m.config.baseLpFeePips);
        assertEq(caps.maxLpFeePips, 17_250);
        assertEq(caps.maxQuoteTakePips, 8_250);
        assertEq(caps.maxSubjectTakeBps, 75);
        m.config.caps = HookrTypes.Caps(caps.maxLpFeePips - 1, caps.maxQuoteTakePips, caps.maxSubjectTakeBps);
        assertFalse(_tryLaunch(m, 1), "LP cap one pip lower must be refused");
        m.config.caps = HookrTypes.Caps(caps.maxLpFeePips, caps.maxQuoteTakePips - 1, caps.maxSubjectTakeBps);
        assertFalse(_tryLaunch(m, 2), "quote cap one pip lower must be refused");
        m.config.caps = HookrTypes.Caps(caps.maxLpFeePips, caps.maxQuoteTakePips, caps.maxSubjectTakeBps - 1);
        assertFalse(_tryLaunch(m, 3), "subject cap one bps lower must be refused");
        m.config.caps = caps;
        assertTrue(_tryLaunch(m, 0), "mirror caps accepted");
    }
}
