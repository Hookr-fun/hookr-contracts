// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrSwapModule} from "../interfaces/IHookrSwapModule.sol";

/// @title HookrFill
/// @notice The outside fill's PoolManager work for root v2 (NC32), kept out of the root's bytes the way HookrLane keeps
///         the lane out: root v2 reaches it only by DELEGATECALL from `beforeSwap`, so it runs as the root and its
///         mint, burn and the swap module's credit are the root's. It asks the root's swap module whether it would
///         fill at all, and only then mints the budget to it as claims, calls its `fill` with at most the module's
///         admitted gas, burns the claims the module gave back, and refuses a fill worse than the pool's own price
///         net of its LP fee. Every swap that reaches it must carry the gas the module could spend at most
///         (`gasFloor`), whether the module fills or not, so a gas limit found while the venue loses to the pool still
///         funds the swap once the venue beats it.
/// @dev Input: root v2's `beforeSwap` calldata unchanged, then one word: the budget below bit 128 and the swap's LP fee
///      in pips above it. Output: one word, the input used below bit 128 and the output delivered above it (zero when
///      the module would not fill). One instance per swap module and admission scope (its immutables), shared by every
///      root built with that module; no storage, no owner. Called directly it acts as itself and holds nothing, so it
///      can move nothing of anyone's.
///
///      The burn after `fill` burns the root's claims: it expects the module to have minted every unused unit of the
///      budget back to the root, as IHookrSwapModule requires. A module that keeps them and reports less input passes
///      every check here and the PoolManager's, and the burn then spends claims the root already held (or reverts the
///      swap when it holds none). Admission review is the guard: an admitted module must mint all unused input back.
contract HookrFill {
    uint256 private constant PIPS = 1_000_000;
    /// @dev The part of `gasFloor` beyond the module's two calls: this contract's own work around them (the claims
    ///      mint and burn, the price check) and the swap's work after the fill (the root's frame, the PoolManager
    ///      swap and the root's afterSwap with the Rules settlement). It covers the whole of a full-Rules swap on the
    ///      combined core without a lane (root.fullRules.noLane.buy, 256,629 with the router and the 21,000 base).
    uint256 private constant FILL_RESERVE = 300_000;

    IPoolManager public immutable poolManager;
    /// @notice The admitted swap module this instance calls, and the most gas each of its calls gets (its admission's
    ///         limit).
    IHookrSwapModule public immutable swapModule;
    uint256 public immutable swapModuleGas;
    /// @notice The least gas a swap must reach this fill with (`InsufficientFillGas` below it): both module calls at
    ///         `swapModuleGas` with the 1/64 each call keeps back, `2 * swapModuleGas * 64 / 63`, plus FILL_RESERVE.
    ///         It is required on every outer exact-input swap of the root, before the module is asked, so the gas
    ///         `eth_estimateGas` finds while the module would not fill already covers the costliest fill the module
    ///         can run (the lane pools' entry floor covers the fill the same way, `laneFillGas`). Within one swap only:
    ///         a route through several swaps that can fill, or a fill before a lane swap, needs the earlier swaps'
    ///         floors on top of its estimate from the caller.
    uint256 public immutable gasFloor;
    /// @notice The registry scope whose admission of `swapModule` a root built with this instance requires at each new
    ///         pool (HookrLane, NC34): the core's part scope.
    address public immutable admissionScope;

    error FillRefused(uint256 amountIn, uint256 amountOut);
    error InsufficientFillGas(uint256 available, uint256 required);
    error InvalidWiring();

    constructor(IPoolManager manager, IHookrSwapModule module, uint256 gasLimit, address scope) {
        if (
            address(manager).code.length == 0 || address(module).code.length == 0 || gasLimit == 0
                || scope == address(0)
        ) {
            revert InvalidWiring();
        }
        poolManager = manager;
        swapModule = module;
        swapModuleGas = gasLimit;
        gasFloor = gasLimit * 128 / 63 + FILL_RESERVE;
        admissionScope = scope;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint256 available = gasleft();
        if (available < gasFloor) revert InsufficientFillGas(available, gasFloor);
        // beforeSwap(address sender, PoolKey key, SwapParams params, bytes hookData): the key's five words from byte
        // 36, zeroForOne at byte 196; the root's word last. The PoolManager wrote every field as a clean word.
        Currency currency0;
        Currency currency1;
        bool zeroForOne;
        PoolId id;
        uint256 word;
        assembly ("memory-safe") {
            currency0 := calldataload(36)
            currency1 := calldataload(68)
            zeroForOne := calldataload(196)
            let p := mload(0x40)
            calldatacopy(p, 36, 160)
            id := keccak256(p, 160)
            word := calldataload(sub(calldatasize(), 32))
        }
        uint256 budget = uint128(word);
        uint256 lpFee = word >> 128;
        (Currency inCur, Currency outCur) = zeroForOne ? (currency0, currency1) : (currency1, currency0);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);
        // The miss pre-check: no venue for the pair, or one that does not beat the pool, costs this view and no claims.
        if (budget == 0 || !swapModule.wouldFill{gas: swapModuleGas}(inCur, outCur, sqrtPriceX96, uint24(lpFee))) {
            return abi.encode(uint256(0));
        }
        poolManager.mint(address(swapModule), inCur.toId(), budget);
        (uint256 amountIn, uint256 amountOut) =
            swapModule.fill{gas: swapModuleGas}(inCur, outCur, budget, sqrtPriceX96, uint24(lpFee));
        if (amountIn > budget || amountOut > uint128(type(int128).max)) revert FillRefused(amountIn, amountOut);
        if (amountIn != budget) poolManager.burn(address(this), inCur.toId(), budget - amountIn);
        // The pool's own rate for amountIn at its spot price, less its LP fee: the least the outside fill may give.
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        (uint256 n, uint256 d) = zeroForOne ? (priceX128, uint256(1) << 128) : (uint256(1) << 128, priceX128);
        if (amountOut < FullMath.mulDiv(FullMath.mulDiv(amountIn, n, d), PIPS - lpFee, PIPS)) {
            revert FillRefused(amountIn, amountOut);
        }
        return abi.encode(amountIn | amountOut << 128);
    }
}
