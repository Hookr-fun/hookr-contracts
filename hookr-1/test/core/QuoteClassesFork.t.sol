// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// @notice The fork, the genesis quote addresses and the helpers the genesis quote suites share
///         (`QuoteClassesForkTest`, `QuoteLookAlikesTest`): the periphery on a Robinhood Chain 4663 fork, against the
///         real PoolManager and the real tokens. `live` is false unless ALCHEMY_RPC_URL is set; the fork URL is the
///         `robinhood` alias in foundry.toml.
abstract contract QuoteClassesForkFixture is PeripheryFixture {
    /// @dev The rehearsal's fork block, and its l1BlockNumber: what `block.number` returns inside a contract on Nitro.
    uint256 internal constant FORK_BLOCK = 72_107_166;
    uint256 internal constant FORK_L1_BLOCK = 26_053_463;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    bytes32 internal constant SET_QUOTE_CLASS = keccak256("SET_QUOTE_CLASS");
    bytes32 internal constant ANY_QUOTE = keccak256("ANY_QUOTE");
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    address internal constant STOCK_BEACON = 0xe10b6f6B275de231345c20D14Ab812db62151b00;
    bytes32 internal constant STOCK_CLASS = 0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NFLX = 0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant PENDLE = 0x5E49E1f85813F2B65858860A3FA231b4186f2e0E;
    /// @dev Every Ethereum-bridged token shares this ClonableBeaconProxy runtime and beacon, and the bridge's standard
    ///      gateway deploys one for any L1 token anyone deposits: a permissionless template, never a class. The
    ///      reviewed bridged tokens are catalog entries by address.
    bytes32 internal constant BRIDGED_CLASS = 0x487e3e7ba0f6ef76ccd39c373954f0edcdfe15c8817bdca4ef73f6df3963e694;
    address internal constant BRIDGE_GATEWAY = 0xfd9b17206278C16DdaacF6AC8f05dBf97EdCb31e;
    address internal constant BRIDGED_BEACON = 0x883d9F54F50c9d096b6B3823532Fdc8fd8DFA293;
    address internal constant USDC = 0x80e0e24718dbFcad49ECAA6F1e6C89A190586cA8;
    address internal constant USDT = 0xE246BC49b0598d7Cd9f0eAD48B885034f1254380;
    /// @dev Other reviewed bridged tokens, catalog entries by address: Lido wstETH, BitGo WBTC, Uniswap, Paxos Gold
    ///      and World Liberty USD.
    address internal constant WSTETH = 0xcD26A6AA5BB008240A998E242F51232FE98B12Cb;
    address internal constant WBTC = 0x6bac06600D220Ac5Ac281AD1f504D2Cf0F90F6e6;
    address internal constant UNI = 0xF177d86a28b520e3E396E4F3B96cd8e72D7dabd8;
    address internal constant PAXG = 0xc700C81925D1d1C10F996fA7c0Dee83a54C4Bb8D;
    address internal constant USD1 = 0xFa44874cFc252349153730421BaabB9c30Ab2330;
    /// @dev An Ondo tokenized stock bridged from Ethereum, in no catalog: an any-quote mode quote only.
    address internal constant HOODON = 0xfB5b5778d45AE47F15323fb59B666c655174A79C;
    /// @dev A Robinhood stock token the issuer has not minted yet (zero supply at the assets pin).
    address internal constant ARM = 0x666716999E75d2652398FF830Bbc2e485946E140;
    uint128 internal constant LIQUIDITY = 1e18;
    uint128 internal constant FUNDS = 1e19;
    uint128 internal constant BUY = 1e15;
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

    /// @dev Gives `to` `amount` of `token` by writing the storage slot `balanceOf` reads. forge-std's `deal` cannot
    ///      write USDG, whose balance read also reads its implementation slot; USDG keeps a balance in 64 bits.
    function _fund(address token, address to, uint256 amount) internal {
        vm.record();
        IERC20(token).balanceOf(to);
        (bytes32[] memory reads,) = vm.accesses(token);
        for (uint256 i = reads.length; i > 0; --i) {
            bytes32 slot = reads[i - 1];
            bytes32 previous = vm.load(token, slot);
            vm.store(token, slot, bytes32(amount));
            if (_balanceOf(token, to) == amount) return;
            vm.store(token, slot, previous);
        }
        revert("no balance slot");
    }

    /// @dev A member sized for every genesis quote: USDG caps a balance at 2^64 - 1 (about 1.8e19 base units).
    function _forkMember(address quote) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(Currency.wrap(quote));
        m.liquidity = LIQUIDITY;
        m.amount0Max = FUNDS;
        m.amount1Max = FUNDS;
    }

    function _balanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (account)));
        if (ok && data.length == 32) balance = abi.decode(data, (uint256));
    }

    /// @dev The reviewed bridged tokens, catalog entries by address.
    function _bridgedCatalog() internal pure returns (address[7] memory) {
        return [USDC, USDT, WSTETH, WBTC, UNI, PAXG, USD1];
    }

    /// @dev The genesis quote admissions in one timelock batch.
    function _admitGenesis() internal {
        address[7] memory bridged = _bridgedCatalog();
        registry.queue(registry.SET_QUOTE(), abi.encode(USDG, true));
        registry.queue(registry.SET_QUOTE(), abi.encode(WETH, true));
        for (uint256 i; i < bridged.length; ++i) {
            registry.queue(registry.SET_QUOTE(), abi.encode(bridged[i], true));
        }
        registry.queue(SET_QUOTE_CLASS, abi.encode(STOCK_CLASS, AAPL));
        registry.queue(ANY_QUOTE, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(USDG, true);
        registry.setQuote(WETH, true);
        for (uint256 i; i < bridged.length; ++i) {
            registry.setQuote(bridged[i], true);
        }
        registry.installQuoteClass(STOCK_CLASS, AAPL);
        registry.authorizeAnyQuote();
    }
}

