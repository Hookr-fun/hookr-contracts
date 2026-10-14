// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";
import {RulesData} from "../utils/RulesData.sol";

/// @notice A launcher that is its pools' liquidity owner and can swap on them: steps run in one PoolManager unlock,
///         each `kind << 128 | amount`, kind 0 adding liquidity, 1 buying with `amount` quote and 2 selling `amount`
///         subject, exact input.
contract OwnerLauncher is IUnlockCallback {
    IPoolManager internal immutable manager;
    HookrRoot internal immutable root;
    PoolKey internal key;
    int24 internal lower;
    int24 internal upper;
    bool internal quoteIs0;

    constructor(IPoolManager manager_, HookrRoot root_) {
        manager = manager_;
        root = root_;
    }

    /// @dev Initializes the pool with this contract as liquidity owner, then runs `steps` in the same transaction.
    function open(
        PoolKey calldata k,
        HookrTypes.PoolConfig calldata pc,
        bytes calldata rulesData,
        int24 lo,
        int24 hi,
        uint256[] calldata steps
    ) external {
        key = k;
        lower = lo;
        upper = hi;
        quoteIs0 = pc.quote == k.currency0;
        root.initializePool(k, pc, rulesData, "", SQRT_ONE);
        manager.unlock(abi.encode(steps));
    }

    function focus(PoolKey calldata k, bool quoteIs0_) external {
        key = k;
        quoteIs0 = quoteIs0_;
    }

    function run(uint256[] calldata steps) external {
        manager.unlock(abi.encode(steps));
    }

    uint160 internal constant SQRT_ONE = uint160(1 << 96);

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256[] memory steps = abi.decode(data, (uint256[]));
        PoolKey memory k = key;
        for (uint256 i; i < steps.length; ++i) {
            uint256 kind = steps[i] >> 128;
            int256 amount = int256(uint256(uint128(steps[i])));
            BalanceDelta d;
            if (kind == 0) {
                (d,) = manager.modifyLiquidity(k, ModifyLiquidityParams(lower, upper, amount, 0), "");
            } else {
                bool zeroForOne = kind == 1 ? quoteIs0 : !quoteIs0;
                d = manager.swap(
                    k,
                    SwapParams(
                        zeroForOne, -amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    ),
                    ""
                );
            }
            _settle(k.currency0, d.amount0());
            _settle(k.currency1, d.amount1());
        }
        return "";
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), uint128(-amount));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, address(this), uint128(amount));
        }
    }
}

