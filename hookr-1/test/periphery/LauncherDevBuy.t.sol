// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";
import {RulesData} from "../utils/RulesData.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @dev Launches with a dev buy and, in the same transaction, buys on the same pool through the router.
contract SameTxBuyer {
    function run(
        HookrLauncher launcher,
        HookrRouter router,
        address rootAddress,
        IHookrLauncher.Token calldata t,
        IHookrLauncher.Member[] calldata members,
        IHookrLauncher.DevBuy calldata buy,
        IHookrRouter.Swap memory follow
    ) external payable {
        if (buy.quoteIn != 0) {
            launcher.launchWithBuy{value: buy.quoteIn}(
                t, rootAddress, members, new bytes[](members.length), buy, block.timestamp
            );
        } else {
            launcher.launch(t, rootAddress, members, block.timestamp);
        }
        follow.key.currency1 = Currency.wrap(launcher.predictToken(address(this), t));
        router.swap{value: uint128(-follow.amountSpecified)}(follow, address(0), new uint256[](0));
    }

    receive() external payable {}
}

/// @dev A catalog quote that calls `hook` whenever tokens move into the PoolManager, once per arming.
contract HookedQuote is ERC20 {
    address public immutable manager;
    address public hook;

    constructor(address manager_) ERC20("Hooked", "HKQ") {
        manager = manager_;
        _mint(msg.sender, 1e30);
    }

    function arm(address hook_) external {
        hook = hook_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        address h = hook;
        if (to == manager && h != address(0) && from != h) {
            hook = address(0);
            QuoteHook(h).onPay();
        }
    }
}

interface QuoteHook {
    function onPay() external;
}

/// @dev Re-enters the Launcher while it pays the dev buy's quote.
contract Reenterer is QuoteHook {
    HookrLauncher internal immutable launcher;

    constructor(HookrLauncher l) {
        launcher = l;
    }

    function onPay() external {
        launcher.sweep(Currency.wrap(address(0)), address(this));
    }
}

/// @dev Swaps on the new pool from inside the Launcher's unlock, before the dev buy, and settles with PoolManager
///      claims it minted earlier.
contract PreBuyer is QuoteHook, IUnlockCallback {
    IPoolManager internal immutable manager;
    PoolKey internal target;

    constructor(IPoolManager m) {
        manager = m;
    }

    function fund(Currency quote, uint256 amount) external {
        manager.unlock(abi.encode(quote, amount));
    }

    function aim(PoolKey calldata key) external {
        target = key;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency quote, uint256 amount) = abi.decode(data, (Currency, uint256));
        manager.sync(quote);
        IERC20(Currency.unwrap(quote)).transfer(address(manager), amount);
        manager.settle();
        manager.mint(address(this), quote.toId(), amount);
        return "";
    }

    /// @dev Buys the subject (currency0) with the quote (currency1).
    function onPay() external {
        PoolKey memory key = target;
        BalanceDelta d = manager.swap(key, SwapParams(false, -1e20, TickMath.MAX_SQRT_PRICE - 1), "");
        manager.burn(address(this), key.currency1.toId(), uint256(uint128(-d.amount1())));
        manager.take(key.currency0, address(this), uint256(uint128(d.amount0())));
    }
}

