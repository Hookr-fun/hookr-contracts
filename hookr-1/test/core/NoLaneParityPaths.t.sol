// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {DevBuyFixture} from "../periphery/DevBuyFixture.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @notice An unauthenticated PoolManager caller: one exact swap per unlock, settled from its own balances.
contract ParityDirectSwapper is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    IPoolManager internal immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) external returns (int256, int256) {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountSpecified)), (int256, int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, int256 amount) = abi.decode(data, (PoolKey, bool, int256));
        BalanceDelta d =
            manager.swap(key, SwapParams(zeroForOne, amount, zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1), "");
        _close(key.currency0);
        _close(key.currency1);
        return abi.encode(int256(d.amount0()), int256(d.amount1()));
    }

    function _close(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d > 0) {
            manager.take(c, address(this), uint256(d));
        } else if (d < 0) {
            if (c.isAddressZero()) {
                manager.settle{value: uint256(-d)}();
            } else {
                manager.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(manager), uint256(-d));
                manager.settle();
            }
        }
    }

    receive() external payable {}
}

/// @notice Outcome parity for pools without a recapture lane, on the paths NoLaneParity does not take: a two-member
///         family (native and ERC-20 quotes) with authenticated and unauthenticated swaps both ways, exact input and
///         exact output, Quoter quotes, the family owner's added liquidity and a partial withdrawal with its fees; a
///         fee-advised pool before and after a keeper reprice, on the fee-only path and with every rule; and a
///         new-token launch with its dev buy. Every amount, quote, claim, burn, price, tick and liquidity is folded
///         into one digest recorded by running this file unchanged on b515830; a pool without a lane must reproduce it
///         to the wei. The source uses only what both commits share.
contract NoLaneParityPathsTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @dev Recorded on b515830 (`forge test --match-path test/core/NoLaneParityPaths.t.sol -vv` there).
    bytes32 internal constant B515830_DIGEST = 0xc2cb31951d363c47945ad61eabcff67929e0420c10c9335b05bfbc9eed1eb9e5;

    HookrFeeAdvisory internal fee;
    ParityDirectSwapper internal direct;
    address internal keeper = address(0xBEEF);
    bytes32 internal digest;
    uint256 internal count;

    function setUp() public {
        _setUpPeriphery();
        fee = new HookrFeeAdvisory(address(this), 1 days, registry, address(0));
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(fee),
            codeHash: address(fee).codehash,
            schemaHash: fee.configSchemaHash(),
            caps: HookrTypes.Caps(50_000, 0, 0),
            gasLimit: 200_000,
            phaseMask: 3,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        fee.queue(fee.ADD_KEEPER(), abi.encode(keeper));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        fee.addKeeper(keeper);
        direct = new ParityDirectSwapper(manager);
        vm.deal(address(direct), 1e27);
        tokenA.transfer(address(direct), 1e26);
        tokenB.transfer(address(direct), 1e26);
    }

    function _fold(string memory label, uint256 value) internal {
        digest = keccak256(abi.encode(digest, value));
        count++;
        emit log_named_uint(label, value);
    }

    function _foldSigned(string memory label, int256 value) internal {
        _fold(label, uint256(value + (1 << 200)));
    }

    function _next() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 7);
    }

    function _subject() internal returns (HookrToken t) {
        t = new HookrToken("Q", "Q", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        t.transfer(trader, 1e27);
        t.transfer(address(direct), 1e27);
        vm.prank(trader);
        t.approve(address(router), type(uint256).max);
    }

    function _routerTrade(PoolKey memory key, bool buy, bool exactInput, uint128 amount, string memory label) internal {
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        Currency quote = root.poolConfig(key.toId()).quote;
        uint256 value = buy && quote.isAddressZero() ? (exactInput ? amount : p.amountBound) : 0;
        vm.prank(trader);
        (uint256 amountIn, uint256 amountOut) = router.swap{value: value}(p, address(0), new uint256[](0));
        _fold(string.concat(label, ".in"), amountIn);
        _fold(string.concat(label, ".out"), amountOut);
        _next();
    }

    function _directTrade(PoolKey memory key, bool buy, int256 amountSpecified, string memory label) internal {
        Currency subject = root.poolConfig(key.toId()).subject;
        bool zeroForOne = buy ? !(key.currency0 == subject) : key.currency0 == subject;
        (int256 d0, int256 d1) = direct.swap(key, zeroForOne, amountSpecified);
        _foldSigned(string.concat(label, ".d0"), d0);
        _foldSigned(string.concat(label, ".d1"), d1);
        _next();
    }

    function _quote(PoolKey memory key, bool buy, uint128 amount, string memory label) internal {
        HookrTypes.ExecutionReceipt memory r = quoter.quote(_swap(key, buy, true, amount), trader);
        _fold(string.concat(label, ".lpFee"), r.lpFeePips);
        _fold(string.concat(label, ".in"), r.inputAmount);
        _fold(string.concat(label, ".out"), r.outputAmount);
        _fold(string.concat(label, ".quoteFee"), r.quoteFee);
        _fold(string.concat(label, ".burn"), r.subjectBurn);
    }

    function _close(PoolKey memory key, address subject, string memory label) internal {
        Currency quote = root.poolConfig(key.toId()).quote;
        (uint160 sqrtPrice, int24 tick,, uint24 lpFee) = manager.getSlot0(key.toId());
        _fold(string.concat(label, ".sqrtPrice"), sqrtPrice);
        _fold(string.concat(label, ".tick"), uint256(int256(tick) + (1 << 32)));
        _fold(string.concat(label, ".storedFee"), lpFee);
        _fold(string.concat(label, ".liquidity"), manager.getLiquidity(key.toId()));
        _fold(string.concat(label, ".protocol"), rules.claimable(quote, protocol));
        _fold(string.concat(label, ".royalty"), rules.claimable(quote, royalty));
        _fold(string.concat(label, ".trader"), rules.claimable(quote, trader));
        _fold(string.concat(label, ".liability"), rules.totalLiability(quote));
        _fold(string.concat(label, ".burned"), IERC20(subject).balanceOf(DEAD));
    }

    function _run(PoolKey memory key, address subject, string memory label) internal {
        _routerTrade(key, true, true, 1e20, string.concat(label, ".buyIn"));
        _directTrade(key, true, -5e19, string.concat(label, ".directBuyIn"));
        _directTrade(key, false, -3e19, string.concat(label, ".directSellIn"));
        _directTrade(key, false, 1e18, string.concat(label, ".directSellOut"));
        _routerTrade(key, false, false, 1e19, string.concat(label, ".sellOut"));
        _quote(key, true, 1e18, string.concat(label, ".quoteBuy"));
        _quote(key, false, 1e18, string.concat(label, ".quoteSell"));
        _routerTrade(key, true, false, 2e19, string.concat(label, ".buyOut"));
        _close(key, subject, label);
    }

    function test_noLanePathsMatchTheReleaseToTheWei() public {
        // A two-member family on native and ERC-20 quotes, every rule, and the owner's liquidity changes.
        HookrToken s1 = _subject();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(0)));
        members[1] = _member(Currency.wrap(address(tokenB)));
        (bytes32 fam,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s1), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        PoolKey memory k0 = launcher.position(fam, 0).key;
        PoolKey memory k1 = launcher.position(fam, 1).key;
        _next();
        _run(k0, address(s1), "family.native");
        _run(k1, address(s1), "family.erc20");
        (uint256 add0, uint256 add1) =
            launcher.addLiquidity{value: 1e22}(fam, 0, 1e21, 1e22, 1e22, vm.getBlockTimestamp());
        _fold("family.add.amount0", add0);
        _fold("family.add.amount1", add1);
        _routerTrade(k0, true, true, 4e20, "family.native.afterAdd");
        uint128 half = launcher.position(fam, 1).liquidity / 2;
        (uint256 out0, uint256 out1) = launcher.withdraw(fam, 1, half, 0, 0, address(this), vm.getBlockTimestamp());
        _fold("family.withdraw.amount0", out0);
        _fold("family.withdraw.amount1", out1);
        _fold("family.position0", launcher.position(fam, 0).liquidity);
        _fold("family.position1", launcher.position(fam, 1).liquidity);
        _close(k0, address(s1), "family.native.end");
        _close(k1, address(s1), "family.erc20.end");

        // A fee-advised pool (fee-only after launch: base fee and protocol share) before and after a keeper reprice.
        HookrToken s2 = _subject();
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(tokenB)));
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        PoolKey memory feeOnly = _advised(s2, m);
        _run(feeOnly, address(s2), "advisedFeeOnly");
        vm.prank(keeper);
        fee.reprice(feeOnly.toId(), 3000, 0, 0, 1 hours);
        _run(feeOnly, address(s2), "advisedFeeOnly.repriced");

        // A fee-advised pool with every rule.
        HookrToken s3 = _subject();
        PoolKey memory full = _advised(s3, _member(Currency.wrap(address(tokenA))));
        _run(full, address(s3), "advisedFull");
        vm.prank(keeper);
        fee.reprice(full.toId(), 4000, 0, 0, 1 hours);
        _run(full, address(s3), "advisedFull.repriced");

        // A new-token launch with its dev buy, then the market.
        (IHookrLauncher.Token memory t, address predicted) = _newToken(Currency.wrap(address(0)), false);
        (bytes32 devFam, address devSubject, uint256 devOut) =
            _launchWithBuy(t, _one(predicted, Currency.wrap(address(0))), IHookrLauncher.DevBuy(0, 1e21, 1, 0));
        _fold("devBuy.out", devOut);
        PoolKey memory devKey = launcher.position(devFam, 0).key;
        _next();
        vm.prank(trader);
        IERC20(devSubject).approve(address(router), type(uint256).max);
        _routerTrade(devKey, true, true, 1e20, "devBuy.market.buyIn");
        _close(devKey, devSubject, "devBuy");

        emit log_named_uint("values", count);
        emit log_named_bytes32("digest", digest);
        assertEq(digest, B515830_DIGEST, "a pool without a lane must reproduce b515830's outcomes");
    }

    function _advised(HookrToken subject, IHookrLauncher.Member memory member) internal returns (PoolKey memory key) {
        member.config.advisory = address(fee);
        member.config.advisoryGasLimit = 200_000;
        member.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = member;
        bytes[] memory configs = new bytes[](1);
        configs[0] = abi.encode(IHookrFeeAdvisory.Config(20_000, 1_000, 0, 0, 5_000, 60, 1 hours));
        (bytes32 fam,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(fam, 0).key;
        _next();
    }
}
