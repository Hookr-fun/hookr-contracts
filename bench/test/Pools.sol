// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {LiquidityAdder} from "../src/LiquidityAdder.sol";
import {Swaps} from "./Swaps.sol";

/// @title Pools
/// @notice The steady-state pool every figure that is not a launch is measured on, and the same pool without a hook:
///         a bench token quoted in WETH, price 1, tick spacing 60, a 0.3% LP fee and 1e24 of liquidity over ticks
///         -60,000 to 60,000. A Hookr pool is the shared root's market for that existing token, opened by the live
///         HookrLauncher. Its hookless twin has the same pair, tick spacing, liquidity and fee, with no hook and a
///         static fee where the launcher's key carries the dynamic-fee flag. A piece is measured on one such pool and
///         compared with a second, on a second bench token deployed the same way, with the piece off.
abstract contract Pools is Swaps {
    uint160 internal constant SQRT_ONE = 1 << 96;
    int24 internal constant SPACING = 60;
    int24 internal constant RANGE = 60_000;
    uint128 internal constant LIQUIDITY = 1e24;
    uint24 internal constant BASE_FEE_PIPS = 3_000;
    /// @dev Hookr's share of the rules that pay it: 20%, the floor the live Rules enforce.
    uint16 internal constant PROTOCOL_SHARE_BPS = 2_000;
    uint256 internal constant SUPPLY = 1e30;
    /// @dev The measured swap: a buy spends this much WETH, a sell sells this much of the token.
    uint128 internal constant SWAP_AMOUNT = 1e21;

    /// @dev The launch guard every guarded figure uses: 15 parent blocks of a Snipe tax that starts at 10% and falls
    ///      to zero over 180 seconds, with a cap on each parent block's net buys.
    uint40 internal constant GUARD_BLOCKS = 15;
    uint24 internal constant SNIPE_PIPS = 100_000;
    uint16 internal constant SNIPE_DECAY_SECONDS = 180;
    uint128 internal constant BLOCK_BUY_CAP = 5e21;

    /// @dev What a buy and a sell cost on one pool.
    struct Costs {
        uint256 buy;
        uint256 sell;
    }

    LiquidityAdder internal adder;
    address internal trader = makeAddr("trader");
    /// @dev The gas of the last `_launch`: the launcher call as one whole transaction.
    uint256 internal launchGas;

    /// @dev Forks the chain and funds the creator (this contract) and `trader` with WETH.
    function setUp() public virtual override {
        super.setUp();
        adder = new LiquidityAdder(POOL_MANAGER);
        deal(WETH, address(this), 1e27);
        IERC20(WETH).approve(address(adder), type(uint256).max);
        IERC20(WETH).approve(address(LAUNCHER), type(uint256).max);
        _approveRouters(trader, WETH);
        deal(WETH, trader, 1e26);
    }

    /// @dev A bench token whose address sorts above WETH, so WETH is currency0 and a buy is zeroForOne, and has no
    ///      zero byte, so every pool's calldata costs the same whatever token it names. The creator (this contract)
    ///      holds the supply and has approved the launcher and the liquidity helper; `trader` holds some and can pay
    ///      every router.
    function _newToken() internal returns (BenchToken token) {
        do {
            token = new BenchToken(SUPPLY, address(this));
        } while (address(token) < WETH || _hasZeroByte(address(token)));
        token.approve(address(LAUNCHER), type(uint256).max);
        token.approve(address(adder), type(uint256).max);
        token.transfer(trader, 1e27);
        _approveRouters(trader, address(token));
    }

    /// @dev Whether any of the 20 bytes of `account` is zero.
    function _hasZeroByte(address account) private pure returns (bool) {
        for (uint256 i; i < 20; ++i) {
            if (uint8(uint160(account) >> (8 * i)) == 0) return true;
        }
        return false;
    }

    /// @dev A wallet that holds WETH and can pay `token` and WETH to every router, and has never held `token`.
    function _wallet(string memory name, BenchToken token) internal returns (address who) {
        who = makeAddr(name);
        deal(WETH, who, 1e26);
        _approveRouters(who, WETH);
        _approveRouters(who, address(token));
    }

    /// @dev A wallet that has never held either token and can pay every router for both.
    function _fresh(string memory name, BenchToken first, BenchToken second) internal returns (address who) {
        who = _wallet(name, first);
        _approveRouters(who, address(second));
    }

    /// @dev The hookless twin of the steady-state pool for `token`.
    function _hookless(BenchToken token) internal returns (PoolKey memory key) {
        key = PoolKey(Currency.wrap(WETH), Currency.wrap(address(token)), BASE_FEE_PIPS, SPACING, IHooks(address(0)));
        POOL_MANAGER.initialize(key, SQRT_ONE);
        adder.add(key, -RANGE, RANGE, LIQUIDITY, address(this));
    }

    /// @dev The launch member of the steady-state pool, on `rules`, with nothing on but the base LP fee: the
    ///      fee-only path, on which the root never calls the Rules. Callers set the rule they measure.
    function _member(address rules) internal pure returns (IHookrLauncher.Member memory m) {
        m.quote = Currency.wrap(WETH);
        m.tickSpacing = SPACING;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -RANGE;
        m.tickUpper = RANGE;
        m.liquidity = LIQUIDITY;
        m.amount0Max = 1e25;
        m.amount1Max = 1e25;
        m.config.rules = rules;
        m.config.baseLpFeePips = BASE_FEE_PIPS;
        m.config.caps = HookrTypes.Caps(600_000, 350_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("hookr-gas-bench");
        m.rules.maxFeePips = BASE_FEE_PIPS;
        m.rules.protocolShareBps = PROTOCOL_SHARE_BPS;
    }

    /// @dev Puts the shared launch guard on the member, with a cap on the tokens one wallet may buy while it lasts
    ///      (zero for Rules that have none).
    function _guard(IHookrLauncher.Member memory m, uint128 walletCap) internal view {
        m.rules.guardEndBlock = uint40(vm.getBlockNumber()) + GUARD_BLOCKS;
        m.rules.snipeTaxPips = SNIPE_PIPS;
        m.rules.snipeDecaySeconds = SNIPE_DECAY_SECONDS;
        m.rules.maxBuyQuoteAmount = BLOCK_BUY_CAP;
        m.rules.potMinBuyQuote = walletCap;
    }

    /// @dev Opens the Hookr market for `token` with the member, and an advisory when the member names one.
    function _launch(BenchToken token, IHookrLauncher.Member memory m, bytes memory advisoryConfig)
        internal
        returns (bytes32 family, PoolKey memory key)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        IHookrLauncher.Token memory subject = IHookrLauncher.Token(address(token), "", "", 0, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp() + 3600;
        if (m.config.advisory == address(0)) {
            (family,) = LAUNCHER.launch(subject, ROOT, members, deadline);
        } else {
            bytes[] memory configs = new bytes[](1);
            configs[0] = advisoryConfig;
            (family,) = LAUNCHER.launchAdvised(subject, ROOT, members, configs, deadline);
        }
        launchGas = vm.lastCallGas().gasTotalUsed;
        key = LAUNCHER.position(family, 0).key;
    }

    /// @dev Takes back the ETH a launch does not use.
    receive() external payable {}

    /// @dev One buy and one sell of half of it before anything is measured, each in its own block, so the pool's
    ///      balances and ledgers are nonzero as on a pool that trades.
    function _warm(PoolKey memory key) internal {
        _swapUniversal(ROUTER_CURATED, trader, key, true, SWAP_AMOUNT);
        _nextBlock();
        _swapUniversal(ROUTER_CURATED, trader, key, false, SWAP_AMOUNT / 2);
        _nextBlock();
    }

    /// @dev One swap through `router`, then the next block: the swap's whole gas.
    function _swapThenNextBlock(address router, address who, PoolKey memory key, bool buy, uint128 amount)
        internal
        returns (uint256 gas)
    {
        gas = _swapUniversal(router, who, key, buy, amount);
        _nextBlock();
    }

    /// @dev A buy and a sell by `trader` on a warmed pool, each in a block of its own.
    function _costs(PoolKey memory key) internal returns (Costs memory c) {
        c.buy = _swapThenNextBlock(ROUTER_CURATED, trader, key, true, SWAP_AMOUNT);
        c.sell = _swapThenNextBlock(ROUTER_CURATED, trader, key, false, SWAP_AMOUNT);
    }
}
