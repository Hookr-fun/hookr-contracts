// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrAdvisory} from "../../../src/interfaces/IHookrAdvisory.sol";

/// @notice A stand-in advisory whose after-phase answer depends on the exact amounts it is handed. Before the swap it
///         takes `beforeTake` on every shape. After it, on the two shapes that allow an after-phase take (an exact-input
///         sell and an exact-output buy), it takes 1 to 20,000 pips drawn from the amounts; with `guard` it refuses a
///         swap of `guardFor` whose amounts are not `want0` and `want1`. Test code only.
contract DeltaAdvisory is IHookrAdvisory {
    uint24 public beforeTake;
    bool public guard;
    address public guardFor;
    int128 public want0;
    int128 public want1;
    address public constant TO = address(0xDE17A);

    function set(uint24 t) external {
        beforeTake = t;
    }

    function setGuard(bool on, address sender, int128 a0, int128 a1) external {
        (guard, guardFor, want0, want1) = (on, sender, a0, a1);
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("quoteleg.delta");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external view returns (HookrTypes.Advice memory a) {
        if (beforeTake != 0) (a.quoteTakePips, a.recipient) = (beforeTake, TO);
    }

    function afterSwap(HookrTypes.SwapContext calldata x, int128 amount0, int128 amount1)
        external
        view
        returns (HookrTypes.Advice memory a)
    {
        if (guard && x.sender == guardFor && (amount0 != want0 || amount1 != want1)) a.reject = true;
        if (x.isBuy != x.exactInput) {
            a.quoteTakePips = uint24(uint256(keccak256(abi.encode(amount0, amount1))) % 20_000 + 1);
            a.recipient = TO;
        }
    }
}

/// @notice A size-tiered sell tax charged after the swap: `high` pips when the quote out (currency0) reaches
///         `threshold`, else `low`. Test code only.
contract TieredSellTax is IHookrAdvisory {
    uint256 public threshold = type(uint256).max;
    uint24 public low;
    uint24 public high;
    address public constant TO = address(0x7133);

    function set(uint256 t, uint24 l, uint24 h) external {
        (threshold, low, high) = (t, l, h);
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("quoteleg.tiered");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external pure returns (HookrTypes.Advice memory a) {}

    function afterSwap(HookrTypes.SwapContext calldata x, int128 amount0, int128)
        external
        view
        returns (HookrTypes.Advice memory a)
    {
        if (x.isBuy || !x.exactInput || amount0 <= 0) return a;
        a.quoteTakePips = uint256(uint128(amount0)) >= threshold ? high : low;
        if (a.quoteTakePips != 0) a.recipient = TO;
    }
}

/// @notice Takes 10% of a buy only while the PoolManager is unlocked, as in a real swap, and nothing when asked
///         outside a lock, as by an `eth_call` quote. Test code only.
contract LockAwareTax is IHookrAdvisory {
    IPoolManager public immutable manager;
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    address public constant TO = address(0x10C4);

    constructor(IPoolManager m) {
        manager = m;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("quoteleg.lockaware");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory a) {
        if (x.isBuy && manager.exttload(IS_UNLOCKED_SLOT) != bytes32(0)) {
            (a.quoteTakePips, a.recipient) = (100_000, TO);
        }
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory a)
    {}
}

/// @notice An after-phase sell tax priced on where the swap ends: `pips` of the gross quote out (currency0) of an
///         exact-input sell when the pool's tick after the swap is above `edge`, else nothing. Its after phase reads the
///         pool's state, not only the amounts it is handed. Test code only.
contract EndTickSellTax is IHookrAdvisory {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    int24 public edge = type(int24).max;
    uint24 public constant PIPS_TAKEN = 20_000;
    address public constant TO = address(0xE7D1);

    constructor(IPoolManager m) {
        manager = m;
    }

    function setEdge(int24 e) external {
        edge = e;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("quoteleg.endtick");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external pure returns (HookrTypes.Advice memory a) {}

    function afterSwap(HookrTypes.SwapContext calldata x, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory a)
    {
        if (x.isBuy || !x.exactInput) return a;
        (, int24 tick,,) = manager.getSlot0(x.id);
        if (tick > edge) (a.quoteTakePips, a.recipient) = (PIPS_TAKEN, TO);
    }
}
