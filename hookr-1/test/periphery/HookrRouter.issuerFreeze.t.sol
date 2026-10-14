// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// @dev A quote with USDG's freeze rule (Paxos): a transfer from or to a frozen account reverts, and so does a
///      transferFrom whose spender is frozen.
contract FreezableQuote is ERC20 {
    address public immutable issuer;
    mapping(address => bool) public frozen;

    error AddressFrozen();

    constructor(uint256 supply) ERC20("Freezable USD", "fUSD") {
        issuer = msg.sender;
        _mint(msg.sender, supply);
    }

    function freeze(address account, bool on) external {
        require(msg.sender == issuer);
        frozen[account] = on;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (frozen[msg.sender]) revert AddressFrozen();
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (frozen[from] || frozen[to]) revert AddressFrozen();
        super._update(from, to, amount);
    }
}

/// @notice G-05 (phase-one review, Appendix A, an unverified Low lead): an issuer freeze of the single immutable
///         HookrRouter stopped all authenticated trading in that asset on every root pinning it, and stranded every
///         open Nth-buy pot in those pools (curatedRouter was 0, so the router was the only authenticated path).
/// @dev At r31 most of it is gone. The router delivers ERC-20 output straight from the PoolManager to the recipient
///      (`takeTo`), so sells into the frozen asset still clear through it; the Nth-buy pot is refused at bind
///      (M-05, `testPocPotConfigRefusedAtLaunch`); and the release root's curated router is the pinned Universal
///      Router, never zero (`script/Rehearse.s.sol`), an authenticated path whose spender is Permit2. What stands: while
///      the issuer freezes the router's address, a HookrRouter swap that pays in that asset reverts, because the
///      router is the ERC-20 spender; other paths keep trading.
contract HookrRouterIssuerFreezeTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    FreezableQuote private usd;
    PoolKey private key;

    function setUp() public {
        _setUpPeriphery();
        usd = new FreezableQuote(1e30);
        _catalogQuote(address(usd));
        usd.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(usd)));
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(0), "Subject", "SUB", 1e27, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        usd.transfer(trader, 1e26);
        vm.startPrank(trader);
        usd.approve(address(router), type(uint256).max);
        ERC20(Currency.unwrap(root.poolConfig(key.toId()).subject)).approve(address(router), type(uint256).max);
        vm.stopPrank();
        _routerSwap(true, 1e21); // the trader holds subject to sell
    }

    function testFrozenRouterStopsOnlyRouterPaymentsInTheAsset() public {
        usd.freeze(address(router), true);
        // A buy pays fUSD through the router, its spender: refused while the router is frozen.
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e20);
        vm.prank(trader);
        vm.expectRevert(FreezableQuote.AddressFrozen.selector);
        router.swap(buy, address(0), new uint256[](0));
        // A sell delivers fUSD from the PoolManager straight to the trader: still clears through the router.
        uint256 before_ = usd.balanceOf(trader);
        _routerSwap(false, 1e20);
        assertGt(usd.balanceOf(trader), before_, "router sells into the frozen asset still pay out");
        // Any other caller of the PoolManager still buys with fUSD.
        PoolSwapTest swapper = new PoolSwapTest(manager);
        vm.prank(trader);
        usd.approve(address(swapper), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usd);
        vm.prank(trader, trader);
        swapper.swap(
            key,
            SwapParams(zeroForOne, -1e20, zeroForOne ? MIN_PRICE : MAX_PRICE),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        // The freeze lifted, the router buys again.
        usd.freeze(address(router), false);
        _routerSwap(true, 1e20);
    }

    function _routerSwap(bool buy, uint128 amount) private {
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }
}