/// @notice DB-01. A launch's dev buy is charged from the launch price and leaves the dynamic fee state unstarted, so the
///         pool's next swap starts it at the post-buy price and every later swap is charged as on a pool launched
///         there: the next buyers pay for their own moves only, and a sell pays for its own move too. Before this
///         change a first buy carried the anchor to its executed price and the next buyer was charged from there. The
///         treatment belongs to one buy: the liquidity owner's first counted buy in the transaction that bound the
///         pool, which also closes that parent block to every other buy.
contract LauncherDevBuyReferenceTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal constant ETH = Currency.wrap(address(0));
    uint128 internal constant DEV = 4e22;
    uint128 internal constant FOLLOW = 1e22;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev A dynamic fee member: sensitivity 10, 5% ceiling, a 20% protocol share, a 1-pip Snipe for one parent block
    ///      (the least guard a dev buy takes) and no LP Rewards, Auto Burn or royalty, so a buy after the launch parent
    ///      block has an LP fee of the 0.3% base plus 80% of its dynamic fee.
    function _dynamic(IHookrLauncher.Member memory m) internal view returns (IHookrLauncher.Member memory) {
        m.rules.maxFeePips = 50_000;
        m.rules.dynamicFeeSens = 10;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 1);
        m.rules.snipeTaxPips = 1;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = 2000;
        return m;
    }

    function _devPool() internal returns (bytes32 family, PoolKey memory key) {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0] = _dynamic(members[0]);
        (family,,) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, DEV, 1, 0));
        key = launcher.position(family, 0).key;
    }

    /// @dev The same member launched at `price` without a dev buy.
    function _plainPool(uint160 price, uint128 liquidity) internal returns (bytes32 family, PoolKey memory key) {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = _one(subject, ETH);
        members[0] = _dynamic(members[0]);
        members[0].sqrtPriceX96 = price;
        members[0].liquidity = liquidity;
        members[0].amount0Max = 1e24;
        (family,) = launcher.launch{value: 1e24}(t, address(root), members, vm.getBlockTimestamp());
        key = launcher.position(family, 0).key;
    }

    function _lpFee(PoolKey memory key, bool buy, uint128 amount) internal returns (uint256) {
        return quoter.quote(_swap(key, buy, true, amount), trader).lpFeePips;
    }

    /// @dev The dynamic fee in pips behind an LP fee on these members: base 3,000 plus 80% of the dynamic fee.
    function _dyn(uint256 lpFee) internal pure returns (uint256) {
        return (lpFee - 3000) * 10_000 / 8000;
    }

    function test_devBuyLeavesTheDynamicFeeStateUnstarted() public {
        (bytes32 family, PoolKey memory key) = _devPool();
        (uint256 minLiquidity, int24 ref, int24 anchor, uint40 movedAt, uint40 referenceAt, int24 moved) =
            rules.referenceState(key.toId());
        assertEq(minLiquidity, launcher.position(family, 0).liquidity / 100, "min liquidity");
        assertEq(ref, 0, "no reference");
        assertEq(anchor, 0, "no anchor");
        assertEq(moved, 0, "no moved tick");
        assertEq(movedAt, 0, "not started");
        assertEq(referenceAt, 0, "not started");
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertLt(tick, -200, "the dev buy moved the price well past a counted move");

        // The next swap starts the state at the post-buy price.
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 5);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        vm.prank(trader);
        router.swap{value: 1e18}(p, address(0), new uint256[](0));
        (, ref,, movedAt, referenceAt,) = rules.referenceState(key.toId());
        assertEq(ref, tick, "reference at the post-buy tick");
        assertEq(referenceAt, vm.getBlockTimestamp(), "started by the first public swap");
        assertEq(movedAt, vm.getBlockTimestamp());
    }

    /// @notice The next buyer pays the fee of the same buy on a pool launched at the post-dev-buy price, in the next
    ///         parent block and after the reset, with no (1 + d)^2 of measuring from the launch price; under the old
    ///         rule it paid from the dev buy's end.
    function test_followerPaysOnlyItsOwnMove() public {
        (bytes32 family, PoolKey memory dev) = _devPool();
        (uint160 p1,,,) = manager.getSlot0(dev.toId());
        uint128 liquidity = launcher.position(family, 0).liquidity;
        // d: the dev buy's distance from the launch price, sqrt(ref) / sqrt(p1) - 1, in WAD.
        uint256 d = FullMath.mulDiv(SQRT_ONE, 1e18, p1) - 1e18;
        (, PoolKey memory control) = _plainPool(p1, liquidity);
        // Old rule: the first buy is a public one of the same size, and it carries the anchor.
        (, PoolKey memory old) = _plainPool(SQRT_ONE, liquidity);
        IHookrRouter.Swap memory first = _swap(old, true, true, DEV);
        vm.prank(trader);
        router.swap{value: DEV}(first, address(0), new uint256[](0));
        (uint160 oldPrice,,,) = manager.getSlot0(old.toId());
        assertApproxEqRel(oldPrice, p1, 1e15, "same move as the dev buy");
        vm.roll(vm.getBlockNumber() + 1);
        uint256 feeDev = _dyn(_lpFee(dev, true, FOLLOW));
        uint256 feeControl = _dyn(_lpFee(control, true, FOLLOW));
        uint256 feeOld = _dyn(_lpFee(old, true, FOLLOW));
        console2.log("dev buy sqrt-price move (1e18)", d);
        console2.log("follower dynamic fee after a dev buy (pips of 47,000)", feeDev);
        console2.log("same buy on a pool launched at the post-dev-buy price", feeControl);
        console2.log("follower dynamic fee under the old rule", feeOld);
        assertApproxEqAbs(feeDev, feeControl, feeControl / 100 + 2, "the control's fee");
        assertGt(feeOld, 10 * feeDev, "the old rule charged the follower from the dev buy's end");
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.roll(vm.getBlockNumber() + 50);
        feeDev = _dyn(_lpFee(dev, true, FOLLOW));
        feeControl = _dyn(_lpFee(control, true, FOLLOW));
        console2.log("after the reset: dev / control", feeDev, feeControl);
        assertApproxEqAbs(feeDev, feeControl, feeControl / 100 + 2, "the control's fee after the reset");
    }

    /// @notice A thin dev-buy member, 10% of supply, whose dev buy moves the sqrt price ~72%: ten minutes on, the next
    ///         buyer pays the control's fee, not (1 + d)^2 times it.
    function test_thinMemberFollowerPaysTheControlFeeAfterTheReset() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _dynamic(_devMember(subject, ETH, SUPPLY / 10));
        members[0].rules.maxBuyQuoteAmount = 1e24;
        members[1] = _devMember(subject, Currency.wrap(address(tokenA)), SUPPLY - SUPPLY / 10);
        (bytes32 family,,) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(0, 8e22, 1, 0));
        PoolKey memory dev = launcher.position(family, 0).key;
        (uint160 p1,,,) = manager.getSlot0(dev.toId());
        assertGt(FullMath.mulDiv(SQRT_ONE, 1e18, p1) - 1e18, 0.5e18, "a large move");
        (, PoolKey memory control) = _plainPool(p1, launcher.position(family, 0).liquidity);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.roll(vm.getBlockNumber() + 50);
        uint256 feeDev = _dyn(_lpFee(dev, true, 1e21));
        uint256 feeControl = _dyn(_lpFee(control, true, 1e21));
        console2.log("thin member, t+600: dev / control", feeDev, feeControl);
        assertApproxEqAbs(feeDev, feeControl, feeControl / 100 + 2, "the control's fee");
    }

    /// @notice A creator sell between the dev buy and the next buyer starts the state at the post-buy price and pays
    ///         for its own move; the next buyer then pays no more than without it.
    function test_sellBetweenDevBuyAndFollowerKeepsTheControlBound() public {
        (bytes32 family, PoolKey memory dev) = _devPool();
        (uint160 p1,,,) = manager.getSlot0(dev.toId());
        (, PoolKey memory control) = _plainPool(p1, launcher.position(family, 0).liquidity);
        uint128 sold = uint128(IERC20(Currency.unwrap(dev.currency1)).balanceOf(address(this)) / 100);
        uint256 sellDev = _lpFee(dev, false, sold);
        uint256 sellControl = _lpFee(control, false, sold);
        console2.log("the 1% sell, LP fee pips: dev / control", sellDev, sellControl);
        assertApproxEqAbs(sellDev, sellControl, sellControl / 100 + 2, "the sell pays what it pays on the control");
        IERC20(Currency.unwrap(dev.currency1)).approve(address(router), sold);
        IHookrRouter.Swap memory sell = _swap(dev, false, true, sold);
        sell.recipient = address(this);
        router.swap(sell, address(0), new uint256[](0));
        vm.roll(vm.getBlockNumber() + 1);
        uint256 feeDev = _dyn(_lpFee(dev, true, FOLLOW));
        uint256 feeControl = _dyn(_lpFee(control, true, FOLLOW));
        console2.log("follower after a 1% creator sell: dev / control", feeDev, feeControl);
        assertLe(feeDev, feeControl + feeControl / 100 + 2, "within the control bound");
    }

    /// @notice A sell back toward the launch price pays the dynamic fee of the same sell on a pool launched at the
    ///         post-dev-buy price.
    function test_sellAfterTheDevBuyPaysItsOwnMove() public {
        (bytes32 family, PoolKey memory dev) = _devPool();
        (uint160 p1,,,) = manager.getSlot0(dev.toId());
        (, PoolKey memory control) = _plainPool(p1, launcher.position(family, 0).liquidity);
        vm.roll(vm.getBlockNumber() + 1);
        uint128 half = uint128(IERC20(Currency.unwrap(dev.currency1)).balanceOf(address(this)) / 2);
        uint256 feeDev = _lpFee(dev, false, half);
        uint256 feeControl = _lpFee(control, false, half);
        console2.log("sell of half the dev buy, LP fee pips: dev / control", feeDev, feeControl);
        assertGt(feeDev, 3000, "a dynamic fee");
        assertApproxEqAbs(feeDev, feeControl, feeControl / 100 + 2, "the control's fee");
    }

    /// @notice A creator router buy in the next parent block is an ordinary public buy: it pays its dynamic fee (20% of
    ///         it to the protocol) and carries the anchor, so the buyer after it pays more, exactly as after the same
    ///         buy on a pool launched at the post-dev-buy price.
    function test_creatorRouterBuyNextBlockMatchesTheControl() public {
        (bytes32 family, PoolKey memory dev) = _devPool();
        (uint160 p1,,,) = manager.getSlot0(dev.toId());
        (, PoolKey memory control) = _plainPool(p1, launcher.position(family, 0).liquidity);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 before = _dyn(_lpFee(dev, true, FOLLOW));
        uint256 claimed = rules.claimable(ETH, protocol);
        IHookrRouter.Swap memory p = _swap(dev, true, true, DEV);
        p.recipient = address(this);
        router.swap{value: DEV}(p, address(0), new uint256[](0));
        assertGt(rules.claimable(ETH, protocol), claimed, "the creator's router buy paid the protocol share");
        p = _swap(control, true, true, DEV);
        p.recipient = address(this);
        router.swap{value: DEV}(p, address(0), new uint256[](0));
        vm.roll(vm.getBlockNumber() + 1);
        uint256 afterBuy = _dyn(_lpFee(dev, true, FOLLOW));
        uint256 afterControl = _dyn(_lpFee(control, true, FOLLOW));
        console2.log("follower dynamic fee after the dev buy", before);
        console2.log(
            "follower dynamic fee after a creator router buy of the same size: dev / control", afterBuy, afterControl
        );
        assertGt(afterBuy, before, "a public buy carries the anchor");
        assertApproxEqAbs(afterBuy, afterControl, afterControl / 100 + 2, "as on the control");
    }

    // ------------------------------------------------------------------------------------------------ single use

    OwnerLauncher internal owner;
    HookrToken internal ownSubject;

    function _owner() internal {
        owner = new OwnerLauncher(manager, root);
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(owner), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(owner), true);
        tokenB.transfer(address(owner), 1e26);
    }

    /// @dev A pool of a fresh subject against tokenB, opened by `owner` at price 1 with a band of ±60,000 ticks.
    function _open(uint256[] memory steps) internal returns (PoolKey memory key) {
        (HookrTypes.PoolConfig memory pc, bytes memory data) = _prepare();
        key = _ownKey();
        owner.open(key, pc, data, -60_000, 60_000, steps);
    }

    function _ownKey() internal view returns (PoolKey memory) {
        Currency subject = Currency.wrap(address(ownSubject));
        Currency quote = Currency.wrap(address(tokenB));
        bool subjectFirst = address(ownSubject) < address(tokenB);
        return PoolKey(
            subjectFirst ? subject : quote,
            subjectFirst ? quote : subject,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(root))
        );
    }

    /// @dev Deploys a fresh subject held by `owner` and returns its pool config and Rules data.
    function _prepare() internal returns (HookrTypes.PoolConfig memory pc, bytes memory data) {
        ownSubject = new HookrToken("Own", "OWN", 1e30, address(owner));
        Currency subject = Currency.wrap(address(ownSubject));
        Currency quote = Currency.wrap(address(tokenB));
        IHookrLauncher.Member memory m = _dynamic(_member(quote));
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        m.rules.maxBuyQuoteAmount = CAP;
        pc = m.config;
        pc.subject = subject;
        pc.quote = quote;
        pc.liquidityOwner = address(owner);
        data = RulesData.encode(m.rules, 1e22);
    }

    function _step(uint256 kind, uint128 amount) internal pure returns (uint256) {
        return kind << 128 | amount;
    }

    /// @notice A second liquidity-owner buy in the launch transaction is refused: the first closed the parent block.
    function test_secondOwnerBuyInTheLaunchTransactionIsRefused() public {
        _owner();
        uint256[] memory steps = new uint256[](3);
        steps[0] = _step(0, 1e24);
        steps[1] = _step(1, 1e22);
        steps[2] = _step(1, 1e22);
        (HookrTypes.PoolConfig memory pc, bytes memory data) = _prepare();
        PoolKey memory refused = _ownKey();
        (bool ok, bytes memory ret) =
            address(owner).call(abi.encodeCall(OwnerLauncher.open, (refused, pc, data, -60_000, 60_000, steps)));
        _capRefusal(ok, ret);
        uint256[] memory one = new uint256[](2);
        one[0] = steps[0];
        one[1] = steps[1];
        PoolKey memory key = _open(one);
        (, int24 ref, int24 anchor, uint40 movedAt,,) = rules.referenceState(key.toId());
        assertEq(ref, 0);
        assertEq(anchor, 0, "the launch buy moved no anchor");
        assertEq(movedAt, 0, "and started no state");
    }

    /// @notice A liquidity-owner sell is priced and settled like any sell: it carries the anchor.
    function test_ownerSellIsNotALaunchBuy() public {
        _owner();
        uint256[] memory steps = new uint256[](2);
        steps[0] = _step(0, 1e24);
        steps[1] = _step(2, 1e22);
        PoolKey memory key = _open(steps);
        (, int24 ref, int24 anchor,,,) = rules.referenceState(key.toId());
        assertEq(ref, 0, "reference at the launch tick");
        assertTrue(anchor != 0, "the sell carried the anchor");
    }

    /// @notice The launch buy is bound to the pool bound last: once another capped pool binds, the first pool's owner
    ///         buy is an ordinary buy that carries the anchor and leaves the parent block open.
    function test_ownerBuyAfterAnotherBindIsOrdinary() public {
        _owner();
        uint256[] memory add = new uint256[](1);
        add[0] = _step(0, 1e24);
        PoolKey memory first = _open(add);
        HookrToken firstSubject = ownSubject;
        _open(add);
        owner.focus(first, first.currency0 == Currency.wrap(address(tokenB)));
        uint256[] memory buy = new uint256[](1);
        buy[0] = _step(1, 1e22);
        owner.run(buy);
        (, int24 ref, int24 anchor,,,) = rules.referenceState(first.toId());
        assertEq(ref, 0);
        assertTrue(anchor != 0, "an ordinary buy carries the anchor");
        IHookrRouter.Swap memory p = _swap(first, true, true, 1e18);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        assertGt(firstSubject.balanceOf(trader), 0, "the parent block stays open");
    }
}

