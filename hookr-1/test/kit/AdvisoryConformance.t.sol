// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {AdvisoryConformance} from "./AdvisoryConformance.sol";
import {TemplateAdvisory} from "./TemplateAdvisory.sol";

/// @notice The kit against TemplateAdvisory, at its own gas floors.
contract TemplateAdvisoryConformanceTest is AdvisoryConformance {
    function _kitDeploy() internal override returns (address) {
        return address(new TemplateAdvisory());
    }

    function _kitRootData() internal pure override returns (bytes memory) {
        return abi.encode(uint256(1_000));
    }

    function _kitPairData(uint24 capPips) internal pure override returns (bytes memory) {
        return abi.encode(uint256(capPips));
    }

    function _kitArtifact() internal pure override returns (string memory) {
        return "out/TemplateAdvisory.sol/TemplateAdvisory.json";
    }

    function _kitOwnBuild() internal pure override returns (bool) {
        return true;
    }

    function _kitRootGasLimit() internal view override returns (uint32) {
        return TemplateAdvisory(kitAdvisory).MIN_ADVISORY_GAS();
    }

    function _kitPairGasLimit() internal view override returns (uint32) {
        return TemplateAdvisory(kitAdvisory).MIN_PAIR_GAS();
    }
}

/// @notice The kit against HookrFeeAdvisory deployed as the release deploys it, reading HookrSessionAdvisory's
///         calendar, with pools that bind no session tiers. The keeper target at the cap is the worst case. On the
///         pair root it runs at MIN_PAIR_GAS. On HookrRoot it runs at FEE_ROOT_GAS: MIN_ADVISORY_GAS (30,000) covers
///         the swap-path call but not `bind`, which the root runs with the same limit.
contract HookrFeeAdvisoryConformanceTest is AdvisoryConformance {
    uint32 internal constant FEE_ROOT_GAS = 200_000;
    address internal keeper = address(0xBEEF);
    /// @notice The shared market calendar the fee advisory reads for tiered pools.
    HookrSessionAdvisory internal calendar;

    function _kitDeploy() internal virtual override returns (address) {
        calendar = new HookrSessionAdvisory(address(this), 1 days);
        HookrFeeAdvisory fee =
            new HookrFeeAdvisory(address(this), 1 days, IHookrRegistry(address(registry)), address(calendar));
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        fee.addKeeper(keeper);
        return address(fee);
    }

    function _config(uint24 cap, uint24 surcharge) internal pure returns (bytes memory) {
        return abi.encode(
            IHookrFeeAdvisory.Config({
                cap: cap,
                surcharge: surcharge,
                premium0: surcharge / 2,
                premium1: 0,
                maxStep: cap,
                minInterval: 60,
                maxTtl: 1 hours
            })
        );
    }

    function _kitRootData() internal view virtual override returns (bytes memory) {
        return _config(_kitRootCapPips(), 1_000);
    }

    function _kitPairData(uint24 capPips) internal view virtual override returns (bytes memory) {
        return _config(capPips, 250);
    }

    function _kitArtifact() internal pure override returns (string memory) {
        return "out/HookrFeeAdvisory.sol/HookrFeeAdvisory.json";
    }

    function _kitOwnBuild() internal pure override returns (bool) {
        return true;
    }

    function _kitRootGasLimit() internal pure override returns (uint32) {
        return FEE_ROOT_GAS;
    }

    function _kitPairGasLimit() internal view virtual override returns (uint32) {
        return HookrFeeAdvisory(kitAdvisory).MIN_PAIR_GAS();
    }

    /// @dev A live keeper target at the pool's cap in both directions.
    function _kitWorstCase(address, PoolId id) internal virtual override {
        HookrFeeAdvisory fee = HookrFeeAdvisory(kitAdvisory);
        uint24 cap = fee.poolBounds(id).cap;
        vm.prank(keeper);
        fee.reprice(id, cap, 0, 0, 1 hours);
    }

    /// @dev Advances the clock, then sets a keeper target anywhere in the cap for a seed-picked lifetime.
    function _kitStress(address, PoolId id, uint256 seed) internal virtual override {
        vm.warp(vm.getBlockTimestamp() + seed % 2 days);
        HookrFeeAdvisory fee = HookrFeeAdvisory(kitAdvisory);
        IHookrFeeAdvisory.Bounds memory b = fee.poolBounds(id);
        uint24 target = uint24((seed >> 64) % (uint256(b.cap) + 1));
        uint24 premium = uint24((seed >> 128) % (uint256(b.cap - target) + 1));
        vm.prank(keeper);
        fee.reprice(id, target, premium, 0, uint32(1 + (seed >> 192) % b.maxTtl));
        vm.warp(vm.getBlockTimestamp() + (seed >> 224) % 2 hours);
    }
}

