// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {AppPoolCapsFixture} from "./HookrRules.appPoolCaps.t.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// I-12 (app side), from the app-lane review: with the app's tight per-pool caps (the exact
/// HookrRules._validate maxima), no swap of any size or direction may revert with a cap error.
/// The root checks the caps on every swap, so if a later Rules change charges one pip above
/// _validate, pools launched by the app would revert. Re-run this after any Rules change and
/// keep the app's poolCaps() and _validate in lockstep.
contract AppPoolCapsFuzzTest is AppPoolCapsFixture {
    bytes4 internal constant AGGREGATE_CAP = IHookrRootState.AggregateCapExceeded.selector;
    bytes4 internal constant MODULE_RESULT = IHookrRootEvents.InvalidModuleResult.selector;

    function _has(bytes memory r, bytes4 sel) internal pure returns (bool) {
        if (r.length < 4) return false;
        for (uint256 i; i + 4 <= r.length; ++i) {
            if (r[i] == sel[0] && r[i + 1] == sel[1] && r[i + 2] == sel[2] && r[i + 3] == sel[3]) return true;
        }
        return false;
    }

    function _noCapError(bool ok, bytes memory reason) internal pure {
        if (ok) return;
        require(!_has(reason, AGGREGATE_CAP), "AggregateCapExceeded under the app's caps");
        require(!_has(reason, MODULE_RESULT), "InvalidModuleResult under the app's caps");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_appCapsNeverRevertSwaps(uint256 which, uint256 a, uint256 b, uint256 c, uint256 d) public {
        which = bound(which, 1, 3);
        (IHookrLauncher.Member memory m, HookrTypes.Caps memory caps) = _config(which);
        m.config.caps = caps;
        bytes32 family = _launchWith(m, which * 4);
        PoolKey memory key = launcher.position(family, 0).key;
        vm.startPrank(trader);
        bool ok;
        bytes memory reason;
        uint128 buyIn = uint128(bound(a, 1e9, 3e23));
        try router.swap{value: buyIn}(_swap(key, true, true, buyIn), address(0), new uint256[](0)) {
            ok = true;
        } catch (bytes memory r) {
            (ok, reason) = (false, r);
        }
        _noCapError(ok, reason);
        uint128 sellIn = uint128(bound(b, 1e9, 1e23));
        try router.swap(_swap(key, false, true, sellIn), address(0), new uint256[](0)) {
            ok = true;
        } catch (bytes memory r) {
            (ok, reason) = (false, r);
        }
        _noCapError(ok, reason);
        uint128 buyOut = uint128(bound(c, 1e9, 1e22));
        try router.swap{value: 1e25}(_swap(key, true, false, buyOut), address(0), new uint256[](0)) {
            ok = true;
        } catch (bytes memory r) {
            (ok, reason) = (false, r);
        }
        _noCapError(ok, reason);
        uint128 sellOut = uint128(bound(d, 1e9, 1e22));
        try router.swap(_swap(key, false, false, sellOut), address(0), new uint256[](0)) {
            ok = true;
        } catch (bytes memory r) {
            (ok, reason) = (false, r);
        }
        _noCapError(ok, reason);
        vm.stopPrank();
    }
}
