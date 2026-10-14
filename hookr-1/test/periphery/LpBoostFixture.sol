// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrLpBoost} from "../../src/periphery/HookrLpBoost.sol";
import {IHookrLpBoost} from "../../src/interfaces/IHookrLpBoost.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {IPositionManagerMinimal} from "../../src/interfaces/external/IPositionManagerMinimal.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";

/// @notice The PositionManager calls the suites make besides the ones HookrLpBoost uses.
interface IPositionManagerTest is IPositionManagerMinimal {
    function nextTokenId() external view returns (uint256);
    function approve(address spender, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data) external payable;
    function unsubscribe(uint256 tokenId) external payable;
    function positionInfo(uint256 tokenId) external view returns (uint256);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable;
    function permitForAll(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external payable;
}

/// @notice Permit2's allowance call.
interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice A subscriber that accepts every notification.
contract NoopSubscriber {
    function notifySubscribe(uint256, bytes memory) external {}
    function notifyUnsubscribe(uint256) external {}
    function notifyBurn(uint256, address, uint256, uint256, int256) external {}
    function notifyModifyLiquidity(uint256, int256, int256) external {}
}

/// @notice HookrLpBoost on the real 4663 PoolManager, Permit2 and v4 PositionManager runtimes, etched at their chain
///         addresses, next to a Hookr stack deployed from its build artifacts: a registry, router, quoter, launcher,
///         root and Rules, a fee-only pool on an ERC-20 quote launched by this contract (its family owner), a reward
///         token on the list and the pool's gauge created by its family owner with a minLiquidity of FLOOR. Every
///         token is a HookrToken, so its fixed supply is its supply bound: 10^30 each, and SMALL_SUPPLY for the two
///         small tokens a gauge at MIN_LIQUIDITY needs. LP positions are minted through the PositionManager; the price
///         moves through v4-core's PoolSwapTest.
abstract contract LpBoostFixture is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_ONE = uint160(1 << 96);
    int24 internal constant SPACING = 60;
    uint48 internal constant DELAY = 30 minutes;
    uint256 internal constant WEEK = 7 days;
    /// @dev A Thursday 00:00 UTC (a week boundary) in 2026, so the suites start on a boundary.
    uint256 internal constant START = 1_790_208_000;
    /// @dev keccak256 of the 4663 v4 PositionManager's runtime (Chain4663Code.POSITION_MANAGER), which HookrLpBoost
    ///      pins.
    bytes32 internal constant POSITION_MANAGER_CODE_HASH =
        0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2;
    /// @dev HookrLpBoost's MIN_LIQUIDITY (test_constructor_pinsWiring pins it): the least minLiquidity a gauge may set.
    uint128 internal constant LEAST_LIQUIDITY = 1_000_000;
    /// @dev The fixture gauge's minLiquidity: a full-range position of 10^15 holds 10^15 raw units of each token at
    ///      price 1, a thousandth of a token. The sizing rule asks for about 5.4e10 at the suites' tick spacings on a
    ///      pool of two 10^30 supplies or of native ETH and one, so FLOOR meets it on every pool they launch from them.
    uint128 internal constant FLOOR = 1e15;
    /// @dev The supply of each small token: under the about 1.8e25 a full-range position of MIN_LIQUIDITY owns on an
    ///      edge of the usable range at the suites' tick spacings, so a gauge on the small tokens' pool may set
    ///      MIN_LIQUIDITY itself.
    uint256 internal constant SMALL_SUPPLY = 1e25;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant INCREASE_LIQUIDITY_FROM_DELTAS = 0x04;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;
    uint8 internal constant SWEEP = 0x14;
    /// @dev The PositionManager's error for a caller that neither owns nor is approved for a position.
    bytes4 internal constant NOT_APPROVED = bytes4(keccak256("NotApproved(address)"));
    /// @dev The PositionManager's error for an `approve` by neither the owner nor an operator of the owner.
    bytes4 internal constant POSM_UNAUTHORIZED = bytes4(keccak256("Unauthorized()"));

    IPoolManager internal manager;
    IPositionManagerTest internal posm;
    address internal permit2;
    HookrRegistry internal registry;
    HookrLauncher internal launcher;
    address internal root;
    HookrRules internal rules;
    address internal router;
    address internal quoter;
    PoolSwapTest internal swapper;
    HookrToken internal subject;
    HookrToken internal quote;
    HookrToken internal reward;
    HookrToken internal smallSubject;
    HookrToken internal smallQuote;
    HookrLpBoost internal boost;

    PoolKey internal key;
    PoolId internal id;
    bytes32 internal family;

