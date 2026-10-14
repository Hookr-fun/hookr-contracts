// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {LiquidityVaultSecurityBase} from "../utils/LiquidityVaultSecurityBase.sol";

/// @dev ERC-20 that calls an armed target once, on its next balance move.
contract CallbackToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 18;
    address public target;
    bytes internal data;
    bool public fired;
    bool public ok;
    bytes public reason;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        fired = false;
        ok = false;
        delete reason;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (target != address(0) && !fired) {
            fired = true;
            (ok, reason) = target.call(data);
        }
    }
}

/// @dev Pool hook that, once armed, either calls a target from inside the vault's modification (mode 1) or buys
///      currency0 up to `limit` before the vault's liquidity is added (mode 2).
contract ReentrantHook {
    IPoolManager internal immutable manager;
    uint8 public mode;
    address public target;
    bytes internal data;
    uint160 public limit;
    bool public ok;
    bytes public reason;

    constructor(IPoolManager m) {
        manager = m;
    }

    function arm(uint8 mode_, address target_, bytes calldata data_, uint160 limit_) external {
        mode = mode_;
        target = target_;
        data = data_;
        limit = limit_;
        ok = false;
        delete reason;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        _act(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        _act(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _act(PoolKey calldata key) internal {
        uint8 m = mode;
        mode = 0;
        if (m == 1) {
            (ok, reason) = target.call(data);
        } else if (m == 2) {
            BalanceDelta d = manager.swap(key, SwapParams(false, -1e24, limit), "");
            uint256 paid = uint256(uint128(-d.amount1()));
            manager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(manager), paid);
            manager.settle();
            manager.take(key.currency0, address(this), uint256(uint128(d.amount0())));
        }
    }
}

/// @notice LV-04: every vault entry point that moves value holds one transient lock, and the PoolManager callback
///         answers only the vault's own unlock. A token callback or a pool hook running inside the vault's
///         modification cannot re-enter, and a hook that moves the price inside a deposit cannot make the vault charge
///         more than the depositor's desired amounts or less favourable than its minimums.
contract HookrLiquidityVaultReentrancyTest is LiquidityVaultSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CallbackToken internal cb;

    function setUp() public {
        _setUpVault();
        cb = new CallbackToken();
        cb.mint(address(this), 1e30);
        cb.approve(address(generic), type(uint256).max);
        address[3] memory actors = [alice, bob, mallory];
        for (uint256 i; i < actors.length; ++i) {
            cb.mint(actors[i], 1e25);
            vm.prank(actors[i]);
            cb.approve(address(vault), type(uint256).max);
        }
    }

    /// @notice A token that calls back on transferFrom (deposit) or transfer (withdraw, claim) meets the lock on
    ///         every vault entry point.
    function test_tokenCallbackCannotReenter() public {
        PoolKey memory k = _callbackPool();
        (uint256 id, uint128 la,,) = _deposit(alice, k, 1e20, 1e20);
        _churn(k, 2, 5e19);
        bytes[] memory calls = _reentries(k, id);
        for (uint256 i; i < calls.length; ++i) {
            cb.arm(address(vault), calls[i]);
            _deposit(bob, k, 1e18, 1e18);
            _assertLocked(cb.ok(), cb.reason(), i);
        }
        for (uint256 i; i < calls.length; ++i) {
            _churn(k, 1, 5e19);
            cb.arm(address(vault), calls[i]);
            _claim(alice, k);
            _assertLocked(cb.ok(), cb.reason(), i);
        }
        cb.arm(address(vault), calls[0]);
        (uint256 out0, uint256 out1,,) = _withdraw(alice, k, la);
        _assertLocked(cb.ok(), cb.reason(), 0);
        assertGt(out0 + out1, 0);
        assertEq(_positionLiquidity(k), vault.totalSupply(id));
    }

    /// @notice A pool hook running inside the vault's add or remove meets the lock, and cannot answer as the
    ///         PoolManager.
    function test_hookCannotReenter() public {
        (PoolKey memory k, ReentrantHook hook) = _hookPool();
        (uint256 id, uint128 la,,) = _deposit(alice, k, 1e20, 1e20);
        _churn(k, 2, 5e19);
        bytes[] memory calls = _reentries(k, id);
        for (uint256 i; i < calls.length; ++i) {
            hook.arm(1, address(vault), calls[i], 0);
            _deposit(bob, k, 1e18, 1e18);
            _assertLocked(hook.ok(), hook.reason(), i);
            hook.arm(1, address(vault), calls[i], 0);
            _claim(alice, k);
            _assertLocked(hook.ok(), hook.reason(), i);
        }
        IHookrLiquidityVault.WithdrawParams memory steal = _wparams(address(hook), k, la);
        hook.arm(
            1, address(vault), abi.encodeCall(vault.unlockCallback, (abi.encode(uint8(1), abi.encode(steal, alice)))), 0
        );
        _withdraw(bob, k, 1);
        assertFalse(hook.ok());
        assertEq(hook.reason(), abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(hook)));
        assertEq(vault.balanceOf(alice, id), la);
        assertEq(_positionLiquidity(k), vault.totalSupply(id));
    }

    /// @notice A hook that buys inside the vault's add moves the price after the vault priced the liquidity. The
    ///         deposit then reverts rather than charge more than desired or pay out less than the minimums.
    function test_hookPriceMoveInsideDepositIsBounded() public {
        (PoolKey memory k, ReentrantHook hook) = _hookPool();
        uint160 up = TickMath.getSqrtPriceAtTick(300);

        // Currency1 binds: the move raises the currency1 a fixed liquidity needs above what was desired.
        hook.arm(2, address(0), "", up);
        vm.prank(alice);
        vm.expectPartialRevert(IHookrLiquidityVault.Slippage.selector);
        vault.deposit(_params(alice, k, 2e20, 1e20));

        // Currency0 binds with slack in currency1: the minimums catch the move.
        IHookrLiquidityVault.DepositParams memory p = _params(alice, k, 1e20, 2e20);
        p.amount0Min = 99e18;
        p.amount1Min = 99e18;
        hook.arm(2, address(0), "", up);
        vm.prank(alice);
        vm.expectPartialRevert(IHookrLiquidityVault.Slippage.selector);
        vault.deposit(p);

        // Without minimums the deposit fills inside the desired amounts at the moved price.
        hook.arm(2, address(0), "", up);
        (, uint128 liquidity, uint256 paid0, uint256 paid1) = _deposit(alice, k, 1e20, 2e20);
        assertLe(paid0, 1e20);
        assertLe(paid1, 2e20);
        assertGt(liquidity, 0);
    }

    function _reentries(PoolKey memory k, uint256 id) internal view returns (bytes[] memory calls) {
        calls = new bytes[](7);
        calls[0] = abi.encodeCall(vault.deposit, (_params(mallory, k, 1e18, 1e18)));
        calls[1] = abi.encodeCall(vault.withdraw, (_wparams(mallory, k, 1)));
        calls[2] = abi.encodeCall(vault.claim, (k, LO, HI, mallory));
        calls[3] = abi.encodeCall(vault.poke, (k, LO, HI));
        calls[4] = abi.encodeCall(vault.transfer, (mallory, id, 0));
        calls[5] = abi.encodeCall(vault.transferFrom, (alice, mallory, id, 0));
        calls[6] = abi.encodeCall(vault.collectProtocolFees, (k.currency0));
    }

    function _assertLocked(bool ok, bytes memory reason, uint256 i) internal pure {
        assertFalse(ok, "re-entered");
        assertEq(reason, abi.encodeWithSelector(IHookrLiquidityVault.Reentrancy.selector), vm.toString(i));
    }

    function _callbackPool() internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = address(cb) < address(tokenB)
            ? (Currency.wrap(address(cb)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(cb)));
        k = PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
        manager.initialize(k, SQRT_ONE);
        _deposit(bob, k, 1e22, 1e22);
    }

    function _hookPool() internal returns (PoolKey memory k, ReentrantHook hook) {
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        uint160 base = uint160(uint256(keccak256("LV-04 reentrant hook")));
        address hookAddress = address((base & ~Hooks.ALL_HOOK_MASK) | flags);
        vm.etch(hookAddress, address(new ReentrantHook(manager)).code);
        hook = ReentrantHook(hookAddress);
        tokenA.transfer(hookAddress, 1e25);
        tokenB.transfer(hookAddress, 1e25);
        k = _key(60);
        k.fee = 3000;
        k.hooks = IHooks(hookAddress);
        manager.initialize(k, SQRT_ONE);
        _ref().modify(k, -6000, 6000, 1e22);
    }
}
