// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageExistingTokenFactory} from "../src/LeverageExistingTokenFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {LeverageOracleLib} from "../src/libraries/LeverageOracleLib.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice A plain well-behaved ERC20 — the token a BYO creator actually brings. Not a
///         HookrToken on purpose: the whole point of the factory under test is that the
///         token predates Hookr and follows no Hookr convention.
contract PlainToken {
    string public name = "Existing Token";
    string public symbol = "EXIST";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address to, uint256 supply) {
        balanceOf[to] = supply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Keeps a cut of every transfer — the accounting-poison shape the factory must refuse.
contract TaxToken is PlainToken {
    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        uint256 kept = amount / 100;
        balanceOf[to] += amount - kept;
        balanceOf[address(0xdead)] += kept;
        return true;
    }
}

/// @notice USDT-shaped: transfers move balances but return nothing. The engine's typed
///         IERC20Like cannot run this token, so the factory must refuse it at creation.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address to, uint256 supply) {
        balanceOf[to] = supply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Moves balances but reports false — the silent-failure shape.
contract FalseToken is PlainToken {
    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return false;
    }
}

/// @notice Tries to open a second market from inside the first creation's transferFrom,
///         swallowing the nested revert so only the reentrancy lock separates the outcomes.
contract ReenterToken is PlainToken {
    LeverageExistingTokenFactory public factory;
    PlainToken public accomplice;
    bool public nestedSucceeded;
    bool private armed;

    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function arm(LeverageExistingTokenFactory factory_, PlainToken accomplice_) external {
        factory = factory_;
        accomplice = accomplice_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            try factory.createMarket{value: 1 ether}(
                address(accomplice), 1_000 ether, 79228162514264337593543950336, 1 ether, _cfg()
            ) {
                nestedSucceeded = true;
            } catch {}
        }
        return super.transferFrom(from, to, amount);
    }

    function _cfg() private pure returns (ILeverage.MarketConfig memory) {
        return ILeverage.MarketConfig({
            ltvBps: 6_000,
            liqThresholdBps: 8_000,
            liqBonusBps: 500,
            reserveFactorBps: 1_000,
            kinkWad: uint64(8e17),
            maxUtilisationWad: uint64(9e17),
            protocolCapWei: 1_000 ether,
            minPoolQuoteWei: 0
        });
    }

    receive() external payable {}
}

contract LeverageExistingTokenFactoryTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint256 constant WAD = 1e18;

    IPoolManager manager;
    LeverageHook hook;
    LeverageExistingTokenFactory factory;
    LeverageRouter router;
    PlainToken token;

    address creator = address(0xC0);
    address lp = address(0x11);
    address trader = address(0x22);
    address arb = address(0x44);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new LeverageRouter(manager);

        // Same flags, same miner, same one-shot binding as the sibling factory's harness —
        // a BYO deployment is a fresh hook instance bound to this factory.
        uint160 flags = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, address(this)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), flags, creation);
        hook = new LeverageHook{salt: salt}(manager, address(this));
        assertEq(address(hook), predicted, "hook address");

        factory = new LeverageExistingTokenFactory(manager, hook);
        hook.setFactory(address(factory));

        token = new PlainToken(creator, 10_000_000 ether);
        vm.deal(creator, 1_000 ether);
        vm.deal(lp, 1_000 ether);
        vm.deal(trader, 1_000 ether);
        vm.deal(arb, 100_000 ether);
    }

    function _cfg() internal pure returns (ILeverage.MarketConfig memory) {
        return ILeverage.MarketConfig({
            ltvBps: 6_000,
            liqThresholdBps: 8_000,
            liqBonusBps: 500,
            reserveFactorBps: 1_000,
            kinkWad: uint64(8e17),
            maxUtilisationWad: uint64(9e17),
            protocolCapWei: 1_000 ether,
            minPoolQuoteWei: 0
        });
    }

    function _open(uint256 tokenAmount, uint256 ethIn, uint128 liq) internal returns (LeverageMarket) {
        vm.startPrank(creator);
        token.approve(address(factory), tokenAmount);
        address marketAddr =
            factory.createMarket{value: ethIn}(address(token), tokenAmount, SQRT_PRICE_1_1, liq, _cfg());
        vm.stopPrank();
        return LeverageMarket(payable(marketAddr));
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    // ------------------------------------------------------------------ the happy path

    function test_opensMarketForExistingToken() public {
        LeverageMarket market = _open(1_000_000 ether, 100 ether, 50 ether);

        assertEq(factory.marketCount(), 1, "one market");
        assertEq(factory.marketOf(address(token)), address(market), "marketOf");
        assertEq(address(market.token()), address(token), "engine adopted the foreign token");
        assertEq(market.factory(), address(factory), "factory recorded");
        assertGt(market.navQuote(false), 0, "seeded NAV");
        // Founding liquidity mints no shares by design — later deposits buy a claim on it,
        // which is the dilution the LP desk discloses. Same shape as the minting factory.
        assertEq(market.totalSupply(), 0, "founding position carries no shares");
    }

    function test_dustAndEthReturnToCreator() public {
        uint256 tokenBefore = token.balanceOf(creator);
        uint256 ethBefore = creator.balance;

        // Oversupply both legs: at a 1:1 price a 50-ether-liquidity full-range position
        // consumes far less than what is committed, so both refund paths must fire.
        _open(5_000_000 ether, 500 ether, 50 ether);

        assertGt(token.balanceOf(creator), tokenBefore - 5_000_000 ether, "token dust came back");
        assertGt(creator.balance, ethBefore - 500 ether, "ETH surplus came back");
        assertEq(token.balanceOf(address(factory)), 0, "factory keeps no tokens");
        assertEq(address(factory).balance, 0, "factory keeps no ETH");
    }

    function test_creditWorksOverAForeignToken() public {
        LeverageMarket market = _open(1_000_000 ether, 100 ether, 50 ether);

        // Warm the observation ring until the market trusts its own price, exactly as the
        // sibling harness does — a fresh pool protects itself, refusing deposits and
        // borrows alike, until the oracle has a history to stand on.
        PoolKey memory key = _key();
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK + 3; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC + 1;
            vm.warp(t);
            vm.prank(arb);
            router.swap{value: 0.05 ether}(
                LeverageRouter.SwapArgs({
                    key: key,
                    zeroForOne: true,
                    amountSpecified: -int256(0.05 ether),
                    sqrtPriceLimitX96: MIN_LIMIT,
                    amountBound: 0,
                    recipient: arb,
                    deadline: type(uint256).max
                })
            );
        }

        vm.prank(lp);
        market.deposit{value: 50 ether}();

        vm.prank(trader);
        market.openPosition{value: 1 ether}(15e17, 0);

        assertGt(market.debtOf(trader), 0, "the market extended credit against a token it did not mint");
        assertGe(market.healthFactorOf(trader), WAD, "position opens healthy");
    }

    // ------------------------------------------------------------------ the token boundary

    function test_refusesFeeOnTransferToken() public {
        TaxToken taxed = new TaxToken(creator, 1_000_000 ether);
        vm.startPrank(creator);
        taxed.approve(address(factory), 1_000_000 ether);
        vm.expectRevert(LeverageExistingTokenFactory.TaxedTransfer.selector);
        factory.createMarket{value: 10 ether}(address(taxed), 1_000_000 ether, SQRT_PRICE_1_1, 10 ether, _cfg());
        vm.stopPrank();
    }

    function test_refusesNoReturnToken() public {
        // The engine's IERC20Like declares `returns (bool)`, so a token that returns
        // nothing does not fail here-and-now — it fails INSIDE the engine later, and the
        // transfer that reverts may be the one a liquidation depends on. Creation is the
        // only gate that can hold that line, so creation holds it.
        NoReturnToken usdtish = new NoReturnToken(creator, 1_000_000 ether);
        vm.startPrank(creator);
        usdtish.approve(address(factory), 1_000_000 ether);
        vm.expectRevert(LeverageExistingTokenFactory.TokenCallFailed.selector);
        factory.createMarket{value: 10 ether}(address(usdtish), 1_000_000 ether, SQRT_PRICE_1_1, 10 ether, _cfg());
        vm.stopPrank();
    }

    function test_refusesFalseReturningToken() public {
        FalseToken liar = new FalseToken(creator, 1_000_000 ether);
        vm.startPrank(creator);
        liar.approve(address(factory), 1_000_000 ether);
        vm.expectRevert(LeverageExistingTokenFactory.TokenCallFailed.selector);
        factory.createMarket{value: 10 ether}(address(liar), 1_000_000 ether, SQRT_PRICE_1_1, 10 ether, _cfg());
        vm.stopPrank();
    }

    function test_refusesSecondMarketForSameToken() public {
        _open(1_000_000 ether, 100 ether, 50 ether);
        vm.startPrank(creator);
        token.approve(address(factory), 1_000_000 ether);
        vm.expectRevert(LeverageExistingTokenFactory.MarketExists.selector);
        factory.createMarket{value: 10 ether}(address(token), 1_000_000 ether, SQRT_PRICE_1_1, 10 ether, _cfg());
        vm.stopPrank();
    }

    function test_refusesEOAAndDegenerateSeeds() public {
        vm.startPrank(creator);
        vm.expectRevert(LeverageExistingTokenFactory.BadToken.selector);
        factory.createMarket{value: 1 ether}(address(0xBEEF), 1 ether, SQRT_PRICE_1_1, 1 ether, _cfg());

        token.approve(address(factory), type(uint256).max);
        vm.expectRevert(LeverageExistingTokenFactory.BadSeed.selector);
        factory.createMarket{value: 0}(address(token), 1 ether, SQRT_PRICE_1_1, 1 ether, _cfg());
        vm.expectRevert(LeverageExistingTokenFactory.BadSeed.selector);
        factory.createMarket{value: 1 ether}(address(token), 0, SQRT_PRICE_1_1, 1 ether, _cfg());
        vm.expectRevert(LeverageExistingTokenFactory.BadSeed.selector);
        factory.createMarket{value: 1 ether}(address(token), 1 ether, SQRT_PRICE_1_1, 0, _cfg());
        vm.stopPrank();
    }

    function test_reentrantCreateIsNeutralized() public {
        ReenterToken hostile = new ReenterToken(creator, 2_000_000 ether);
        PlainToken accomplice = new PlainToken(address(hostile), 1_000_000 ether);
        hostile.arm(factory, accomplice);
        vm.deal(address(hostile), 10 ether);

        vm.startPrank(creator);
        hostile.approve(address(factory), 1_000_000 ether);
        factory.createMarket{value: 10 ether}(address(hostile), 1_000_000 ether, SQRT_PRICE_1_1, 5 ether, _cfg());
        vm.stopPrank();

        // The outer creation lands; the nested attempt inside transferFrom was refused by
        // the lock and swallowed by the token. Only one market may exist.
        assertEq(hostile.nestedSucceeded(), false, "nested createMarket must fail");
        assertEq(factory.marketCount(), 1, "exactly one market");
        assertEq(factory.marketOf(address(accomplice)), address(0), "accomplice got no market");
    }

    function test_strayEthRefused() public {
        vm.deal(arb, 1 ether);
        vm.prank(arb);
        (bool ok,) = address(factory).call{value: 1 ether}("");
        assertFalse(ok, "stray ETH must be refused");
    }
}
