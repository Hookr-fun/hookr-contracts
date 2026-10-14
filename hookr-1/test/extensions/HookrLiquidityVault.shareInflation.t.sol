// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {ReferenceLP} from "../utils/ReferenceLP.sol";
import {LiquidityVaultSecurityBase} from "../utils/LiquidityVaultSecurityBase.sol";

/// @dev Mints PoolManager ERC-6909 claims backed by its own tokens and sends them to `to`.
contract ClaimsDonor is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function donate(Currency currency, address to, uint256 amount) external {
        manager.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
        manager.settle();
        manager.mint(to, currency.toId(), amount);
        return "";
    }
}

/// @notice LV-03: shares are minted 1:1 with the liquidity each deposit adds to the vault's own position, so there is
///         no exchange rate to inflate. A first depositor's dust, a donation to the pool, claims or ETH sent to the
///         vault, and rounding cannot tax a later depositor or charge more than it asked to pay.
contract HookrLiquidityVaultShareInflationTest is LiquidityVaultSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ClaimsDonor internal claimsDonor;

    function setUp() public {
        _setUpVault();
        claimsDonor = new ClaimsDonor(manager);
        tokenA.transfer(address(claimsDonor), 1e26);
        tokenB.transfer(address(claimsDonor), 1e26);
    }

    /// @notice A dust first deposit, a donation to the pool and claims sent straight to the vault before a victim's
    ///         deposit leave the victim paying and receiving exactly what a direct position does, and none of the
    ///         donations land on the victim's shares.
    function testFuzz_firstDepositorCannotTaxLaterDepositors(uint64 dust, uint96 poolGift, uint96 vaultGift) public {
        PoolKey memory k = _plainPool(3000);
        uint256 d = bound(dust, 1e3, 1e12);
        (uint256 id, uint128 lm,,) = _deposit(mallory, k, d, d);
        donor.donate(k, bound(poolGift, 1, 1e22), bound(poolGift, 1, 1e22), "");
        claimsDonor.donate(k.currency0, address(vault), bound(vaultGift, 1, 1e24));
        claimsDonor.donate(k.currency1, address(vault), bound(vaultGift, 1, 1e24));

        ReferenceLP ref = _ref();
        (, uint128 la, uint256 paid0, uint256 paid1) = _deposit(alice, k, 1e20, 1e20);
        (int256 r0, int256 r1,,) = ref.modify(k, LO, HI, int256(uint256(la)));
        assertEq(paid0, uint256(-r0));
        assertEq(paid1, uint256(-r1));
        assertEq(vault.balanceOf(alice, id), la);
        assertEq(vault.totalSupply(id), uint256(la) + lm);
        assertEq(_positionLiquidity(k), vault.totalSupply(id));
        (uint256 c0, uint256 c1) = _claim(alice, k);
        assertEq(c0 + c1, 0);

        _churn(k, 2, 5e19);
        (uint256 out0, uint256 out1, uint256 f0, uint256 f1) = _withdraw(alice, k, la);
        (int256 q0, int256 q1, uint256 rf0, uint256 rf1) = ref.modify(k, LO, HI, -int256(uint256(la)));
        assertEq(out0, uint256(q0));
        assertEq(out1, uint256(q1));
        assertApproxEqAbs(f0, rf0, 2);
        assertApproxEqAbs(f1, rf1, 2);
        assertEq(_positionLiquidity(k), vault.totalSupply(id));
    }

    /// @notice Deposits at any price, below, inside or above the range, never charge more than desired and mint
    ///         exactly the liquidity added. The vault rounds liquidity down, the PoolManager rounds amounts up, and the
    ///         product never exceeds the desired amount.
    function testFuzz_depositNeverChargesAboveDesired(uint96 a0, uint96 a1, int24 tick) public {
        PoolKey memory k = _plainPool(3000);
        int24 target = int24(bound(tick, -1_200, 1_200));
        (uint160 price,,,) = manager.getSlot0(k.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        if (limit != price) {
            bool zeroForOne = limit < price;
            generic.swap(k, SwapParams(zeroForOne, -1e24, limit), PoolSwapTest.TestSettings(false, false), "");
        }
        uint256 d0 = bound(a0, 1e9, 1e24);
        uint256 d1 = bound(a1, 1e9, 1e24);
        (uint256 id, uint128 liquidity, uint256 paid0, uint256 paid1) = _deposit(alice, k, d0, d1);
        assertLe(paid0, d0);
        assertLe(paid1, d1);
        assertEq(vault.balanceOf(alice, id), liquidity);
        assertEq(_positionLiquidity(k), liquidity);
    }

    /// @notice Known limit, pinned: the vault has no sweep. ERC-6909 claims and ETH sent to it, and shares sent to
    ///         its own address, stay there for good; they never fund a deposit, never count toward a holder's fees
    ///         and never block an exit.
    function test_pinned_strayAssetsAreStranded() public {
        PoolKey memory k = _nativePlainPool();
        (uint256 id, uint128 la,,) = _deposit(alice, k, 1e20, 1e20);
        (, uint128 lb,,) = _deposit(bob, k, 1e20, 1e20);
        vm.deal(address(vault), 5e20);
        claimsDonor.donate(k.currency1, address(vault), 1e21);

        // Stray ETH never pays for a native deposit, and the refund is msg.value less what the deposit used.
        vm.prank(mallory);
        vm.expectRevert(IHookrLiquidityVault.InvalidValue.selector);
        vault.deposit(_params(mallory, k, 1e20, 1e20));
        uint256 before = mallory.balance;
        vm.prank(mallory);
        (,, uint256 paid0,) = vault.deposit{value: 2e20}(_params(mallory, k, 1e20, 1e20));
        assertEq(before - mallory.balance, paid0);
        assertEq(address(vault).balance, 5e20);

        // Shares sent to the vault's own address are lost with their principal.
        vm.prank(bob);
        vault.transfer(address(vault), id, lb / 2);
        assertEq(vault.balanceOf(address(vault), id), lb / 2);

        _churn(k, 2, 5e19);
        _withdraw(alice, k, la);
        _withdraw(bob, k, lb - lb / 2);
        _withdraw(mallory, k, uint128(vault.balanceOf(mallory, id)));
        assertEq(vault.totalSupply(id), lb / 2);
        assertEq(_positionLiquidity(k), lb / 2);
        assertEq(address(vault).balance, 5e20);
        assertGe(_claims(k.currency1), 1e21);
    }
}
