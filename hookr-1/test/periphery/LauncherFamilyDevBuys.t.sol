// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {LauncherFamilyFixture} from "./LauncherFamily.t.sol";

/// @notice launchFamily's dev buys: up to one per member, each run right after its member's add, all of them inside
///         one 5% hold bound with the unplaced supply, each paying its member's guard.
contract LauncherFamilyDevBuysTest is LauncherFamilyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant LAUNCHED_TOPIC = IHookrLauncher.MemberLaunched.selector;

    Currency[8] internal quotes;

    function setUp() public {
        _setUpPeriphery();
        quotes[0] = ETH;
        quotes[1] = Currency.wrap(address(tokenA));
        quotes[2] = Currency.wrap(address(tokenB));
        for (uint256 i = 3; i < 8; ++i) {
            HookrToken q = new HookrToken("Q", "Q", 1e30, address(this));
            q.approve(address(launcher), type(uint256).max);
            _catalogQuote(address(q));
            quotes[i] = Currency.wrap(address(q));
        }
    }

    /// @dev A new token with `n` guarded members, each holding SUPPLY / n of subject, in quotes[0..n).
    function _family(uint256 n) internal returns (IHookrLauncher.LaunchParams memory p, address subject) {
        IHookrLauncher.Token memory t;
        (t, subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](n);
        for (uint256 i; i < n; ++i) {
            members[i] = _devMember(subject, quotes[i], SUPPLY / n);
        }
        p = _params(t, members);
    }

    function _buys(IHookrLauncher.LaunchParams memory p, uint256 n, uint128 quoteIn, uint32 lockStep)
        internal
        pure
        returns (IHookrLauncher.LaunchParams memory)
    {
        p.buys = new IHookrLauncher.DevBuy[](n);
        for (uint256 k; k < n; ++k) {
            // Buys listed last member first: their order in `buys` does not set the order they run in.
            p.buys[k] = IHookrLauncher.DevBuy(uint8(n - 1 - k), quoteIn, 1, uint32(k) * lockStep);
        }
        return p;
    }

    function _balance(Currency c) internal view returns (uint256) {
        return
            Currency.unwrap(c) == address(0)
                ? address(this).balance
                : IERC20(Currency.unwrap(c)).balanceOf(address(this));
    }

    /// @dev DevBuyExecuted's data.
    struct BuyLog {
        uint8 member;
        uint256 quoteIn;
        uint256 subjectOut;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceAfterX96;
        uint256 lockedUntil;
    }

    /// @dev One DevBuyExecuted: member `member`'s buy of 1e21 on its own pool; returns its subject.
    function _buyLog(Vm.Log memory log, bytes32 family, uint256 member) internal view returns (uint256) {
        BuyLog memory b = abi.decode(log.data, (BuyLog));
        assertEq(b.member, member, "member order");
        assertEq(b.quoteIn, 1e21);
        assertEq(log.topics[2], PoolId.unwrap(_id(family, b.member)), "its own pool");
        return b.subjectOut;
    }

    /// @dev Eight DevBuyExecuted logs in member order, each for its own member's pool and right before that member's
    ///      MemberLaunched, whose subject sums to `out`.
    function _checkBuyLogs(Vm.Log[] memory logs, bytes32 family, uint256 out) internal view {
        uint256 sum;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launcher)) continue;
            if (logs[i].topics[0] == DEV_BUY_TOPIC) {
                sum += _buyLog(logs[i], family, seen++);
            } else if (logs[i].topics[0] == LAUNCHED_TOPIC) {
                (uint8 member,,) = abi.decode(logs[i].data, (uint8, address, uint128));
                assertEq(member + 1, seen, "a member's buy comes right before its MemberLaunched");
            }
        }
        assertEq(seen, 8, "eight dev buys");
        assertEq(sum, out, "the return is the sum of the buys");
    }

    function _balances() internal view returns (uint256[8] memory before) {
        for (uint256 i; i < 8; ++i) {
            before[i] = _balance(quotes[i]);
        }
    }

    /// @dev Each member spent exactly its 1e21 dev buy, moved, keeps its claims backed and paid its Snipe's share.
    function _checkMembers(bytes32 family, uint256[8] memory before) internal view {
        for (uint8 i; i < 8; ++i) {
            assertEq(before[i] - _balance(quotes[i]), 1e21, "each buy spends exactly its quoteIn");
            assertTrue(_price(family, i) != SQRT_ONE, "each member moved");
            assertTrue(rules.accountingInvariant(quotes[i]), "claims backed");
            assertGt(rules.claimable(quotes[i], protocol), 0, "each buy paid its member's Snipe share");
        }
    }

    /// @notice A dev buy on every member of an eight-member family: each runs right after its own member's add, in
    ///         member order whatever their order in `buys`, logs its DevBuyExecuted right before its member's
    ///         MemberLaunched, spends exactly its quoteIn, moves its own member's price and pays its member's Snipe. The
    ///         return is the sum of the buys, the creator ends at most at 5% of supply and the family stays locked until
    ///         the latest dev buy lock.
    function test_devBuyOnEveryMemberOfEightMembers() public {
        (IHookrLauncher.LaunchParams memory p, address subject) = _family(8);
        uint256[8] memory before = _balances();
        vm.recordLogs();
        (bytes32 family,, uint256 out) = _launchFamily(_buys(p, 8, 1e21, 1_000));
        _checkBuyLogs(vm.getRecordedLogs(), family, out);
        _checkMembers(family, before);
        uint256 held = IERC20(subject).balanceOf(address(this));
        assertGe(held, out);
        assertLe(held, SUPPLY / 20, "at most 5% held");
        assertEq(launcher.principalLockedUntil(family), vm.getBlockNumber() + 7_000, "the latest dev buy lock");
    }

    /// @notice Each dev buy closes its own member's launch parent block to every other buy.
    function test_devBuysCloseEachLaunchBlock() public {
        (IHookrLauncher.LaunchParams memory p,) = _family(3);
        (bytes32 family,,) = _launchFamily(_buys(p, 3, 1e21, 0));
        for (uint8 i = 1; i < 3; ++i) {
            IHookrRouter.Swap memory buy = _swap(launcher.position(family, i).key, true, true, 1e18);
            _capRefused(trader, buy, 0);
        }
    }

    /// @notice The dev buys share one 5% bound with the unplaced supply: two buys that each fit alone together pass it.
    function test_devBuysShareOneHoldBound() public {
        (IHookrLauncher.LaunchParams memory p, address subject) = _family(2);
        p = _buys(p, 1, 6e22, 0);
        uint256 snap = vm.snapshotState();
        (,, uint256 one) = _launchFamily(p);
        uint256 heldOne = IERC20(subject).balanceOf(address(this));
        assertLe(heldOne, SUPPLY / 20);
        vm.revertToState(snap);
        p = _buys(p, 2, 6e22, 0);
        uint256 value = _value(p);
        vm.expectPartialRevert(IHookrLauncher.DevBuyAboveCap.selector);
        launcher.launchFamily{value: value}(p);
        assertGt(one * 2, SUPPLY / 20 - (heldOne - one), "two such buys pass the bound");
    }

    /// @notice A retained cap stricter than the dev buy bound refuses first with RetainedAboveCap; a looser one lets
    ///         the dev buy bound refuse with DevBuyAboveCap.
    function test_devBuysAndTheRetainedCap() public {
        (IHookrLauncher.LaunchParams memory p,) = _family(2);
        p = _buys(p, 2, 1e22, 0);
        uint256 snap = vm.snapshotState();
        (,, uint256 out) = _launchFamily(p);
        vm.revertToState(snap);
        assertGt(out, 0);
        p.maxRetainedBps = 1;
        _refuseWith(p, IHookrLauncher.RetainedAboveCap.selector);
        p = _buys(p, 2, 8e22, 0);
        p.maxRetainedBps = 9_000;
        _refuseWith(p, IHookrLauncher.DevBuyAboveCap.selector);
    }

    /// @dev `p` with two dev buys: member 1's and `second`.
    function _twoBuys(IHookrLauncher.LaunchParams memory p, IHookrLauncher.DevBuy memory second)
        internal
        pure
        returns (IHookrLauncher.LaunchParams memory)
    {
        p.buys = new IHookrLauncher.DevBuy[](2);
        p.buys[0] = IHookrLauncher.DevBuy(1, 1e21, 1, 0);
        p.buys[1] = second;
        return p;
    }

    /// @notice Each dev buy is checked as launchWithBuy checks its one, and a member takes at most one.
    function test_devBuyRefusals() public {
        bytes memory err = abi.encodeWithSelector(IHookrLauncher.InvalidDevBuy.selector);
        (IHookrLauncher.LaunchParams memory p,) = _family(3);
        _refuse(_twoBuys(p, IHookrLauncher.DevBuy(1, 1e21, 1, 0)), err);
        _refuse(_twoBuys(p, IHookrLauncher.DevBuy(3, 1e21, 1, 0)), err);
        _refuse(_twoBuys(p, IHookrLauncher.DevBuy(2, 0, 1, 0)), err);
        _refuse(_twoBuys(p, IHookrLauncher.DevBuy(2, 1e21, 0, 0)), err);
        _refuse(_twoBuys(p, IHookrLauncher.DevBuy(2, 1e21, 1, 2_628_001)), err);
        _refuse(_twoBuys(p, IHookrLauncher.DevBuy(2, CAP + 1, 1, 0)), err);
    }

    /// @notice A guarded dev buy member needs a Snipe, and an existing token takes no dev buy.
    function test_devBuyMemberRefusals() public {
        bytes memory err = abi.encodeWithSelector(IHookrLauncher.InvalidDevBuy.selector);
        (IHookrLauncher.LaunchParams memory p,) = _family(3);
        p = _twoBuys(p, IHookrLauncher.DevBuy(2, 1e21, 1, 0));
        p.members[2].rules.snipeTaxPips = 0;
        _refuse(p, err);
        (p,) = _family(3);
        p = _twoBuys(p, IHookrLauncher.DevBuy(2, 1e21, 1, 0));
        p.token = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        _refuse(p, err);
    }

    /// @notice T39 in a family: a dev buy on an unguarded member runs beside one on a guarded member; the unguarded one
    ///         closes nothing, and both count toward the one 5% bound.
    function test_devBuyOnAnUnguardedMember() public {
        (IHookrLauncher.LaunchParams memory p, address subject) = _family(2);
        p.members[1].rules.guardEndBlock = 0;
        p.members[1].rules.snipeTaxPips = 0;
        p.members[1].rules.maxBuyQuoteAmount = 0;
        p = _buys(p, 2, 1e21, 0);
        vm.recordLogs();
        (bytes32 family,, uint256 out) = _launchFamily(p);
        uint256 seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launcher) && logs[i].topics[0] == DEV_BUY_TOPIC) ++seen;
        }
        assertEq(seen, 2, "both dev buys ran");
        assertLe(IERC20(subject).balanceOf(address(this)), SUPPLY / 20, "one 5% bound");
        assertGe(IERC20(subject).balanceOf(address(this)), out);
        // The guarded member's launch parent block is closed; the unguarded member's is open.
        IHookrRouter.Swap memory guarded = _swap(launcher.position(family, 0).key, true, true, 1e18);
        _capRefused(trader, guarded, 1e18);
        IHookrRouter.Swap memory open = _swap(launcher.position(family, 1).key, true, true, 1e18);
        vm.prank(trader);
        router.swap(open, address(0), new uint256[](0));
    }

    /// @notice A dev buy's minimum is its own: one buy short of its minSubjectOut reverts the launch.
    function test_devBuySlippageIsPerBuy() public {
        (IHookrLauncher.LaunchParams memory p,) = _family(2);
        p = _buys(p, 2, 1e21, 0);
        p.buys[1].minSubjectOut = type(uint128).max;
        _refuseWith(p, IHookrLauncher.DevBuySlippage.selector);
    }
}