/// @notice HookrLauncher.launchWithBuy: the dev buy of a new-token launch. Unit, negative and fuzz cases.
contract LauncherDevBuyTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal constant ETH = Currency.wrap(address(0));
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    /// @dev HookrLauncher's private dev-buy bound, as its NatSpec states it.
    uint256 internal constant MAX_DEV_BUY_LOCK_BLOCKS = 2_628_000;

    function setUp() public {
        _setUpPeriphery();
    }

    // ------------------------------------------------------------------------------------------------ delivery

    /// @notice ETH quote: the PoolManager pays the subject straight to the caller, the caller spends exactly the dev
    ///         buy (the band holds no quote), the event and the return agree, and nothing rests with the Launcher.
    function test_ethQuote_deliversToCallerAndSpendsExactly() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 2e22, 1, 0);
        uint256 ethBefore = address(this).balance;
        vm.recordLogs();
        (bytes32 family, address s, uint256 out) = _launchWithBuy(t, members, buy);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(s, subject, "predicted subject");
        assertGt(out, 0, "bought");
        assertEq(ethBefore - address(this).balance, buy.quoteIn, "spends exactly the dev buy");
        (uint256 n, uint256 first) = _devBuyLogs(logs);
        assertEq(n, 1, "one DevBuyExecuted");
        assertEq(logs[first].topics[1], family, "family");
        assertEq(logs[first].topics[2], PoolId.unwrap(_id(family, 0)), "pool");
        assertEq(address(uint160(uint256(logs[first].topics[3]))), address(this), "buyer");
        (uint8 member, uint256 quoteIn, uint256 subjectOut, uint160 p0, uint160 p1, uint256 lockedUntil) =
            abi.decode(logs[first].data, (uint8, uint256, uint256, uint160, uint160, uint256));
        assertEq(member, 0);
        assertEq(quoteIn, buy.quoteIn);
        assertEq(subjectOut, out, "event and return agree");
        assertEq(p0, SQRT_ONE, "launch price");
        assertEq(p1, _price(family, 0), "post-buy price");
        assertLt(p1, p0, "a buy of currency1 moves the price down");
        assertEq(lockedUntil, launcher.principalLockedUntil(family), "lock");
        assertEq(lockedUntil, members[0].rules.guardEndBlock, "the guard alone");
        // The bought subject moved PoolManager -> caller in one transfer and never through the Launcher.
        bool delivered;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != subject || logs[i].topics[0] != TRANSFER_TOPIC) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            if (from == address(manager) && to == address(this) && abi.decode(logs[i].data, (uint256)) == out) {
                delivered = true;
            }
            assertFalse(from == address(manager) && to == address(launcher), "never through the Launcher");
            assertFalse(from == address(manager) && to == address(manager), "never to the PoolManager");
        }
        assertTrue(delivered, "PoolManager -> caller");
        assertEq(address(launcher).balance, 0, "no native at rest");
        assertEq(IERC20(subject).balanceOf(address(launcher)), 0, "no subject at rest");
        uint256 mine = IERC20(subject).balanceOf(address(this));
        assertEq(mine + IERC20(subject).balanceOf(address(manager)) + IERC20(subject).balanceOf(DEAD), SUPPLY, "supply");
        assertGt(mine, out, "the unplaced 0.1% came back too");
        assertLe(mine, SUPPLY / 20, "at most 5% held");
    }

    /// @notice ERC-20 quote, subject as currency0 and as currency1: one pull covers the buy, nothing is refunded.
    function test_erc20Quote_bothSortOrders() public {
        Currency quote = Currency.wrap(address(tokenB));
        for (uint256 k; k < 2; ++k) {
            bool subjectFirst = k == 0;
            (IHookrLauncher.Token memory t, address subject) = _newToken(quote, subjectFirst);
            IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e22, 1, 0);
            uint256 before = tokenB.balanceOf(address(this));
            (bytes32 family,, uint256 out) = _launchWithBuy(t, _one(subject, quote), buy);
            PoolKey memory key = launcher.position(family, 0).key;
            assertEq(Currency.unwrap(key.currency0) == subject, subjectFirst, "sort order");
            assertEq(before - tokenB.balanceOf(address(this)), buy.quoteIn, "quote spend");
            assertEq(tokenB.balanceOf(address(launcher)), 0, "no quote at rest");
            assertEq(IERC20(subject).balanceOf(address(launcher)), 0, "no subject at rest");
            assertGe(IERC20(subject).balanceOf(address(this)), out, "delivered");
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price > SQRT_ONE, subjectFirst, "the buy moved the price toward the subject's band");
            assertTrue(rules.accountingInvariant(quote), "claims backed");
        }
    }

    /// @notice A dev buy on member 5 of an eight-member family leaves every sibling's price and refund as a launch
    ///         without it.
    function test_eightMemberFamily_siblingsUntouched() public {
        Currency[8] memory quotes;
        quotes[0] = ETH;
        quotes[1] = Currency.wrap(address(tokenA));
        quotes[2] = Currency.wrap(address(tokenB));
        for (uint256 i = 3; i < 8; ++i) {
            HookrToken q = new HookrToken("Q", "Q", 1e30, address(this));
            q.approve(address(launcher), type(uint256).max);
            _catalogQuote(address(q));
            quotes[i] = Currency.wrap(address(q));
        }
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](8);
        for (uint256 i; i < 8; ++i) {
            members[i] = _devMember(subject, quotes[i], SUPPLY / 8);
        }
        uint8 k = 5;
        uint256[9] memory plain;
        uint256 snap = vm.snapshotState();
        (bytes32 family,) = launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        for (uint256 i; i < 8; ++i) {
            plain[i] = _bal(quotes[i]);
        }
        plain[8] = IERC20(subject).balanceOf(address(this));
        vm.revertToState(snap);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(k, 1e21, 1, 0);
        uint256 out;
        (family,, out) = _launchWithBuy(t, members, buy);
        for (uint8 i; i < 8; ++i) {
            if (i == k) {
                assertEq(plain[i] - _bal(quotes[i]), buy.quoteIn, "member k: the dev buy");
                assertTrue(_price(family, i) != SQRT_ONE, "member k moved");
            } else {
                assertEq(_bal(quotes[i]), plain[i], "sibling refund unchanged");
                assertEq(_price(family, i), SQRT_ONE, "sibling price unchanged");
            }
        }
        assertEq(IERC20(subject).balanceOf(address(this)), plain[8] + out, "subject: the retained supply plus the buy");
    }

    function _bal(Currency c) internal view returns (uint256) {
        return
            Currency.unwrap(c) == address(0)
                ? address(this).balance
                : IERC20(Currency.unwrap(c)).balanceOf(address(this));
    }

    // ------------------------------------------------------------------------------------------------ fees

    /// @notice Every leg a guarded buy pays: the quote take (LP Rewards share, royalty, burn slice and the Snipe's
    ///         protocol share) to Rules claims, Auto Burn to 0xdead, and the LP fee to the family's own position, which
    ///         the owner collects. No refund.
    function test_feeLegs() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 2e22, 1, 0);
        vm.recordLogs();
        (bytes32 family,, uint256 out) = _launchWithBuy(t, _one(subject, ETH), buy);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 earned;
        uint256 refund;
        uint256 burned;
        uint24 lpFee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(root) && logs[i].topics[0] == HOOK_FEE_TOPIC) {
                (earned, refund, burned) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, lpFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        // Quote take: LP Rewards share 5,000 + royalty 750 + burn slice 2,500 + Snipe share 125,000 pips.
        uint256 take = uint256(buy.quoteIn) * 133_250 / 1e6;
        assertEq(earned, take, "quote take");
        assertEq(refund, 0, "no refund");
        assertEq(rules.claimable(ETH, royalty), uint256(buy.quoteIn) * 750 / 1e6, "royalty");
        assertEq(rules.claimable(ETH, protocol) + rules.claimable(ETH, royalty), take, "protocol and royalty");
        assertTrue(rules.accountingInvariant(ETH), "claims backed");
        // Auto Burn: 75 bps of the gross output (100 less the 25 bps protocol slice taken in quote).
        assertGt(burned, 0);
        assertEq(IERC20(subject).balanceOf(DEAD), burned, "burned to 0xdead");
        assertEq(burned, (out + burned) * 75 / 10_000, "net burn rate");
        // LP fee: base 3,000 + LP Rewards 14,250 + the Snipe's LP part 375,000 pips of the pool input.
        assertEq(lpFee, 392_250, "LP fee");
        (uint256 fee0, uint256 fee1) = launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        assertEq(fee1, 0, "no subject fees");
        assertApproxEqAbs(fee0, (buy.quoteIn - take) * 392_250 / 1e6, 2, "the owner collects the LP part");
    }

    /// @notice A decaying Snipe still charges the dev buy the full launch tax: it runs at the launch second.
    function test_fullSnipeWithDecay() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0].rules.snipeDecaySeconds = 120;
        members[0].rules.snipeFloorPips = 10_000;
        vm.recordLogs();
        _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, 2e22, 1, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint24 lpFee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, lpFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        assertEq(lpFee, 392_250, "the full 50% Snipe");
    }

    // ------------------------------------------------------------------------------------------------ guard cap

    /// @notice The dev buy counts against the cap and closes the launch parent block to every other buy on the member;
    ///         sells still clear, and the next parent block reopens the full cap.
    function test_closesLaunchParentBlock() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        (bytes32 family,, uint256 out) = _launchWithBuy(t, _one(subject, ETH), IHookrLauncher.DevBuy(0, 2e22, 1, 0));
        PoolKey memory key = launcher.position(family, 0).key;
        IHookrRouter.Swap memory tiny = _swap(key, true, true, 1e15);
        _capRefused(trader, tiny, 1e15);
        // A sell in the same parent block clears.
        IERC20(subject).approve(address(router), out / 2);
        IHookrRouter.Swap memory sell = _swap(key, false, true, uint128(out / 2));
        sell.recipient = address(this);
        router.swap(sell, address(0), new uint256[](0));
        _capRefused(trader, tiny, 1e15);
        vm.roll(vm.getBlockNumber() + 1);
        IHookrRouter.Swap memory full = _swap(key, true, true, CAP);
        vm.prank(trader);
        router.swap{value: CAP}(full, address(0), new uint256[](0));
    }

    /// @notice A caller contract cannot add a router buy to its dev buy in the same transaction; after a plain launch
    ///         the same router buy clears.
    function test_sameTransactionRouterBuyRefused() public {
        SameTxBuyer buyer = new SameTxBuyer();
        vm.deal(address(buyer), 1e24);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Dev", "DEV", SUPPLY, bytes32(uint256(77)));
        address subject = launcher.predictToken(address(buyer), t);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        PoolKey memory key =
            PoolKey(ETH, Currency.wrap(subject), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        IHookrRouter.Swap memory follow =
            IHookrRouter.Swap(key, true, -int128(1e21), 1, MIN_PRICE, address(buyer), vm.getBlockTimestamp());
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = address(buyer)
            .call(
                abi.encodeCall(
                    SameTxBuyer.run,
                    (launcher, router, address(root), t, members, IHookrLauncher.DevBuy(0, 2e22, 1, 0), follow)
                )
            );
        _capRefusal(ok, ret);
        vm.revertToState(snap);
        buyer.run(launcher, router, address(root), t, members, IHookrLauncher.DevBuy(0, 0, 0, 0), follow);
        assertGt(IERC20(subject).balanceOf(address(buyer)), 0, "the router buy clears after a plain launch");
    }

    // ------------------------------------------------------------------------------------------------ quote, lock

    /// @notice An eth_call with minSubjectOut 1 returns the exact output the real call delivers.
    function test_callQuoteMatchesTheRealCall() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(Currency.wrap(address(tokenB)), true);
        IHookrLauncher.Member[] memory members = _one(subject, Currency.wrap(address(tokenB)));
        uint256 snap = vm.snapshotState();
        (,, uint256 quoted) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, 3e22, 1, 0));
        vm.revertToState(snap);
        snap = vm.snapshotState();
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.DevBuySlippage.selector, quoted, quoted + 1));
        launcher.launchWithBuy(
            t,
            address(root),
            members,
            new bytes[](1),
            IHookrLauncher.DevBuy(0, 3e22, uint128(quoted + 1), 0),
            vm.getBlockTimestamp()
        );
        (,, uint256 out) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, 3e22, uint128(quoted), 0));
        assertEq(out, quoted, "the quote is exact");
    }

    /// @notice lockBlocks keeps the family's principal locked past the guard; a shorter one leaves the guard's lock.
    function test_lockBlocks() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        uint256 b0 = vm.getBlockNumber();
        (bytes32 family,,) = _launchWithBuy(t, _one(subject, ETH), IHookrLauncher.DevBuy(0, 2e22, 1, 1000));
        assertEq(launcher.principalLockedUntil(family), b0 + 1000);
        vm.roll(b0 + 999);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PrincipalLocked.selector, family, 0, b0 + 1000));
        launcher.withdraw(family, 0, 1, 0, 0, address(this), vm.getBlockTimestamp());
        // Fees stay collectable while locked.
        launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        vm.roll(b0 + 1000);
        launcher.withdraw(family, 0, 1e18, 0, 0, address(this), vm.getBlockTimestamp());
        (t, subject) = _newToken(ETH, false);
        (family,,) = _launchWithBuy(t, _one(subject, ETH), IHookrLauncher.DevBuy(0, 2e22, 1, 50));
        assertEq(launcher.principalLockedUntil(family), vm.getBlockNumber() + 100, "the guard is longer");
    }

    /// @notice Log order: the pool's PoolOpened, the buy's Swap and HookFee, DevBuyExecuted, then MemberLaunched and
    ///         FamilyLaunched. An indexer that registers pools from PoolOpened sees the dev buy.
    function test_logOrder() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        vm.recordLogs();
        _launchWithBuy(t, _one(subject, ETH), IHookrLauncher.DevBuy(0, 2e22, 1, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[6] memory logIndexes;
        bytes32[6] memory topics = [
            IHookrRootEvents.PoolOpened.selector,
            SWAP_TOPIC,
            HOOK_FEE_TOPIC,
            DEV_BUY_TOPIC,
            IHookrLauncher.MemberLaunched.selector,
            IHookrLauncher.FamilyLaunched.selector
        ];
        for (uint256 j; j < 6; ++j) {
            logIndexes[j] = type(uint256).max;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics.length != 0 && logs[i].topics[0] == topics[j]) {
                    logIndexes[j] = i;
                    break;
                }
            }
            assertTrue(logIndexes[j] != type(uint256).max, "log missing");
            if (j != 0) assertGt(logIndexes[j], logIndexes[j - 1], "log order");
        }
        assertEq(_swapsFrom(logs, address(launcher)), 1, "the Launcher's only swap");
    }

    // ------------------------------------------------------------------------------------------------ refusals

    function _refuse(
        IHookrLauncher.Token memory t,
        IHookrLauncher.Member[] memory members,
        IHookrLauncher.DevBuy memory buy,
        bytes memory err
    ) internal {
        vm.expectRevert(err);
        launcher.launchWithBuy(t, address(root), members, new bytes[](members.length), buy, vm.getBlockTimestamp());
    }

    /// @notice Every input outside the dev buy's bounds reverts InvalidDevBuy before any funding.
    function test_revert_invalidInputs() public {
        Currency quote = Currency.wrap(address(tokenB));
        (IHookrLauncher.Token memory t, address subject) = _newToken(quote, true);
        IHookrLauncher.Member[] memory members = _one(subject, quote);
        bytes memory err = abi.encodeWithSelector(IHookrLauncher.InvalidDevBuy.selector);
        IHookrLauncher.Token memory existing = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        _refuse(existing, members, IHookrLauncher.DevBuy(0, 1e21, 1, 0), err);
        _refuse(t, members, IHookrLauncher.DevBuy(0, 0, 1, 0), err);
        _refuse(t, members, IHookrLauncher.DevBuy(0, 1e21, 0, 0), err);
        _refuse(t, members, IHookrLauncher.DevBuy(1, 1e21, 1, 0), err);
        uint256 maxLock = MAX_DEV_BUY_LOCK_BLOCKS;
        _refuse(t, members, IHookrLauncher.DevBuy(0, 1e21, 1, uint32(maxLock + 1)), err);
        members[0].rules.maxBuyQuoteAmount = type(uint128).max;
        _refuse(t, members, IHookrLauncher.DevBuy(0, uint128(type(int128).max) + 1, 1, 0), err);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidFamily.selector));
        launcher.launchWithBuy(
            t, address(root), members, new bytes[](2), IHookrLauncher.DevBuy(0, 1e21, 1, 0), vm.getBlockTimestamp()
        );
    }

    /// @notice A guarded dev-buy member must be guarded past this block, with a Snipe and a cap covering the buy. Its
    ///         protocol share is any share the Rules admit: here 10%, a partner launchpad's share, and zero, this
    ///         fixture's Rules floor. (An unguarded member takes a dev buy: test_unguardedMember.)
    function test_revert_unfitMember() public {
        Currency quote = Currency.wrap(address(tokenB));
        (IHookrLauncher.Token memory t, address subject) = _newToken(quote, true);
        bytes memory err = abi.encodeWithSelector(IHookrLauncher.InvalidDevBuy.selector);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e21, 1, 0);
        IHookrLauncher.Member[] memory members = _one(subject, quote);
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber());
        _refuse(t, members, buy, err);
        members = _one(subject, quote);
        members[0].rules.maxBuyQuoteAmount = buy.quoteIn - 1;
        _refuse(t, members, buy, err);
        members = _one(subject, quote);
        members[0].rules.snipeTaxPips = 0;
        _refuse(t, members, buy, err);
        members = _one(subject, quote);
        members[0].rules.protocolShareBps = 1000;
        uint256 snap = vm.snapshotState();
        _launchWithBuy(t, members, buy);
        assertGt(rules.claimable(quote, protocol), 0, "a 10% share takes its part of the dev buy's Snipe");
        vm.revertToState(snap);
        members[0].rules.protocolShareBps = 0;
        _launchWithBuy(t, members, buy);
    }

    /// @notice An unguarded member (guardEndBlock, Snipe and cap all zero) takes a dev buy (T39): it pays the member's
    ///         Rules legs with no Snipe, its LP fee is every buyer's, it closes no parent block, it logs DevBuyExecuted,
    ///         and the 5% hold bound still holds.
    function test_unguardedMember() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0].rules.guardEndBlock = 0;
        members[0].rules.snipeTaxPips = 0;
        members[0].rules.maxBuyQuoteAmount = 0;
        IHookrLauncher.DevBuy memory big = IHookrLauncher.DevBuy(0, 1e23, 1, 0);
        vm.expectPartialRevert(IHookrLauncher.DevBuyAboveCap.selector);
        launcher.launchWithBuy{value: big.quoteIn}(
            t, address(root), members, new bytes[](1), big, vm.getBlockTimestamp()
        );

        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 2e22, 1, 300);
        uint256 ethBefore = address(this).balance;
        vm.recordLogs();
        (bytes32 family,, uint256 out) = _launchWithBuy(t, members, buy);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(out, 0, "bought");
        assertEq(ethBefore - address(this).balance, buy.quoteIn, "spends exactly the dev buy");
        (uint256 n, uint256 first) = _devBuyLogs(logs);
        assertEq(n, 1, "one DevBuyExecuted");
        (,,,,, uint256 lockedUntil) = abi.decode(logs[first].data, (uint8, uint256, uint256, uint160, uint160, uint256));
        assertEq(lockedUntil, vm.getBlockNumber() + 300, "no guard: the dev buy's own lock");
        assertEq(launcher.principalLockedUntil(family), vm.getBlockNumber() + 300);
        assertEq(_swapsFrom(logs, address(launcher)), 1, "the Launcher sent the one swap");
        uint24 devFee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, devFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        assertLe(IERC20(subject).balanceOf(address(this)), SUPPLY / 20, "at most 5% held");
        // The launch parent block stays open, and the next buyer pays the same LP fee: no Snipe either way.
        PoolKey memory key = launcher.position(family, 0).key;
        IHookrRouter.Swap memory follow = _swap(key, true, true, 1e21);
        vm.recordLogs();
        vm.prank(trader);
        router.swap{value: 1e21}(follow, address(0), new uint256[](0));
        logs = vm.getRecordedLogs();
        uint24 nextFee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, nextFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        assertEq(devFee, nextFee, "the dev buy pays every buyer's LP fee");
        assertLt(devFee, 100_000, "no Snipe");
        assertTrue(rules.accountingInvariant(ETH), "claims backed");
    }

    /// @notice msg.value must be exactly the native member's budget plus the dev buy; a short approval reverts.
    function test_revert_funding() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e21, 1, 0);
        for (uint256 k; k < 2; ++k) {
            vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidFunding.selector));
            launcher.launchWithBuy{value: k == 0 ? buy.quoteIn - 1 : buy.quoteIn + 1}(
                t, address(root), members, new bytes[](1), buy, vm.getBlockTimestamp()
            );
        }
        Currency quote = Currency.wrap(address(tokenB));
        (t, subject) = _newToken(quote, false);
        members = _one(subject, quote);
        tokenB.approve(address(launcher), buy.quoteIn - 1);
        vm.expectRevert();
        launcher.launchWithBuy(t, address(root), members, new bytes[](1), buy, vm.getBlockTimestamp());
        tokenB.approve(address(launcher), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidFamily.selector));
        launcher.launchWithBuy(t, address(root), members, new bytes[](1), buy, vm.getBlockTimestamp() - 1);
    }

    /// @notice The creator holds at most 5% when the launch returns: unplaced supply counts with the dev buy.
    function test_revert_aboveCap() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _devMember(subject, ETH, SUPPLY * 90 / 100);
        vm.expectPartialRevert(IHookrLauncher.DevBuyAboveCap.selector);
        launcher.launchWithBuy{value: 1e18}(
            t, address(root), members, new bytes[](1), IHookrLauncher.DevBuy(0, 1e18, 1, 0), vm.getBlockTimestamp()
        );
        members = _one(subject, ETH);
        members[0].rules.maxBuyQuoteAmount = 1e24;
        vm.expectPartialRevert(IHookrLauncher.DevBuyAboveCap.selector);
        launcher.launchWithBuy{value: 3e23}(
            t, address(root), members, new bytes[](1), IHookrLauncher.DevBuy(0, 3e23, 1, 0), vm.getBlockTimestamp()
        );
        // With the 90% band, a launch without a dev buy keeps its uncapped refund.
        members[0] = _devMember(subject, ETH, SUPPLY * 90 / 100);
        launcher.launch(t, address(root), members, vm.getBlockTimestamp());
        assertGt(IERC20(subject).balanceOf(address(this)), SUPPLY / 10);
    }

    /// @notice A band too small for the buy: with a quote take the root refuses the unauthenticated refund; with none
    ///         the Launcher refuses the partial fill.
    function test_revert_bandTooSmall() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0].rules.maxBuyQuoteAmount = type(uint128).max;
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e27, 1, 0);
        (bool ok, bytes memory ret) = address(launcher).call{value: buy.quoteIn}(
            abi.encodeCall(
                HookrLauncher.launchWithBuy, (t, address(root), members, new bytes[](1), buy, vm.getBlockTimestamp())
            )
        );
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(_hookError(IHooks.afterSwap.selector, "")), "wrapped by the PoolManager");
        assertTrue(
            _contains(ret, abi.encodePacked(IHookrRootState.UnauthenticatedRefund.selector)), "UnauthenticatedRefund"
        );
        members[0].rules.protocolShareBps = 0;
        members[0].rules.burnBps = 0;
        members[0].rules.lpBps = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        vm.expectPartialRevert(IHookrLauncher.DevBuyPartialFill.selector);
        launcher.launchWithBuy{value: buy.quoteIn}(
            t, address(root), members, new bytes[](1), buy, vm.getBlockTimestamp()
        );
    }

    /// @notice A quote whose transfer re-enters the Launcher while the dev buy pays reverts Reentered.
    function test_revert_reentrantQuote() public {
        HookedQuote q = new HookedQuote(address(manager));
        _catalogQuote(address(q));
        q.approve(address(launcher), type(uint256).max);
        q.arm(address(new Reenterer(launcher)));
        Currency quote = Currency.wrap(address(q));
        (IHookrLauncher.Token memory t, address subject) = _newToken(quote, true);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.Reentered.selector));
        launcher.launchWithBuy(
            t,
            address(root),
            _one(subject, quote),
            new bytes[](1),
            IHookrLauncher.DevBuy(0, 1e21, 1, 0),
            vm.getBlockTimestamp()
        );
    }

    /// @notice A quote that swaps on the new pool while the add pays it moves the price before the dev buy, which then
    ///         refuses: the dev buy is always priced from the launch price.
    function test_revert_swapBeforeTheDevBuy() public {
        HookedQuote q = new HookedQuote(address(manager));
        _catalogQuote(address(q));
        q.approve(address(launcher), type(uint256).max);
        PreBuyer pre = new PreBuyer(manager);
        q.transfer(address(pre), 1e22);
        Currency quote = Currency.wrap(address(q));
        pre.fund(quote, 1e22);
        // The subject sorts first, so the add pays it before the quote, and a band straddling price 1 takes both: the
        // quote's transfer into the PoolManager runs its hook inside the Launcher's unlock, after the add.
        (IHookrLauncher.Token memory t, address subject) = _newToken(quote, true);
        IHookrLauncher.Member[] memory members = _one(subject, quote);
        members[0].tickLower = -60_000;
        members[0].tickUpper = 60_000;
        members[0].liquidity =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_ONE, TickMath.getSqrtPriceAtTick(60_000), SUPPLY) / 1000 * 999;
        members[0].amount0Max = uint128(SUPPLY);
        members[0].amount1Max = uint128(2 * SUPPLY);
        PoolKey memory key =
            PoolKey(Currency.wrap(subject), quote, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        pre.aim(key);
        q.arm(address(pre));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidDevBuy.selector));
        launcher.launchWithBuy(
            t, address(root), members, new bytes[](1), IHookrLauncher.DevBuy(0, 1e21, 1, 0), vm.getBlockTimestamp()
        );
        // Unarmed, the same straddling launch fills (its unplaced subject is within the cap).
        q.arm(address(0));
        (,, uint256 out) = launcher.launchWithBuy(
            t, address(root), members, new bytes[](1), IHookrLauncher.DevBuy(0, 1e21, 1, 0), vm.getBlockTimestamp()
        );
        assertGt(out, 0);
    }

    /// @notice unlockCallback runs only for the pending change it was armed with.
    function test_revert_callback() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidCallback.selector));
        launcher.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidCallback.selector));
        launcher.unlockCallback(abi.encode(uint256(1)));
        assertEq(PoolId.unwrap(launcher.launchBuyPool()), bytes32(0), "no launch buy outside launchWithBuy");
    }

    // ------------------------------------------------------------------------------------------------ fuzz

    /// @dev A dynamic fee member's maxFeePips at `sens` and `share`: a 4.7% span over the 3,000 base, or the widest the
    ///      reach bound admits there (HookrDynamicFee.withinReach) where that is smaller.
    function _dynamicMaxFee(uint8 sens, uint16 share) internal pure returns (uint24) {
        uint256 widest = RulesData.maxDynamicFeeSpan(sens, share, 3000);
        return uint24(3000 + (widest < 47_000 ? widest : 47_000));
    }

    /// @notice Over buy sizes, launch prices, bands, Snipe and decay, Auto Burn, LP Rewards, shares, dynamic fees and
    ///         sort orders, a launch either reverts with a dev-buy bound or delivers `out` to the caller, spends exactly
    ///         the buy, leaves nothing in the Launcher, backs every Rules claim and leaves the dynamic fee state
    ///         unstarted.
    function testFuzz_devBuy(
        uint128 quoteIn,
        int16 tickSeed,
        uint16 widthSeed,
        uint24 snipe,
        uint16 decay,
        uint16 burn,
        uint16 lp,
        uint16 share,
        uint8 sens,
        bool subjectFirst,
        bool native
    ) public {
        quoteIn = uint128(bound(quoteIn, 1e9, 5e22));
        int24 tick = int24(int256(bound(tickSeed, -100, 100))) * 60;
        int24 width = int24(int256(bound(widthSeed, 20, 1000))) * 60;
        Currency quote = native ? ETH : Currency.wrap(address(tokenB));
        (IHookrLauncher.Token memory t, address subject) = _newToken(quote, subjectFirst);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _devMemberAt(subject, quote, SUPPLY, tick, width);
        IHookrLauncher.Member memory m = members[0];
        m.rules.snipeTaxPips = uint24(bound(snipe, 1, 250_000));
        m.rules.snipeDecaySeconds = uint16(bound(decay, 0, 3600));
        m.rules.snipeFloorPips = m.rules.snipeDecaySeconds == 0 ? 0 : m.rules.snipeTaxPips / 2;
        m.rules.burnBps = uint16(bound(burn, 0, 300));
        m.rules.lpBps = uint16(bound(lp, 0, 300));
        m.rules.royaltyBps = m.rules.lpBps == 0 ? 0 : 500;
        m.rules.royaltyTo = m.rules.lpBps == 0 ? address(0) : royalty;
        m.rules.protocolShareBps = uint16(bound(share, 0, 5000));
        sens = uint8(bound(sens, 0, 10));
        if (sens != 0) {
            m.rules.maxFeePips = _dynamicMaxFee(sens, m.rules.protocolShareBps);
            m.rules.dynamicFeeSens = sens;
        }
        uint256 quoteBefore = _bal(quote);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, quoteIn, 1, 0);
        try launcher.launchWithBuy{value: native ? quoteIn : 0}(
            t, address(root), members, new bytes[](1), buy, vm.getBlockTimestamp()
        ) returns (
            bytes32 family, address, uint256 out
        ) {
            uint256 held = IERC20(subject).balanceOf(address(this));
            assertGe(out, 1, "at least minSubjectOut");
            assertGe(held, out, "delivered");
            assertLe(held, SUPPLY / 20, "at most 5% held");
            assertEq(quoteBefore - _bal(quote), quoteIn, "spends exactly the buy");
            assertEq(IERC20(subject).balanceOf(address(launcher)), 0, "no subject at rest");
            assertEq(
                Currency.unwrap(quote) == address(0) ? address(launcher).balance : tokenB.balanceOf(address(launcher)),
                0
            );
            assertTrue(rules.accountingInvariant(quote), "claims backed");
            (, int24 ref, int24 anchor, uint40 movedAt, uint40 referenceAt, int24 moved) =
                rules.referenceState(_id(family, 0));
            assertEq(movedAt, 0, "dynamic fee state not started");
            assertEq(referenceAt, 0, "dynamic fee state not started");
            assertEq(ref, 0, "no reference");
            assertEq(anchor, 0, "no anchor");
            assertEq(moved, 0, "no moved tick");
        } catch (bytes memory err) {
            bytes4 s = bytes4(err);
            assertTrue(
                s == IHookrLauncher.DevBuyAboveCap.selector || s == IHookrLauncher.DevBuySlippage.selector
                    || s == IHookrLauncher.DevBuyPartialFill.selector
                    || s == bytes4(_hookError(IHooks.afterSwap.selector, "")),
                "only a dev-buy bound refuses"
            );
        }
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (haystack.length < needle.length) return false;
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            bool matched = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
