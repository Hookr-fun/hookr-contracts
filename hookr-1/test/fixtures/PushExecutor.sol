// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";

/// @title PushExecutor
/// @notice Test and rehearsal stand-in for a recapture executor that pushes a set amount in a set currency on every
///         lane call, funded from its own balance: the pool's quote, a settlement-set currency such as WETH, or, in
///         STRAY_MINT, twice the amount minted to the root and only the amount pushed, which the root must refuse.
///         It swaps nothing. Not a partner's code.
contract PushExecutor {
    using CurrencyLibrary for Currency;

    enum Mode {
        NOTHING,
        PUSH,
        STRAY_MINT
    }

    IPoolManager public immutable manager;
    address public immutable root;
    address public immutable operator;
    Mode public mode;
    Currency public currency;
    uint256 public amount;

    error NotOperator();
    error NotRoot();

    constructor(IPoolManager manager_, address root_, address operator_) {
        (manager, root, operator) = (manager_, root_, operator_);
    }

    /// @notice Sets what each later lane call does. Only the operator.
    function set(Mode mode_, Currency currency_, uint256 amount_) external {
        if (msg.sender != operator) revert NotOperator();
        (mode, currency, amount) = (mode_, currency_, amount_);
    }

    /// @notice The lane call: nothing, or a mint to the root and a push of `amount` in `currency`. Only the root.
    function executeArbitrage(PoolKey calldata key, address) external returns (uint256) {
        if (msg.sender != root) revert NotRoot();
        Mode m = mode;
        if (m == Mode.NOTHING) return 0;
        (Currency c, uint256 a) = (currency, amount);
        uint256 minted = m == Mode.STRAY_MINT ? 2 * a : a;
        if (c.isAddressZero()) {
            manager.settle{value: minted}();
        } else {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), minted);
            manager.settle();
        }
        manager.mint(root, c.toId(), minted);
        IHookrLaneRoot(root).settleRecapture(key, c, a);
        return a;
    }

    receive() external payable {}
}