/// @notice The genesis quote kinds on a Robinhood Chain 4663 fork, against the real PoolManager and the real tokens:
///         the Robinhood stock tokens admitted as one class through AAPL's runtime codehash, USDG and WETH in the
///         catalog, and an ERC-20 in neither (PENDLE) through any-quote mode. One family opens a pool on each and a
///         router buy on every member accrues the protocol claim in that member's quote. Skipped unless
///         ALCHEMY_RPC_URL is set; the fork URL is the `robinhood` alias in foundry.toml.
contract QuoteClassesForkTest is QuoteClassesForkFixture {
    using PoolIdLibrary for PoolKey;

    function test_fork_stockTokensShareTheClassCodehashAndBeacon() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        address[4] memory stocks = [AAPL, NVDA, NFLX, SPY];
        for (uint256 i; i < stocks.length; ++i) {
            assertEq(stocks[i].codehash, STOCK_CLASS);
            assertEq(stocks[i].code.length, 283);
            assertEq(address(uint160(uint256(vm.load(stocks[i], BEACON_SLOT)))), STOCK_BEACON);
        }
    }

    function test_fork_genesisQuotesQualifyWithTheirBadges() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        assertFalse(registry.isQuote(NVDA) || registry.isQuote(USDG) || registry.isQuote(PENDLE));
        _admitGenesis();
        address[4] memory stocks = [AAPL, NVDA, NFLX, SPY];
        for (uint256 i; i < stocks.length; ++i) {
            assertTrue(registry.isQuote(stocks[i]));
            assertEq(uint8(registry.badgeForQuote(stocks[i])), uint8(IHookrRegistry.QuoteBadge.CLASS));
        }
        assertEq(uint8(registry.badgeForQuote(USDG)), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        assertEq(uint8(registry.badgeForQuote(WETH)), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        assertEq(uint8(registry.badgeForQuote(PENDLE)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        address[7] memory bridged = _bridgedCatalog();
        for (uint256 i; i < bridged.length; ++i) {
            assertEq(uint8(registry.badgeForQuote(bridged[i])), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        }
        assertEq(uint8(registry.badgeForQuote(HOODON)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        assertEq(uint8(registry.badgeForQuote(address(0))), uint8(IHookrRegistry.QuoteBadge.NATIVE));
        // The Robinhood beacon is a contract but not a stock token: any-quote mode admits it, unreviewed.
        assertEq(uint8(registry.badgeForQuote(STOCK_BEACON)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
    }

    /// @dev No bridged token is reviewed by its code: every one shares the runtime and beacon, so the reviewed ones
    ///      are catalog entries by address and the rest, HOODon here, are quotes through any-quote mode alone, stopped
    ///      by `dismissAnyQuoteNow` while the catalog stays. The only admitted class is the stock class.
    function test_fork_bridgedTokensAreReviewedByAddress() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        address[7] memory bridged = _bridgedCatalog();
        for (uint256 i; i < bridged.length; ++i) {
            assertEq(bridged[i].codehash, BRIDGED_CLASS);
            assertEq(address(uint160(uint256(vm.load(bridged[i], BEACON_SLOT)))), BRIDGED_BEACON);
        }
        assertEq(HOODON.codehash, BRIDGED_CLASS);
        _admitGenesis();
        (bool anyQuote,, bytes32[] memory classes) = registry.openQuoteTerms();
        assertTrue(anyQuote);
        assertEq(classes.length, 1);
        assertEq(classes[0], STOCK_CLASS);
        registry.dismissAnyQuoteNow();
        assertFalse(registry.isQuote(HOODON));
        assertEq(uint8(registry.badgeForQuote(HOODON)), uint8(IHookrRegistry.QuoteBadge.NONE));
        for (uint256 i; i < bridged.length; ++i) {
            assertTrue(registry.isQuote(bridged[i]));
            assertEq(uint8(registry.badgeForQuote(bridged[i])), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        }
    }

    /// @dev Known limit, pinned: a stock token the issuer has not minted has the class runtime but no supply, so it
    ///      is no class member until the issuer mints it. It is still a quote through any-quote mode, badged
    ///      UNREVIEWED, as every contract is live.
    function test_fork_unmintedStockJoinsTheClassOnlyOnceMinted() public {
        if (!live || ARM.code.length == 0) {
            vm.skip(true);
            return;
        }
        assertEq(ARM.codehash, STOCK_CLASS);
        assertEq(IERC20(ARM).totalSupply(), 0);
        _admitGenesis();
        assertTrue(registry.isQuote(ARM));
        assertEq(uint8(registry.badgeForQuote(ARM)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        registry.dismissAnyQuoteNow();
        assertFalse(registry.isQuote(ARM));
        assertTrue(registry.isQuote(AAPL) && registry.isQuote(NVDA));
    }

    /// @dev One tokenA family on ETH, WETH, USDG, NVDA, NFLX, PENDLE and USDC; a router buy on each member.
    function test_fork_familyOnEveryGenesisQuoteKindTrades() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _admitGenesis();
        address[7] memory quotes = [address(0), WETH, USDG, NVDA, NFLX, PENDLE, USDC];
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](quotes.length);
        for (uint256 i; i < quotes.length; ++i) {
            members[i] = _forkMember(quotes[i]);
            if (quotes[i] == address(0)) continue;
            _fund(quotes[i], address(this), FUNDS);
            _fund(quotes[i], trader, FUNDS);
            IERC20(quotes[i]).approve(address(launcher), type(uint256).max);
            vm.prank(trader);
            IERC20(quotes[i]).approve(address(router), type(uint256).max);
        }
        (bytes32 family,) = launcher.launch{value: FUNDS}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        for (uint256 i; i < quotes.length; ++i) {
            PoolKey memory key = launcher.position(family, uint8(i)).key;
            Currency q = Currency.wrap(quotes[i]);
            assertEq(Currency.unwrap(root.poolConfig(key.toId()).quote), quotes[i]);
            IHookrRouter.Swap memory s = _swap(key, true, true, BUY);
            uint256 before = rules.claimable(q, protocol);
            vm.prank(trader);
            (uint256 amountIn, uint256 amountOut) =
                router.swap{value: quotes[i] == address(0) ? BUY : 0}(s, address(0), new uint256[](0));
            assertEq(amountIn, BUY);
            assertGt(amountOut, 0);
            assertGt(rules.claimable(q, protocol), before, "the protocol claim accrues in the member's quote");
            assertTrue(rules.accountingInvariant(q));
        }
    }

    /// @dev Any ERC-20 is a subject as it is live: a stock token attached as the subject of an existing-token family on
    ///      ETH and USDG, bought through the router.
    function test_fork_stockTokenAsSubject() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _admitGenesis();
        _fund(NVDA, address(this), 2 * uint256(FUNDS));
        _fund(USDG, address(this), FUNDS);
        IERC20(NVDA).approve(address(launcher), type(uint256).max);
        IERC20(USDG).approve(address(launcher), type(uint256).max);
        _fund(USDG, trader, FUNDS);
        vm.prank(trader);
        IERC20(USDG).approve(address(router), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _forkMember(address(0));
        members[1] = _forkMember(USDG);
        (bytes32 family,) = launcher.launch{value: FUNDS}(
            IHookrLauncher.Token(NVDA, "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        for (uint8 i; i < 2; ++i) {
            PoolKey memory key = launcher.position(family, i).key;
            assertEq(Currency.unwrap(root.poolConfig(key.toId()).subject), NVDA);
            uint256 before = IERC20(NVDA).balanceOf(trader);
            IHookrRouter.Swap memory s = _swap(key, true, true, BUY);
            vm.prank(trader);
            (, uint256 amountOut) = router.swap{value: i == 0 ? BUY : 0}(s, address(0), new uint256[](0));
            assertGt(amountOut, 0);
            assertEq(IERC20(NVDA).balanceOf(trader), before + amountOut);
        }
    }
}
