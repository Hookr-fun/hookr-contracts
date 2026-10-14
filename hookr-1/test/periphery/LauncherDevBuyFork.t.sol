// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";

/// @notice New-token launches on a Robinhood Chain 4663 fork, against the real PoolManager: the Hookr 1 launches of
///         the release's live-launch gas table, without and with a dev buy. Each launch opens a 1e27 token
///         single-sided at tick 198,060 with a 207,000-tick founding band, the live coordinator's shape. That table sets
///         them against the receipt of HOW's live launch (tx
///         0xbc1c0b3c77f2fadd760e23e48ac108d03029cb052dea9c81becc9bfc01bdb3c2, L2 block 60,024,790), which sent 0.005
///         ETH for its creator buy. Skipped unless ALCHEMY_RPC_URL is set; the fork URL is the `robinhood` alias in
///         foundry.toml. Run with `--isolate` for per-transaction gasUsed.
contract LauncherDevBuyForkTest is DevBuyFixture {
    uint256 internal constant FORK_BLOCK = 71_811_725;
    /// @dev eth_getBlockByNumber(71_811_725).l1BlockNumber: what `block.number` returns inside a contract on Nitro.
    uint256 internal constant FORK_L1_BLOCK = 26_050_989;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    int24 internal constant OPEN_TICK = 198_060;
    uint256 internal constant FORK_SUPPLY = 1e27;
    uint128 internal constant HOW_DEV_BUY = 0.005 ether;
    bool internal live;

    function setUp() public {
        if (bytes(vm.envOr("ALCHEMY_RPC_URL", string(""))).length == 0) return;
        vm.createSelectFork("robinhood", FORK_BLOCK);
        vm.roll(FORK_L1_BLOCK);
        _deployPeriphery(PM);
        live = true;
    }

    /// @dev The release's registry delay.
    function _registryDelay() internal pure override returns (uint48) {
        return 30 minutes;
    }

    /// @dev A new token against ETH opening at OPEN_TICK, 99.9% of its supply in [OPEN_TICK - 207,000, OPEN_TICK].
    ///      `how` gives HOW's rules (base 0.3%, 3% ceiling, sensitivity 9, Auto Burn 40, LP Rewards 30) with the guard
    ///      a dev buy needs (100 parent blocks, a 1-pip Snipe, a cap of the dev buy); otherwise HKR's (2% ceiling,
    ///      sensitivity 5, Auto Burn 100, LP Rewards 25) and no guard. Both at a 20% protocol share, as live pools.
    function _launchArgs(bool how, bytes32 salt)
        internal
        view
        returns (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members)
    {
        t = IHookrLauncher.Token(address(0), "Fork Dev", "FDEV", FORK_SUPPLY, salt);
        members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        int24 lo = OPEN_TICK - 207_000;
        uint160 sL = TickMath.getSqrtPriceAtTick(lo);
        uint160 sU = TickMath.getSqrtPriceAtTick(OPEN_TICK);
        m.sqrtPriceX96 = sU;
        m.tickLower = lo;
        m.tickUpper = OPEN_TICK;
        m.liquidity = uint128(FullMath.mulDiv(FORK_SUPPLY, 1 << 96, sU - sL) * 999 / 1000);
        m.amount0Max = 0;
        m.amount1Max = uint128(FORK_SUPPLY);
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = 2000;
        if (how) {
            m.rules.maxFeePips = 30_000;
            m.rules.dynamicFeeSens = 9;
            m.rules.burnBps = 40;
            m.rules.lpBps = 30;
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
            m.rules.snipeTaxPips = 1;
            m.rules.maxBuyQuoteAmount = HOW_DEV_BUY;
        } else {
            m.rules.maxFeePips = 20_000;
            m.rules.dynamicFeeSens = 5;
            m.rules.burnBps = 100;
            m.rules.lpBps = 25;
        }
        members[0] = m;
    }

    function _gas(string memory label) internal view returns (uint256 used) {
        used = vm.lastCallGas().gasTotalUsed;
        console2.log(label, used);
    }

    /// @notice Hookr 1 new-token launch, ETH quote, no dev buy, HKR's rules: a row of the release's live-launch gas table.
    function test_fork_launchNewToken_noDevBuy() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) =
            _launchArgs(false, bytes32(uint256(1)));
        (bytes32 family, address subject) = launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        _gas("Hookr 1 launch, new token, ETH quote, HKR rules, no dev buy");
        assertEq(address(launcher).balance, 0);
        assertEq(IERC20(subject).balanceOf(address(launcher)), 0);
        assertGt(launcher.position(family, 0).liquidity, 0);
    }

    /// @notice The same launch with HOW's rules and the guard a dev buy needs, without the buy.
    function test_fork_launchNewToken_howRules_noDevBuy() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) = _launchArgs(true, bytes32(uint256(2)));
        launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        _gas("Hookr 1 launch, new token, ETH quote, HOW rules + guard, no dev buy");
    }

    /// @notice HOW's launch with its 0.005 ETH dev buy, on Hookr 1: delivery, fee legs, the cap and an idle Launcher.
    function test_fork_launchNewToken_devBuy() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        (IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members) = _launchArgs(true, bytes32(uint256(3)));
        uint256 before = address(this).balance;
        vm.recordLogs();
        (bytes32 family, address subject, uint256 out) = launcher.launchWithBuy{value: HOW_DEV_BUY}(
            t,
            address(root),
            members,
            new bytes[](1),
            IHookrLauncher.DevBuy(0, HOW_DEV_BUY, 1, 0),
            vm.getBlockTimestamp()
        );
        _gas("Hookr 1 launch, new token, ETH quote, HOW rules + guard, 0.005 ETH dev buy");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 n,) = _devBuyLogs(logs);
        assertEq(n, 1, "one DevBuyExecuted");
        assertEq(before - address(this).balance, HOW_DEV_BUY, "spends exactly the dev buy");
        uint256 held = IERC20(subject).balanceOf(address(this));
        assertGe(held, out, "delivered to the caller");
        assertLe(held, FORK_SUPPLY / 20, "at most 5% held");
        assertGt(IERC20(subject).balanceOf(DEAD), 0, "Auto Burn");
        assertGt(rules.claimable(Currency.wrap(address(0)), protocol), 0, "protocol share");
        assertTrue(rules.accountingInvariant(Currency.wrap(address(0))), "claims backed");
        assertEq(address(launcher).balance, 0, "no native at rest");
        assertEq(IERC20(subject).balanceOf(address(launcher)), 0, "no subject at rest");
        console2.log("  subject out", out);
        console2.log("  principal locked until", launcher.principalLockedUntil(family));
    }
}