/// @notice DB-01, later transaction. Each call is its own transaction here, as on chain: the launch buy's marker is
///         transient, so a liquidity-owner buy in a later transaction than the bind is an ordinary buy.
/// forge-config: default.isolate = true
contract LauncherDevBuyLaterTransactionTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;

    OwnerLauncher internal owner;

    function setUp() public {
        _setUpPeriphery();
        owner = new OwnerLauncher(manager, root);
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(owner), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(owner), true);
        tokenB.transfer(address(owner), 1e26);
    }

    function test_ownerBuyInALaterTransactionIsOrdinary() public {
        HookrToken subjectToken = new HookrToken("Own", "OWN", 1e30, address(owner));
        Currency subject = Currency.wrap(address(subjectToken));
        Currency quote = Currency.wrap(address(tokenB));
        bool subjectFirst = address(subjectToken) < address(tokenB);
        PoolKey memory key = PoolKey(
            subjectFirst ? subject : quote,
            subjectFirst ? quote : subject,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(root))
        );
        IHookrLauncher.Member memory m = _member(quote);
        m.rules.maxFeePips = 50_000;
        m.rules.dynamicFeeSens = 10;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        m.rules.maxBuyQuoteAmount = CAP;
        HookrTypes.PoolConfig memory pc = m.config;
        pc.subject = subject;
        pc.quote = quote;
        pc.liquidityOwner = address(owner);
        uint256[] memory add = new uint256[](1);
        add[0] = uint256(1e24);
        owner.open(key, pc, RulesData.encode(m.rules, 1e22), -60_000, 60_000, add);
        uint256[] memory buy = new uint256[](1);
        buy[0] = uint256(1) << 128 | 1e22;
        owner.run(buy);
        (, int24 ref, int24 anchor,,,) = rules.referenceState(key.toId());
        assertEq(ref, 0);
        assertTrue(anchor != 0, "a later-transaction owner buy carries the anchor");
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        assertGt(subjectToken.balanceOf(trader), 0, "the parent block stays open");
    }
}
