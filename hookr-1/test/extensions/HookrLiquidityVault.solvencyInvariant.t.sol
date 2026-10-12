// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {LiquidityVaultSecurityBase} from "../utils/LiquidityVaultSecurityBase.sol";

/// @dev Drives deposits, withdrawals, claims, pokes, share transfers, swaps, donations, skim changes and protocol
///      collections on one vault range of a hookless pool.
contract VaultHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant LO = -600;
    int24 internal constant HI = 600;

    HookrLiquidityVault internal immutable vault;
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapper;
    PoolDonateTest internal immutable donor;
    address internal immutable owner;
    uint256 internal immutable id;
    uint160 internal immutable floor;
    uint160 internal immutable ceiling;
    PoolKey internal key;
    address[3] internal actors;

    constructor(
        HookrLiquidityVault vault_,
        IPoolManager manager_,
        PoolSwapTest swapper_,
        PoolDonateTest donor_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        vault = vault_;
        manager = manager_;
        swapper = swapper_;
        donor = donor_;
        owner = vault_.owner();
        key = key_;
        actors = actors_;
        id = vault_.rangeId(key_.toId(), LO, HI);
        floor = TickMath.getSqrtPriceAtTick(-5_000);
        ceiling = TickMath.getSqrtPriceAtTick(5_000);
        IERC20(Currency.unwrap(key_.currency0)).approve(address(swapper_), type(uint256).max);
        IERC20(Currency.unwrap(key_.currency1)).approve(address(swapper_), type(uint256).max);
        IERC20(Currency.unwrap(key_.currency0)).approve(address(donor_), type(uint256).max);
        IERC20(Currency.unwrap(key_.currency1)).approve(address(donor_), type(uint256).max);
    }

    function deposit(uint256 seed, uint256 a0, uint256 a1) external {
        address who = actors[seed % 3];
        a0 = bound(a0, 1e9, 1e21);
        a1 = bound(a1, 1e9, 1e21);
        vm.prank(who);
        vault.deposit(IHookrLiquidityVault.DepositParams(key, LO, HI, a0, a1, 0, 0, who, block.timestamp));
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address who = actors[seed % 3];
        uint256 balance = vault.balanceOf(who, id);
        if (balance == 0) return;
        uint128 liquidity = uint128(bound(amount, 1, balance));
        vm.prank(who);
        vault.withdraw(IHookrLiquidityVault.WithdrawParams(key, LO, HI, liquidity, 0, 0, who, block.timestamp));
    }

    function claim(uint256 seed) external {
        address who = actors[seed % 3];
        vm.prank(who);
        vault.claim(key, LO, HI, who);
    }

    function poke() external {
        if (vault.totalSupply(id) == 0) return;
        vault.poke(key, LO, HI);
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address sender = actors[from % 3];
        uint256 balance = vault.balanceOf(sender, id);
        vm.prank(sender);
        vault.transfer(actors[to % 3], id, bound(amount, 0, balance));
    }

    function swap(bool zeroForOne, uint256 amount) external {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint160 limit = zeroForOne ? floor : ceiling;
        if (zeroForOne ? price <= limit : price >= limit) return;
        swapper.swap(
            key,
            SwapParams(zeroForOne, -int256(bound(amount, 1e6, 1e20)), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function donate(uint256 a0, uint256 a1) external {
        donor.donate(key, bound(a0, 1, 1e18), bound(a1, 1, 1e18), "");
    }

    function setSkim(uint16 bps) external {
        bps = uint16(bound(bps, 0, vault.maxSkimBps()));
        uint16 current = vault.skimBps();
        if (bps > current) {
            bytes32 kind = vault.SET_SKIM();
            bytes32 op = vault.operationHash(kind, abi.encode(bps));
            uint48 ready = vault.readyAt(op);
            if (ready == 0 || block.timestamp > uint256(ready) + vault.GRACE()) {
                vm.prank(owner);
                vault.queue(kind, abi.encode(bps));
                ready = vault.readyAt(op);
            }
            if (block.timestamp < ready) vm.warp(ready);
        }
        vm.prank(owner);
        vault.setSkim(bps);
    }

    function collect(bool zero) external {
        vault.collectProtocolFees(zero ? key.currency0 : key.currency1);
    }
}

/// @notice LV-06: under any sequence of the vault's actions and pool activity, shares equal the vault position's
///         liquidity, balances sum to the supply, the claims the vault holds cover the protocol's skim plus every
///         holder's realised fees, and the skim never exceeds its bound.
contract HookrLiquidityVaultSolvencyInvariantTest is LiquidityVaultSecurityBase {
    using PoolIdLibrary for PoolKey;

    VaultHandler internal handler;
    PoolKey internal key;
    uint256 internal id;

    function setUp() public {
        _setUpVault();
        key = _plainPool(3000);
        id = vault.rangeId(key.toId(), LO, HI);
        handler = new VaultHandler(vault, manager, generic, donor, key, [alice, bob, mallory]);
        tokenA.transfer(address(handler), 1e27);
        tokenB.transfer(address(handler), 1e27);
        _deposit(alice, key, 1e20, 1e20);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.claim.selector;
        selectors[3] = VaultHandler.poke.selector;
        selectors[4] = VaultHandler.transfer.selector;
        selectors[5] = VaultHandler.swap.selector;
        selectors[6] = VaultHandler.swap.selector;
        selectors[7] = VaultHandler.donate.selector;
        selectors[8] = VaultHandler.setSkim.selector;
        selectors[9] = VaultHandler.collect.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // Every fuzzed call comes from one account no invariant reads: on a fork, whose base fee is not zero, a call's
        // sender is left holding ETH for its gas, which would read as a balance of a checked contract.
        targetSender(address(uint160(uint256(keccak256("hookr.invariant.sender")))));
    }

    function invariant_sharesLiquidityAndClaimsCoverLiabilities() public view {
        uint256 supply = vault.totalSupply(id);
        assertEq(uint256(_positionLiquidity(key)), supply, "shares = position liquidity");
        assertEq(vault.balanceOf(alice, id) + vault.balanceOf(bob, id) + vault.balanceOf(mallory, id), supply);
        (uint256 o0, uint256 o1) = _owed(id, _holders());
        assertGe(_claims(key.currency0), vault.protocolFees(key.currency0) + o0, "currency0 covered");
        assertGe(_claims(key.currency1), vault.protocolFees(key.currency1) + o1, "currency1 covered");
        assertLe(vault.skimBps(), vault.maxSkimBps());
        assertEq(address(vault).balance, 0);
    }
}
