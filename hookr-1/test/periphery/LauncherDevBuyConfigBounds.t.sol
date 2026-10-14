// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";

/// @notice A creator contract: a plain launch, then a router buy on the new pool in the same transaction.
contract AtomicFirstBuyer {
    function run(
        HookrLauncher launcher,
        HookrRouter router,
        address rootAddress,
        IHookrLauncher.Token calldata t,
        IHookrLauncher.Member[] calldata members,
        IHookrRouter.Swap memory follow
    ) external payable {
        launcher.launch(t, rootAddress, members, block.timestamp);
        follow.key.currency1 = Currency.wrap(launcher.predictToken(address(this), t));
        router.swap{value: uint128(-follow.amountSpecified)}(follow, address(0), new uint256[](0));
    }

    receive() external payable {}
}

/// @notice DBC-1 to DBC-4: what the dev-buy limits admit and what they then deliver. DBC-1 and DBC-4 are closed and
///         tested here; the rest is pinned as known limits (README, "Open before deploy"), and a change that closes one
///         must update its test.
contract LauncherDevBuyConfigBoundsTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;

    Currency internal constant ETH = Currency.wrap(address(0));
    /// @dev HookrRules' erc7201 root; the guard counter mapping is its fourth field.
    bytes32 internal constant RULES_SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    uint256 internal constant GUARD_MASK = (uint256(1) << 192) - 1;

    function setUp() public {
        _setUpPeriphery();
    }

    function _lastLpFee(Vm.Log[] memory logs) internal view returns (uint24 lpFee) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, lpFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    function _earned(Vm.Log[] memory logs) internal view returns (uint256 earned, bool seen) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(root) && logs[i].topics[0] == HOOK_FEE_TOPIC) {
                (earned,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                seen = true;
            }
        }
    }

    /// @dev The DBC-1 member: guarded for one parent block, no LP Rewards, Auto Burn or royalty.
    function _oneBlockMember(address subject, uint24 snipe, uint16 share)
        internal
        view
        returns (IHookrLauncher.Member[] memory members)
    {
        members = _one(subject, ETH);
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 1);
        members[0].rules.snipeTaxPips = snipe;
        members[0].rules.burnBps = 0;
        members[0].rules.lpBps = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.protocolShareBps = share;
    }

    function _guardWord(PoolKey memory key) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(key.toId()), uint256(RULES_SLOT) + 3));
        return uint256(vm.load(address(rules), slot));
    }

    /// @notice DBC-1. A zero-Snipe dev-buy member is refused, so the dev buy always pays a Snipe. With one, at a 10%
    ///         partner share, the protocol takes 10% of it and the creator's round trip is no longer free.
    function test_zeroSnipeDevBuyMemberIsRefused() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 4e22, 1, 0);
        IHookrLauncher.Member[] memory members = _oneBlockMember(subject, 0, 2_000);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidDevBuy.selector));
        launcher.launchWithBuy{value: buy.quoteIn}(
            t, address(root), members, new bytes[](1), buy, vm.getBlockTimestamp()
        );

        members = _oneBlockMember(subject, 100_000, 1_000);
        uint256 ethBefore = address(this).balance;
        vm.recordLogs();
        (bytes32 family,, uint256 out) = _launchWithBuy(t, members, buy);
        (uint256 earned, bool seen) = _earned(vm.getRecordedLogs());
        assertTrue(seen, "the dev buy ran through the root");
        assertGt(out, 0, "bought");
        // 10% of a 10% Snipe: 1% of quoteIn.
        uint256 take = uint256(buy.quoteIn) / 100;
        assertApproxEqRel(rules.claimable(ETH, protocol), take, 1e15, "the protocol takes its share of the Snipe");
        assertEq(earned, rules.claimable(ETH, protocol), "as the dev buy's quote take");

        vm.roll(vm.getBlockNumber() + 1);
        uint128 liquidity = launcher.position(family, 0).liquidity;
        launcher.withdraw(family, 0, liquidity, 0, 0, address(this), vm.getBlockTimestamp());
        assertLe(address(this).balance + take * 999 / 1000, ethBefore, "the round trip costs the creator the take");
    }

    /// @notice DBC-1, known limit. The dev-buy member's guard may end one parent block after launch. The dev buy pays
    ///         its Snipe, but it closes that block, so public buyers never trade under the guard: in the next parent
    ///         block a buy of three times the launch cap clears at the base fee.
    function test_pinned_oneBlockGuardLeavesPublicBuyersNoGuardedBlock() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        (bytes32 family,,) =
            _launchWithBuy(t, _oneBlockMember(subject, 100_000, 1_000), IHookrLauncher.DevBuy(0, 4e22, 1, 0));
        PoolKey memory key = launcher.position(family, 0).key;
        IHookrRouter.Swap memory tiny = _swap(key, true, true, 1e15);
        _capRefused(trader, tiny, 1e15);

        vm.roll(vm.getBlockNumber() + 1);
        IHookrRouter.Swap memory big = _swap(key, true, true, 3 * CAP);
        vm.recordLogs();
        vm.prank(trader);
        router.swap{value: 3 * CAP}(big, address(0), new uint256[](0));
        assertEq(_lastLpFee(vm.getRecordedLogs()), 3000, "public buyer: no guard, no Snipe, no cap");
    }

    /// @notice DBC-1, known limit. The protocol's part of the Snipe is rounded down in pips: a 9-pip Snipe at a 10%
    ///         share takes nothing. The creator's Snipe sets the protocol's take on a dev buy.
    function test_pinned_tinySnipeTakesNothing() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        _launchWithBuy(t, _oneBlockMember(subject, 9, 1_000), IHookrLauncher.DevBuy(0, 4e22, 1, 0));
        assertEq(rules.claimable(ETH, protocol), 0, "9 pips x 10% rounds to zero");
    }

    /// @notice DBC-3. lockBlocks holds the principal, not the dev buy's LP fee parts: at the maximum Snipe and a year's
    ///         lockBlocks, the event reports the lock, withdrawing liquidity is refused, and the LP fee parts (the base
    ///         fee and the Snipe net of the protocol share) are collectable in the launch block, as README and
    ///         DevBuyExecuted now say.
    function test_lockBlocksHoldsThePrincipalNotTheFees() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0].rules.snipeTaxPips = 597_000;
        members[0].rules.burnBps = 0;
        members[0].rules.lpBps = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.protocolShareBps = 2_000;
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 4e22, 1, 2_628_000);
        uint256 b = vm.getBlockNumber();
        vm.recordLogs();
        (bytes32 family,,) = _launchWithBuy(t, members, buy);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 n, uint256 first) = _devBuyLogs(logs);
        assertEq(n, 1);
        (,,,,, uint256 lockedUntil) = abi.decode(logs[first].data, (uint8, uint256, uint256, uint160, uint160, uint256));
        assertEq(lockedUntil, b + 2_628_000, "the event reports the principal's one-year lock");

        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PrincipalLocked.selector, family, 0, b + 2_628_000));
        launcher.withdraw(family, 0, 1, 0, 0, address(this), vm.getBlockTimestamp());
        (uint256 fee0,) = launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        uint256 take = uint256(buy.quoteIn) * (597_000 * 2_000 / 10_000) / 1_000_000;
        uint256 lpFee = (buy.quoteIn - take) * (3000 + 597_000 * 8_000 / 10_000) / 1_000_000;
        emit log_named_uint("LP fee parts out in the launch block (bps of quoteIn)", fee0 * 10_000 / buy.quoteIn);
        assertApproxEqRel(fee0, lpFee, 1e15, "the LP fee parts are fees, collectable at once");
    }

    /// @notice DBC-4. A Snipe that decays to a zero floor inside the launch parent block used to lift the cap there, so
    ///         a public buy cleared in the parent block the dev buy closed, and the closure marker plus that buy
    ///         overflowed the guard counter into its block field. At a zero tax the cap is now the counter's width:
    ///         the launch parent block stays closed, the word keeps its block, and the next parent block has no cap.
    function test_zeroFloorDecayKeepsTheLaunchParentBlockClosed() public {
        vm.roll(100);
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0].rules.snipeDecaySeconds = 1;
        members[0].rules.snipeFloorPips = 0;
        (bytes32 family,,) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, 2e22, 1, 0));
        PoolKey memory key = launcher.position(family, 0).key;
        uint256 b = vm.getBlockNumber();

        IHookrRouter.Swap memory tiny = _swap(key, true, true, 1e15);
        _capRefused(trader, tiny, 1e15);

        // One second later, same parent block: the tax is zero and the block is still closed.
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(vm.getBlockNumber(), b, "still the launch parent block");
        IHookrRouter.Swap memory big = _swap(key, true, true, 3 * CAP);
        _capRefused(trader, big, 3 * CAP);
        uint256 word = _guardWord(key);
        assertEq(word >> 192, b, "the guard word keeps its parent block");
        assertEq(word & GUARD_MASK, GUARD_MASK, "and the closure");

        // The next parent block has no cap at a zero tax.
        vm.roll(b + 1);
        uint256 before = IERC20(subject).balanceOf(trader);
        vm.prank(trader);
        router.swap{value: 3 * CAP}(big, address(0), new uint256[](0));
        assertGt(IERC20(subject).balanceOf(trader), before, "a buy of 3x the cap clears in the next parent block");
        word = _guardWord(key);
        assertEq(word >> 192, b + 1, "counted in its own parent block");
        assertLe(word & GUARD_MASK, 3 * CAP, "within the counter");
    }

    /// @notice DBC-2, known limit. The 5% cap and the DevBuyExecuted label bind only launchWithBuy. A creator contract
    ///         that calls the plain launch and then the router in the same transaction gets the same first fill at the
    ///         launch price, here on an unguarded member and uncapped: over 30% of supply. Its Swap's sender is the
    ///         router, so only the FamilyLaunched transaction and the family owner identify it as the creator's buy.
    function test_pinned_plainLaunchPlusSameTxRouterBuyIsUncappedAndUnlabelled() public {
        AtomicFirstBuyer buyer = new AtomicFirstBuyer();
        vm.deal(address(buyer), 1e25);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Dev", "DEV", SUPPLY, bytes32(uint256(99)));
        address subject = launcher.predictToken(address(buyer), t);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0].rules.guardEndBlock = 0;
        members[0].rules.snipeTaxPips = 0;
        members[0].rules.maxBuyQuoteAmount = 0;
        PoolKey memory key =
            PoolKey(ETH, Currency.wrap(subject), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        IHookrRouter.Swap memory follow =
            IHookrRouter.Swap(key, true, -int128(5e23), 1, MIN_PRICE, address(buyer), vm.getBlockTimestamp());
        vm.recordLogs();
        buyer.run(launcher, router, address(root), t, members, follow);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 held = IERC20(subject).balanceOf(address(buyer));
        emit log_named_uint("creator share of supply after the launch transaction (bps)", held * 10_000 / SUPPLY);
        assertGt(held, SUPPLY * 3 / 10, "over 30% of supply bought at the launch price in the launch transaction");
        (uint256 n,) = _devBuyLogs(logs);
        assertEq(n, 0, "no DevBuyExecuted");
        assertEq(_swapsFrom(logs, address(launcher)), 0, "no Launcher-sent Swap");
        assertEq(_swapsFrom(logs, address(router)), 1, "the first swap is an ordinary router Swap");
    }

    /// @notice DBC-2 with T39. The creator's first fill on an unguarded member can be the dev buy instead: the same
    ///         member as the pinned case above, through launchWithBuy, is bounded by the 5% hold and labelled. The
    ///         uncapped plain-launch buy stays possible (pinned above); the dev buy is the creator's labelled route.
    function test_unguardedDevBuyIsCappedAndLabelled() public {
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Dev", "DEV", SUPPLY, bytes32(uint256(97)));
        address subject = launcher.predictToken(address(this), t);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0].rules.guardEndBlock = 0;
        members[0].rules.snipeTaxPips = 0;
        members[0].rules.maxBuyQuoteAmount = 0;
        IHookrLauncher.DevBuy memory over = IHookrLauncher.DevBuy(0, 5e23, 1, 0);
        vm.expectPartialRevert(IHookrLauncher.DevBuyAboveCap.selector);
        launcher.launchWithBuy{value: over.quoteIn}(
            t, address(root), members, new bytes[](1), over, vm.getBlockTimestamp()
        );
        vm.recordLogs();
        (,, uint256 out) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, 3e22, 1, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 n,) = _devBuyLogs(logs);
        assertEq(n, 1, "labelled DevBuyExecuted");
        assertEq(_swapsFrom(logs, address(launcher)), 1, "a Launcher-sent Swap");
        assertGt(out, 0);
        assertLe(IERC20(subject).balanceOf(address(this)), SUPPLY / 20, "within the 5% hold");
    }

    /// @notice DBC-2, known limit. On a guarded member the same-transaction router buy pays the guard like any buyer:
    ///         a buy above the per-block cap is refused, and one within it pays the full Snipe with its protocol share.
    function test_pinned_sameTxRouterBuyPaysTheGuard() public {
        AtomicFirstBuyer buyer = new AtomicFirstBuyer();
        vm.deal(address(buyer), 1e25);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Dev", "DEV", SUPPLY, bytes32(uint256(98)));
        address subject = launcher.predictToken(address(buyer), t);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        PoolKey memory key =
            PoolKey(ETH, Currency.wrap(subject), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        IHookrRouter.Swap memory follow =
            IHookrRouter.Swap(key, true, -int128(2 * CAP), 1, MIN_PRICE, address(buyer), vm.getBlockTimestamp());
        (bool ok, bytes memory ret) = address(buyer)
            .call(abi.encodeCall(AtomicFirstBuyer.run, (launcher, router, address(root), t, members, follow)));
        _capRefusal(ok, ret);

        follow.amountSpecified = -int128(CAP);
        vm.recordLogs();
        buyer.run(launcher, router, address(root), t, members, follow);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(_lastLpFee(logs), 3000 + 500_000 / 2, "the full Snipe, net of the protocol share, in the LP fee");
        assertGt(rules.claimable(ETH, protocol), 0, "the protocol share");
        (uint256 n,) = _devBuyLogs(logs);
        assertEq(n, 0, "no DevBuyExecuted");
    }
}