    address internal protocol = address(0x1001);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal mallory = makeAddr("mallory");
    address internal sponsor = makeAddr("sponsor");
    address internal guardian = makeAddr("guardian");
    /// @dev The gauge's governance owner (the Safe in the release).
    address internal gov = makeAddr("gov");

    function setUp() public virtual {
        vm.warp(START);
        _etchChain();
        _deployStack(IPoolManager(Chain4663Code.POOL_MANAGER_ADDRESS));
        (family, key) = _launch(Currency.wrap(address(quote)), 1e24);
        id = key.toId();
        boost = _deployBoost();
        _activate(boost);
        _listReward(boost, address(reward));
        boost.createGauge(key, _terms(4, 52, 30_000, FLOOR));
        // Every suite starts on a week boundary.
        vm.warp(_weekAfter(vm.getBlockTimestamp()));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Chain and stack
    // ------------------------------------------------------------------------------------------------------------

    function _etchChain() internal {
        vm.etch(Chain4663Code.POOL_MANAGER_ADDRESS, Chain4663Code.POOL_MANAGER);
        vm.etch(Chain4663Code.PERMIT2_ADDRESS, Chain4663Code.PERMIT2);
        vm.etch(Chain4663Code.POSITION_MANAGER_ADDRESS, Chain4663Code.POSITION_MANAGER);
    }

    /// @dev The Hookr stack on `manager_`, every contract deployed from its artifact; this contract owns the registry.
    function _deployStack(IPoolManager manager_) internal {
        manager = manager_;
        posm = IPositionManagerTest(Chain4663Code.POSITION_MANAGER_ADDRESS);
        permit2 = Chain4663Code.PERMIT2_ADDRESS;
        registry = HookrRegistry(
            deployCode("HookrRegistry.sol:HookrRegistry", abi.encode(address(this), manager_, uint48(1 days)))
        );
        router = deployCode("HookrRouter.sol:HookrRouter", abi.encode(manager_, registry, address(0)));
        quoter = deployCode("HookrQuoter.sol:HookrQuoter", abi.encode(manager_, registry));
        launcher = HookrLauncher(payable(deployCode("HookrLauncher.sol:HookrLauncher", abi.encode(manager_, registry))));
        root = address(ReleaseWiring.deployRoot(manager_, registry, router, quoter, address(0)));
        rules = HookrRules(deployCode("HookrRules.sol:HookrRules", abi.encode(manager_, registry, protocol, root, 0)));
        ReleaseWiring.registerRootAndLauncher(registry, root, address(launcher));
        ReleaseWiring.admitAfterDelay(registry, root, ReleaseWiring.rulesAdmission(rules, 200_000));
        subject = _token("Subject", "SUB");
        quote = _token("Quote", "QTE");
        reward = _token("Reward", "RWD");
        smallSubject = _token("Small subject", "SSUB", SMALL_SUPPLY);
        smallQuote = _token("Small quote", "SQTE", SMALL_SUPPLY);
        address[] memory catalog = new address[](2);
        (catalog[0], catalog[1]) = (address(quote), address(smallQuote));
        ReleaseWiring.catalogQuotes(registry, catalog);
        swapper = new PoolSwapTest(manager_);
        HookrToken[4] memory tokens = [subject, quote, smallSubject, smallQuote];
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].approve(address(launcher), type(uint256).max);
            tokens[i].approve(address(swapper), type(uint256).max);
        }
        vm.deal(address(this), 1e30);
        // Back to a week boundary, so maturities in the suites fall where the tests expect them.
        vm.warp((vm.getBlockTimestamp() / WEEK + 1) * WEEK);
    }

    function _token(string memory name, string memory symbol) internal returns (HookrToken t) {
        return _token(name, symbol, 1e30);
    }

    function _token(string memory name, string memory symbol, uint256 supply) internal returns (HookrToken t) {
        t = HookrToken(deployCode("HookrToken.sol:HookrToken", abi.encode(name, symbol, supply, address(this))));
    }

    /// @dev A fee-only pool (the 0.3% base LP fee, nothing per swap) of `subject` against `quote_`, opened at price 1
    ///      with this contract's launch position over [-60,000, 60,000].
    function _launch(Currency quote_, uint128 liquidity) internal returns (bytes32 family_, PoolKey memory key_) {
        return _launch(quote_, liquidity, SPACING, 3000);
    }

    function _launch(Currency quote_, uint128 liquidity, int24 spacing)
        internal
        returns (bytes32 family_, PoolKey memory key_)
    {
        return _launch(quote_, liquidity, spacing, 3000);
    }

    /// @dev As above with a base LP fee of `lpFeePips`. Zero makes a pool that charges nothing per swap, which
    ///      HookrRules accepts wherever no Hookr minimum binds: an existing-token subject, an arb recapture pool, or
    ///      this fixture, whose protocol recipient is not a treasury.
    function _launch(Currency quote_, uint128 liquidity, int24 spacing, uint24 lpFeePips)
        internal
        returns (bytes32 family_, PoolKey memory key_)
    {
        return _launchOf(address(subject), quote_, liquidity, spacing, lpFeePips, 1e27);
    }

    /// @dev A pool of the two small tokens, as `_launch`; a gauge on it may set MIN_LIQUIDITY.
    function _launchSmall(uint128 liquidity, int24 spacing, uint24 lpFeePips)
        internal
        returns (bytes32 family_, PoolKey memory key_)
    {
        Currency small = Currency.wrap(address(smallQuote));
        return _launchOf(address(smallSubject), small, liquidity, spacing, lpFeePips, 1e23);
    }

    /// @dev A one-member existing-token family of `subject_` against `quote_` (this contract its family owner): see
    ///      `_launchToken`.
    function _launchOf(
        address subject_,
        Currency quote_,
        uint128 liquidity,
        int24 spacing,
        uint24 lpFeePips,
        uint128 budget
    ) internal returns (bytes32 family_, PoolKey memory key_) {
        return _launchToken(
            IHookrLauncher.Token(subject_, "", "", 0, bytes32(0)), quote_, liquidity, spacing, lpFeePips, budget
        );
    }

    /// @dev A one-member family of `token` (an existing token, or a new HookrToken the launcher deploys) against
    ///      `quote_`, this contract its family owner, opened at price 1 with its launch position of `liquidity` over
    ///      [-60,000, 60,000] rounded in to the tick spacing, paid from budgets of `budget` of each currency.
    function _launchToken(
        IHookrLauncher.Token memory token,
        Currency quote_,
        uint128 liquidity,
        int24 spacing,
        uint24 lpFeePips,
        uint128 budget
    ) internal returns (bytes32 family_, PoolKey memory key_) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory m;
        m.quote = quote_;
        m.tickSpacing = spacing;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000 / spacing * spacing;
        m.tickUpper = 60_000 / spacing * spacing;
        m.liquidity = liquidity;
        m.amount0Max = budget;
        m.amount1Max = budget;
        m.config.rules = address(rules);
        m.config.baseLpFeePips = lpFeePips;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("lp-boost");
        m.rules.maxFeePips = lpFeePips;
        m.rules.protocolShareBps = 2500;
        members[0] = m;
        (family_,) =
            launcher.launch{value: quote_.isAddressZero() ? budget : 0}(token, root, members, vm.getBlockTimestamp());
        key_ = launcher.position(family_, 0).key;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gauge
    // ------------------------------------------------------------------------------------------------------------

    function _deployBoost() internal returns (HookrLpBoost) {
        return new HookrLpBoost(
            IHookrRegistry(address(registry)),
            IHookrLauncherView(address(launcher)),
            IPositionManagerMinimal(address(posm)),
            gov,
            DELAY
        );
    }

    function _activate(HookrLpBoost b) internal {
        bytes32 kind = b.ACTIVATE();
        vm.prank(gov);
        b.queue(kind, "");
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(gov);
        b.activate();
    }

    function _listReward(HookrLpBoost b, address token) internal {
        bytes32 kind = b.ADD_REWARD_TOKEN();
        vm.prank(gov);
        b.queue(kind, abi.encode(token));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(gov);
        b.addRewardToken(token);
    }

    /// @dev Declares `bound` as `currency`'s supply bound on `b` through its queue.
    function _declareBound(HookrLpBoost b, address currency, uint256 bound) internal {
        bytes32 kind = b.SET_SUPPLY_BOUND();
        vm.prank(gov);
        b.queue(kind, abi.encode(currency, bound));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(gov);
        b.setSupplyBound(currency, bound);
    }

    /// @dev Queues `kind(arguments)` on the gauge as its owner and waits out the delay.
    function _queued(bytes32 kind, bytes memory arguments) internal {
        vm.prank(gov);
        boost.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + DELAY);
    }

    /// @dev Appoints the registry's guardian through the registry's own queue.
    function _appointGuardian() internal {
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
    }

    /// @dev Terms paying the listed reward, with the fixture gauge's minLiquidity, FLOOR.
    function _terms(uint16 minLockWeeks, uint16 maxLockWeeks, uint16 maxBoostBps)
        internal
        view
        returns (IHookrLpBoost.Terms memory)
    {
        return _terms(minLockWeeks, maxLockWeeks, maxBoostBps, FLOOR);
    }

    function _terms(uint16 minLockWeeks, uint16 maxLockWeeks, uint16 maxBoostBps, uint128 minLiquidity)
        internal
        view
        returns (IHookrLpBoost.Terms memory)
    {
        return IHookrLpBoost.Terms(address(reward), minLockWeeks, maxLockWeeks, maxBoostBps, minLiquidity);
    }

    /// @dev This contract (the gauge's creator) pulls `amount` of the reward from itself into a `weeks_`-week tranche.
    function _notify(uint256 amount, uint16 weeks_) internal {
        reward.approve(address(boost), amount);
        boost.notify(id, amount, weeks_);
    }

    /// @dev `who`, paid from this contract, funds a tranche of `amount` ending where the gauge's latest tranche ends,
    ///      or at the first week boundary a week or more ahead when that end is less than a week away.
    function _fund(address who, uint256 amount) internal {
        uint256 finish = boost.gauge(id).periodFinish;
        uint256 time = vm.getBlockTimestamp();
        uint256 weeks_ = finish > time ? (finish - time) / WEEK : 0;
        _fund(who, amount, uint16(weeks_ == 0 ? 1 : weeks_));
    }

    /// @dev `who`, paid from this contract, funds a `weeks_`-week tranche of `amount`.
    function _fund(address who, uint256 amount, uint16 weeks_) internal {
        reward.transfer(who, amount);
        vm.startPrank(who);
        reward.approve(address(boost), amount);
        boost.fund(id, amount, weeks_);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Positions
    // ------------------------------------------------------------------------------------------------------------

    function _fullRange() internal pure returns (int24 lower, int24 upper) {
        return (TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));
    }

    /// @dev Mints a position of `liquidity` over [lower, upper] in `key_` to `lp` through the PositionManager, paid by
    ///      `lp` (funded here) through Permit2, and returns its token id.
    function _mint(address lp, PoolKey memory key_, int24 lower, int24 upper, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        _fundLp(lp, key_);
        tokenId = posm.nextTokenId();
        bool native = key_.currency0.isAddressZero();
        bytes memory actions =
            native ? abi.encodePacked(MINT_POSITION, SETTLE_PAIR, SWEEP) : abi.encodePacked(MINT_POSITION, SETTLE_PAIR);
        bytes[] memory params = new bytes[](native ? 3 : 2);
        params[0] =
            abi.encode(key_, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, lp, bytes(""));
        params[1] = abi.encode(key_.currency0, key_.currency1);
        if (native) params[2] = abi.encode(key_.currency0, lp);
        vm.prank(lp);
        posm.modifyLiquidities{value: native ? 1e27 : 0}(abi.encode(actions, params), vm.getBlockTimestamp());
    }

    function _mintFullRange(address lp, uint128 liquidity) internal returns (uint256) {
        (int24 lower, int24 upper) = _fullRange();
        return _mint(lp, key, lower, upper, liquidity);
    }

    /// @dev Gives `lp` ETH and, from this contract, a tenth of each pool token's supply up to 10^27, and approves the
    ///      PositionManager through Permit2.
    function _fundLp(address lp, PoolKey memory key_) internal {
        vm.deal(lp, 1e28);
        Currency[2] memory cs = [key_.currency0, key_.currency1];
        for (uint256 i; i < 2; ++i) {
            if (cs[i].isAddressZero()) continue;
            address token = Currency.unwrap(cs[i]);
            uint256 tenth = IERC20(token).totalSupply() / 10;
            uint256 amount = tenth < 1e27 ? tenth : 1e27;
            if (IERC20(token).balanceOf(lp) < amount) IERC20(token).transfer(lp, amount);
            vm.startPrank(lp);
            IERC20(token).approve(permit2, type(uint256).max);
            IPermit2Approve(permit2).approve(token, address(posm), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    function _stake(address lp, uint256 tokenId, uint16 lockWeeks) internal {
        vm.startPrank(lp);
        posm.approve(address(boost), tokenId);
        boost.stake(tokenId, lockWeeks);
        vm.stopPrank();
    }

    function _mintAndStake(address lp, uint128 liquidity, uint16 lockWeeks) internal returns (uint256 tokenId) {
        tokenId = _mintFullRange(lp, liquidity);
        _stake(lp, tokenId, lockWeeks);
    }

    function _claim(address lp, uint256 tokenId) internal returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.prank(lp);
        return boost.claim(id, ids, lp);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Price and time
    // ------------------------------------------------------------------------------------------------------------

    function _tick(PoolId id_) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id_);
    }

    /// @dev Swaps in `key_` toward `limit` with an exact input large enough to reach it where liquidity allows.
    function _swapToPrice(PoolKey memory key_, uint160 limit, uint256 maxIn) internal {
        (uint160 price,,,) = manager.getSlot0(key_.toId());
        if (limit == price) return;
        bool zeroForOne = limit < price;
        uint256 value = zeroForOne && key_.currency0.isAddressZero() ? maxIn : 0;
        swapper.swap{value: value}(
            key_, SwapParams(zeroForOne, -int256(maxIn), limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function _swapToTick(PoolKey memory key_, int24 tick) internal {
        _swapToPrice(key_, TickMath.getSqrtPriceAtTick(tick), 1e29);
    }

    /// @dev The least minLiquidity `createGauge` accepts for `key_`: MIN_LIQUIDITY, or more where the sizing rule asks
    ///      for it. SqrtPriceMath rounds a full-range position's edge amounts down: getAmount0Delta(lower, upper, L) is
    ///      floor(L x 2^96 x (upper - lower) / (lower x upper)) and getAmount1Delta(lower, upper, L) is
    ///      floor(L x (upper - lower) / 2^96), so the least L whose amount is above a bound b is
    ///      ceil((b + 1) x lower x upper / (2^96 x (upper - lower))) for currency0 and ceil((b + 1) x 2^96 / (upper -
    ///      lower)) for currency1.
    function _sizingFloor(PoolKey memory key_) internal view returns (uint128) {
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key_.tickSpacing));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key_.tickSpacing));
        uint256 span = upper - lower;
        uint256 b0 = boost.supplyBound(Currency.unwrap(key_.currency0));
        uint256 b1 = boost.supplyBound(Currency.unwrap(key_.currency1));
        uint256 l0 =
            FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(b0 + 1, uint256(lower) * upper, span), 1, 1 << 96);
        uint256 l1 = FullMath.mulDivRoundingUp(b1 + 1, 1 << 96, span);
        uint256 least = l0 > l1 ? l0 : l1;
        return uint128(least > LEAST_LIQUIDITY ? least : LEAST_LIQUIDITY);
    }

    /// @dev What `createGauge` answers a minLiquidity of `liquidity` on `key_` under the sizing rule, computed forward
    ///      with SqrtPriceMath as the rule states it: currency0's edge is checked first, then currency1's; empty when
    ///      both edge amounts are above their bounds.
    function _sizingRefusal(PoolKey memory key_, uint128 liquidity) internal view returns (bytes memory) {
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key_.tickSpacing));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key_.tickSpacing));
        Currency[2] memory cs = [key_.currency0, key_.currency1];
        uint256[2] memory atEdge = [
            SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, false),
            SqrtPriceMath.getAmount1Delta(lower, upper, liquidity, false)
        ];
        for (uint256 i; i < 2; ++i) {
            address c = Currency.unwrap(cs[i]);
            uint256 b = boost.supplyBound(c);
            if (b == 0) return abi.encodeWithSelector(IHookrLpBoost.NoSupplyBound.selector, c);
            if (atEdge[i] <= b) {
                return abi.encodeWithSelector(IHookrLpBoost.MinLiquidityTooLow.selector, c, atEdge[i], b);
            }
        }
        return "";
    }

    /// @dev The currency, edge amount and bound a MinLiquidityTooLow refusal names.
    function _decodeTooLow(bytes memory refusal) internal pure returns (address, uint256, uint256) {
        assertEq(bytes4(refusal), IHookrLpBoost.MinLiquidityTooLow.selector);
        bytes memory args = new bytes(refusal.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = refusal[i + 4];
        }
        return abi.decode(args, (address, uint256, uint256));
    }

    function _weekAfter(uint256 t) internal pure returns (uint256) {
        return (t / WEEK + 1) * WEEK;
    }

    /// @dev Moves the clock to the next week boundary unless it is on one, so a tranche started next runs whole weeks.
    function _onAWeekBoundary() internal {
        uint256 t = vm.getBlockTimestamp();
        if (t % WEEK != 0) vm.warp(_weekAfter(t));
    }

    /// @dev now + lockWeeks weeks, rounded up to a week boundary.
    function _maturity(uint16 lockWeeks) internal view returns (uint48) {
        return uint48((vm.getBlockTimestamp() + uint256(lockWeeks) * WEEK + WEEK - 1) / WEEK * WEEK);
    }

    receive() external payable {}
}
