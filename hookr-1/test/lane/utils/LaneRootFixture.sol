// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrToken} from "../../../src/support/HookrToken.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../../src/interfaces/IHookrRouter.sol";
import {LaneFixture} from "../LaneFixture.sol";

/// @notice Shared fixture: HookrRoot with the recapture lane, launches through the release HookrLauncher.
abstract contract LaneRootFixture is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function _rc(bool on) internal pure returns (HookrTypes.RecaptureConfig memory c) {
        if (!on) return c;
        c.on = true;
        c.traderBps = 2000;
        c.lpBps = 8000;
        c.releaseBlocks = RELEASE;
    }

    function _member(Currency quote, bool lane, bool guarded, uint16 lpBps)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m.quote = quote;
        m.tickSpacing = 60;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000;
        m.tickUpper = 60_000;
        m.liquidity = 1e24;
        m.amount0Max = 1e24;
        m.amount1Max = 1e24;
        m.config.rules = address(rules);
        m.config.baseLpFeePips = BASE_FEE;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("lane-root");
        m.rules.maxFeePips = BASE_FEE;
        m.rules.protocolShareBps = 2500;
        m.rules.lpBps = lpBps;
        if (guarded) {
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
            m.rules.snipeTaxPips = 500_000;
            m.rules.maxBuyQuoteAmount = 1e22;
        }
        m.recapture = _rc(lane);
    }

    function _launch(HookrToken subject, IHookrLauncher.Member[] memory members)
        internal
        returns (bytes32 family, PoolKey[] memory keys)
    {
        uint256 value;
        for (uint256 i; i < members.length; ++i) {
            if (members[i].quote.isAddressZero()) value = 1e24;
        }
        (family,) = launcher.launch{value: value}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        keys = new PoolKey[](members.length);
        for (uint256 i; i < members.length; ++i) {
            keys[i] = launcher.position(family, uint8(i)).key;
        }
    }

    function _one(HookrToken subject, bool lane, bool guarded, uint16 lpBps)
        internal
        returns (bytes32 family, PoolKey memory key)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH, lane, guarded, lpBps);
        PoolKey[] memory keys;
        (family, keys) = _launch(subject, members);
        key = keys[0];
    }

    function _seedRef(PoolKey memory key) internal {
        seeder.seed{value: key.currency0.isAddressZero() ? 1e24 : 0}(_ref(key), SQRT_ONE, -60_000, 60_000, 1e24);
    }

    function _sellWithGas(PoolKey memory key, address who, uint256 amount, uint256 g) internal {
        IHookrRouter.Swap memory p = _swapParams(key, ETH, false, true, amount, who);
        vm.prank(who);
        router.swap{gas: g}(p, address(0), new uint256[](0));
    }

    function sellWithGas(PoolKey memory key, uint256 g) external {
        require(msg.sender == address(this));
        _sellWithGas(key, whale, 1e18, g);
    }

    /// @dev The least gas at which a 1e18 sell by the whale on `key` succeeds, to 1,000 gas, as eth_estimateGas finds.
    function _leastGas(PoolKey memory key) internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 8_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.sellWithGas(key, mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
    }
}
