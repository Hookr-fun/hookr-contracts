// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrLpBoost} from "../../src/periphery/HookrLpBoost.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrLpBoost} from "../../src/interfaces/IHookrLpBoost.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {IPositionManagerMinimal} from "../../src/interfaces/external/IPositionManagerMinimal.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {LpBoostFixture, NoopSubscriber} from "./LpBoostFixture.sol";

/// @notice A PositionManager stand-in reporting another PoolManager, for the constructor's wiring check.
contract OtherManagerPositionManager {
    function poolManager() external pure returns (address) {
        return address(0xdead);
    }
}

/// @notice Every HookrLpBoost entry and refusal: inert before ACTIVATE, the reward-token list, the supply bounds,
///         both gauge creation paths and the sizing rule, notify and fund, stake verification, the boost at its bounds,
///         accrual, the maturity drop exact at the week boundary, extension, withdrawal, claims, fee collection, the
///         brakes and the queued unpauses.
contract HookrLpBoostTest is LpBoostFixture {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q128 = 1 << 128;

    // ------------------------------------------------------------------------------------------------------------
    // Construction and inertness
    // ------------------------------------------------------------------------------------------------------------

    function test_constructor_pinsWiring() public view {
        assertEq(address(boost.poolManager()), Chain4663Code.POOL_MANAGER_ADDRESS);
        assertEq(address(boost.positionManager()), Chain4663Code.POSITION_MANAGER_ADDRESS);
        assertEq(boost.positionManagerCodeHash(), POSITION_MANAGER_CODE_HASH);
        assertEq(Chain4663Code.POSITION_MANAGER_ADDRESS.codehash, POSITION_MANAGER_CODE_HASH);
        assertEq(keccak256(Chain4663Code.POSITION_MANAGER), POSITION_MANAGER_CODE_HASH);
        assertEq(address(boost.registry()), address(registry));
        assertEq(address(boost.launcher()), address(launcher));
        assertEq(boost.owner(), gov);
        assertEq(boost.delay(), DELAY);
        assertEq(boost.WEEK(), 7 days);
        assertEq(boost.MAX_LOCK_WEEKS(), 104);
        assertEq(boost.MAX_BOOST_BPS(), 30_000);
        assertEq(boost.MAX_PERIOD_WEEKS(), 52);
        assertEq(boost.MIN_LIQUIDITY(), 1_000_000);
        assertEq(boost.NATIVE_SUPPLY_BOUND(), 2 ** 96);
        assertEq(boost.ACTIVATE(), keccak256("ACTIVATE"));
        assertEq(boost.ADD_REWARD_TOKEN(), keccak256("ADD_REWARD_TOKEN"));
        assertEq(boost.SET_SUPPLY_BOUND(), keccak256("SET_SUPPLY_BOUND"));
        assertEq(boost.hookrTokenCodeHash(), address(subject).codehash);
        assertEq(boost.CREATE_GAUGE(), keccak256("CREATE_GAUGE"));
        assertEq(boost.UNPAUSE(), keccak256("UNPAUSE"));
        assertEq(boost.UNPAUSE_ALL(), keccak256("UNPAUSE_ALL"));
        assertEq(boost.releaseId(), 1);
    }

    function test_constructor_refusesBadWiring() public {
        IHookrRegistry r = IHookrRegistry(address(registry));
        IHookrLauncherView l = IHookrLauncherView(address(launcher));
        IPositionManagerMinimal p = IPositionManagerMinimal(address(posm));
        vm.expectRevert(IHookrLpBoost.InvalidWiring.selector);
        new HookrLpBoost(IHookrRegistry(makeAddr("noCode")), l, p, gov, DELAY);
        vm.expectRevert(IHookrLpBoost.InvalidWiring.selector);
        new HookrLpBoost(r, IHookrLauncherView(makeAddr("noCode")), p, gov, DELAY);
        vm.expectRevert(IHookrLpBoost.InvalidWiring.selector);
        new HookrLpBoost(r, l, IPositionManagerMinimal(makeAddr("noCode")), gov, DELAY);
        address other = address(new OtherManagerPositionManager());
        vm.expectRevert(IHookrLpBoost.InvalidWiring.selector);
        new HookrLpBoost(r, l, IPositionManagerMinimal(other), gov, DELAY);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidDelay.selector, uint48(1)));
        new HookrLpBoost(r, l, p, gov, 1);
    }

    function test_inactive_everyGaugeEntryReverts() public {
        HookrLpBoost fresh = _deployBoost();
        assertFalse(fresh.active());
        uint256[] memory none = new uint256[](0);
        bytes4 inactive = IHookrLpBoost.Inactive.selector;
        vm.startPrank(gov);
        vm.expectRevert(inactive);
        fresh.addRewardToken(address(reward));
        vm.expectRevert(inactive);
        fresh.removeRewardToken(address(reward));
        vm.expectRevert(inactive);
        fresh.setSupplyBound(address(reward), 1e30);
        vm.expectRevert(inactive);
        fresh.removeSupplyBound(address(reward));
        vm.expectRevert(inactive);
        fresh.pause(id);
        vm.expectRevert(inactive);
        fresh.pauseAll();
        vm.expectRevert(inactive);
        fresh.unpause(id);
        vm.expectRevert(inactive);
        fresh.unpauseAll();
        vm.expectRevert(inactive);
        fresh.notify(id, 0, 1);
        vm.stopPrank();
        vm.expectRevert(inactive);
        fresh.createGauge(key, _terms(4, 52, 30_000));
        vm.expectRevert(inactive);
        fresh.fund(id, 1, 1);
        vm.expectRevert(inactive);
        fresh.stake(1, 4);
        vm.expectRevert(inactive);
        fresh.extend(1, 4);
        vm.expectRevert(inactive);
        fresh.withdraw(1, alice);
        vm.expectRevert(inactive);
        fresh.claim(id, none, alice);
        vm.expectRevert(inactive);
        fresh.collectFees(1, alice);
        vm.expectRevert(inactive);
        fresh.poke(id);
        // Activation itself waits out the queue.
        bytes32 op = _op(fresh, keccak256("ACTIVATE"), "");
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, 0));
        fresh.activate();
    }

    function test_activate_onceThroughTheQueue() public {
        HookrLpBoost fresh = _deployBoost();
        bytes32 kind = fresh.ACTIVATE();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        fresh.queue(kind, "");
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NonCanonicalArguments.selector, kind));
        fresh.queue(kind, hex"00");
        vm.prank(gov);
        fresh.queue(kind, "");
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        fresh.activate();
        vm.expectEmit(address(fresh));
        emit IHookrLpBoost.Activated();
        vm.prank(gov);
        fresh.activate();
        assertTrue(fresh.active());
        vm.prank(gov);
        vm.expectRevert(IHookrLpBoost.AlreadyActive.selector);
        fresh.queue(kind, "");
        vm.prank(gov);
        vm.expectRevert(IHookrLpBoost.AlreadyActive.selector);
        fresh.activate();
    }

    function test_queue_refusesUnknownKinds() public {
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.UnknownOperation.selector, keccak256("SWEEP")));
        boost.queue(keccak256("SWEEP"), "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reward-token list
    // ------------------------------------------------------------------------------------------------------------

    function test_addRewardToken_throughTheQueue() public {
        IERC20 token = IERC20(address(_token("Other", "OTH")));
        assertFalse(boost.rewardTokenListed(address(token)));
        bytes32 kind = boost.ADD_REWARD_TOKEN();
        vm.prank(gov);
        boost.queue(kind, abi.encode(address(token)));
        vm.prank(gov);
        vm.expectRevert();
        boost.addRewardToken(address(token));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.RewardTokenSet(address(token), true, gov);
        vm.prank(gov);
        boost.addRewardToken(address(token));
        assertTrue(boost.rewardTokenListed(address(token)));
    }

    function test_addRewardToken_refusals() public {
        bytes32 kind = boost.ADD_REWARD_TOKEN();
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotAContract.selector, alice));
        boost.queue(kind, abi.encode(alice));
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidRewardToken.selector, address(posm)));
        boost.queue(kind, abi.encode(address(posm)));
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidRewardToken.selector, address(manager)));
        boost.queue(kind, abi.encode(address(manager)));
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidRewardToken.selector, address(boost)));
        boost.queue(kind, abi.encode(address(boost)));
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.AlreadyListed.selector, address(reward)));
        boost.queue(kind, abi.encode(address(reward)));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NonCanonicalArguments.selector, kind));
        boost.queue(kind, abi.encodePacked(abi.encode(address(quote)), uint256(0)));
        vm.stopPrank();
    }

    function test_removeRewardToken_brakeForNewGaugesOnly() public {
        _appointGuardian();
        _onAWeekBoundary();
        uint256 tokenId = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        // A queued re-listing is voided by the removal.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        boost.removeRewardToken(address(reward));
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.RewardTokenSet(address(reward), false, guardian);
        vm.prank(guardian);
        boost.removeRewardToken(address(reward));
        assertFalse(boost.rewardTokenListed(address(reward)));
        // The existing gauge keeps paying it.
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        assertApproxEqAbs(_claim(alice, tokenId), 1e21, 1);
        // A new gauge cannot pick it.
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.RewardTokenNotListed.selector, address(reward)));
        boost.createGauge(k2, _terms(4, 52, 30_000));
        // Re-listing goes through a new queue entry: one queued before a removal is void.
        bytes32 add = boost.ADD_REWARD_TOKEN();
        vm.prank(gov);
        boost.queue(add, abi.encode(address(reward)));
        vm.prank(gov);
        boost.removeRewardToken(address(reward));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(gov);
        vm.expectRevert();
        boost.addRewardToken(address(reward));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Supply bounds
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Native ETH and every HookrToken have their bound built in, the launcher's own new tokens included (one
    ///      runtime, no immutables); any other ERC-20 has none until the owner declares one.
    function test_supplyBound_builtInForNativeEthAndHookrTokens() public {
        assertEq(boost.supplyBound(address(0)), 2 ** 96);
        assertEq(boost.supplyBound(address(subject)), 1e30);
        assertEq(boost.supplyBound(address(smallQuote)), SMALL_SUPPLY);
        (, PoolKey memory k2) = _launchToken(
            IHookrLauncher.Token(address(0), "Fresh", "FRSH", 7e26, bytes32("fresh")),
            Currency.wrap(address(quote)),
            1e18,
            SPACING,
            3000,
            1e24
        );
        address fresh = Currency.unwrap(k2.currency0) == address(quote)
            ? Currency.unwrap(k2.currency1)
            : Currency.unwrap(k2.currency0);
        assertEq(fresh.codehash, boost.hookrTokenCodeHash());
        assertEq(boost.supplyBound(fresh), 7e26);
        // Its family owner opens a gauge with no declaration.
        boost.createGauge(k2, _terms(4, 52, 30_000));
        assertEq(boost.supplyBound(address(_plain(1e24))), 0);
    }

    function test_setSupplyBound_throughTheQueue() public {
        MockERC20 plain = _plain(1e24);
        bytes32 kind = boost.SET_SUPPLY_BOUND();
        vm.prank(gov);
        boost.queue(kind, abi.encode(address(plain), uint256(2e24)));
        vm.prank(gov);
        vm.expectRevert();
        boost.setSupplyBound(address(plain), 2e24);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        boost.setSupplyBound(address(plain), 2e24);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.SupplyBoundSet(address(plain), 2e24, gov);
        vm.prank(gov);
        boost.setSupplyBound(address(plain), 2e24);
        assertEq(boost.supplyBound(address(plain)), 2e24);
        // A later declaration replaces it, through the queue again.
        _declareBound(boost, address(plain), 5e24);
        assertEq(boost.supplyBound(address(plain)), 5e24);
    }

    function test_setSupplyBound_refusals() public {
        MockERC20 plain = _plain(1e24);
        bytes32 kind = boost.SET_SUPPLY_BOUND();
        vm.startPrank(gov);
        // Native ETH's bound and a HookrToken's are built in; an account without code has none to declare.
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotAContract.selector, address(0)));
        boost.queue(kind, abi.encode(address(0), uint256(1e30)));
        vm.expectRevert(
            abi.encodeWithSelector(IHookrLpBoost.InvalidSupplyBound.selector, address(subject), uint256(1e31))
        );
        boost.queue(kind, abi.encode(address(subject), uint256(1e31)));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotAContract.selector, alice));
        boost.queue(kind, abi.encode(alice, uint256(1)));
        // Zero, and less than already exists.
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidSupplyBound.selector, address(plain), uint256(0)));
        boost.queue(kind, abi.encode(address(plain), uint256(0)));
        vm.expectRevert(
            abi.encodeWithSelector(IHookrLpBoost.InvalidSupplyBound.selector, address(plain), uint256(1e24 - 1))
        );
        boost.queue(kind, abi.encode(address(plain), uint256(1e24 - 1)));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NonCanonicalArguments.selector, kind));
        boost.queue(kind, abi.encodePacked(abi.encode(address(plain), uint256(1e24)), uint256(0)));
        // The supply itself is a bound; it is checked again when executed, after the supply grew past it.
        boost.queue(kind, abi.encode(address(plain), uint256(1e24)));
        vm.stopPrank();
        plain.mint(alice, 1);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrLpBoost.InvalidSupplyBound.selector, address(plain), uint256(1e24))
        );
        boost.setSupplyBound(address(plain), 1e24);
    }

    /// @dev The brake stops new gauges on pools holding the currency and voids every declaration queued before it,
    ///      whatever bound it names; a gauge created before keeps paying.
    function test_removeSupplyBound_brakeForNewGaugesOnly() public {
        _appointGuardian();
        MockERC20 plain = _plain(1e24);
        _declareBound(boost, address(plain), 1e24);
        (, PoolKey memory k2) = _launchOf(address(plain), Currency.wrap(address(quote)), 1e18, SPACING, 3000, 1e23);
        PoolId id2 = k2.toId();
        boost.createGauge(k2, _terms(4, 52, 30_000));
        _onAWeekBoundary();
        uint256 a = _mintFullRangeOf(alice, k2, 1e18);
        _stake(alice, a, 4);
        reward.approve(address(boost), 4e21);
        boost.notify(id2, 4e21, 4);
        bytes32 kind = boost.SET_SUPPLY_BOUND();
        vm.startPrank(gov);
        boost.queue(kind, abi.encode(address(plain), uint256(2e24)));
        boost.queue(kind, abi.encode(address(plain), uint256(3e24)));
        vm.stopPrank();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        boost.removeSupplyBound(address(plain));
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.SupplyBoundSet(address(plain), 0, guardian);
        vm.prank(guardian);
        boost.removeSupplyBound(address(plain));
        assertEq(boost.supplyBound(address(plain)), 0);
        // The gauge created before keeps paying.
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        vm.prank(alice);
        assertApproxEqAbs(boost.claim(id2, _one(a), alice), 1e21, 1);
        // A new gauge on a pool that holds it is refused.
        (, PoolKey memory k3) = _launchOf(address(plain), Currency.wrap(address(0)), 1e18, SPACING, 3000, 1e23);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NoSupplyBound.selector, address(plain)));
        boost.createGauge(k3, _terms(4, 52, 30_000));
        // Both declarations queued before the brake are void.
        vm.prank(gov);
        vm.expectRevert();
        boost.setSupplyBound(address(plain), 2e24);
        vm.prank(gov);
        vm.expectRevert();
        boost.setSupplyBound(address(plain), 3e24);
        // One queued after it goes through.
        _declareBound(boost, address(plain), 2e24);
        boost.createGauge(k3, _terms(4, 52, 30_000));
    }

    /// @dev A brake cannot remove a bound that is built in: native ETH's and a HookrToken's stay, and no event claims
    ///      otherwise.
    function test_removeSupplyBound_refusesABuiltInBound() public {
        _appointGuardian();
        bytes4 invalid = IHookrLpBoost.InvalidSupplyBound.selector;
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(invalid, address(0), uint256(0)));
        boost.removeSupplyBound(address(0));
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(invalid, address(subject), uint256(0)));
        boost.removeSupplyBound(address(subject));
        assertEq(boost.supplyBound(address(0)), 2 ** 96);
        assertEq(boost.supplyBound(address(subject)), 1e30);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gauge creation
    // ------------------------------------------------------------------------------------------------------------

    function test_createGauge_byFamilyOwner() public view {
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        assertEq(PoolId.unwrap(g.key.toId()), PoolId.unwrap(id));
        assertEq(g.creator, address(this));
        assertEq(g.terms.rewardToken, address(reward));
        assertEq(g.terms.minLockWeeks, 4);
        assertEq(g.terms.maxLockWeeks, 52);
        assertEq(g.terms.maxBoostBps, 30_000);
        assertEq(g.terms.minLiquidity, FLOOR);
        assertFalse(g.paused);
        assertEq(g.periodFinish, 0);
        assertEq(g.totalWeight, 0);
        assertEq(launcher.familyOwner(launcher.poolFamily(id)), address(this));
    }

    function test_createGauge_emits() public {
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        IHookrLpBoost.Terms memory t = _terms(1, 104, 10_000);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.GaugeCreated(k2.toId(), address(this), address(reward), k2, t);
        boost.createGauge(k2, t);
    }

    function test_createGauge_byOwnerThroughTheQueue() public {
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        IHookrLpBoost.Terms memory t = _terms(2, 8, 15_000);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotFamilyOwner.selector, mallory));
        boost.createGauge(k2, t);
        vm.prank(gov);
        vm.expectRevert();
        boost.createGauge(k2, t);
        _queued(boost.CREATE_GAUGE(), abi.encode(k2, t));
        vm.prank(gov);
        boost.createGauge(k2, t);
        IHookrLpBoost.Gauge memory g = boost.gauge(k2.toId());
        assertEq(g.creator, gov);
        assertEq(g.terms.maxBoostBps, 15_000);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.GaugeExists.selector, k2.toId()));
        boost.createGauge(k2, t);
    }

    function test_createGauge_refusesBadTerms() public {
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        IHookrLpBoost.Terms[6] memory bad = [
            _terms(0, 52, 30_000),
            _terms(10, 9, 30_000),
            _terms(4, 105, 30_000),
            _terms(4, 52, 9_999),
            _terms(4, 52, 30_001),
            _terms(4, 52, 30_000, 999_999)
        ];
        bytes32 kind = boost.CREATE_GAUGE();
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IHookrLpBoost.InvalidTerms.selector);
            boost.createGauge(k2, bad[i]);
            vm.prank(gov);
            vm.expectRevert(IHookrLpBoost.InvalidTerms.selector);
            boost.queue(kind, abi.encode(k2, bad[i]));
        }
        // Each bound itself is accepted: the longest locks, the highest boost and, on the small tokens' pool where
        // the sizing rule asks for less, the least minLiquidity.
        (, PoolKey memory k3) = _launchSmall(1e18, SPACING, 3000);
        boost.createGauge(k3, _terms(104, 104, 30_000, LEAST_LIQUIDITY));
        assertEq(boost.gauge(k3.toId()).terms.minLiquidity, boost.MIN_LIQUIDITY());
    }

    /// @dev The sizing rule at its floor, on both sides: one less than the floor is refused naming the currency whose
    ///      edge binds, what a full-range position of it owns there and that currency's bound, directly and when
    ///      queued; the floor itself is created. Native ETH binds against the small subject (2^96 against 10^25) and
    ///      the 10^30 subject binds against native ETH.
    function test_createGauge_sizingRuleAtItsFloor() public {
        (, PoolKey memory small) =
            _launchOf(address(smallSubject), Currency.wrap(address(0)), 1e18, SPACING, 3000, 1e23);
        (, PoolKey memory big) = _launch(Currency.wrap(address(0)), 1e24);
        PoolKey[2] memory keys = [small, big];
        address[2] memory binding = [address(0), address(subject)];
        bytes32 kind = boost.CREATE_GAUGE();
        for (uint256 i; i < 2; ++i) {
            uint128 least = _sizingFloor(keys[i]);
            assertGt(least, LEAST_LIQUIDITY);
            bytes memory refusal = _sizingRefusal(keys[i], least - 1);
            (address named,,) = _decodeTooLow(refusal);
            assertEq(named, binding[i]);
            vm.expectRevert(refusal);
            boost.createGauge(keys[i], _terms(4, 52, 30_000, least - 1));
            vm.prank(gov);
            vm.expectRevert(refusal);
            boost.queue(kind, abi.encode(keys[i], _terms(4, 52, 30_000, least - 1)));
            assertEq(_sizingRefusal(keys[i], least).length, 0);
            boost.createGauge(keys[i], _terms(4, 52, 30_000, least));
            assertEq(boost.gauge(keys[i].toId()).terms.minLiquidity, least);
        }
    }

    /// @dev A pool holding an ERC-20 with no declared bound gets no gauge, by either path, until the owner declares
    ///      one.
    function test_createGauge_aCurrencyWithoutABoundIsRefused() public {
        MockERC20 plain = _plain(1e24);
        (, PoolKey memory k2) = _launchOf(address(plain), Currency.wrap(address(quote)), 1e18, SPACING, 3000, 1e23);
        bytes memory refusal = abi.encodeWithSelector(IHookrLpBoost.NoSupplyBound.selector, address(plain));
        vm.expectRevert(refusal);
        boost.createGauge(k2, _terms(4, 52, 30_000));
        bytes32 kind = boost.CREATE_GAUGE();
        vm.prank(gov);
        vm.expectRevert(refusal);
        boost.queue(kind, abi.encode(k2, _terms(4, 52, 30_000)));
        _declareBound(boost, address(plain), 1e24);
        boost.createGauge(k2, _terms(4, 52, 30_000, _sizingFloor(k2)));
    }

    /// @dev For any tick spacing v4 allows, on a pool of a fresh 10^30 HookrToken against another or against native
    ///      ETH, `createGauge` takes the floor `_sizingFloor` derives by inverting SqrtPriceMath and refuses one less
    ///      with exactly the refusal the rule's forward reading gives: the floor is exact at every spacing, tick
    ///      spacing 31,689 (the usable range's narrowest band) included, whichever side the fresh token sorts to.
    function testFuzz_createGauge_refusedExactlyBelowTheSizingFloor(uint16 spacingSeed, bool native) public {
        int24 spacing = int24(uint24(bound(spacingSeed, 1, 32_767)));
        Currency quote_ = native ? Currency.wrap(address(0)) : Currency.wrap(address(quote));
        HookrToken fresh = _token("Fuzz", "FUZ");
        fresh.approve(address(launcher), type(uint256).max);
        (, PoolKey memory k2) = _launchOf(address(fresh), quote_, 1e18, spacing, 3000, 1e24);
        uint128 least = _sizingFloor(k2);
        bytes memory refusal = _sizingRefusal(k2, least - 1);
        assertGt(refusal.length, 0, "one less than the floor breaks the rule");
        assertEq(_sizingRefusal(k2, least).length, 0, "the floor meets it");
        vm.expectRevert(refusal);
        boost.createGauge(k2, _terms(4, 52, 30_000, least - 1));
        boost.createGauge(k2, _terms(4, 52, 30_000, least));
    }

    /// @dev The ceiling on both sides. A plain subject whose declared bound is 10^40, against the 10^30 quote: what
    ///      both bounds could fund (about sqrt(10^70)) is above v4's maximum liquidity per tick, which binds, so one
    ///      more than it is refused and it is created. The 10^30 subject against the 10^30 quote: the supplies bind
    ///      near 10^30, so a minLiquidity eighteen decimals too large (FLOOR x 10^18), under the tick maximum, is
    ///      refused directly and when queued, and 10^30 itself is created.
    function test_createGauge_minLiquidityCeilingOnBothSides() public {
        MockERC20 plain = _plain(1e24);
        _declareBound(boost, address(plain), 1e40);
        (, PoolKey memory k2) = _launchOf(address(plain), Currency.wrap(address(quote)), 1e18, SPACING, 3000, 1e23);
        uint128 perTick = Pool.tickSpacingToMaxLiquidityPerTick(SPACING);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.MinLiquidityTooHigh.selector, perTick + 1));
        boost.createGauge(k2, _terms(4, 52, 30_000, perTick + 1));
        boost.createGauge(k2, _terms(4, 52, 30_000, perTick));
        (, PoolKey memory k3) = _launch(Currency.wrap(address(quote)), 1e24, 120, 3000);
        uint128 slip = FLOOR * 1e18;
        assertLt(slip, Pool.tickSpacingToMaxLiquidityPerTick(120), "under the tick maximum: the supplies bind");
        bytes memory refusal = abi.encodeWithSelector(IHookrLpBoost.MinLiquidityTooHigh.selector, slip);
        vm.expectRevert(refusal);
        boost.createGauge(k3, _terms(4, 52, 30_000, slip));
        bytes32 kind = boost.CREATE_GAUGE();
        vm.prank(gov);
        vm.expectRevert(refusal);
        boost.queue(kind, abi.encode(k3, _terms(4, 52, 30_000, slip)));
        boost.createGauge(k3, _terms(4, 52, 30_000, 1e30));
    }

    /// @dev For a plain subject of a declared bound of any magnitude against each kind of quote, at any tick spacing:
    ///      createGauge refuses exactly the minLiquidity above min(v4's maximum liquidity per tick, B + isqrt(C)), B
    ///      and C as `_checkCeiling` rounds them, and creates the ceiling itself wherever the sizing floor allows. The
    ///      ceiling is sound and close: the most liquidity any sqrt price funds within both supply bounds, found by
    ///      bisection with a mint's own rounding, is never above it, and when the supplies bind it is above that most
    ///      by no more than B + 2.
    function testFuzz_createGauge_minLiquidityCeilingIsSoundAndClose(
        uint256 boundSeed,
        uint8 quoteSeed,
        uint16 spacingSeed
    ) public {
        int24 spacing = int24(uint24(bound(spacingSeed, 1, 32_767)));
        MockERC20 plain = _plain(1e24);
        // A bound of any magnitude from 10^24 to 10^45, so either side of the ceiling binds.
        uint256 magnitude = 10 ** (24 + boundSeed % 22);
        _declareBound(boost, address(plain), magnitude + (boundSeed >> 8) % magnitude);
        Currency[3] memory quotes =
            [Currency.wrap(address(0)), Currency.wrap(address(quote)), Currency.wrap(address(smallQuote))];
        (, PoolKey memory k) = _launchOf(address(plain), quotes[quoteSeed % 3], 1e18, spacing, 3000, 1e23);
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(spacing));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(spacing));
        uint256 b0 = boost.supplyBound(Currency.unwrap(k.currency0));
        uint256 b1 = boost.supplyBound(Currency.unwrap(k.currency1));
        (uint256 ceiling, uint256 bTerm) = _ceiling(spacing, lower, upper, b0, b1);
        if (ceiling < _sizingFloor(k)) return;
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.MinLiquidityTooHigh.selector, uint128(ceiling + 1)));
        boost.createGauge(k, _terms(4, 52, 30_000, uint128(ceiling + 1)));
        boost.createGauge(k, _terms(4, 52, 30_000, uint128(ceiling)));
        uint256 perTick = Pool.tickSpacingToMaxLiquidityPerTick(spacing);
        uint256 most = _mostFundable(lower, upper, b0, b1);
        assertGe(ceiling, most < perTick ? most : perTick, "never below what a position could hold");
        if (ceiling < perTick) assertLe(ceiling, most + bTerm + 2, "close to it where the supplies bind");
    }

    function test_createGauge_refusesPoolsThatAreNotHookrPools() public {
        IHookrLpBoost.Terms memory t = _terms(4, 52, 30_000);
        bytes32 kind = boost.CREATE_GAUGE();
        // A pool the registered root never initialized.
        PoolKey memory unknown = key;
        unknown.fee = 500;
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidPool.selector, unknown.toId()));
        boost.queue(kind, abi.encode(unknown, t));
        // A hookless pool.
        PoolKey memory plain = PoolKey(key.currency0, key.currency1, 3000, SPACING, IHooks(address(0)));
        manager.initialize(plain, SQRT_ONE);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidPool.selector, plain.toId()));
        boost.queue(kind, abi.encode(plain, t));
        // A hook that is not a registered root.
        PoolKey memory foreign = key;
        foreign.hooks = IHooks(address(launcher));
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidPool.selector, foreign.toId()));
        boost.queue(kind, abi.encode(foreign, t));
        // Outside the queue only a family owner creates, and these pools have none.
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotFamilyOwner.selector, address(this)));
        boost.createGauge(plain, t);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotFamilyOwner.selector, address(this)));
        boost.createGauge(unknown, t);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Notify and fund
    // ------------------------------------------------------------------------------------------------------------

    function test_notify_startsATranche() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 rate = FullMath.mulDiv(52e21, Q128, 52 weeks);
        reward.approve(address(boost), 52e21);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Notified(id, address(this), 52e21, 52e21, uint48(t0 + 52 weeks));
        boost.notify(id, 52e21, 52);
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        assertEq(g.scheduled, 52e21);
        assertEq(g.periodFinish, t0 + 52 weeks);
        assertEq(g.rewardRateX128, rate);
        assertEq(g.emissionLeftX128, rate * 52 weeks);
        assertEq(boost.endingRate(id, t0 + 52 weeks), rate);
        assertEq(g.funded, 52e21);
        assertEq(reward.balanceOf(address(boost)), 52e21);
    }

    /// @dev A tranche ends on the first week boundary its length or more ahead, as a maturity does, and emits its
    ///      amount evenly over the whole of it.
    function test_notify_aTrancheEndsOnAWeekBoundary() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 t = vm.getBlockTimestamp();
        uint48 finish = uint48(_weekAfter(t + 4 weeks));
        assertEq(finish - t, 4 weeks + 4 days);
        reward.approve(address(boost), 4e21);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Notified(id, address(this), 4e21, 4e21, finish);
        boost.notify(id, 4e21, 4);
        assertEq(boost.gauge(id).periodFinish, finish);
        vm.warp(t + (finish - t) / 2);
        assertApproxEqAbs(boost.pendingRewards(a), 2e21, 1);
        vm.warp(finish);
        assertApproxEqAbs(boost.pendingRewards(a), 4e21, 1);
    }

    function test_notify_refusals() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotGaugeCreator.selector, mallory));
        boost.notify(id, 0, 4);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidDuration.selector, uint16(0)));
        boost.notify(id, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidDuration.selector, uint16(53)));
        boost.notify(id, 0, 53);
        // Nothing to pull and nothing unassigned: a tranche of nothing is refused.
        vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
        boost.notify(id, 0, 4);
        PoolId unknown = PoolId.wrap(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.UnknownGauge.selector, unknown));
        boost.notify(unknown, 0, 4);
        // The owner may notify any gauge.
        reward.transfer(gov, 1e18);
        vm.startPrank(gov);
        reward.approve(address(boost), 1e18);
        boost.notify(id, 1e18, 4);
        vm.stopPrank();
        assertEq(boost.gauge(id).scheduled, 1e18);
    }

    /// @dev A notify while another tranche runs adds a tranche beside it: the running one keeps its rate to its own
    ///      end, the new one emits its amount to its end, and the gauge's rate is their sum until the first ends.
    function test_notify_addsATrancheBesideTheRunningOne() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        uint256 first = boost.gauge(id).rewardRateX128;
        vm.warp(t0 + 2 weeks);
        _notify(1e21, 4);
        uint256 second = FullMath.mulDiv(1e21, Q128, 4 weeks);
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        assertEq(g.rewardRateX128, first + second);
        assertEq(g.periodFinish, t0 + 6 weeks);
        assertEq(boost.endingRate(id, t0 + 4 weeks), first);
        assertEq(boost.endingRate(id, t0 + 6 weeks), second);
        // At the first tranche's end: all of its 4e21 and half of the second's 1e21.
        vm.warp(t0 + 4 weeks);
        assertApproxEqAbs(boost.pendingRewards(a), 4e21 + 5e20, 2);
        boost.poke(id);
        g = boost.gauge(id);
        assertEq(g.rewardRateX128, second, "the first tranche's rate left at its end");
        assertEq(boost.endingRate(id, t0 + 4 weeks), 0);
        assertApproxEqAbs(g.scheduled, 5e20, 1);
        // At the second's end both have emitted whole, and nothing is left.
        vm.warp(t0 + 6 weeks);
        assertApproxEqAbs(_claim(alice, a), 5e21, 2);
        g = boost.gauge(id);
        assertEq(g.scheduled, 0);
        assertEq(g.rewardRateX128, 0);
        assertEq(g.emissionLeftX128, 0);
        assertEq(g.unassigned, 0);
    }

    function test_notify_rollsTheUnassignedRemainder() public {
        _notify(4e21, 4);
        // Nothing is staked for one week: its emission is unassigned.
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(id);
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        assertEq(g.unassigned, 1e21);
        assertEq(g.scheduled, 3e21);
        _mintAndStake(alice, 1e18, 4);
        // The remainder comes back only through a notify, as a tranche of its own beside the running one.
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Notified(id, address(this), 0, 1e21, uint48(vm.getBlockTimestamp() + 3 weeks));
        boost.notify(id, 0, 3);
        g = boost.gauge(id);
        assertEq(g.unassigned, 0);
        assertEq(g.scheduled, 4e21);
        assertEq(g.funded, 4e21);
        vm.warp(vm.getBlockTimestamp() + 3 weeks);
        assertApproxEqAbs(boost.pendingRewards(_lastToken()), 4e21, 1);
    }

    /// @dev Anyone funds a tranche of its own, with or without other tranches running: it ends where its length puts
    ///      it and emits its amount there.
    function test_fund_startsATrancheOfItsOwn() public {
        uint256 tokenId = _mintAndStake(alice, 1e18, 4);
        uint256 t0 = vm.getBlockTimestamp();
        reward.transfer(sponsor, 7e21);
        vm.startPrank(sponsor);
        reward.approve(address(boost), type(uint256).max);
        vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
        boost.fund(id, 0, 4);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidDuration.selector, uint16(0)));
        boost.fund(id, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidDuration.selector, uint16(53)));
        boost.fund(id, 1, 53);
        // No tranche runs yet: a partner starts the gauge's rewards on its own.
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Funded(id, sponsor, 4e21, uint48(t0 + 4 weeks));
        boost.fund(id, 4e21, 4);
        vm.stopPrank();
        // Two weeks in, a second funding to the same end raises the rate from then on.
        vm.warp(t0 + 2 weeks);
        vm.prank(sponsor);
        boost.fund(id, 2e21, 2);
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        assertEq(g.periodFinish, t0 + 4 weeks);
        assertEq(g.scheduled, 4e21);
        assertEq(g.funded, 6e21);
        vm.warp(t0 + 4 weeks);
        assertApproxEqAbs(boost.pendingRewards(tokenId), 6e21, 2);
        // Once every tranche has ended, a funding starts a new one.
        vm.prank(sponsor);
        boost.fund(id, 1e21, 1);
        assertEq(boost.gauge(id).periodFinish, t0 + 5 weeks);
        vm.warp(t0 + 5 weeks);
        assertApproxEqAbs(boost.pendingRewards(tokenId), 7e21, 3);
    }

    function test_funding_isIrrevocableAndPaidOnlyToStakers() public {
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 8 weeks);
        boost.poke(id);
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        // Nobody staked: the whole budget waits in the unassigned remainder, still held.
        assertEq(g.unassigned, 4e21);
        assertEq(g.scheduled, 0);
        assertEq(reward.balanceOf(address(boost)), 4e21);
        uint256 tokenId = _mintAndStake(alice, 1e18, 4);
        _notify(0, 4);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        assertApproxEqAbs(_claim(alice, tokenId), 4e21, 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Stake
    // ------------------------------------------------------------------------------------------------------------

    function test_stake_recordsTheVerifiedPosition() public {
        uint256 tokenId = _mintFullRange(alice, 1e18);
        uint48 maturity = _maturity(28);
        vm.startPrank(alice);
        posm.approve(address(boost), tokenId);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Staked(tokenId, id, alice, 1e18, 28, maturity, 20_000);
        boost.stake(tokenId, 28);
        vm.stopPrank();
        IHookrLpBoost.Stake memory s = boost.stakeOf(tokenId);
        assertEq(s.owner, alice);
        assertEq(s.maturity, maturity);
        assertEq(s.boostBps, 20_000);
        assertEq(s.liquidity, 1e18);
        assertEq(PoolId.unwrap(s.poolId), PoolId.unwrap(id));
        assertEq(posm.ownerOf(tokenId), address(boost));
        assertEq(boost.gauge(id).totalWeight, 2e18);
        (uint256 drop,) = boost.weekState(id, maturity);
        assertEq(drop, 1e18);
        assertEq(boost.gauge(id).lastDropWeek, maturity);
    }

    function test_stake_maturityRoundsUpToAWeekBoundary() public {
        vm.warp(vm.getBlockTimestamp() + 3 days + 5);
        uint256 tokenId = _mintAndStake(alice, 1e18, 4);
        uint256 maturity = boost.stakeOf(tokenId).maturity;
        assertEq(maturity % WEEK, 0);
        assertGe(maturity, vm.getBlockTimestamp() + 4 weeks);
        assertLt(maturity, vm.getBlockTimestamp() + 5 weeks);
    }

    function test_boost_atItsBounds() public {
        assertEq(boost.boostFor(id, 4), 10_000);
        assertEq(boost.boostFor(id, 52), 30_000);
        assertEq(boost.boostFor(id, 28), 20_000);
        // 10,000 + 20,000 x 1 / 48, rounded down.
        assertEq(boost.boostFor(id, 5), 10_416);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidLock.selector, uint16(3)));
        boost.boostFor(id, 3);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidLock.selector, uint16(53)));
        boost.boostFor(id, 53);
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        boost.createGauge(k2, _terms(12, 12, 25_000));
        assertEq(boost.boostFor(k2.toId(), 12), 25_000);
    }

    function test_stake_refusesAConcentratedPosition() public {
        uint256 tokenId = _mint(alice, key, -600, 600, 1e18);
        vm.startPrank(alice);
        posm.approve(address(boost), tokenId);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotFullRange.selector, int24(-600), int24(600)));
        boost.stake(tokenId, 4);
        vm.stopPrank();
        (int24 lower,) = _fullRange();
        uint256 half = _mint(alice, key, lower, 0, 1e18);
        vm.startPrank(alice);
        posm.approve(address(boost), half);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotFullRange.selector, lower, int24(0)));
        boost.stake(half, 4);
        vm.stopPrank();
    }

    function test_stake_refusesASubscribedPosition() public {
        uint256 tokenId = _mintFullRange(alice, 1e18);
        address subscriber = address(new NoopSubscriber());
        vm.startPrank(alice);
        posm.subscribe(tokenId, subscriber, "");
        posm.approve(address(boost), tokenId);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.HasSubscriber.selector, tokenId));
        boost.stake(tokenId, 4);
        posm.unsubscribe(tokenId);
        posm.approve(address(boost), tokenId);
        boost.stake(tokenId, 4);
        vm.stopPrank();
    }

    function test_stake_refusals() public {
        uint256 tokenId = _mintFullRange(alice, 1e18);
        // Not the owner, even when approved.
        vm.prank(alice);
        posm.approve(address(boost), tokenId);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotPositionOwner.selector, tokenId, mallory));
        boost.stake(tokenId, 4);
        // Lock outside the terms.
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidLock.selector, uint16(3)));
        boost.stake(tokenId, 3);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidLock.selector, uint16(53)));
        boost.stake(tokenId, 53);
        vm.stopPrank();
        // A token that does not exist.
        uint256 missing = posm.nextTokenId();
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.PoolMismatch.selector, missing));
        boost.stake(missing, 4);
        // Less liquidity than the gauge's minLiquidity.
        uint256 below = _mintFullRange(bob, FLOOR - 1);
        vm.startPrank(bob);
        posm.approve(address(boost), below);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.LiquidityTooLow.selector, FLOOR - 1, FLOOR));
        boost.stake(below, 4);
        vm.stopPrank();
        uint256 least = _mintFullRange(bob, FLOOR);
        _stake(bob, least, 4);
        // Not approved.
        uint256 unapproved = _mintFullRange(carol, 1e18);
        vm.prank(carol);
        vm.expectRevert();
        boost.stake(unapproved, 4);
        // A pool with no gauge.
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        (int24 lower, int24 upper) = _fullRange();
        uint256 other = _mint(carol, k2, lower, upper, 1e18);
        vm.startPrank(carol);
        posm.approve(address(boost), other);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.UnknownGauge.selector, k2.toId()));
        boost.stake(other, 4);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Accrual
    // ------------------------------------------------------------------------------------------------------------

    function test_accrual_oneStakerTakesTheWholeEmission() public {
        uint256 tokenId = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        assertApproxEqAbs(boost.pendingRewards(tokenId), 1e21, 1);
        vm.warp(vm.getBlockTimestamp() + 3 weeks);
        assertApproxEqAbs(boost.pendingRewards(tokenId), 4e21, 1);
        // Nothing accrues after the period ends.
        vm.warp(vm.getBlockTimestamp() + 10 weeks);
        assertApproxEqAbs(boost.pendingRewards(tokenId), 4e21, 1);
        assertApproxEqAbs(_claim(alice, tokenId), 4e21, 1);
        assertEq(boost.pendingRewards(tokenId), 0);
    }

    function test_accrual_splitsByBoostedWeight() public {
        uint256 a = _mintAndStake(alice, 1e18, 52);
        uint256 b = _mintAndStake(bob, 1e18, 4);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        assertApproxEqAbs(boost.pendingRewards(a), 3e21, 2);
        assertApproxEqAbs(boost.pendingRewards(b), 1e21, 2);
        assertLe(boost.pendingRewards(a) + boost.pendingRewards(b), 4e21);
    }

    function test_maturityDrop_isExactAtTheWeekBoundary() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 a = _mintAndStake(alice, 1e18, 28);
        uint256 b = _mintAndStake(bob, 1e18, 52);
        uint48 ma = boost.stakeOf(a).maturity;
        assertEq(ma, t0 + 28 weeks);
        _notify(52e21, 52);
        // Nobody touches the gauge until four weeks after alice's maturity.
        vm.warp(ma + 4 weeks);
        // Before the boundary: 2 of 5 for alice. After it: 1 of 4.
        uint256 aliceExpected = 28e21 * 2 / 5 + 4e21 / 4;
        uint256 bobExpected = 28e21 * 3 / 5 + 4e21 * 3 / 4;
        assertApproxEqAbs(boost.pendingRewards(a), aliceExpected, 2);
        assertApproxEqAbs(boost.pendingRewards(b), bobExpected, 2);
        vm.expectEmit(true, true, false, false, address(boost));
        emit IHookrLpBoost.WeekClosed(id, ma, 1e18, 0, 0);
        assertApproxEqAbs(_claim(alice, a), aliceExpected, 2);
        assertApproxEqAbs(_claim(bob, b), bobExpected, 2);
        (uint256 drop, uint256 recorded) = boost.weekState(id, ma);
        assertEq(drop, 0);
        assertGt(recorded, 0);
        assertEq(boost.stakeOf(a).boostBps, 10_000);
        assertEq(boost.gauge(id).totalWeight, 1e18 + 3e18);
    }

    function test_maturityDrop_sameWhenPokedAtTheBoundary() public {
        uint256 a = _mintAndStake(alice, 1e18, 28);
        uint256 b = _mintAndStake(bob, 1e18, 52);
        uint48 ma = boost.stakeOf(a).maturity;
        _notify(52e21, 52);
        vm.warp(ma - 1);
        boost.poke(id);
        vm.warp(ma);
        boost.poke(id);
        vm.warp(ma + 1);
        boost.poke(id);
        vm.warp(ma + 4 weeks);
        assertApproxEqAbs(boost.pendingRewards(a), 28e21 * 2 / 5 + 4e21 / 4, 4);
        assertApproxEqAbs(boost.pendingRewards(b), 28e21 * 3 / 5 + 4e21 * 3 / 4, 4);
    }

    function test_pendingRewards_matchesTheSettlement() public {
        uint256 a = _mintAndStake(alice, 3e18, 28);
        _mintAndStake(bob, 1e18, 52);
        _notify(52e21, 52);
        vm.warp(vm.getBlockTimestamp() + 30 weeks + 3 days);
        uint256 pending = boost.pendingRewards(a);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.RewardsAccrued(a, alice, pending);
        uint256 paid = _claim(alice, a);
        assertEq(paid, pending);
        assertEq(reward.balanceOf(alice), pending);
        assertEq(boost.pendingRewards(a), 0);
        assertEq(boost.pendingRewards(12345), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Extend
    // ------------------------------------------------------------------------------------------------------------

    function test_extend_movesTheMaturityAndRepricesTheBoost() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(52e21, 52);
        uint48 before = boost.stakeOf(a).maturity;
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256 pending = boost.pendingRewards(a);
        uint48 maturity = _maturity(52);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Extended(a, 52, maturity, 30_000);
        vm.prank(alice);
        boost.extend(a, 52);
        // Accrual was settled first.
        assertEq(boost.owed(id, alice), pending);
        IHookrLpBoost.Stake memory s = boost.stakeOf(a);
        assertEq(s.maturity, maturity);
        assertEq(s.boostBps, 30_000);
        assertEq(boost.gauge(id).totalWeight, 3e18);
        (uint256 oldDrop,) = boost.weekState(id, before);
        (uint256 newDrop,) = boost.weekState(id, maturity);
        assertEq(oldDrop, 0);
        assertEq(newDrop, 2e18);
    }

    function test_extend_afterMaturityBoostsAgain() public {
        uint256 a = _mintAndStake(alice, 1e18, 28);
        _mintAndStake(bob, 1e18, 52);
        _notify(52e21, 52);
        vm.warp(boost.stakeOf(a).maturity + 1 weeks);
        vm.prank(alice);
        boost.extend(a, 16);
        IHookrLpBoost.Stake memory s = boost.stakeOf(a);
        assertEq(s.boostBps, 15_000);
        // Alice was 1x for the week after maturity, then 1.5x.
        assertEq(boost.gauge(id).totalWeight, 15e17 + 3e18);
        // A shorter lock lowers the boost; the maturity still moves later.
        vm.warp(vm.getBlockTimestamp() + 10 weeks);
        vm.prank(alice);
        boost.extend(a, 8);
        assertEq(boost.stakeOf(a).boostBps, 11_666);
        assertEq(boost.stakeOf(a).maturity, _maturity(8));
    }

    /// Extending to the maturity the stake already has moves nothing and is refused, with both values equal. Mutation
    /// gate LB-3 (the check read `<`, which accepted the no-op).
    function test_extend_toTheSameMaturityIsRefused() public {
        uint256 a = _mintAndStake(alice, 1e18, 28);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.MaturityNotLater.selector, _maturity(28), _maturity(28)));
        boost.extend(a, 28);
    }

    function test_extend_refusals() public {
        uint256 a = _mintAndStake(alice, 1e18, 28);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.MaturityNotLater.selector, _maturity(4), _maturity(28)));
        boost.extend(a, 4);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotStaker.selector, a, mallory));
        boost.extend(a, 52);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidLock.selector, uint16(53)));
        boost.extend(a, 53);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotStaked.selector, uint256(999)));
        boost.extend(999, 52);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Withdraw and claim
    // ------------------------------------------------------------------------------------------------------------

    function test_withdraw_fromMaturityOn() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(8e21, 8);
        uint48 maturity = boost.stakeOf(a).maturity;
        vm.warp(maturity - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.Locked.selector, a, maturity));
        boost.withdraw(a, alice);
        vm.warp(maturity);
        uint256 pending = boost.pendingRewards(a);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Withdrawn(a, alice, carol);
        vm.prank(alice);
        boost.withdraw(a, carol);
        assertEq(posm.ownerOf(a), carol);
        assertEq(boost.stakeOf(a).owner, address(0));
        assertEq(boost.gauge(id).totalWeight, 0);
        // Rewards settled at the withdrawal stay claimable.
        assertEq(boost.owed(id, alice), pending);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        assertEq(boost.claim(id, none, alice), pending);
        assertEq(boost.owed(id, alice), 0);
        // The position can be staked again by its new owner.
        _stake(carol, a, 4);
        assertEq(boost.stakeOf(a).owner, carol);
    }

    function test_withdraw_refusals() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        vm.warp(boost.stakeOf(a).maturity);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotStaker.selector, a, mallory));
        boost.withdraw(a, mallory);
        address[6] memory bad = [address(0), address(1), address(2), address(boost), address(posm), address(manager)];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidRecipient.selector, bad[i]));
            boost.withdraw(a, bad[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotStaked.selector, uint256(999)));
        boost.withdraw(999, alice);
    }

    function test_claim_settlesAndPays() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        uint256 a2 = _mintAndStake(alice, 1e18, 4);
        uint256 b = _mintAndStake(bob, 1e18, 4);
        _notify(3e21, 1);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256[] memory both = new uint256[](2);
        both[0] = a;
        both[1] = a2;
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.Claimed(id, alice, carol, 2e21);
        vm.prank(alice);
        uint256 paid = boost.claim(id, both, carol);
        assertEq(paid, 2e21);
        assertEq(reward.balanceOf(carol), paid);
        assertEq(boost.gauge(id).paid, paid);
        // Another staker's position, another gauge's position and bad recipients are refused.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotStaker.selector, b, alice));
        boost.claim(id, _one(b), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidRecipient.selector, address(0)));
        boost.claim(id, _one(b), address(0));
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        boost.createGauge(k2, _terms(4, 52, 30_000));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.OtherGauge.selector, b, k2.toId()));
        boost.claim(k2.toId(), _one(b), bob);
        // Nothing owed pays nothing.
        vm.prank(carol);
        assertEq(boost.claim(id, new uint256[](0), carol), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // LP fees
    // ------------------------------------------------------------------------------------------------------------

    function test_collectFees_paysTheLpsOwnFeesAtAnyTime() public {
        uint256 a = _mintAndStake(alice, 1e21, 52);
        _swapToTick(key, 600);
        _swapToTick(key, -600);
        _swapToTick(key, 0);
        uint128 liquidity = posm.getPositionLiquidity(a);
        uint256 before0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(carol);
        uint256 before1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(carol);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.FeesCollected(a, carol);
        vm.prank(alice);
        boost.collectFees(a, carol);
        assertGt(IERC20(Currency.unwrap(key.currency0)).balanceOf(carol), before0);
        assertGt(IERC20(Currency.unwrap(key.currency1)).balanceOf(carol), before1);
        assertEq(posm.getPositionLiquidity(a), liquidity);
        assertEq(IERC20(Currency.unwrap(key.currency0)).balanceOf(address(boost)), 0);
        assertEq(IERC20(Currency.unwrap(key.currency1)).balanceOf(address(boost)), 0);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotStaker.selector, a, mallory));
        boost.collectFees(a, mallory);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.InvalidRecipient.selector, address(1)));
        boost.collectFees(a, address(1));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Brakes
    // ------------------------------------------------------------------------------------------------------------

    function test_pause_stopsNewActivityButNeverWithdrawalsOrFees() public {
        _appointGuardian();
        uint256 a = _mintAndStake(alice, 1e18, 4);
        uint256 waiting = _mintFullRange(bob, 1e18);
        _notify(8e21, 8);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, mallory));
        boost.pause(id);
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.GaugePauseSet(id, true, guardian);
        vm.prank(guardian);
        boost.pause(id);
        bytes memory paused = abi.encodeWithSelector(IHookrLpBoost.GaugeIsPaused.selector, id);
        vm.startPrank(bob);
        posm.approve(address(boost), waiting);
        vm.expectRevert(paused);
        boost.stake(waiting, 4);
        vm.stopPrank();
        vm.expectRevert(paused);
        boost.notify(id, 0, 4);
        vm.prank(sponsor);
        vm.expectRevert(paused);
        boost.fund(id, 1, 1);
        vm.prank(alice);
        vm.expectRevert(paused);
        boost.extend(a, 8);
        vm.prank(alice);
        vm.expectRevert(paused);
        boost.claim(id, _one(a), alice);
        // Fees, the accrual walk and withdrawal still work.
        vm.prank(alice);
        boost.collectFees(a, alice);
        vm.warp(boost.stakeOf(a).maturity);
        boost.poke(id);
        vm.prank(alice);
        boost.withdraw(a, alice);
        assertEq(posm.ownerOf(a), alice);
        uint256 owedAtWithdrawal = boost.owed(id, alice);
        assertGt(owedAtWithdrawal, 0);
        // Only a queued unpause lifts it.
        vm.prank(gov);
        vm.expectRevert();
        boost.unpause(id);
        _queued(boost.UNPAUSE(), abi.encode(id));
        vm.prank(gov);
        boost.unpause(id);
        assertFalse(boost.gauge(id).paused);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        assertEq(boost.claim(id, none, alice), owedAtWithdrawal);
    }

    function test_pause_voidsAQueuedUnpause() public {
        _appointGuardian();
        bytes32 unpauseKind = boost.UNPAUSE();
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.GaugeNotPaused.selector, id));
        boost.queue(unpauseKind, abi.encode(id));
        vm.prank(guardian);
        boost.pause(id);
        _queued(boost.UNPAUSE(), abi.encode(id));
        // The guardian brakes again: the queued unpause is void.
        vm.prank(guardian);
        boost.pause(id);
        vm.prank(gov);
        vm.expectRevert();
        boost.unpause(id);
        assertTrue(boost.gauge(id).paused);
        // An unknown gauge cannot be paused or queued.
        PoolId unknown = PoolId.wrap(bytes32(uint256(7)));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.UnknownGauge.selector, unknown));
        boost.pause(unknown);
    }

    function test_pauseAll_stopsEveryGaugeAndGaugeCreation() public {
        _appointGuardian();
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        uint256 end = boost.gauge(id).periodFinish;
        vm.expectEmit(address(boost));
        emit IHookrLpBoost.AllPauseSet(true, gov);
        vm.prank(gov);
        boost.pauseAll();
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        vm.expectRevert(IHookrLpBoost.AllPaused.selector);
        boost.createGauge(k2, _terms(4, 52, 30_000));
        vm.expectRevert(IHookrLpBoost.AllPaused.selector);
        boost.notify(id, 0, 4);
        vm.prank(alice);
        vm.expectRevert(IHookrLpBoost.AllPaused.selector);
        boost.claim(id, _one(a), alice);
        vm.prank(alice);
        boost.collectFees(a, alice);
        // The guardian re-brakes: an UNPAUSE_ALL queued before is void.
        _queued(boost.UNPAUSE_ALL(), "");
        vm.prank(guardian);
        boost.pauseAll();
        vm.prank(gov);
        vm.expectRevert();
        boost.unpauseAll();
        _queued(boost.UNPAUSE_ALL(), "");
        vm.prank(gov);
        boost.unpauseAll();
        assertFalse(boost.pausedAll());
        bytes32 unpauseAll = boost.UNPAUSE_ALL();
        vm.prank(gov);
        vm.expectRevert(IHookrLpBoost.NotAllPaused.selector);
        boost.queue(unpauseAll, "");
        vm.warp(end);
        vm.prank(alice);
        assertApproxEqAbs(boost.claim(id, _one(a), alice), 4e21, 1);
    }

    /// The guardian is the registry's IHookrRegistry.guardian, read live, and the owner is checked first: with none
    /// appointed only the owner brakes, a removed guardian is refused at once, and when the registry's read reverts
    /// every other caller is refused while the owner still brakes, so no brake of the owner's depends on the read.
    function test_guardianReadFailsClosed() public {
        // No guardian appointed: only the owner brakes.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, guardian));
        boost.pauseAll();
        vm.prank(gov);
        boost.pauseAll();
        assertTrue(boost.pausedAll());

        // Appointed, the guardian brakes; removed, it is refused at once.
        _appointGuardian();
        vm.prank(guardian);
        boost.pause(id);
        registry.removeGuardian();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, guardian));
        boost.pause(id);

        // The registry's read reverts: the appointed guardian is refused with it, and the owner still brakes.
        _appointGuardian();
        vm.mockCallRevert(address(registry), abi.encodeCall(IHookrRegistry.guardian, ()), bytes("unavailable"));
        vm.prank(guardian);
        vm.expectRevert(bytes("unavailable"));
        boost.pause(id);
        vm.prank(gov);
        boost.pause(id);
        assertTrue(boost.gauge(id).paused);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------------------------

    /// @dev For any terms within the bounds and any lock within them, the boost is linear from 1x at minLockWeeks to
    ///      maxBoostBps at maxLockWeeks, rounded down, never above the maximum and never lower for a longer lock.
    function testFuzz_boost_linearWithinAnyTerms(uint16 minSeed, uint16 maxSeed, uint16 boostSeed, uint16 lockSeed)
        public
    {
        uint16 minLock = uint16(bound(minSeed, 1, 104));
        uint16 maxLock = uint16(bound(maxSeed, minLock, 104));
        uint16 maxBoost = uint16(bound(boostSeed, 10_000, 30_000));
        uint16 lock = uint16(bound(lockSeed, minLock, maxLock));
        HookrLpBoost fresh = _deployBoost();
        _activate(fresh);
        _listReward(fresh, address(reward));
        fresh.createGauge(key, _terms(minLock, maxLock, maxBoost));
        uint256 expected = minLock == maxLock
            ? maxBoost
            : 10_000 + uint256(maxBoost - 10_000) * (lock - minLock) / (maxLock - minLock);
        uint16 got = fresh.boostFor(id, lock);
        assertEq(got, expected);
        assertGe(got, 10_000);
        assertLe(got, maxBoost);
        if (lock < maxLock) assertLe(got, fresh.boostFor(id, lock + 1));
        if (minLock < maxLock) assertEq(fresh.boostFor(id, minLock), 10_000);
        assertEq(fresh.boostFor(id, maxLock), maxBoost);
    }

    /// @dev A stake at any time, with any lock and liquidity: its maturity is the first week boundary at least
    ///      lockWeeks weeks ahead, its weight is liquidity x boost / 10,000 rounded down, and its boost part waits in
    ///      that week's drop.
    function testFuzz_stake_maturityWeightAndDrop(uint32 offsetSeed, uint16 lockSeed, uint128 liquiditySeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(offsetSeed, 0, 3 * WEEK));
        uint16 lock = uint16(bound(lockSeed, 4, 52));
        uint128 liquidity = uint128(bound(liquiditySeed, FLOOR, 1e24));
        uint256 t = vm.getBlockTimestamp();
        uint256 tokenId = _mintAndStake(alice, liquidity, lock);
        IHookrLpBoost.Stake memory s = boost.stakeOf(tokenId);
        assertEq(s.maturity % WEEK, 0);
        assertGe(s.maturity, t + uint256(lock) * WEEK);
        assertLt(s.maturity, t + uint256(lock + 1) * WEEK);
        uint16 b = boost.boostFor(id, lock);
        assertEq(s.boostBps, b);
        uint256 weight = uint256(liquidity) * b / 10_000;
        assertEq(boost.gauge(id).totalWeight, weight);
        (uint256 drop,) = boost.weekState(id, s.maturity);
        assertEq(drop, weight - liquidity);
    }

    /// @dev Two stakes of any liquidities and locks share any span of a period by weight: each earns its share of the
    ///      emission within a unit of rounding, and together never more than was emitted.
    function testFuzz_accrual_twoStakesShareByWeight(
        uint128 liquidityA,
        uint128 liquidityB,
        uint16 lockA,
        uint16 lockB,
        uint32 elapsedSeed,
        uint96 budgetSeed
    ) public {
        liquidityA = uint128(bound(liquidityA, FLOOR, 1e24));
        liquidityB = uint128(bound(liquidityB, FLOOR, 1e24));
        lockA = uint16(bound(lockA, 4, 52));
        lockB = uint16(bound(lockB, 4, 52));
        uint256 budget = bound(budgetSeed, 1e6, 1e27);
        uint256 a = _mintAndStake(alice, liquidityA, lockA);
        uint256 b = _mintAndStake(bob, liquidityB, lockB);
        _notify(budget, 4);
        // Within the period and before any boost ends (every maturity is at least four weeks out).
        uint256 elapsed = bound(elapsedSeed, 1, 4 weeks);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 emitted = budget * elapsed / 4 weeks;
        uint256 weightA = uint256(liquidityA) * boost.boostFor(id, lockA) / 10_000;
        uint256 weightB = uint256(liquidityB) * boost.boostFor(id, lockB) / 10_000;
        uint256 pa = boost.pendingRewards(a);
        uint256 pb = boost.pendingRewards(b);
        assertLe(pa + pb, emitted);
        assertApproxEqAbs(pa, emitted * weightA / (weightA + weightB), 1);
        assertApproxEqAbs(pb, emitted * weightB / (weightA + weightB), 1);
    }

    /// @dev Across maturities, idle weeks and the period's end, a claim pays exactly what pendingRewards showed, and a
    ///      second claim in the same block pays nothing.
    function testFuzz_pendingRewards_isWhatAClaimPays(uint32[4] memory gaps, uint16 lockSeed) public {
        uint256 a = _mintAndStake(alice, 1e18, uint16(bound(lockSeed, 4, 52)));
        _mintAndStake(bob, 2e18, 52);
        _notify(52e21, 52);
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 0, 20 weeks));
            uint256 pending = boost.pendingRewards(a);
            assertEq(_claim(alice, a), pending);
            assertEq(_claim(alice, a), 0);
        }
    }

    /// @dev Four tranches of any amounts and lengths, notified and funded at any times beside one another: at any
    ///      moment the one stake in the gauge has earned what each tranche emits evenly from its start to its end, to
    ///      within rounding and never more, and by the last end every amount whole.
    function testFuzz_tranches_eachEmitsItsAmountToItsEnd(
        uint96[4] memory amounts,
        uint8[4] memory lengths,
        uint32[4] memory gaps,
        uint32 checkSeed
    ) public {
        uint256 a = _mintAndStake(alice, 1e18, 52);
        uint256[3][4] memory tranches;
        uint256 total;
        uint256 last;
        for (uint256 i; i < 4; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 0, 6 weeks));
            uint256 amount = bound(amounts[i], 1, 1e27);
            uint16 weeks_ = uint16(bound(lengths[i], 1, 52));
            uint256 start = vm.getBlockTimestamp();
            uint256 finish = (start + uint256(weeks_) * WEEK + WEEK - 1) / WEEK * WEEK;
            tranches[i] = [start, finish, amount];
            total += amount;
            if (finish > last) last = finish;
            if (i % 2 == 0) _notify(amount, weeks_);
            else _fund(sponsor, amount, weeks_);
        }
        assertEq(boost.gauge(id).periodFinish, last);
        vm.warp(bound(checkSeed, vm.getBlockTimestamp(), last + 1 weeks));
        uint256 exact;
        for (uint256 i; i < 4; ++i) {
            uint256 end = vm.getBlockTimestamp() < tranches[i][1] ? vm.getBlockTimestamp() : tranches[i][1];
            exact += FullMath.mulDiv(tranches[i][2], end - tranches[i][0], tranches[i][1] - tranches[i][0]);
        }
        uint256 pending = boost.pendingRewards(a);
        assertLe(pending, exact + 5, "never ahead of the tranches");
        assertGe(pending + 16, exact, "behind them by rounding only");
        vm.warp(last);
        pending = boost.pendingRewards(a);
        assertLe(pending, total);
        assertGe(pending + 3, total, "every amount by the last end");
        assertEq(_claim(alice, a), pending);
        assertEq(boost.gauge(id).scheduled, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _one(uint256 tokenId) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    function _lastToken() internal view returns (uint256) {
        return posm.nextTokenId() - 1;
    }

    function _op(HookrLpBoost b, bytes32 kind, bytes memory arguments) internal view returns (bytes32) {
        return b.operationHash(kind, arguments);
    }

    /// @dev A plain ERC-20 with no bound built in: `supply` minted to this contract, approved to the launcher.
    function _plain(uint256 supply) internal returns (MockERC20 plain) {
        plain = new MockERC20("Plain", "PLN", 18);
        plain.mint(address(this), supply);
        plain.approve(address(launcher), type(uint256).max);
    }

    /// @dev `_checkCeiling`'s ceiling as documented: min(the maximum liquidity per tick, B + isqrt(C)) with B = ceil(
    ///      ceil(lower x upper / 2^96) x b0 / span) + ceil(b1 x 2^96 / span) and C = ceil(b0 x b1 x upper / span), the
    ///      supply side dropped once b0 x b1 reaches 2^255; and B.
    function _ceiling(int24 spacing, uint160 lower, uint160 upper, uint256 b0, uint256 b1)
        internal
        pure
        returns (uint256 ceiling, uint256 bTerm)
    {
        ceiling = Pool.tickSpacingToMaxLiquidityPerTick(spacing);
        uint256 span = upper - lower;
        bTerm = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(lower, upper, FixedPoint96.Q96), b0, span)
            + FullMath.mulDivRoundingUp(b1, FixedPoint96.Q96, span);
        if (b0 > type(uint256).max / b1 || (b0 * b1) >> 255 != 0) return (ceiling, bTerm);
        uint256 supply = bTerm + Math.sqrt(FullMath.mulDivRoundingUp(b0 * b1, upper, span));
        if (supply < ceiling) ceiling = supply;
    }

    /// @dev The most liquidity a full-range position could be minted with inside the usable range while paying no more
    ///      than b0 of currency0 and b1 of currency1, SqrtPriceMath rounding the amounts up as a mint does: at sqrt
    ///      price x it pays ceil(L x (x - lower) / 2^96) of currency1, so the highest x within b1 is lower + floor(b1 x
    ///      2^96 / L), where it pays the least currency0 any affordable price asks. Found by bisection, a position of
    ///      more being unaffordable at every price.
    function _mostFundable(uint160 lower, uint160 upper, uint256 b0, uint256 b1) internal pure returns (uint256 lo) {
        uint256 hi = type(uint128).max;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_fundable(lower, upper, b0, b1, uint128(mid))) lo = mid;
            else hi = mid - 1;
        }
    }

    function _fundable(uint160 lower, uint160 upper, uint256 b0, uint256 b1, uint128 liquidity)
        internal
        pure
        returns (bool)
    {
        uint256 room = FullMath.mulDiv(b1, FixedPoint96.Q96, liquidity);
        if (room >= upper - lower) return true;
        uint160 x = uint160(lower + room);
        return SqrtPriceMath.getAmount0Delta(x, upper, liquidity, true) <= b0;
    }

    function _mintFullRangeOf(address lp, PoolKey memory k, uint128 liquidity) internal returns (uint256) {
        return _mint(lp, k, TickMath.minUsableTick(k.tickSpacing), TickMath.maxUsableTick(k.tickSpacing), liquidity);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Bounds
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The whole reward supply over one week to one stake of MIN_LIQUIDITY, the least weight any gauge can hold
    ///      (a gauge whose minLiquidity is the bound itself, on the small tokens' pool where the sizing rule allows
    ///      it): the accumulator stays exact.
    function test_accrual_largestBudgetOnTheLeastWeight() public {
        (, PoolKey memory k2) = _launchSmall(1e18, SPACING, 3000);
        PoolId id2 = k2.toId();
        uint128 least = LEAST_LIQUIDITY;
        boost.createGauge(k2, _terms(4, 52, 30_000, least));
        (int24 lower, int24 upper) = _fullRange();
        uint256 a = _mint(alice, k2, lower, upper, least);
        _stake(alice, a, 4);
        uint256 all = reward.balanceOf(address(this));
        reward.approve(address(boost), all);
        boost.notify(id2, all, 1);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256 pending = boost.pendingRewards(a);
        assertLe(pending, all);
        assertGe(pending + 1, all);
        assertEq(boost.gauge(id2).rewardPerWeightX128, 0);
        vm.prank(alice);
        assertEq(boost.claim(id2, _one(a), alice), pending);
        assertEq(boost.gauge(id2).rewardPerWeightX128, FullMath.mulDiv(all, Q128, least));
    }

    /// @dev For any minLiquidity a gauge may set and any position, the stake is refused exactly when the position holds
    ///      less: LiquidityTooLow names both amounts.
    function testFuzz_stake_refusedExactlyBelowTheGaugesMinLiquidity(uint128 floorSeed, uint128 liquiditySeed) public {
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        uint128 floor = uint128(bound(floorSeed, _sizingFloor(k2), 1e24));
        uint128 liquidity = uint128(bound(liquiditySeed, 1, 2e24));
        boost.createGauge(k2, _terms(4, 52, 30_000, floor));
        (int24 lower, int24 upper) = _fullRange();
        uint256 a = _mint(alice, k2, lower, upper, liquidity);
        vm.startPrank(alice);
        posm.approve(address(boost), a);
        if (liquidity < floor) {
            vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.LiquidityTooLow.selector, liquidity, floor));
            boost.stake(a, 4);
            assertEq(boost.stakeOf(a).owner, address(0));
        } else {
            boost.stake(a, 4);
            assertEq(boost.stakeOf(a).liquidity, liquidity);
        }
        vm.stopPrank();
    }
}