/// @notice The kit against HookrFeeAdvisory with pools that bind session tiers next to the keeper surcharge, on the
///         2026 NYSE calendar. It runs at MIN_TIERED_GAS on the pair root and FEE_ROOT_GAS on HookrRoot. The worst
///         case is a keeper target at the cap on the evening before Thanksgiving, the closed tier reached through
///         the calendar's closure lookup, with the calendar's account cold as well.
contract HookrFeeAdvisoryTieredConformanceTest is HookrFeeAdvisoryConformanceTest {
    function _kitDeploy() internal override returns (address) {
        vm.warp(_ny(2026, 9, 29, 11, 0, 0, true));
        return super._kitDeploy();
    }

    function _tiered(uint24 cap, uint24 surcharge) internal pure returns (bytes memory) {
        return abi.encode(
            IHookrFeeAdvisory.Config({
                cap: cap,
                surcharge: surcharge,
                premium0: surcharge / 2,
                premium1: 0,
                maxStep: cap,
                minInterval: 60,
                maxTtl: 1 hours
            }),
            HookrSessionTiers.Tiers(cap / 25, cap / 6, cap / 4, cap / 2, cap, 1_800, 1_800, 1)
        );
    }

    function _kitRootData() internal view override returns (bytes memory) {
        return _tiered(_kitRootCapPips(), 1_000);
    }

    function _kitPairData(uint24 capPips) internal pure override returns (bytes memory) {
        return _tiered(capPips, 250);
    }

    function _kitPairGasLimit() internal view override returns (uint32) {
        return HookrFeeAdvisory(kitAdvisory).MIN_TIERED_GAS();
    }

    function _kitCold() internal override {
        vm.cool(kitAdvisory);
        vm.cool(address(calendar));
    }

    /// @dev The evening before Thanksgiving, then the keeper target at the cap within its lifetime.
    function _kitWorstCase(address binder, PoolId id) internal override {
        vm.warp(_ny(2026, 11, 25, 20, 30, 0, false));
        super._kitWorstCase(binder, id);
    }

    /// @dev The keeper stress, then any second of the following five years, covered by the calendar or not.
    function _kitStress(address binder, PoolId id, uint256 seed) internal override {
        super._kitStress(binder, id, seed);
        vm.warp(vm.getBlockTimestamp() + uint256(keccak256(abi.encode(seed))) % (5 * 365 days));
    }

    function _ny(uint256 y, uint256 m, uint256 d, uint256 h, uint256 mi, uint256 sec, bool dst)
        internal
        pure
        returns (uint256)
    {
        return
            HookrMarketCalendar.dayOf(y, m, d) * 1 days + h * 1 hours + mi * 1 minutes + sec + (dst ? 4 : 5) * 1 hours;
    }
}

/// @notice The kit against HookrSessionAdvisory at its gas floors, with ramps and the uncovered-as-closed flag, on
///         the 2026 NYSE calendar.
contract HookrSessionAdvisoryConformanceTest is AdvisoryConformance {
    function _kitDeploy() internal override returns (address) {
        vm.warp(_ny(2026, 9, 29, 11, 0, 0, true));
        return address(new HookrSessionAdvisory(address(this), 1 days));
    }

    function _schedule(uint24 cap) internal pure returns (bytes memory) {
        return abi.encode(IHookrSessionAdvisory.Schedule(cap / 25, cap / 6, cap / 4, cap / 2, cap, 1_800, 1_800, 1));
    }

    function _kitRootData() internal view override returns (bytes memory) {
        return _schedule(_kitRootCapPips());
    }

    function _kitPairData(uint24 capPips) internal pure override returns (bytes memory) {
        return _schedule(capPips);
    }

    function _kitArtifact() internal pure override returns (string memory) {
        return "out/HookrSessionAdvisory.sol/HookrSessionAdvisory.json";
    }

    function _kitOwnBuild() internal pure override returns (bool) {
        return true;
    }

    function _kitRootGasLimit() internal view override returns (uint32) {
        return HookrSessionAdvisory(kitAdvisory).MIN_ADVISORY_GAS();
    }

    function _kitPairGasLimit() internal view override returns (uint32) {
        return HookrSessionAdvisory(kitAdvisory).MIN_PAIR_GAS();
    }

    /// @dev The evening before Thanksgiving: the closed tier, reached through the closure lookup.
    function _kitWorstCase(address, PoolId) internal override {
        vm.warp(_ny(2026, 11, 25, 21, 0, 0, false));
    }

    /// @dev Any second of the following five years, covered or not.
    function _kitStress(address, PoolId, uint256 seed) internal override {
        vm.warp(vm.getBlockTimestamp() + seed % (5 * 365 days));
    }

    function _ny(uint256 y, uint256 m, uint256 d, uint256 h, uint256 mi, uint256 sec, bool dst)
        internal
        pure
        returns (uint256)
    {
        return
            HookrMarketCalendar.dayOf(y, m, d) * 1 days + h * 1 hours + mi * 1 minutes + sec + (dst ? 4 : 5) * 1 hours;
    }
}
