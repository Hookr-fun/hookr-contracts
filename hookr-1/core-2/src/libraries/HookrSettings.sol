// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title HookrSettings
/// @notice Revision-3 canonical v1 carrier. Grid values are exact; bind-context checks belong to HookrRulesChecks.
library HookrSettings {
    error InvalidSettings();

    struct Settings {
        uint8 cutBuy;
        uint8 cutSell;
        uint8 cutTo;
        bool sandwichGuard;
        bool walletCap;
        bool exitClock;
        bool holderPot;
        bool storm;
        bool windows;
        uint8 cutSellTo;
        uint16 wcMantissa;
        uint8 wcExponent;
        uint8 exitTop;
        uint8 exitFloor;
        uint8 exitHorizon;
        uint8 exitUnit;
        uint8 exitCurve;
        uint8 exitTo;
        uint8 hpEpoch;
        uint8 hpAgeCap;
        uint8 hpBoost;
        uint8 hpSellRule;
        uint8 hpBounty;
        uint8 stormCeiling;
        uint8 stormFloor;
        uint8 stormTempo;
        uint8 stormTo;
        uint16 buyPause;
        uint8 sellLock;
        uint32 prizeCap;
        uint8 sgWindow;
        uint8 sgMax;
        uint8 sgTo;
    }

    function encode(Settings memory s) internal pure returns (uint32 hot, uint128 cold) {
        _validate(s);
        if (!_enabled(s)) return (0, 0);
        uint256 h = uint256(1) << 30;
        uint256 c;
        h |= uint256(s.cutBuy) << 0;
        h |= uint256(s.cutSell) << 7;
        h |= uint256(s.cutTo) << 14;
        h |= uint256(s.sandwichGuard ? 1 : 0) << 17;
        h |= uint256(s.walletCap ? 1 : 0) << 19;
        h |= uint256(s.exitClock ? 1 : 0) << 20;
        h |= uint256(s.holderPot ? 1 : 0) << 21;
        h |= uint256(s.storm ? 1 : 0) << 22;
        h |= uint256(s.windows ? 1 : 0) << 23;
        h |= uint256(s.cutSellTo) << 24;
        c |= uint256(s.wcMantissa) << 0;
        c |= uint256(s.wcExponent) << 14;
        c |= uint256(s.exitTop) << 19;
        c |= uint256(s.exitFloor) << 26;
        c |= uint256(s.exitHorizon) << 33;
        c |= uint256(s.exitUnit) << 39;
        c |= uint256(s.exitCurve) << 40;
        c |= uint256(s.exitTo) << 42;
        c |= uint256(s.hpEpoch) << 45;
        c |= uint256(s.hpAgeCap) << 46;
        c |= uint256(s.hpBoost) << 52;
        c |= uint256(s.hpSellRule) << 57;
        c |= uint256(s.hpBounty) << 58;
        c |= uint256(s.stormCeiling) << 63;
        c |= uint256(s.stormFloor) << 71;
        c |= uint256(s.stormTempo) << 79;
        c |= uint256(s.stormTo) << 82;
        c |= uint256(s.buyPause) << 85;
        c |= uint256(s.sellLock) << 94;
        c |= uint256(s.prizeCap) << 97;
        c |= uint256(s.sgWindow) << 114;
        c |= uint256(s.sgMax) << 116;
        c |= uint256(s.sgTo) << 120;
        return (uint32(h), uint128(c));
    }

    function decode(uint32 hot, uint128 cold) internal pure returns (Settings memory s) {
        if (hot == 0 && cold == 0) return s;
        if (hot >> 30 != 1 || hot & ((uint32(1) << 18) | (uint32(7) << 27)) != 0 || cold >> 123 != 0) {
            revert InvalidSettings();
        }
        s.cutBuy = uint8((hot >> 0) & 127);
        s.cutSell = uint8((hot >> 7) & 127);
        s.cutTo = uint8((hot >> 14) & 7);
        s.sandwichGuard = (hot >> 17) & 1 != 0;
        s.walletCap = (hot >> 19) & 1 != 0;
        s.exitClock = (hot >> 20) & 1 != 0;
        s.holderPot = (hot >> 21) & 1 != 0;
        s.storm = (hot >> 22) & 1 != 0;
        s.windows = (hot >> 23) & 1 != 0;
        s.cutSellTo = uint8((hot >> 24) & 7);
        s.wcMantissa = uint16((cold >> 0) & 16383);
        s.wcExponent = uint8((cold >> 14) & 31);
        s.exitTop = uint8((cold >> 19) & 127);
        s.exitFloor = uint8((cold >> 26) & 127);
        s.exitHorizon = uint8((cold >> 33) & 63);
        s.exitUnit = uint8((cold >> 39) & 1);
        s.exitCurve = uint8((cold >> 40) & 3);
        s.exitTo = uint8((cold >> 42) & 7);
        s.hpEpoch = uint8((cold >> 45) & 1);
        s.hpAgeCap = uint8((cold >> 46) & 63);
        s.hpBoost = uint8((cold >> 52) & 31);
        s.hpSellRule = uint8((cold >> 57) & 1);
        s.hpBounty = uint8((cold >> 58) & 31);
        s.stormCeiling = uint8((cold >> 63) & 255);
        s.stormFloor = uint8((cold >> 71) & 255);
        s.stormTempo = uint8((cold >> 79) & 7);
        s.stormTo = uint8((cold >> 82) & 7);
        s.buyPause = uint16((cold >> 85) & 511);
        s.sellLock = uint8((cold >> 94) & 7);
        s.prizeCap = uint32((cold >> 97) & 131071);
        s.sgWindow = uint8((cold >> 114) & 3);
        s.sgMax = uint8((cold >> 116) & 15);
        s.sgTo = uint8((cold >> 120) & 7);
        _validate(s);
        if (!_enabled(s)) revert InvalidSettings();
    }

    function validate(uint32 hot, uint128 cold) internal pure {
        decode(hot, cold);
    }

    /// @notice Exact smallest-exponent decimal. Zero and caps that cannot fit exactly are refused.
    function walletCap(uint256 cap) internal pure returns (uint16 mantissa, uint8 exponent) {
        if (cap == 0) revert InvalidSettings();
        uint256 divisor = 1;
        for (uint8 e; e <= 31; ++e) {
            if (cap % divisor == 0 && cap / divisor < 16_384) return (uint16(cap / divisor), e);
            divisor *= 10;
        }
        revert InvalidSettings();
    }

    function _enabled(Settings memory s) private pure returns (bool) {
        return s.cutBuy != 0 || s.cutSell != 0 || s.sandwichGuard || s.walletCap || s.exitClock || s.holderPot
            || s.storm || s.windows || s.prizeCap != 0;
    }

    function _inactive(bool on, uint256 fields) private pure {
        if (!on && fields != 0) revert InvalidSettings();
    }

    function _validate(Settings memory s) private pure {
        if (s.cutBuy > 100 || s.cutSell > 100) revert InvalidSettings();
        bool cut = s.cutBuy != 0 || s.cutSell != 0;
        if (cut ? s.cutTo < 1 || s.cutTo > 4 : s.cutTo != 0) revert InvalidSettings();
        if (s.cutSellTo != 0 && (s.cutBuy == 0 || s.cutSell == 0 || s.cutSellTo > 4 || s.cutSellTo == s.cutTo)) {
            revert InvalidSettings();
        }
        _inactive(s.walletCap, uint256(s.wcMantissa) | s.wcExponent);
        if (
            s.walletCap
                && (s.wcMantissa == 0
                    || s.wcMantissa > 16_383
                    || s.wcExponent > 31
                    || (s.wcExponent != 0 && uint256(s.wcMantissa) * 10 < 16_384))
        ) revert InvalidSettings();
        _inactive(s.exitClock, uint256(s.exitTop) | s.exitFloor | s.exitHorizon | s.exitUnit | s.exitCurve | s.exitTo);
        if (
            s.exitClock
                && (s.exitTop < 1
                    || s.exitTop > 100
                    || s.exitFloor >= s.exitTop
                    || s.exitUnit > 1
                    || (s.exitUnit == 0
                            ? s.exitHorizon < 1 || s.exitHorizon > 63
                            : s.exitHorizon < 3 || s.exitHorizon > 30)
                    || s.exitCurve > 2
                    || s.exitTo > 4)
        ) revert InvalidSettings();
        _inactive(s.holderPot, uint256(s.hpEpoch) | s.hpAgeCap | s.hpBoost | s.hpSellRule | s.hpBounty);
        if (
            s.holderPot
                && (s.hpEpoch > 1
                    || s.hpAgeCap < 1
                    || s.hpAgeCap > 56
                    || s.hpBoost > 20
                    || s.hpSellRule > 1
                    || s.hpBounty < 1
                    || s.hpBounty > 20)
        ) revert InvalidSettings();
        _inactive(s.storm, uint256(s.stormCeiling) | s.stormFloor | s.stormTempo | s.stormTo);
        if (
            s.storm
                && (s.stormCeiling < 1
                    || s.stormCeiling > 200
                    || s.stormFloor > s.stormCeiling
                    || s.stormTempo > 3
                    || s.stormTo > 4)
        ) revert InvalidSettings();
        _inactive(s.windows, uint256(s.buyPause) | s.sellLock);
        if (s.windows && (s.buyPause > 300 || s.sellLock > 5 || (s.buyPause == 0 && s.sellLock == 0))) {
            revert InvalidSettings();
        }
        _inactive(s.sandwichGuard, uint256(s.sgWindow) | s.sgMax | s.sgTo);
        if (s.sandwichGuard && (s.sgWindow > 3 || s.sgMax < 5 || s.sgMax > 15 || s.sgTo < 2 || s.sgTo > 4)) {
            revert InvalidSettings();
        }
        if (s.prizeCap > 100_000) revert InvalidSettings();
    }
}
