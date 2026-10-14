// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrLaneExecutor} from "../../src/interfaces/callback/IHookrLaneExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {KothWashFixture} from "./utils/KothWashFixture.sol";

/// @notice Hostile executor for REVIEW L-1. It pays off an existing debt of the outer caller (count -1) and opens a
///         debt of its own in a currency outside the pool pair (count +1). Every frame check passes.
contract DebtShiftExecutor is IHookrLaneExecutor {
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;
    address public root;
    address public victim;
    Currency public payFor;
    Currency public outside;
    bool public shift;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function set(address _root, address _victim, Currency _payFor, Currency _outside, bool _shift) external {
        (root, victim, payFor, outside, shift) = (_root, _victim, _payFor, _outside, _shift);
    }

    function checkV3PoolsMev(address, address, address, bool) external pure returns (bool) {
        return false;
    }

    function executeArbitrage(PoolKey calldata, address) external returns (uint256) {
        require(msg.sender == root, "root");
        int256 d = manager.currencyDelta(victim, payFor);
        if (shift && d < 0) {
            manager.sync(payFor);
            IERC20(Currency.unwrap(payFor)).transfer(address(manager), uint256(-d));
            manager.settleFor(victim);
        }
        manager.mint(address(this), outside.toId(), 1);
        return 0;
    }
}

/// @notice The frame's delta count check (review finding L-1, pinned as the current behaviour): a hostile executor
///         that settles a debt the outer caller already carries and opens a debt of its own passes every frame
///         check, and the trader's transaction then reverts at the end of its unlock. An admission item for the
///         executor.
contract FrameDebtShiftTest is KothWashFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// REVIEW L-1. The frame compares the PoolManager's nonzero-delta COUNT, so a hostile executor can settle a debt
    /// the outer caller already carries and open a debt of its own in a third currency: all frame checks pass, the
    /// arb recapture is recorded as succeeded, and the trader's transaction then reverts at unlock end with
    /// CurrencyNotSettled. Fail-open does not hold for callers whose unlock carries a delta when they swap (a JIT or
    /// multi-step integrator). Control: the same debt without the shift is caught by the frame. An admission item for
    /// the executor.
    function test_frameCountCheckLetsExecutorShiftDebt() public {
        DebtShiftExecutor ex = new DebtShiftExecutor(manager);
        ex.set(address(root), address(0), subject, Currency.wrap(address(tokenB)), false);
        _openLane(address(ex));
        PoolKey memory k = _openKoth(ETH);
        Currency s = _subjectOf(k);
        IERC20(Currency.unwrap(s)).transfer(address(ex), 1e26);
        Actor a = _newActor(k);
        Currency tb = Currency.wrap(address(tokenB));

        // Control: the executor only opens its own debt. The frame catches the count change; the swap completes.
        ex.set(address(root), address(a), s, tb, false);
        a.jitSwap(k, true, -1e18, MIN_PRICE, -600, 600, 1e22);

        // Shift: pay the caller's add-liquidity debt in the subject, open 1 wei of debt in tokenB.
        ex.set(address(root), address(a), s, tb, true);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        a.jitSwap(k, true, -1e18, MIN_PRICE, -600, 600, 1e22);
    }
}
