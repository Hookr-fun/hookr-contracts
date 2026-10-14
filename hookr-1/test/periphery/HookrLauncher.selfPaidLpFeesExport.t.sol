// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {ServiceEventExport} from "../utils/ServiceEventExport.sol";

/// @notice L-07 regression, chain half. A sole-LP family owner wash-trades its own pool: every LP fee it pays
///         comes straight back to it, yet the DailyLPFees allocator counted the fee as program weight.
/// @dev Original numbers (unfixed service, b7aeae64, 10 round trips of 100 ETH against 10 x 10 ETH of organic
///      volume): the attacker took 90.9% of a shared daily cash budget (909,086,916 of 1,000,000,000 units) for a
///      net cost of 16 wei plus about 0.00018 ETH of gas. This test keeps the exploit on chain (the attacker is the
///      only LP and collects back what it paid) and exports the history for the operator service, which must weight
///      self-paid fees at zero.
contract HookrLauncherSelfPaidLpFeesExportTest is ServiceEventExport {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal honestOwner = address(0x2001);
    address internal attacker = address(0x3001);
    address internal freshWallet = address(0x3002);

    struct Pool {
        bytes32 family;
        PoolKey key;
        address subject;
    }

    Pool private honest;
    Pool private attack;
    PoolSwapTest private generic;

    function setUp() public {
        _setUpPeriphery();
        vm.deal(honestOwner, 1e25);
        vm.deal(attacker, 1e25);
        generic = new PoolSwapTest(manager);
    }

    function testExportSelfPaidWash() public {
        honest = _launchAs(honestOwner, bytes32(uint256(1)), "HON");
        attack = _launchAs(attacker, bytes32(uint256(2)), "ATK");
        vm.prank(trader);
        IERC20(honest.subject).approve(address(router), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            uint256 got = _routerTrade(honest, trader, true, 10 ether);
            _routerTrade(honest, trader, false, uint128(got));
        }
        // Wash from the family-owner address through HookrRouter (payer == owner).
        vm.prank(attacker);
        IERC20(attack.subject).approve(address(router), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            uint256 got = _routerTrade(attack, attacker, true, 100 ether);
            _routerTrade(attack, attacker, false, uint128(got));
        }
        // Wash through an unauthenticated generic caller sent by the owner (PoolManager sender != owner).
        _begin();
        vm.prank(attacker, attacker);
        generic.swap{value: 100 ether}(
            attack.key, SwapParams(true, -100 ether, MIN_PRICE), PoolSwapTest.TestSettings(false, false), ""
        );
        _capture(attacker);
        // The attacker collects back every LP fee it paid.
        _begin();
        vm.prank(attacker, attacker);
        (uint256 fee0, uint256 fee1) = launcher.withdraw(attack.family, 0, 0, 0, 0, attacker, block.timestamp);
        _capture(attacker);
        assertGt(fee0, 0, "owner collected its own ETH fees");
        assertGt(fee1, 0, "owner collected its own subject fees");
        emit log_named_string("L07_VECTOR_SELF_PAID_WASH", _export());
    }

    /// @dev Disclosed Sybil limit: a fresh wallet funded by the owner is indistinguishable onchain.
    function testExportFreshWalletWash() public {
        honest = _launchAs(honestOwner, bytes32(uint256(1)), "HON");
        attack = _launchAs(attacker, bytes32(uint256(2)), "ATK");
        vm.prank(trader);
        IERC20(honest.subject).approve(address(router), type(uint256).max);
        uint256 got = _routerTrade(honest, trader, true, 10 ether);
        _routerTrade(honest, trader, false, uint128(got));
        vm.deal(freshWallet, 1e21);
        vm.prank(freshWallet);
        IERC20(attack.subject).approve(address(router), type(uint256).max);
        got = _routerTrade(attack, freshWallet, true, 100 ether);
        _routerTrade(attack, freshWallet, false, uint128(got));
        emit log_named_string("L07_VECTOR_FRESH_WALLET", _export());
    }

    function _launchAs(address who, bytes32 salt, string memory sym) private returns (Pool memory p) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.baseLpFeePips = 10_000;
        members[0].rules.maxFeePips = 10_000;
        members[0].rules.burnBps = 0;
        members[0].rules.lpBps = 0;
        members[0].rules.potBps = 0;
        members[0].rules.potEveryNBuys = 0;
        members[0].rules.potMinBuyQuote = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.protocolShareBps = 0;
        _begin();
        vm.prank(who, who);
        (p.family, p.subject) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(0), sym, sym, 1e27, salt), address(root), members, block.timestamp
        );
        _capture(who);
        p.key = launcher.position(p.family, 0).key;
    }

    function _routerTrade(Pool storage p, address who, bool buy, uint128 amount) private returns (uint256 got) {
        uint256 before = buy ? IERC20(p.subject).balanceOf(who) : who.balance;
        _begin();
        IHookrRouter.Swap memory s = _swap(p.key, buy, true, amount);
        s.recipient = who;
        vm.prank(who, who);
        router.swap{value: buy ? amount : 0}(s, address(0), new uint256[](0));
        _capture(who);
        got = (buy ? IERC20(p.subject).balanceOf(who) : who.balance) - before;
    }

    function _export() private returns (string memory) {
        int24[] memory ticks = new int24[](2);
        ticks[0] = -60_000;
        ticks[1] = 60_000;
        bytes32[] memory positions = new bytes32[](1);
        positions[0] = _familyPosition(honest.family, -60_000, 60_000);
        _exportPool(honest.key, ticks, positions);
        positions[0] = _familyPosition(attack.family, -60_000, 60_000);
        _exportPool(attack.key, ticks, positions);
        return _vector(
            string.concat(
                '"honestPool":"',
                vm.toString(PoolId.unwrap(honest.key.toId())),
                '","attackPool":"',
                vm.toString(PoolId.unwrap(attack.key.toId())),
                '","honestOwner":"',
                vm.toString(honestOwner),
                '","attacker":"',
                vm.toString(attacker),
                '","freshWallet":"',
                vm.toString(freshWallet),
                '","generic":"',
                vm.toString(address(generic)),
                '",'
            )
        );
    }
}
