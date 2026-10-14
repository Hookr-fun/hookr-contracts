// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {ReferenceLP} from "../utils/ReferenceLP.sol";
import {LiquidityVaultSecurityBase} from "../utils/LiquidityVaultSecurityBase.sol";

/// @dev Native recipient of a withdrawal that, while the vault holds the PoolManager lock, tries to reach other
///      holders' principal and the vault's claims.
contract ThiefRecipient {
    HookrLiquidityVault internal immutable vault;
    IPoolManager internal immutable manager;
    bytes internal forged;
    uint256 internal claimId;
    bytes[4] public reasons;
    bool[4] public succeeded;
    bool public attempted;

    constructor(HookrLiquidityVault v, IPoolManager m) {
        vault = v;
        manager = m;
    }

    function arm(bytes memory forgedCallback, uint256 id) external {
        forged = forgedCallback;
        claimId = id;
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        _try(0, address(vault), abi.encodeCall(HookrLiquidityVault.unlockCallback, (forged)));
        _try(
            1,
            address(manager),
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256,uint256)", address(vault), address(this), claimId, 1
            )
        );
        _try(2, address(manager), abi.encodeWithSignature("burn(address,uint256,uint256)", address(vault), claimId, 1));
        _try(
            3, address(manager), abi.encodeWithSignature("transfer(address,uint256,uint256)", address(this), claimId, 1)
        );
    }

    function _try(uint256 i, address target, bytes memory data) internal {
        (bool ok, bytes memory reason) = target.call(data);
        succeeded[i] = ok;
        reasons[i] = reason;
    }
}

/// @dev A pool hook that moves `amount` of currency0 between itself and the LP on every add or remove, using the
///      return-delta permissions: 1 takes on add, 2 pays on add, 3 takes on remove (fee collection included), 4 pays
///      on remove. The hook settles its own side inside the callback.
contract HostileLiquidityHook {
    IPoolManager internal immutable manager;
    uint8 public mode;
    uint128 public amount;

    constructor(IPoolManager m) {
        manager = m;
    }

    function set(uint8 mode_, uint128 amount_) external {
        mode = mode_;
        amount = amount_;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, _shift(key, mode == 1, mode == 2));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, _shift(key, mode == 3, mode == 4));
    }

    function _shift(PoolKey calldata key, bool take, bool pay) internal returns (BalanceDelta) {
        int128 a = int128(amount);
        if (take) {
            manager.take(key.currency0, address(this), amount);
            return toBalanceDelta(a, 0);
        }
        if (pay) {
            manager.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).transfer(address(manager), amount);
            manager.settle();
            return toBalanceDelta(-a, 0);
        }
        return BalanceDeltaLibrary.ZERO_DELTA;
    }
}

