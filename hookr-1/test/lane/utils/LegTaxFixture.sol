// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrToken} from "../../../src/support/HookrToken.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../../src/interfaces/IHookrAdvisory.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {HooklessVenue} from "../../fixtures/CyclingExecutor.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {LegTaxAdvisory, LegExecutor} from "../mocks/LegTaxMocks.sol";

/// @notice Shared setup: the lane with a `LegExecutor`, the stand-in advisories admitted on the root, and helpers that
///         launch an advised lane pool and read a leg's charge.
abstract contract LegTaxFixture is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant LO = 4295128740;
    uint160 internal constant HI = 1461446703485210103287273052203988822378723970341;
    uint24 internal constant TAX = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    bytes4 internal constant WRAPPED = 0x90bfb865;
    uint8 internal constant BOTH = 3;

    LegExecutor internal legEx;
    LegTaxAdvisory internal tax;
    HooklessVenue internal outsider;

    function _setUpLegTax() internal {
        _setUpLane();
        legEx = new LegExecutor(manager);
        legEx.setUp(address(root), address(rules));
        _openLane(address(legEx), 3_000_000);
        vm.deal(address(legEx), 1e28);
        tax = new LegTaxAdvisory();
        _admit(address(tax), 50_000, 100_000, BOTH, false);
        outsider = new HooklessVenue(manager);
    }

    function _admit(address advisory, uint24 capLp, uint24 capQuote, uint8 phases, bool failOpen) internal {
        IHookrRegistry.Admission memory adm = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: advisory,
            codeHash: advisory.codehash,
            schemaHash: IHookrAdvisory(advisory).configSchemaHash(),
            caps: HookrTypes.Caps(capLp, capQuote, 0),
            gasLimit: 100_000,
            phaseMask: phases,
            feeOnly: failOpen,
            failOpen: failOpen
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), adm));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), adm);
    }

    /// @dev A one-member ETH-quoted lane family (currency0 is the quote) bound to `advisory` for `phases`, or with no
    ///      advisory when it is zero. The executor holds 1e26 of its subject.
    function _launchPool(
        address advisory,
        uint8 phases,
        bool failOpen,
        HookrTypes.RulesConfig memory r,
        HookrTypes.RecaptureConfig memory rc
    ) internal returns (PoolKey memory key) {
        HookrToken subject = _newSubject();
        subject.transfer(address(legEx), 1e26);
        subject.approve(address(outsider), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, r, rc);
        bytes32 family;
        if (advisory == address(0)) {
            (family,) = launcher.launch{value: 1e24}(
                IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
                address(root),
                members,
                vm.getBlockTimestamp()
            );
        } else {
            members[0].config.advisory = advisory;
            members[0].config.advisoryGasLimit = 100_000;
            members[0].config.advisoryPhases = phases;
            members[0].config.advisoryFailOpen = failOpen;
            bytes[] memory data = new bytes[](1);
            data[0] = hex"01";
            (family,) = launcher.launchAdvised{value: 1e24}(
                IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
                address(root),
                members,
                data,
                vm.getBlockTimestamp()
            );
        }
        key = launcher.position(family, 0).key;
    }

    function _taxedPool() internal returns (PoolKey memory) {
        return _launchPool(address(tax), BOTH, false, _laneRules(false), _recaptureOnlyRc());
    }

    function _plainPool() internal returns (PoolKey memory) {
        return _launchPool(address(0), 0, false, _laneRules(false), _recaptureOnlyRc());
    }

    /// @dev One armed leg, then a 1e18 authenticated buy by the whale on `trigger`; returns the frame outcome and the
    ///      tax queues' credits.
    function _runLeg(PoolKey memory trigger, PoolKey memory legPool, bool afterPhase, bool zeroForOne, int256 amount)
        internal
        returns (Outcome memory o, uint256 buyCredit, uint256 sellCredit)
    {
        legEx.clear();
        legEx.add(afterPhase, legPool, zeroForOne, amount, zeroForOne ? LO + 1 : HI - 1, 0);
        uint256 b0 = rules.claimable(ETH, tax.BUY_TO());
        uint256 s0 = rules.claimable(ETH, tax.SELL_TO());
        vm.recordLogs();
        _buy(trigger, ETH, whale, 1e18);
        o = _outcome(vm.getRecordedLogs());
        buyCredit = rules.claimable(ETH, tax.BUY_TO()) - b0;
        sellCredit = rules.claimable(ETH, tax.SELL_TO()) - s0;
    }

    /// @dev The revert reason a leg's WrappedError carries (the root's own error).
    function _inner(bytes memory err) internal pure returns (bytes4) {
        require(err.length >= 4 && bytes4(err) == WRAPPED, "not a WrappedError");
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        return bytes4(reason);
    }

    function _innerReason(bytes memory err) internal pure returns (bytes memory reason) {
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        (,, reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
    }

    /// @dev The ETH (currency0) a pool's in-range liquidity earned since `before`, from feeGrowthGlobal0.
    function _fees0(PoolKey memory key, uint256 before) internal view returns (uint256) {
        (uint256 g0,) = manager.getFeeGrowthGlobals(key.toId());
        return (g0 - before) * manager.getLiquidity(key.toId()) >> 128;
    }
}
