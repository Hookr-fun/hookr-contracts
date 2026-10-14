// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLaneRules} from "../../src/interfaces/IHookrLaneRules.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrAdvisoryFeeCounter} from "../../src/interfaces/IHookrAdvisoryFeeCounter.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";

/// @notice HookrRoot does not inherit IHookrLaneRoot, and HookrRules inherits none of IHookrLaneRules,
///         IHookrRecaptureRules and IHookrAdvisoryFeeCounter: both serve those surfaces from their fallbacks, which
///         keeps the selectors out of the dispatchers, so no compiler check ties an interface function to the code
///         that answers it. The root's fallback answers `laneModule()` from its own code and forwards every other
///         selector to HookrLane; the Rules' fallback answers `recaptureModule()` and `carryLeg` from their own code
///         and forwards every other selector to HookrRecapture.
/// @dev A call cannot show a missing root selector: HookrLane's fallback reverts `Unauthorized()` for a selector it
///      does not know, never with empty data. So each surface is checked against the build artifacts: every
///      interface selector must be a function of the contract or its module, or one its fallback answers itself.
///      The Rules are also called once per interface function with real arguments: a selector HookrRecapture lacks
///      reverts with empty data there, since HookrRecapture has no fallback.
contract ModuleSurfaceTest is PeripheryFixture {
    /// @dev HookrRules' RECAPTURE_MODULE_SELECTOR and CARRY_LEG_SELECTOR, the selectors its fallback answers itself.
    bytes4 internal constant RULES_RECAPTURE_MODULE = 0x720e68f5;
    bytes4 internal constant RULES_CARRY_LEG = 0xff341722;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev The function signatures of an artifact under out/. External, and called through `this`, so the artifact's
    ///      text (megabytes for the Rules, the root and their modules) lives only in that call's memory.
    function signaturesOf(string calldata artifact) external view returns (string[] memory) {
        return vm.parseJsonKeys(vm.readFile(string.concat("out/", artifact)), ".methodIdentifiers");
    }

    function _signatures(string memory artifact) internal view returns (string[] memory) {
        return this.signaturesOf(artifact);
    }

    function _has(string[] memory signatures, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == selector) return true;
        }
        return false;
    }

    function _has(bytes4[] memory selectors, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == selector) return true;
        }
        return false;
    }

    /// @dev Requires every function of `surface` to be a function of `host` or `module`, or one of `own`.
    function _assertServed(string memory surface, string memory host, string memory module, bytes4[] memory own)
        internal
        view
    {
        string[] memory wanted = _signatures(surface);
        string[] memory hostSignatures = _signatures(host);
        string[] memory moduleSignatures = _signatures(module);
        assertGt(wanted.length, 0, surface);
        for (uint256 i; i < wanted.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(wanted[i])));
            bool served = _has(own, selector) || _has(hostSignatures, selector) || _has(moduleSignatures, selector);
            assertTrue(
                served, string.concat(wanted[i], " of ", surface, " is served by neither ", host, " nor ", module)
            );
        }
    }

    function test_rootServesEveryLaneRootSelector() public view {
        bytes4[] memory own = new bytes4[](1);
        own[0] = IHookrLaneRoot.laneModule.selector;
        _assertServed(
            "IHookrLaneRoot.sol/IHookrLaneRoot.json",
            "HookrRoot.sol/HookrRoot.json",
            "HookrLane.sol/HookrLane.json",
            own
        );
        // laneModule() is the root's own answer: the module and the codehash it reports.
        (address module, bytes32 codeHash) = IHookrLaneRoot(address(root)).laneModule();
        assertGt(module.code.length, 0);
        assertEq(module.codehash, codeHash);
    }

    function test_rulesServeEveryLaneAndRecaptureRulesSelector() public view {
        assertEq(IHookrRecaptureRules.recaptureModule.selector, RULES_RECAPTURE_MODULE);
        assertEq(IHookrLaneRules.carryLeg.selector, RULES_CARRY_LEG);
        bytes4[] memory own = new bytes4[](2);
        own[0] = RULES_RECAPTURE_MODULE;
        own[1] = RULES_CARRY_LEG;
        _assertServed(
            "IHookrLaneRules.sol/IHookrLaneRules.json",
            "HookrRules.sol/HookrRules.json",
            "HookrRecapture.sol/HookrRecapture.json",
            own
        );
        _assertServed(
            "IHookrRecaptureRules.sol/IHookrRecaptureRules.json",
            "HookrRules.sol/HookrRules.json",
            "HookrRecapture.sol/HookrRecapture.json",
            own
        );
    }

    /// The Rules serve IHookrAdvisoryFeeCounter from their fallback (HookrRecapture), with a real answer.
    function test_rulesServeTheAdvisoryFeeCounter() public {
        bytes4[] memory own = new bytes4[](0);
        _assertServed(
            "IHookrAdvisoryFeeCounter.sol/IHookrAdvisoryFeeCounter.json",
            "HookrRules.sol/HookrRules.json",
            "HookrRecapture.sol/HookrRecapture.json",
            own
        );
        string[] memory rulesOwn = _signatures("HookrRules.sol/HookrRules.json");
        assertFalse(
            _has(rulesOwn, IHookrAdvisoryFeeCounter.advisoryFeeCredited.selector), "not in the Rules' dispatcher"
        );
        (bool ok, bytes memory out) = address(rules)
            .call(abi.encodeCall(IHookrAdvisoryFeeCounter.advisoryFeeCredited, (PoolId.wrap(bytes32(uint256(1))))));
        assertTrue(ok);
        assertEq(abi.decode(out, (uint256)), 0, "an unknown pool counted nothing");
    }

    /// Every IHookrRecaptureRules function (IHookrLaneRules' included) called on the Rules with real arguments either
    /// answers or reverts with data; none reverts empty, as a selector neither the Rules nor HookrRecapture has would.
    function test_rulesAnswerEveryRecaptureRulesCall() public {
        PoolId id = PoolId.wrap(bytes32(uint256(1)));
        PoolKey memory key;
        Currency currency;
        HookrTypes.SwapContext memory context;
        HookrTypes.SwapSimulation memory simulation;
        bytes[] memory calls = new bytes[](39);
        uint256 n;
        // IHookrLaneRules
        calls[n++] = abi.encodeCall(IHookrLaneRules.recaptureMode, (id));
        calls[n++] = abi.encodeCall(IHookrLaneRules.settleRecapture, (key, currency, address(this), 1, 1, 1));
        calls[n++] = abi.encodeCall(IHookrLaneRules.settleLeg, (id, address(this), 1));
        calls[n++] = abi.encodeCall(IHookrLaneRules.carryLeg, (context, simulation, 1));
        calls[n++] = abi.encodeCall(IHookrLaneRules.flushRecapture, (key));
        calls[n++] = abi.encodeCall(IHookrLaneRules.creditSweep, (currency, 1));
        // IHookrRecaptureRules
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.settleEpoch, (id));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.claimPool, (id, address(this)));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.recaptureConfig, (id));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.hill, (id));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.pendingPrize, (id));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.poolAccrued, (id, currency));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.poolAccruedCurrencies, (id));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.pendingDonation, (id));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.recaptureDefaults, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.prizeBound, (400, 0, 2500));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.prizeBoundFor, (400, 0, 2500, 0));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.protocolShareFloor, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.minimumFee, (id));
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.recaptureModule, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MIN_TRADER_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MAX_TRADER_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.DEFAULT_TRADER_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.DEFAULT_LP_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MAX_POT_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.DEFAULT_POT_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MIN_PERIOD, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MAX_PERIOD, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.DEFAULT_PERIOD, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MIN_POT_RELEASE_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MAX_POT_RELEASE_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.DEFAULT_POT_RELEASE_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MIN_PRIZE_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.PRIZE_SHARE_OF_FEE_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.RECAPTURE_PROTOCOL_BPS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.FULL_RELEASE_EPOCHS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MIN_RELEASE_BLOCKS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.MAX_RELEASE_BLOCKS, ());
        calls[n++] = abi.encodeCall(IHookrRecaptureRules.DEFAULT_RELEASE_BLOCKS, ());
        // One call per interface function: a function added to the interface needs its call here.
        string[] memory surface = _signatures("IHookrRecaptureRules.sol/IHookrRecaptureRules.json");
        assertEq(n, surface.length, "one call per IHookrRecaptureRules function");
        bytes4[] memory called = new bytes4[](n);
        for (uint256 i; i < n; ++i) {
            called[i] = bytes4(calls[i]);
            (bool ok, bytes memory out) = address(rules).call(calls[i]);
            assertTrue(
                ok || out.length != 0,
                string.concat(vm.toString(abi.encodePacked(called[i])), " reverted with empty data")
            );
        }
        for (uint256 i; i < surface.length; ++i) {
            assertTrue(_has(called, bytes4(keccak256(bytes(surface[i])))), string.concat(surface[i], " not called"));
        }
    }
}
