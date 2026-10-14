// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrPairAdvisory} from "../../src/interfaces/IHookrPairAdvisory.sol";
import {PairRootFixture} from "./PairRootFixture.sol";

/// @dev Returns the size of the call data it receives as the surcharge.
contract CallDataLengthAdvisory {
    function bindPair(PoolId, uint24, uint32, bytes calldata) external pure returns (bytes4) {
        return IHookrPairAdvisory.bindPair.selector;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        return abi.encode(input.length);
    }
}

/// @dev Accepts only canonically encoded `surchargeForSwap` call data and returns the hash of the whole call.
contract CanonicalAdvisory {
    function bindPair(PoolId, uint24, uint32, bytes calldata) external pure returns (bytes4) {
        return IHookrPairAdvisory.bindPair.selector;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        (bytes32 id, bool zeroForOne, int256 amount, uint160 limit, bytes memory data, address sender) =
            abi.decode(input[4:], (bytes32, bool, int256, uint160, bytes, address));
        bytes memory canonical = abi.encodeCall(
            IHookrPairAdvisory.surchargeForSwap, (PoolId.wrap(id), zeroForOne, amount, limit, data, sender)
        );
        if (keccak256(canonical) != keccak256(input)) revert("not canonical");
        return abi.encode(uint256(7));
    }
}

/// How the pair root builds and funds the `surchargeForSwap` call.
contract PairRootAdvisoryCallTest is PairRootFixture {
    function setUp() public {
        _setUpFactory();
    }

    /// @return outcome 0 when the call reverted, otherwise the Swap event's fee (1 when no Swap was logged).
    function _try(bytes memory data, uint256 g) internal returns (uint256 outcome) {
        vm.recordLogs();
        vm.prank(trader);
        (bool ok,) = address(router).call{gas: g}(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        return 1;
    }

    /// @return outcome 0 when the hook call reverted, otherwise the returned fee without the override flag.
    function _hook(address root, bytes memory input, uint256 g) internal returns (uint256 outcome) {
        vm.prank(address(manager));
        (bool ok, bytes memory out) = root.call{gas: g}(input);
        if (!ok) return 0;
        (,, uint24 fee) = abi.decode(out, (bytes4, int256, uint24));
        return fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    /// The gas check runs after the hookData is copied into memory, so the copy's memory growth cannot starve the
    /// advisory after the check passed: from the smallest gas at which the hook returns upward, every call returns
    /// the advisory's own value and never the fail-open cap, whatever the hookData size.
    function test_advisory_largeHookDataNeverStarvesIntoCap() public {
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 3_000, 2_000, true);
        p.advisoryGasLimit = 100_000;
        (HookrPairRoot root, PoolKey memory key) = _deploy(p);
        // Returns 100 (fee 3,100) only when entered with at least 90,000 gas.
        advisory.set(6, 90_000);
        uint256[3] memory sizes = [uint256(0), 64_000, 256_000];
        for (uint256 i; i < sizes.length; ++i) {
            bytes memory input = abi.encodeCall(
                HookrPairRoot.beforeSwap,
                (trader, key, SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1), new bytes(sizes[i]))
            );
            uint256 lo = 50_000;
            uint256 hi = 5_000_000;
            assertEq(_hook(address(root), input, hi), 3_100, "ample gas pays the advisory's value");
            while (hi - lo > 100) {
                uint256 mid = (lo + hi) / 2;
                if (_hook(address(root), input, mid) == 0) lo = mid;
                else hi = mid;
            }
            for (uint256 g = hi; g < hi + 300_000; g += 1_000) {
                uint256 outcome = _hook(address(root), input, g);
                if (outcome != 0) assertEq(outcome, 3_100, "a returned fee is the advisory's value");
            }
        }
    }

    /// The call data is the canonical ABI encoding: selector plus a payload padded to a multiple of 32 bytes.
    function test_advisory_callDataIsCanonicallyPadded() public {
        CallDataLengthAdvisory a = new CallDataLengthAdvisory();
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 0, 5_000, true);
        p.advisory = address(a);
        (, PoolKey memory key) = _deploy(p);
        _fund(key);
        uint256[8] memory lens = [uint256(0), 1, 28, 29, 31, 32, 33, 64];
        for (uint256 i; i < lens.length; ++i) {
            uint256 len = lens[i];
            uint256 canonical = 4 + 6 * 32 + 32 + (len + 31) / 32 * 32;
            assertEq(_swapFee(key, true, -1e15, new bytes(len)), canonical, "canonical call data size");
        }
    }

    /// An advisory that checks its call data byte for byte against `abi.encodeCall` accepts every hookData length.
    function test_advisory_strictDecoderAcceptsEveryLength() public {
        CanonicalAdvisory a = new CanonicalAdvisory();
        (Currency c0, Currency c1) = _erc();
        IHookrPairRoot.Params memory p = _advised(c0, c1, 3_000, 2_000, false);
        p.advisory = address(a);
        (, PoolKey memory key) = _deploy(p);
        _fund(key);
        for (uint256 len; len <= 70; ++len) {
            bytes memory h = new bytes(len);
            for (uint256 j; j < len; ++j) {
                h[j] = bytes1(uint8(j + 1));
            }
            assertEq(_swapFee(key, len % 2 == 0, -1e15, h), 3_007);
        }
    }
}