/// @notice LV-01: HookrLiquidityVault holds every LP's principal in one PoolManager position per range and every
///         realised fee as ERC-6909 claims shared across ranges. These attacks try to move principal or claims that
///         belong to someone else. None succeeds.
contract HookrLiquidityVaultPrincipalTheftTest is LiquidityVaultSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpVault();
    }

    /// @notice Shares are the only claim on principal: withdraw burns the caller's own shares, and moving someone
    ///         else's shares needs their allowance or operator approval.
    function test_strangerCannotWithdrawOrMoveShares() public {
        PoolKey memory k = _plainPool(3000);
        (uint256 id, uint128 liquidity,,) = _deposit(alice, k, 1e20, 1e20);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InsufficientShares.selector, 0, liquidity));
        vault.withdraw(_wparams(mallory, k, liquidity));

        vm.prank(mallory);
        vm.expectRevert(); // allowance underflow
        vault.transferFrom(alice, mallory, id, liquidity);

        // An operator can move shares but still withdraws only what it holds.
        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.InsufficientShares.selector, 0, liquidity));
        vault.withdraw(_wparams(bob, k, liquidity));

        assertEq(vault.balanceOf(alice, id), liquidity);
        assertEq(vault.totalSupply(id), liquidity);
        assertEq(_positionLiquidity(k), liquidity);
    }

    /// @notice While the vault holds the PoolManager lock and pays a native recipient, that recipient cannot forge a
    ///         vault callback, spend the vault's ERC-6909 claims, or re-enter.
    function test_lockHolderCallbackCannotReachOtherFunds() public {
        PoolKey memory k = _nativePlainPool();
        ReferenceLP refAlice = _ref();
        (uint256 id, uint128 la,,) = _deposit(alice, k, 1e20, 1e20);
        refAlice.modify(k, LO, HI, int256(uint256(la)));
        (, uint128 lm,,) = _deposit(mallory, k, 1e18, 1e18);
        _churn(k, 3, 5e19);
        vault.poke(k, LO, HI);
        uint256 claims0 = _claims(k.currency0);
        assertGt(claims0, 0);

        ThiefRecipient thief = new ThiefRecipient(vault, manager);
        IHookrLiquidityVault.WithdrawParams memory steal = _wparams(address(thief), k, la);
        thief.arm(abi.encode(uint8(1), abi.encode(steal, alice)), k.currency0.toId());

        vm.prank(mallory);
        vault.withdraw(_wparams(address(thief), k, lm));
        assertTrue(thief.attempted());
        assertEq(
            thief.reasons(0), abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(thief)), "forged"
        );
        for (uint256 i; i < 4; ++i) {
            assertFalse(thief.succeeded(i));
        }

        // Alice's shares, principal and fees are intact.
        assertEq(vault.balanceOf(alice, id), la);
        (uint256 out0, uint256 out1, uint256 f0, uint256 f1) = _withdraw(alice, k, la);
        (int256 r0, int256 r1, uint256 rf0, uint256 rf1) = refAlice.modify(k, LO, HI, -int256(uint256(la)));
        assertEq(out0, uint256(r0));
        assertEq(out1, uint256(r1));
        assertApproxEqAbs(f0, rf0, 2);
        assertApproxEqAbs(f1, rf1, 2);
        assertEq(vault.totalSupply(id), 0);
        assertLe(_claims(k.currency0), 4);
        assertLe(_claims(k.currency1), 4);
    }

    /// @notice A pool whose hook shifts deltas on add, remove and fee collection shares currencies with an honest
    ///         range, but can only move value between itself and the LPs of its own pool. The claims the vault holds
    ///         always cover every range's realised fees, and the honest range earns what a direct position earns.
    ///         Known limit: such a hook can block fee claims (and, if it wished, removals) in its own pool.
    function test_hostileHookCannotReachOtherRanges() public {
        PoolKey memory honest = _plainPool(3000);
        (PoolKey memory hostileKey, HostileLiquidityHook hook) = _hostilePool();
        ReferenceLP refAlice = _ref();
        (uint256 honestId, uint128 la,,) = _deposit(alice, honest, 1e20, 1e20);
        refAlice.modify(honest, LO, HI, int256(uint256(la)));
        _raiseSkim(1_000);

        // 1 take on add: the depositor pays the hook's cut on top of its liquidity, within amount0Desired.
        IERC20 cut = _erc20(hostileKey.currency0);
        uint256 hookBefore = cut.balanceOf(address(hook));
        hook.set(1, 1e18);
        (uint256 hostileId, uint128 lm,,) = _deposit(mallory, hostileKey, 3e20, 1e20);
        (, uint128 lb,,) = _deposit(bob, hostileKey, 3e20, 1e20);
        assertEq(cut.balanceOf(address(hook)) - hookBefore, 2e18);
        _solvent(honest, honestId, hostileId);

        // 2 pay on add: the hook subsidises a deposit.
        hook.set(2, 1e18);
        _deposit(mallory, hostileKey, 3e20, 1e20);
        hook.set(0, 0);
        _churn(honest, 2, 5e19);
        _churn(hostileKey, 2, 5e19);
        _solvent(honest, honestId, hostileId);

        // 3 take on remove: fee collection in the hostile pool reverts; a withdrawal pays principal net of the cut.
        hook.set(3, 1e18);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.UnexpectedDelta.selector, -int256(1e18), int256(0)));
        vault.claim(hostileKey, LO, HI, mallory);
        vault.poke(honest, LO, HI);
        _withdraw(mallory, hostileKey, lm / 2);
        _solvent(honest, honestId, hostileId);

        // 4 pay on remove: the hook adds to a withdrawal's principal; fee collection reverts again.
        hook.set(4, 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IHookrLiquidityVault.UnexpectedDelta.selector, int256(1e18), int256(0)));
        vault.claim(hostileKey, LO, HI, bob);
        _withdraw(bob, hostileKey, lb);
        _solvent(honest, honestId, hostileId);
        hook.set(0, 0);
        _churn(hostileKey, 2, 5e19);
        _churn(honest, 1, 5e19);
        _withdraw(mallory, hostileKey, uint128(vault.balanceOf(mallory, hostileId)));
        _solvent(honest, honestId, hostileId);

        // The honest range is untouched.
        (uint256 out0, uint256 out1, uint256 f0, uint256 f1) = _withdraw(alice, honest, la);
        (int256 r0, int256 r1, uint256 rf0, uint256 rf1) = refAlice.modify(honest, LO, HI, -int256(uint256(la)));
        assertEq(out0, uint256(r0));
        assertEq(out1, uint256(r1));
        assertApproxEqAbs(f0, rf0 - rf0 * 1_000 / 10_000, 4);
        assertApproxEqAbs(f1, rf1 - rf1 * 1_000 / 10_000, 4);
        _solvent(honest, honestId, hostileId);
        uint256 skim0 = vault.protocolFees(honest.currency0);
        assertGt(skim0, 0);
        assertEq(vault.collectProtocolFees(honest.currency0), skim0);
        _solvent(honest, honestId, hostileId);
    }

    function _hostilePool() internal returns (PoolKey memory k, HostileLiquidityHook hook) {
        uint160 flags = Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        uint160 base = uint160(uint256(keccak256("LV-01 hostile hook")));
        address hookAddress = address((base & ~Hooks.ALL_HOOK_MASK) | flags);
        vm.etch(hookAddress, address(new HostileLiquidityHook(manager)).code);
        hook = HostileLiquidityHook(hookAddress);
        tokenA.transfer(hookAddress, 1e24);
        tokenB.transfer(hookAddress, 1e24);
        k = _key(60);
        k.fee = 3000;
        k.hooks = IHooks(hookAddress);
        manager.initialize(k, SQRT_ONE);
        _ref().modify(k, -6000, 6000, 1e22);
    }

    /// @dev The vault's claims in each currency cover the protocol's skim and every holder's realised fees in both
    ///      ranges.
    function _solvent(PoolKey memory honest, uint256 honestId, uint256 hostileId) internal view {
        (uint256 h0, uint256 h1) = _owed(honestId, _holders());
        (uint256 x0, uint256 x1) = _owed(hostileId, _holders());
        assertGe(_claims(honest.currency0), vault.protocolFees(honest.currency0) + h0 + x0, "currency0 covered");
        assertGe(_claims(honest.currency1), vault.protocolFees(honest.currency1) + h1 + x1, "currency1 covered");
    }
}
