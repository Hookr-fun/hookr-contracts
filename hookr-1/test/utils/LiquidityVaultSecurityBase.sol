// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {RootSecurityBase} from "./RootSecurityBase.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {ReferenceLP} from "./ReferenceLP.sol";

/// @notice Shared setup for the HookrLiquidityVault attack tests: a vault with a 20% skim bound paying the treasury,
///         funded actors, plain v4 pools next to the Hookr fixture root, and the vault's liabilities per currency.
abstract contract LiquidityVaultSecurityBase is RootSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    int24 internal constant LO = -600;
    int24 internal constant HI = 600;
    Currency internal constant ETH = Currency.wrap(address(0));

    HookrLiquidityVault internal vault;
    HookrTreasury internal treasury;
    PoolDonateTest internal donor;
    address internal treasuryTarget = address(0x7A26E7);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal mallory = address(0xBAD);

    function _setUpVault() internal {
        _setUpRootSecurity();
        treasury = new HookrTreasury(address(this), treasuryTarget, manager);
        vault = new HookrLiquidityVault(manager, address(treasury), address(this), 1 days, 2_000);
        treasury.admitSource(address(vault));
        donor = new PoolDonateTest(manager);
        tokenA.approve(address(donor), type(uint256).max);
        tokenB.approve(address(donor), type(uint256).max);
        address[3] memory actors = [alice, bob, mallory];
        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i]);
        }
    }

    function _fund(address who) internal {
        tokenA.transfer(who, 1e25);
        tokenB.transfer(who, 1e25);
        vm.deal(who, 1e25);
        vm.startPrank(who);
        tokenA.approve(address(vault), type(uint256).max);
        tokenB.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A hookless tokenA/tokenB pool at price 1 with 1e22 of reference liquidity over [-6000, 6000].
    function _plainPool(uint24 fee) internal returns (PoolKey memory k) {
        k = _key(60);
        k.fee = fee;
        k.hooks = IHooks(address(0));
        manager.initialize(k, SQRT_ONE);
        _ref().modify(k, -6000, 6000, 1e22);
    }

    /// @dev A hookless ETH/tokenA pool at price 1 with 1e22 of reference liquidity over [-6000, 6000].
    function _nativePlainPool() internal returns (PoolKey memory k) {
        k = PoolKey(ETH, Currency.wrap(address(tokenA)), 3000, 60, IHooks(address(0)));
        manager.initialize(k, SQRT_ONE);
        _ref().modify(k, -6000, 6000, 1e22);
    }

    function _params(address who, PoolKey memory k, uint256 a0, uint256 a1)
        internal
        view
        returns (IHookrLiquidityVault.DepositParams memory)
    {
        return IHookrLiquidityVault.DepositParams(k, LO, HI, a0, a1, 0, 0, who, vm.getBlockTimestamp());
    }

    function _wparams(address to, PoolKey memory k, uint128 liquidity)
        internal
        view
        returns (IHookrLiquidityVault.WithdrawParams memory)
    {
        return IHookrLiquidityVault.WithdrawParams(k, LO, HI, liquidity, 0, 0, to, vm.getBlockTimestamp());
    }

    function _deposit(address who, PoolKey memory k, uint256 a0, uint256 a1)
        internal
        returns (uint256 id, uint128 liquidity, uint256 paid0, uint256 paid1)
    {
        vm.prank(who);
        return vault.deposit{value: k.currency0.isAddressZero() ? a0 : 0}(_params(who, k, a0, a1));
    }

    function _withdraw(address who, PoolKey memory k, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        vm.prank(who);
        return vault.withdraw(_wparams(who, k, liquidity));
    }

    function _claim(address who, PoolKey memory k) internal returns (uint256, uint256) {
        vm.prank(who);
        return vault.claim(k, LO, HI, who);
    }

    function _ref() internal returns (ReferenceLP r) {
        r = new ReferenceLP(manager);
        tokenA.transfer(address(r), 1e25);
        tokenB.transfer(address(r), 1e25);
        vm.deal(address(r), 1e25);
    }

    /// @dev Exact-input round trips on a hookless pool that stay inside [-6000, 6000].
    function _churn(PoolKey memory k, uint256 rounds, uint256 amount) internal {
        for (uint256 i; i < rounds; ++i) {
            _plainSwap(k, true, amount);
            _plainSwap(k, false, amount);
        }
    }

    function _plainSwap(PoolKey memory k, bool zeroForOne, uint256 amount) internal {
        uint256 value = zeroForOne && k.currency0.isAddressZero() ? amount : 0;
        generic.swap{value: value}(
            k,
            SwapParams(zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE : MAX_PRICE),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _raiseSkim(uint16 bps) internal {
        vault.queue(vault.SET_SKIM(), abi.encode(bps));
        vm.warp(vm.getBlockTimestamp() + vault.delay());
        vault.setSkim(bps);
    }

    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(vault), c.toId());
    }

    function _positionLiquidity(PoolKey memory k) internal view returns (uint128 liquidity) {
        (liquidity,,) = manager.getPositionInfo(k.toId(), address(vault), LO, HI, bytes32(0));
    }

    /// @dev What the vault owes in currency0 and currency1 of range `id` to `holders`: realised fees owed plus
    ///      realised fees not yet credited to their checkpoints.
    function _owed(uint256 id, address[] memory holders) internal view returns (uint256 owed0, uint256 owed1) {
        IHookrLiquidityVault.Range memory r = vault.range(id);
        for (uint256 i; i < holders.length; ++i) {
            IHookrLiquidityVault.Account memory a = vault.account(id, holders[i]);
            uint256 balance = vault.balanceOf(holders[i], id);
            owed0 += a.owed0;
            owed1 += a.owed1;
            unchecked {
                owed0 += FullMath.mulDiv(r.feesPerShare0X128 - a.feesPerShare0X128, balance, FixedPoint128.Q128);
                owed1 += FullMath.mulDiv(r.feesPerShare1X128 - a.feesPerShare1X128, balance, FixedPoint128.Q128);
            }
        }
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](3);
        h[0] = alice;
        h[1] = bob;
        h[2] = mallory;
    }

    function _erc20(Currency c) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(c));
    }
}
