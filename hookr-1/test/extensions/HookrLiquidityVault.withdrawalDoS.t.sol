// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {ReferenceLP} from "../utils/ReferenceLP.sol";
import {LiquidityVaultSecurityBase} from "../utils/LiquidityVaultSecurityBase.sol";

/// @dev Refuses ETH.
contract EthRefuser {
    receive() external payable {
        revert("no ETH");
    }
}

/// @notice LV-05: no third party can stop an LP from taking its principal and fees out. Dust deposits into the same
///         range, gifted shares, pokes, donations, a protocol recipient that refuses payment and a recipient that
///         reverts leave every other exit working. What can hold principal is the pool's own removal rule.
contract HookrLiquidityVaultWithdrawalDoSTest is LiquidityVaultSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpVault();
    }

    function test_griefingCannotBlockExit() public {
        PoolKey memory k = _plainPool(3000);
        ReferenceLP ref = _ref();
        (uint256 id, uint128 la,,) = _deposit(alice, k, 1e20, 1e20);
        ref.modify(k, LO, HI, int256(uint256(la)));
        for (uint256 i; i < 10; ++i) {
            (, uint128 dust,,) = _deposit(mallory, k, 1e6 + i, 1e6);
            vm.prank(mallory);
            vault.transfer(alice, id, dust);
            vm.prank(mallory);
            vault.poke(k, LO, HI);
            donor.donate(k, 1e15, 1e15, "");
            _churn(k, 1, 1e19);
        }

        (uint256 out0, uint256 out1,,) = _withdraw(alice, k, la);
        (int256 r0, int256 r1,,) = ref.modify(k, LO, HI, -int256(uint256(la)));
        assertEq(out0, uint256(r0));
        assertEq(out1, uint256(r1));
        uint128 gifted = uint128(vault.balanceOf(alice, id));
        assertGt(gifted, 0);
        _withdraw(alice, k, gifted);
        assertEq(vault.balanceOf(alice, id), 0);
        assertEq(vault.totalSupply(id), 0);
        (uint256 o0, uint256 o1) = _owed(id, _holders());
        assertEq(o0 + o1, 0);
    }

    /// @notice A protocol recipient that refuses payment blocks only its own collection, and a withdrawal to a
    ///         reverting recipient fails only for the caller that named it.
    function test_refusingRecipientsBlockOnlyThemselves() public {
        EthRefuser refuser = new EthRefuser();
        vault = new HookrLiquidityVault(manager, address(refuser), address(this), 1 days, 2_000);
        vm.prank(alice);
        _erc20(Currency.wrap(address(tokenA))).approve(address(vault), type(uint256).max);
        _raiseSkim(2_000);
        PoolKey memory k = _nativePlainPool();
        (uint256 id, uint128 la,,) = _deposit(alice, k, 1e20, 1e20);
        _churn(k, 3, 5e19);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(_wparams(address(refuser), k, la));

        (uint256 out0,, uint256 f0,) = _withdraw(alice, k, la);
        assertGt(out0 + f0, 0);
        assertEq(vault.totalSupply(id), 0);
        uint256 skim = vault.protocolFees(k.currency0);
        assertGt(skim, 0);
        vm.expectRevert();
        vault.collectProtocolFees(k.currency0);
        assertEq(vault.protocolFees(k.currency0), skim);
        assertGe(_claims(k.currency0), skim);
    }

    /// @notice Known limit, pinned: a pool sees the vault, not the depositor, as its LP. A Hookr pool whose launch
    ///         guard names the vault as its liquidity owner admits every depositor during the guard, where a direct
    ///         LP is refused, and holds every depositor's principal until guardEndBlock. Fees stay claimable.
    function test_pinned_guardOwnedByVaultAdmitsAnyDepositor() public {
        HookrTypes.RulesConfig memory c = _rulesConfig();
        uint256 guardEnd = vm.getBlockNumber() + 100;
        c.guardEndBlock = uint40(guardEnd);
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        pc.liquidityOwner = address(vault);
        PoolKey memory k = _open(pc, abi.encode(c), 10);

        ReferenceLP direct = _ref();
        vm.expectRevert();
        direct.modify(k, LO, HI, 1e18);

        (uint256 id, uint128 lm,,) = _deposit(mallory, k, 1e20, 1e20);
        assertEq(vault.balanceOf(mallory, id), lm);
        vm.prank(mallory);
        vm.expectRevert();
        vault.withdraw(_wparams(mallory, k, lm));
        _claim(mallory, k);

        vm.roll(guardEnd);
        (uint256 out0, uint256 out1,,) = _withdraw(mallory, k, lm);
        assertGt(out0 + out1, 0);
    }
}
