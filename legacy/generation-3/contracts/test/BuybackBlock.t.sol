// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrHookLens} from "../src/HookrHookLens.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Arb-buyback block: launch-side validation and the hook's gating rules that are
///         observable without a live pool. The anchor ratchet, the in-unlock execution and
///         the burn accounting need real swaps; they belong to the fork suite.
contract BuybackBlockTest is Test {
    HookrLaunchpad pad;
    HookrHook hook;

    address creator = address(0xC0FFEE);

    uint96 constant TARGET = 1 ether;

    function setUp() public {
        pad = new HookrLaunchpad(IPoolManager(address(0xDEAD001)), new HookrBlueprints(address(this)));
        HookrBlueprints bpReg = pad.blueprints();
        vm.deal(address(this), 1000 ether);
        vm.deal(creator, 100 ether);

        // Real HookrHook bytecode at a mined address; configurePool/preview paths run for real.
        HookrHook impl = new HookrHook(IPoolManager(address(0xDEAD001)), address(pad));
        uint160 flags = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
        address target;
        for (uint256 i = 1; i < 500_000; i++) {
            target = address(uint160(uint256(keccak256(abi.encode(i)))));
            if (uint160(target) & 0x3FFF == flags && target.code.length == 0) break;
        }
        vm.etch(target, address(impl).code);
        hook = HookrHook(payable(target));
        pad.setHook(hook);
        vm.deal(target, 1 ether);
    }

    receive() external payable {}

    function _params(uint16 buybackBps) internal pure returns (HookrLaunchpadLib.HookParams memory p) {
        p.guardBlocks = 0;
        p.maxBuyBps = 0;
        p.snipeTaxPips = 0;
        p.baseFeePips = 3000;
        p.maxFeePips = 3000;
        p.surgeSens = 0;
        p.burnBps = 0;
        p.burnTriggerWei = 0;
        p.lpBps = 25;
        p.potBps = 0;
        p.potEveryNBuys = 0;
        p.potMinBuyWei = 0.001 ether;
        p.buybackBps = buybackBps;
        p.buybackDrawdownBps = 1000; // -10%
        p.buybackCooldownBlocks = 30;
        p.buybackMinSpendWei = 0.01 ether;
        p.buybackMaxSpendWei = 0.5 ether;
    }

    function test_disabledBlock_rejectsAnyLiveParameter() public {
        HookrLaunchpadLib.HookParams memory p = _params(0);
        p.buybackMinSpendWei = 0.01 ether; // live param with bps == 0 must be refused
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(p);
    }

    function test_minSpendBelowProtocolFloor_rejected() public {
        HookrLaunchpadLib.HookParams memory p = _params(50);
        p.buybackMinSpendWei = 0.0009 ether;
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(p);
    }

    function test_maxSpendBelowMinSpend_rejected() public {
        HookrLaunchpadLib.HookParams memory p = _params(50);
        p.buybackMaxSpendWei = p.buybackMinSpendWei - 1;
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(p);
    }

    function test_drawdownBounds_enforced() public {
        HookrLaunchpadLib.HookParams memory p = _params(50);
        p.buybackDrawdownBps = 5; // below the 10 floor
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(p);

        HookrLaunchpadLib.HookParams memory q = _params(50);
        q.buybackDrawdownBps = 9901; // above the 9900 ceiling
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(q);
    }

    function test_cooldownBounds_enforced() public {
        HookrLaunchpadLib.HookParams memory p = _params(50);
        p.buybackCooldownBlocks = 0;
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(p);

        HookrLaunchpadLib.HookParams memory q = _params(50);
        q.buybackCooldownBlocks = 100_001;
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(q);
    }

    function test_cutCeiling_includesBuybackShare() public {
        // lp 25 + pot 900 + buyback 76 = 1001 > 1000 -> rejected
        HookrLaunchpadLib.HookParams memory p = _params(76);
        p.potBps = 900;
        p.potEveryNBuys = 500;
        vm.expectRevert(HookrLaunchpad.BadHookParams.selector);
        HookrLaunchpadLib.validateHookParams(p);

        // exactly 1000 passes and maps through to the hook config
        HookrLaunchpadLib.HookParams memory okp = _params(76);
        okp.potBps = 899;
        HookrHook.PoolConfig memory cfg = HookrLaunchpadLib.previewPoolConfig(okp, 1e18, pad.SUPPLY());
        assertEq(cfg.buybackBps, 76);
        assertEq(cfg.buybackDrawdownBps, 1000);
        assertEq(cfg.buybackCooldownBlocks, 30);
        assertEq(cfg.buybackMinSpendWei, 0.01 ether);
        assertEq(cfg.buybackMaxSpendWei, 0.5 ether);
    }

    function test_lens_reportsUnconfiguredPoolAsDisabled() public {
        HookrHookLens lens = new HookrHookLens(hook);
        HookrHookLens.BuybackStatus memory v = lens.buybackStatus(PoolId.wrap(bytes32(uint256(1))));
        assertFalse(v.ready);
        assertFalse(v.configured);
    }

    }
