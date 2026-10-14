// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {ProtocolFeeForkBase} from "./HookrRoot.protocolFeeAdapterFork.t.sol";

/// @notice SYS-02 (09-24 audit, gap-lens, never independently verified, Informational): a v4 protocol fee pushed
///         between a quote and its swap moves the swap's output by up to 0.1% and lifts the pool's total fee above
///         its frozen LP fee cap (the finder: 100,334 against 100,000).
/// @dev Reproduced on a 4663 fork at r31, live: a pool whose frozen LP fee cap equals its base fee (no rule raises
///      its LP fee) charges exactly the cap; once the fee adapter's fee is pushed, the PoolManager adds the protocol
///      fee on top (protocol + lp - protocol * lp / 1e6), so the total exceeds the frozen cap, and the same swap
///      quoted just before the push pays out less than the quote. The caps bound Hookr's own fees only; the router's
///      `amountBound` is what protects the trader.
contract HookrRootProtocolFeeAboveFrozenCapForkTest is ProtocolFeeForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpFork();
    }

    function test_fork_totalFeeExceedsTheFrozenLpCapAndTheQuoteMoves() public {
        if (!live) return;
        // Base fee 3,000 pips and no rule that adds LP fee: the frozen LP fee cap is the base fee itself.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.caps = HookrTypes.Caps(3000, 200_000, 1000);
        members[0].rules.lpBps = 0;
        members[0].rules.burnBps = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(family, 0).key;
        uint24 cap = root.poolConfig(key.toId()).caps.maxLpFeePips;
        assertEq(cap, 3000, "frozen LP fee cap");

        (, uint24 feeBefore) = _swapFee(key, true, 1e19, true);
        assertEq(feeBefore, cap, "without the protocol fee a swap pays exactly the cap");

        IHookrRouter.Swap memory p = _swap(key, true, true, 1e20);
        uint256 quoted = quoter.quote(p, trader).outputAmount;
        _protocolFeeOn(key);
        (uint256 out, uint24 feeAfter) = _swapFee(key, true, 1e20, true);
        assertEq(feeAfter, 1000 + 3000 - 3, "protocol + lp - protocol * lp / 1e6");
        assertGt(feeAfter, cap, "the total fee exceeds the frozen LP fee cap");
        assertLt(out, quoted, "the swap pays out less than the quote taken before the push");
        emit log_named_uint("frozen LP fee cap (pips)", cap);
        emit log_named_uint("total swap fee after the push (pips)", feeAfter);
        emit log_named_uint("output below the earlier quote (bps)", (quoted - out) * 10_000 / quoted);
    }
}
