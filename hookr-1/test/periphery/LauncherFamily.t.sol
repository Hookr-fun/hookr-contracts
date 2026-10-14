// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrLaunchChecks} from "../../src/libraries/HookrLaunchChecks.sol";
import {IHookrLaunchFee} from "../../src/interfaces/IHookrLaunchFee.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrToken} from "../../src/interfaces/IHookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrDynamicFee} from "../../src/libraries/HookrDynamicFee.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {DustRangeSwapper} from "../utils/DustRangeSwapper.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";
import {RulesData} from "../utils/RulesData.sol";

/// @dev Moves an empty reference pool's price inside an unlock, for free, then launches a family in the same
///      transaction: the opening check reads the moved price.
contract ReferenceMover is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function approve(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function moveThenLaunch(
        HookrLauncher launcher,
        IHookrLauncher.LaunchParams calldata p,
        PoolKey calldata ref,
        uint160 to
    ) external payable returns (bytes32 family) {
        manager.unlock(abi.encode(ref, to));
        (family,,) = launcher.launchFamily{value: msg.value}(p);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory ref, uint160 to) = abi.decode(data, (PoolKey, uint160));
        (uint160 price,,,) = StateLibrary.getSlot0(manager, ref.toId());
        // An empty pool: the swap moves the price to its limit and trades nothing.
        manager.swap(ref, SwapParams(to < price, -1, to), "");
        return "";
    }
}

/// @notice Shared helpers for launchFamily's suites: LaunchParams with today's defaults, quotes at chosen addresses,
///         reference pools and sqrt prices of exact rational prices.
abstract contract LauncherFamilyFixture is DevBuyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal constant ETH = Currency.wrap(address(0));
    uint256 internal constant BPS = 10_000;
    uint256 internal references;

    /// @dev launchFamily's input for `members` with today's defaults: no knobs, no advisory, no dev buy, no retained
    ///      cap, no opening check.
    function _params(IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members)
        internal
        view
        returns (IHookrLauncher.LaunchParams memory p)
    {
        uint256 n = members.length;
        p.token = t;
        p.root = address(root);
        p.members = members;
        p.knobs = new IHookrLauncher.MemberKnobs[](n);
        p.advisoryConfigs = new bytes[](n);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
    }

    /// @dev The native value a launch needs: each native member's budget (the native quote is currency0) and the dev
    ///      buys on native members.
    function _value(IHookrLauncher.LaunchParams memory p) internal pure returns (uint256 value) {
        IHookrLauncher.Member[] memory members = p.members;
        for (uint256 i; i < members.length; ++i) {
            if (_native(members[i])) value += members[i].amount0Max;
        }
        IHookrLauncher.DevBuy[] memory buys = p.buys;
        for (uint256 k; k < buys.length; ++k) {
            // A buy naming no member pays nothing here: the launcher refuses it.
            if (buys[k].member < members.length && _native(members[buys[k].member])) value += buys[k].quoteIn;
        }
    }

    function _native(IHookrLauncher.Member memory m) internal pure returns (bool) {
        return Currency.unwrap(m.quote) == address(0);
    }

    function _launchFamily(IHookrLauncher.LaunchParams memory p)
        internal
        returns (bytes32 family, address subject, uint256 out)
    {
        (family, subject, out) = launcher.launchFamily{value: _value(p)}(p);
    }

    function _refuse(IHookrLauncher.LaunchParams memory p, bytes memory err) internal {
        uint256 value = _value(p);
        vm.expectRevert(err);
        launcher.launchFamily{value: value}(p);
    }

    /// @dev Expects launchFamily to revert with `selector`, whatever its arguments.
    function _refuseWith(IHookrLauncher.LaunchParams memory p, bytes4 selector) internal {
        uint256 value = _value(p);
        vm.expectPartialRevert(selector);
        launcher.launchFamily{value: value}(p);
    }

    /// @dev A cataloged quote token at `where`, held and approved by this contract.
    function _quoteAt(address where) internal returns (Currency) {
        deployCodeTo("HookrToken.sol:HookrToken", abi.encode("Quote", "Q", uint256(1e30), address(this)), where);
        HookrToken(where).approve(address(launcher), type(uint256).max);
        _catalogQuote(where);
        return Currency.wrap(where);
    }

    /// @dev A new token of `supply` whose address's first byte is from 0x40 to 0xbf: quotes at 0x10.. sort below it
    ///      and quotes at 0xe0.. above it, and the native quote always below.
    function _middleToken(uint256 supply) internal returns (IHookrLauncher.Token memory t, address subject) {
        return _middleTokenFor(address(this), supply);
    }

    /// @dev _middleToken for a launch by `creator`.
    function _middleTokenFor(address creator, uint256 supply)
        internal
        returns (IHookrLauncher.Token memory t, address subject)
    {
        t = IHookrLauncher.Token(address(0), "Family", "FAM", supply, bytes32(0));
        for (;;) {
            t.salt = bytes32(nextSalt++);
            subject = launcher.predictToken(creator, t);
            uint256 top = uint160(subject) >> 152;
            if (top >= 0x40 && top < 0xc0) return (t, subject);
        }
    }

    /// @dev sqrt(num / den) in Q64.96, rounded down.
    function _sqrtX96(uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(num, 1 << 192, den)));
    }

    /// @dev The sqrtPriceX96 of a pool of `subject` and `quote` in which one subject costs num / den quote.
    function _memberPrice(address subject, Currency quote, uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(subject) < uint160(Currency.unwrap(quote)) ? _sqrtX96(num, den) : _sqrtX96(den, num);
    }

    /// @dev An empty plain pool (no hook, 0.3%) of `a` and `b` on the PoolManager, initialized where one `a` costs
    ///      num / den `b`.
    function _reference(Currency a, Currency b, uint256 num, uint256 den) internal returns (PoolKey memory key) {
        bool aFirst = uint160(Currency.unwrap(a)) < uint160(Currency.unwrap(b));
        // A fresh fee tier for every reference, so two references of one pair are two pools.
        key = PoolKey(aFirst ? a : b, aFirst ? b : a, uint24(3000 + references++), 60, IHooks(address(0)));
        manager.initialize(key, aFirst ? _sqrtX96(num, den) : _sqrtX96(den, num));
    }

    /// @dev A member of `quote` opening at `sqrtPriceX96` with a wide band and 1e22 liquidity.
    function _priced(Currency quote, uint160 sqrtPriceX96) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(quote);
        m.sqrtPriceX96 = sqrtPriceX96;
        m.liquidity = 1e22;
    }

    function _held(address subject) internal view returns (uint256) {
        return IERC20(subject).balanceOf(address(this));
    }
}

/// @notice HookrLauncher.launchFamily: parity with launch at today's defaults, the knobs (supply weights, the minimum
///         dynamic fee liquidity divisor, the lock end) and the retained-supply cap, with every refusal.
contract LauncherFamilyTest is LauncherFamilyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant RETAINED_TOPIC = IHookrLauncher.FamilyRetained.selector;
    bytes32 internal constant WEIGHTS_TOPIC = IHookrLauncher.FamilyWeights.selector;
    bytes32 internal constant OPENING_TOPIC = IHookrLauncher.FamilyOpeningChecked.selector;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev A family's state that launch and launchFamily must leave alike: every member's committed policy (key,
    ///      configuration and module data) and minimum dynamic fee liquidity, the lock, and this contract's balances.
    struct Snap {
        bytes32[] policies;
        uint256[] minimums;
        uint256 lock;
        uint256[] balances;
    }

    function _snapshot(bytes32 family, uint256 n, Currency[] memory currencies) internal view returns (Snap memory x) {
        x.policies = new bytes32[](n);
        x.minimums = new uint256[](n);
        for (uint8 i; i < n; ++i) {
            PoolId id = launcher.position(family, i).key.toId();
            x.policies[i] = root.policyHash(id);
            (x.minimums[i],,,,,) = rules.referenceState(id);
        }
        x.lock = launcher.principalLockedUntil(family);
        x.balances = new uint256[](currencies.length);
        for (uint256 i; i < currencies.length; ++i) {
            address c = Currency.unwrap(currencies[i]);
            x.balances[i] = c == address(0) ? address(this).balance : IERC20(c).balanceOf(address(this));
        }
    }

    function _assertSame(Snap memory x, Snap memory y) internal pure {
        for (uint256 i; i < x.policies.length; ++i) {
            assertEq(x.policies[i], y.policies[i], "same committed policy");
            assertEq(x.minimums[i], y.minimums[i], "same minimum dynamic fee liquidity");
        }
        assertEq(x.lock, y.lock, "same lock");
        for (uint256 i; i < x.balances.length; ++i) {
            assertEq(x.balances[i], y.balances[i], "same balances");
        }
    }

    /// @dev The FamilyRetained log in `logs`, if any.
    function _retained(Vm.Log[] memory logs) internal view returns (bool seen, uint256 held, uint256 cap) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launcher) && logs[i].topics[0] == RETAINED_TOPIC) {
                (held, cap) = abi.decode(logs[i].data, (uint256, uint256));
                seen = true;
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ parity

    /// @notice At today's defaults launchFamily launches what launch does: the same family id, the same pools with the
    ///         same committed configuration and Rules data (a dynamic fee member's minimum is its liquidity / 100), the
    ///         same lock and the same refunds, and it logs none of launchFamily's own events for an existing token.
    function test_defaultsMatchLaunch() public {
        Currency[] memory currencies = new Currency[](3);
        currencies[0] = Currency.wrap(address(tokenA));
        currencies[1] = Currency.wrap(address(tokenB));
        currencies[2] = ETH;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[1] = _member(ETH);
        members[1].rules.maxFeePips = 100_000;
        members[1].rules.dynamicFeeSens = 5;
        members[1].rules.guardEndBlock = uint40(vm.getBlockNumber() + 50);
        members[1].rules.snipeTaxPips = 100_000;
        members[1].rules.maxBuyQuoteAmount = 1e30;
        IHookrLauncher.Token memory existing = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        uint256 snap = vm.snapshotState();
        (bytes32 a,) =
            launcher.launch{value: members[1].amount0Max}(existing, address(root), members, vm.getBlockTimestamp());
        Snap memory viaLaunch = _snapshot(a, 2, currencies);
        vm.revertToState(snap);
        vm.recordLogs();
        (bytes32 b,,) = _launchFamily(_params(existing, members));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(a, b, "same family id");
        Snap memory viaFamily = _snapshot(b, 2, currencies);
        _assertSame(viaLaunch, viaFamily);
        assertEq(viaFamily.minimums[1], uint256(members[1].liquidity) / 100, "liquidity / 100");
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != RETAINED_TOPIC && topic != WEIGHTS_TOPIC && topic != OPENING_TOPIC, "no family extras");
        }
    }

    /// @notice A new token with a dev buy: launchWithBuy and launchFamily deliver the same subject and leave the same
    ///         state, and launchFamily logs FamilyRetained with no cap (the whole supply).
    function test_defaultsMatchLaunchWithBuy() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory one = _one(subject, ETH);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 2e22, 1, 77);
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = Currency.wrap(subject);
        currencies[1] = ETH;
        uint256 snap = vm.snapshotState();
        (bytes32 c,, uint256 outC) = _launchWithBuy(t, one, buy);
        Snap memory viaLaunch = _snapshot(c, 1, currencies);
        vm.revertToState(snap);
        IHookrLauncher.LaunchParams memory p = _params(t, one);
        p.buys = new IHookrLauncher.DevBuy[](1);
        p.buys[0] = buy;
        vm.recordLogs();
        (bytes32 d,, uint256 outD) = _launchFamily(p);
        (bool seen, uint256 held, uint256 cap) = _retained(vm.getRecordedLogs());
        assertEq(c, d, "same family id");
        assertEq(outC, outD, "same dev buy");
        Snap memory viaFamily = _snapshot(d, 1, currencies);
        _assertSame(viaLaunch, viaFamily);
        assertTrue(seen, "FamilyRetained");
        assertEq(held, viaFamily.balances[0], "retained: what the creator holds");
        assertEq(cap, SUPPLY, "no cap: the whole supply");
    }

    // ------------------------------------------------------------------------------------------------ presentation

    /// @notice launchFamily gives a new token its tagline and logo URI for good, an existing token takes none, and
    ///         launch, launchAdvised and launchWithBuy launch new tokens without one.
    function test_presentation() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.LaunchParams memory p = _params(t, _one(subject, ETH));
        p.tagline = "a tagline";
        p.logoURI = "ipfs://logo";
        uint256 snap = vm.snapshotState();
        _launchFamily(p);
        assertEq(HookrToken(subject).tagline(), "a tagline");
        assertEq(HookrToken(subject).logoURI(), "ipfs://logo");
        vm.expectRevert(IHookrToken.NotPresenter.selector);
        HookrToken(subject).setPresentation("changed", "");
        vm.revertToState(snap);

        p.tagline = string(new bytes(161));
        _refuse(p, abi.encodeWithSelector(IHookrToken.InvalidMetadata.selector));

        launcher.launch(t, address(root), _one(subject, ETH), vm.getBlockTimestamp());
        assertEq(HookrToken(subject).tagline(), "", "launch gives none");
        assertEq(HookrToken(subject).logoURI(), "");

        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        p = _params(IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), members);
        p.logoURI = "ipfs://logo";
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidFunding.selector));
    }

    // ------------------------------------------------------------------------------------------------ shape

    /// @notice Knobs, advisory configs and references must each fit the members.
    function test_shapeRefusals() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[1] = _member(ETH);
        IHookrLauncher.Token memory existing = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        bytes memory err = abi.encodeWithSelector(IHookrLauncher.InvalidFamily.selector);
        IHookrLauncher.LaunchParams memory p = _params(existing, members);
        p.knobs = new IHookrLauncher.MemberKnobs[](1);
        _refuse(p, err);
        p = _params(existing, members);
        p.advisoryConfigs = new bytes[](3);
        _refuse(p, err);
        p = _params(existing, members);
        p.opening.toleranceBps = 100;
        p.opening.references = new PoolKey[](2);
        _refuse(p, err);
        p.opening.references = new PoolKey[](0);
        _refuse(p, err);
        // Two members in one quote are refused, so every member after the first names a reference of its own quote.
        p = _params(existing, members);
        p.members[1].quote = Currency.wrap(address(tokenB));
        _refuse(p, err);
    }

    // ------------------------------------------------------------------------------------------------ retained cap

    function test_retainedCapRange() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.LaunchParams memory p = _params(t, _one(subject, ETH));
        p.maxRetainedBps = 10_001;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidRetainedCap.selector, uint256(10_001)));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH);
        p = _params(IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), members);
        p.maxRetainedBps = 9_999;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidRetainedCap.selector, uint256(9_999)));
        p.maxRetainedBps = 0;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidRetainedCap.selector, uint256(0)));
        p.maxRetainedBps = 10_000;
        _launchFamily(p);
    }

    /// @dev One native member whose band (below tick 0, the subject being currency1) takes exactly `amount` subject.
    function _exactMember(address subject, uint256 amount) internal view returns (IHookrLauncher.Member memory m) {
        m = _devMemberAt(subject, ETH, amount, 0, 60_000);
        m.rules.guardEndBlock = 0;
        m.rules.snipeTaxPips = 0;
        m.rules.maxBuyQuoteAmount = 0;
    }

    /// @notice The retained cap's boundary to the unit. The member's band takes `spent` subject whatever the supply, so
    ///         a supply of 2 x spent leaves the creator exactly spent, a 5,000 bps cap of it: accepted, logged as
    ///         FamilyRetained(spent, spent). One more unit of supply leaves it spent + 1 against the same cap: refused.
    function test_retainedCapBoundary() public {
        // Dry run: what the band takes.
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _exactMember(subject, 1e23);
        uint256 snap = vm.snapshotState();
        _launchFamily(_params(t, members));
        uint256 spent = SUPPLY - _held(subject);
        vm.revertToState(snap);
        assertGt(spent, 0);
        // The band's liquidity, not the budget, sets what it takes: budget it exactly.
        members[0].amount1Max = uint128(spent);

        t.supply = 2 * spent;
        subject = launcher.predictToken(address(this), t);
        IHookrLauncher.LaunchParams memory p = _params(t, members);
        p.maxRetainedBps = 5_000;
        vm.expectEmit(false, false, false, true, address(launcher));
        emit IHookrLauncher.FamilyRetained(bytes32(0), spent, spent);
        _launchFamily(p);
        assertEq(_held(subject), spent, "held exactly the cap");

        t.salt = bytes32(nextSalt++);
        t.supply = 2 * spent + 1;
        p = _params(t, members);
        p.maxRetainedBps = 5_000;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.RetainedAboveCap.selector, spent + 1, spent));
    }

    /// @dev Dry run of a one-member launch with a dev buy of `quoteIn` into a supply of `supply`: the subject the creator
    ///      does not keep, supply less what it holds afterwards. The band's deposit and the buy's output do not depend on
    ///      the supply, so this is the same at every supply.
    function _notKept(uint256 supply, uint128 quoteIn) internal returns (uint256) {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        t.supply = supply;
        subject = launcher.predictToken(address(this), t);
        IHookrLauncher.LaunchParams memory p = _params(t, _oneDevMember(subject));
        p.buys = new IHookrLauncher.DevBuy[](1);
        p.buys[0] = IHookrLauncher.DevBuy(0, quoteIn, 1, 0);
        uint256 snap = vm.snapshotState();
        _launchFamily(p);
        uint256 kept = _held(subject);
        vm.revertToState(snap);
        return supply - kept;
    }

    /// @dev A supply the dry run's own hold bound accepts: above the band's deposit (about 3.996e22) and within 5% of it.
    uint256 internal constant DRY_SUPPLY = 4.05e22;

    function _oneDevMember(address subject) internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _devMember(subject, ETH, 4e22);
    }

    /// @notice The dev buy bound's boundary to the unit: what the creator holds, the unplaced supply plus the buy's
    ///         output, may be exactly floor(supply / 20) and no more. The subject the creator does not keep, c, is the
    ///         same at every supply, so a supply of 20c / 19 leaves exactly c / 19 held and a cap of c / 19: accepted;
    ///         twenty more units of supply leave it c / 19 + 20 against a cap of c / 19 + 1: refused. Mutation gate LA-4
    ///         (the bound refused a hold equal to the cap).
    function test_devBuyCapBoundary() public {
        uint128 quoteIn;
        uint256 c;
        for (uint128 k; k < 64; ++k) {
            quoteIn = 1e21 + k * 997;
            c = _notKept(DRY_SUPPLY, quoteIn);
            if (c % 19 == 0) break;
        }
        assertEq(c % 19, 0, "a buy size whose kept share divides evenly");
        uint256 supply = 20 * c / 19;
        assertGt(supply, 4e22, "the supply holds the band");

        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        t.supply = supply;
        subject = launcher.predictToken(address(this), t);
        IHookrLauncher.LaunchParams memory p = _params(t, _oneDevMember(subject));
        p.buys = new IHookrLauncher.DevBuy[](1);
        p.buys[0] = IHookrLauncher.DevBuy(0, quoteIn, 1, 0);
        _launchFamily(p);
        assertEq(_held(subject), c / 19, "held exactly the cap");
        assertEq(supply / 20, c / 19);

        t.salt = bytes32(nextSalt++);
        t.supply = supply + 20;
        subject = launcher.predictToken(address(this), t);
        p = _params(t, _oneDevMember(subject));
        p.buys = new IHookrLauncher.DevBuy[](1);
        p.buys[0] = IHookrLauncher.DevBuy(0, quoteIn, 1, 0);
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.DevBuyAboveCap.selector, c / 19 + 20, c / 19 + 1));
    }

    /// @notice A launch fee-free family takes exactly its native budgets: one wei more is refused, as one wei less is.
    ///         Mutation gate LA-10 (a surplus was accepted).
    function test_launchFamilyRefusesASurplusOfNative() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _exactMember(subject, 1e23);
        IHookrLauncher.LaunchParams memory p = _params(t, members);
        uint256 value = _value(p);
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launchFamily{value: value + 1}(p);
        if (value != 0) {
            vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
            launcher.launchFamily{value: value - 1}(p);
        }
        launcher.launchFamily{value: value}(p);
    }

    /// @notice A member's range must have width: ticks that meet are refused, as is an inverted range. Mutation gate
    ///         LA-12 (an empty range passed the launcher's check).
    function test_aMemberRangeMustHaveWidth() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _exactMember(subject, 1e23);
        members[0].tickUpper = members[0].tickLower;
        _refuse(_params(t, members), abi.encodeWithSelector(IHookrLauncher.InvalidFamily.selector));
        members[0].tickUpper = members[0].tickLower - 60;
        _refuse(_params(t, members), abi.encodeWithSelector(IHookrLauncher.InvalidFamily.selector));
    }

    /// @notice A guard window of exactly the longest allowed (100,000 parent blocks) launches, one block more is
    ///         refused. Mutation gate LA-2 (the longest window was refused).
    function test_guardWindowOfExactlyTheMaximum() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _exactMember(subject, 1e23);
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
        _launchFamily(_params(t, members));
        (t, subject) = _newToken(ETH, false);
        members[0] = _exactMember(subject, 1e23);
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_001);
        _refuseWith(_params(t, members), IHookrLauncher.GuardTooLong.selector);
    }

    /// @notice Over caps from 0 to 10,000 bps, a launch is accepted exactly when what the creator holds is at most
    ///         floor(supply x cap / 10,000), the cap rounded down.
    function testFuzz_retainedCap(uint16 capBps, uint256 supplySeed) public {
        capBps = uint16(bound(capBps, 0, 10_000));
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        t.supply = bound(supplySeed, 2e23, 1e27);
        subject = launcher.predictToken(address(this), t);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _exactMember(subject, 1e23);
        IHookrLauncher.LaunchParams memory p = _params(t, members);
        uint256 snap = vm.snapshotState();
        _launchFamily(p);
        uint256 held = _held(subject);
        vm.revertToState(snap);
        uint256 cap = FullMath.mulDiv(t.supply, capBps, BPS);
        p.maxRetainedBps = capBps;
        if (held <= cap) {
            _launchFamily(p);
            assertEq(_held(subject), held);
        } else {
            _refuse(p, abi.encodeWithSelector(IHookrLauncher.RetainedAboveCap.selector, held, cap));
        }
    }

    // ------------------------------------------------------------------------------------------------ weights

    /// @dev `n` members of a new token, each in its own quote, with exactly-budgeted subject bands.
    function _weighted(uint16[] memory weights, uint256 supply)
        internal
        returns (IHookrLauncher.LaunchParams memory p, address subject)
    {
        IHookrLauncher.Token memory t;
        (t, subject) = _newToken(ETH, false);
        t.supply = supply;
        subject = launcher.predictToken(address(this), t);
        Currency[3] memory quotes = [ETH, Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB))];
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](weights.length);
        for (uint256 i; i < weights.length; ++i) {
            uint256 share = FullMath.mulDiv(supply, weights[i], BPS);
            members[i] = _devMember(subject, quotes[i], share);
            members[i].rules.guardEndBlock = 0;
            members[i].rules.snipeTaxPips = 0;
            members[i].rules.maxBuyQuoteAmount = 0;
            // The subject's side holds exactly the weight's share.
            if (uint160(subject) < uint160(Currency.unwrap(quotes[i]))) members[i].amount0Max = uint128(share);
            else members[i].amount1Max = uint128(share);
        }
        p = _params(t, members);
        for (uint256 i; i < weights.length; ++i) {
            p.knobs[i].subjectWeightBps = weights[i];
        }
    }

    /// @notice Weights fund each member with exactly its share of supply, logged as FamilyWeights.
    function test_weightsFundEachMemberItsShare() public {
        uint16[] memory w = new uint16[](3);
        (w[0], w[1], w[2]) = (5_000, 3_000, 2_000);
        (IHookrLauncher.LaunchParams memory p, address subject) = _weighted(w, 1e24 + 7);
        uint16[8] memory logged;
        (logged[0], logged[1], logged[2]) = (5_000, 3_000, 2_000);
        vm.expectEmit(false, false, false, true, address(launcher));
        emit IHookrLauncher.FamilyWeights(bytes32(0), logged);
        (bytes32 family,,) = _launchFamily(p);
        // Each band holds at most its share; the creator holds the rest of supply.
        uint256 placed = IERC20(subject).balanceOf(address(manager));
        uint256 shares = uint256(5e23 + 3) + (3e23 + 2) + (2e23 + 1);
        assertEq(_held(subject) + placed, 1e24 + 7, "supply");
        assertLe(placed, shares, "at most the shares");
        assertGe(placed, shares * 998 / 1000, "the bands hold their shares");
        assertEq(launcher.memberCount(family), 3);
    }

    function test_weightRefusals() public {
        uint16[] memory w = new uint16[](2);
        (w[0], w[1]) = (6_000, 5_000);
        (IHookrLauncher.LaunchParams memory p,) = _weighted(w, 1e24);
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidWeights.selector));

        (w[0], w[1]) = (6_000, 4_000);
        (p,) = _weighted(w, 1e24);
        p.knobs[1].subjectWeightBps = 0;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidWeights.selector));
        (p,) = _weighted(w, 1e24);
        p.knobs[0].subjectWeightBps = 0;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidWeights.selector));

        // A budget one unit off its share, either way.
        (p,) = _weighted(w, 1e24);
        uint256 expected = 6e23;
        bool side0 = p.members[0].amount0Max != 0;
        if (side0) p.members[0].amount0Max += 1;
        else p.members[0].amount1Max += 1;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.WeightMismatch.selector, uint8(0), expected + 1, expected));
        if (side0) p.members[0].amount0Max -= 2;
        else p.members[0].amount1Max -= 2;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.WeightMismatch.selector, uint8(0), expected - 1, expected));

        // Weights are for a new token's supply.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH);
        p = _params(IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), members);
        p.knobs[0].subjectWeightBps = 10_000;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidWeights.selector));

        // A supply far past what a budget can hold: floor(supply x weight / 10,000) computes without overflow and the
        // budget simply cannot match it.
        (w[0], w[1]) = (6_000, 4_000);
        (p,) = _weighted(w, 1e24);
        p.token.supply = type(uint256).max;
        uint256 huge = type(uint256).max / BPS * 6_000 + type(uint256).max % BPS * 6_000 / BPS;
        uint256 budget = side0 ? p.members[0].amount0Max : p.members[0].amount1Max;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.WeightMismatch.selector, uint8(0), budget, huge));
    }

    // ------------------------------------------------------------------------------------------------ divisor

    function _dynamic(Currency quote, uint128 liquidity) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(quote);
        m.liquidity = liquidity;
        m.rules.maxFeePips = 100_000;
        m.rules.dynamicFeeSens = 5;
        m.config.caps.maxLpFeePips = 600_000;
    }

    function _minimumAt(uint16 divisor, uint128 liquidity) internal returns (uint256 minimum) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _dynamic(ETH, liquidity);
        IHookrLauncher.LaunchParams memory p =
            _params(IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), members);
        p.knobs[0].dynamicFeeLiquidityDivisor = divisor;
        uint256 snap = vm.snapshotState();
        (bytes32 family,,) = _launchFamily(p);
        (minimum,,,,,) = rules.referenceState(launcher.position(family, 0).key.toId());
        vm.revertToState(snap);
    }

    /// @notice A dynamic fee member's minimum dynamic fee liquidity is its launch liquidity over its divisor, 100 by
    ///         default, from 2 (half the launch liquidity) to 10,000, never below 1.
    function test_divisorSetsTheMinimum() public {
        uint128 l = 1e24;
        assertEq(_minimumAt(0, l), l / 100, "default");
        assertEq(_minimumAt(2, l), l / 2, "2: half the launch liquidity");
        assertEq(_minimumAt(250, l), l / 250);
        assertEq(_minimumAt(10_000, l), l / 10_000, "10,000");
        assertEq(_minimumAt(10_000, 5_000), 1, "never below 1");
        (uint256 minD, uint256 maxD, uint256 maxTol, uint256 maxLock) = HookrLaunchChecks.familyBounds();
        assertEq(minD, 2);
        assertEq(maxD, 10_000);
        assertEq(maxTol, 1_000);
        assertEq(maxLock, 100_000);
    }

    function test_divisorRefusals() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _dynamic(ETH, 1e24);
        members[1] = _member(Currency.wrap(address(tokenB)));
        IHookrLauncher.LaunchParams memory p =
            _params(IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), members);
        p.knobs[0].dynamicFeeLiquidityDivisor = 10_001;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidDivisor.selector, uint8(0), uint256(10_001)));
        p.knobs[0].dynamicFeeLiquidityDivisor = 1;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidDivisor.selector, uint8(0), uint256(1)));
        p.knobs[0].dynamicFeeLiquidityDivisor = 0;
        p.knobs[1].dynamicFeeLiquidityDivisor = 100;
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidDivisor.selector, uint8(1), uint256(100)));
    }

    // ------------------------------------------------------------------------------------------------ lock end

    /// @notice A lock end keeps every member's principal locked until it; fees stay collectable.
    function test_lockEndRaisesThePrincipalLock() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH);
        members[1] = _member(Currency.wrap(address(tokenB)));
        uint256 guardEnd = vm.getBlockNumber() + 100;
        members[1].rules.guardEndBlock = uint40(guardEnd);
        members[1].rules.snipeTaxPips = 100_000;
        members[1].rules.maxBuyQuoteAmount = 1e30;
        members[1].config.caps.maxLpFeePips = 600_000;
        IHookrLauncher.LaunchParams memory p =
            _params(IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), members);
        uint256 end = vm.getBlockNumber() + 5_000;
        p.knobs[0].lockEndBlock = uint64(end);
        p.knobs[1].lockEndBlock = uint64(guardEnd);
        (bytes32 family,,) = _launchFamily(p);
        assertEq(launcher.principalLockedUntil(family), end, "the latest lock end");
        vm.roll(end - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PrincipalLocked.selector, family, uint8(0), end));
        launcher.withdraw(family, 0, 1, 0, 0, address(this), vm.getBlockTimestamp());
        launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        vm.roll(end);
        launcher.withdraw(family, 0, 1e20, 0, 0, address(this), vm.getBlockTimestamp());
        launcher.withdraw(family, 1, 1e20, 0, 0, address(this), vm.getBlockTimestamp());
    }

    /// @notice A lock end runs from the family's last guard end to launch + 100,000 parent blocks.
    function test_lockEndBounds() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH);
        members[1] = _member(Currency.wrap(address(tokenB)));
        uint256 guardEnd = vm.getBlockNumber() + 300;
        members[1].rules.guardEndBlock = uint40(guardEnd);
        members[1].rules.snipeTaxPips = 100_000;
        members[1].rules.maxBuyQuoteAmount = 1e30;
        members[1].config.caps.maxLpFeePips = 600_000;
        IHookrLauncher.LaunchParams memory p =
            _params(IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), members);
        p.knobs[0].lockEndBlock = uint64(guardEnd - 1);
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidLockEnd.selector, uint8(0), guardEnd - 1));
        uint256 last = vm.getBlockNumber() + 100_000;
        p.knobs[0].lockEndBlock = uint64(last + 1);
        _refuse(p, abi.encodeWithSelector(IHookrLauncher.InvalidLockEnd.selector, uint8(0), last + 1));
        uint256 snap = vm.snapshotState();
        p.knobs[0].lockEndBlock = uint64(guardEnd);
        (bytes32 family,,) = _launchFamily(p);
        assertEq(launcher.principalLockedUntil(family), guardEnd, "a lock end at the guard end changes nothing");
        vm.revertToState(snap);
        p.knobs[0].lockEndBlock = uint64(last);
        (family,,) = _launchFamily(p);
        assertEq(launcher.principalLockedUntil(family), last, "the latest allowed");
    }

    /// @notice With a dev buy, the family stays locked until the latest of its guards, its lock ends and its dev
    ///         buys' locks.
    function test_lockEndAndDevBuyLock() public {
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.LaunchParams memory p = _params(t, _one(subject, ETH));
        p.buys = new IHookrLauncher.DevBuy[](1);
        p.buys[0] = IHookrLauncher.DevBuy(0, 1e21, 1, 2_000);
        p.knobs[0].lockEndBlock = uint64(vm.getBlockNumber() + 1_000);
        uint256 snap = vm.snapshotState();
        (bytes32 family,,) = _launchFamily(p);
        assertEq(launcher.principalLockedUntil(family), vm.getBlockNumber() + 2_000, "the dev buy's lock");
        vm.revertToState(snap);
        p.knobs[0].lockEndBlock = uint64(vm.getBlockNumber() + 3_000);
        (family,,) = _launchFamily(p);
        assertEq(launcher.principalLockedUntil(family), vm.getBlockNumber() + 3_000, "the lock end");
    }
}

/// @notice launchFamily's opening check: one opening price across members, each converted into member 0's quote
///         through a reference pool the creator names, within a tolerance of 1 to 1,000 bps.
contract LauncherFamilyOpeningTest is LauncherFamilyFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency internal low1;
    Currency internal low2;
    Currency internal low3;
    Currency internal high1;
    Currency internal high2;
    Currency internal high3;
    Currency internal high4;

    function setUp() public {
        _setUpPeriphery();
        low1 = _quoteAt(address(0x1000000000000000000000000000000000000001));
        low2 = _quoteAt(address(0x1000000000000000000000000000000000000002));
        low3 = _quoteAt(address(0x1000000000000000000000000000000000000003));
        high1 = _quoteAt(address(0xe000000000000000000000000000000000000001));
        high2 = _quoteAt(address(0xe000000000000000000000000000000000000002));
        high3 = _quoteAt(address(0xE000000000000000000000000000000000000003));
        high4 = _quoteAt(address(0xe000000000000000000000000000000000000004));
    }

    /// @dev A two-member family of a new middle token: member 0 in `quote0` at price p0 (num0 / den0), member 1 in
    ///      `quote1` at price p1 (num1 / den1), checked through `ref` at `toleranceBps`.
    function _pair(Currency quote0, uint256 num0, uint256 den0, Currency quote1, uint256 num1, uint256 den1)
        internal
        returns (IHookrLauncher.LaunchParams memory p, address subject)
    {
        IHookrLauncher.Token memory t;
        (t, subject) = _middleToken(1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _priced(quote0, _memberPrice(subject, quote0, num0, den0));
        members[1] = _priced(quote1, _memberPrice(subject, quote1, num1, den1));
        p = _params(t, members);
        p.opening.references = new PoolKey[](1);
    }

    function _opening(IHookrLauncher.LaunchParams memory p, uint16 tol, PoolKey memory ref)
        internal
        pure
        returns (IHookrLauncher.LaunchParams memory)
    {
        p.opening.toleranceBps = tol;
        p.opening.references[0] = ref;
        return p;
    }

    /// @notice An empty check checks nothing and logs nothing.
    function test_emptyCheckSkips() public {
        (IHookrLauncher.LaunchParams memory p,) = _pair(high1, 2, 1, high2, 7, 1);
        p.opening.references = new PoolKey[](0);
        vm.recordLogs();
        _launchFamily(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IHookrLauncher.FamilyOpeningChecked.selector, "no check logged");
        }
    }

    /// @notice A check needs a tolerance of 1 to 1,000 bps.
    function test_toleranceRange() public {
        (IHookrLauncher.LaunchParams memory p,) = _pair(high1, 2, 1, high2, 1, 2);
        // One high2 costs 4 high1: a subject at 1/2 high2 costs 2 high1, member 0's price.
        PoolKey memory ref = _reference(high2, high1, 4, 1);
        _refuse(
            _opening(p, 0, ref), abi.encodeWithSelector(IHookrLauncher.OpeningToleranceOutOfRange.selector, uint16(0))
        );
        _refuse(
            _opening(p, 1_001, ref),
            abi.encodeWithSelector(IHookrLauncher.OpeningToleranceOutOfRange.selector, uint16(1_001))
        );
        uint256 snap = vm.snapshotState();
        p = _opening(p, 1, ref);
        vm.expectEmit(false, false, false, true, address(launcher));
        emit IHookrLauncher.FamilyOpeningChecked(bytes32(0), 1, keccak256(abi.encode(p.opening.references)));
        _launchFamily(p);
        vm.revertToState(snap);
        _launchFamily(_opening(p, 1_000, ref));
    }

    /// @notice A reference must hold exactly the member's quote and member 0's quote, and be initialized.
    function test_referenceRefusals() public {
        (IHookrLauncher.LaunchParams memory p,) = _pair(high1, 2, 1, high2, 1, 2);
        PoolKey memory wrong = _reference(high2, high3, 1, 1);
        _refuse(
            _opening(p, 10, wrong), abi.encodeWithSelector(IHookrLauncher.OpeningReferenceMismatch.selector, uint8(1))
        );
        PoolKey memory zero;
        _refuse(
            _opening(p, 10, zero), abi.encodeWithSelector(IHookrLauncher.OpeningReferenceMismatch.selector, uint8(1))
        );
        PoolKey memory unset = PoolKey(high1, high2, 500, 10, IHooks(address(0)));
        _refuse(
            _opening(p, 10, unset),
            abi.encodeWithSelector(IHookrLauncher.OpeningReferenceUninitialized.selector, uint8(1))
        );
        // A member's opening price outside the PoolManager's range is refused as the PoolManager refuses it.
        PoolKey memory ref = _reference(high2, high1, 4, 1);
        p = _opening(p, 10, ref);
        p.members[1].sqrtPriceX96 = TickMath.MIN_SQRT_PRICE - 1;
        _refuse(p, abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, TickMath.MIN_SQRT_PRICE - 1));
    }

    /// @dev The largest a with a^2 x 10,000 <= y and the least a with a^2 x 10,000 >= z.
    function _edges(uint256 y, uint256 z) internal pure returns (uint256 hi, uint256 lo) {
        hi = Math.sqrt(y / BPS);
        lo = Math.sqrt(z / BPS);
        while (lo * lo * BPS < z) ++lo;
        while (lo > 0 && (lo - 1) * (lo - 1) * BPS >= z) --lo;
    }

    /// @notice Each band edge to the unit: with a reference at exactly 1, member 1's converted sqrt price is its own,
    ///         so the largest and least accepted sqrt prices are exact, and one unit past either is refused with the
    ///         converted price and the band in Q64.96 price units.
    function test_bandEdges() public {
        (IHookrLauncher.LaunchParams memory p, address subject) = _pair(high1, 3, 2, high2, 3, 2);
        PoolKey memory ref = _reference(high2, high1, 1, 1);
        uint16 tol = 250;
        p = _opening(p, tol, ref);
        uint256 s0 = p.members[0].sqrtPriceX96;
        assertTrue(uint160(subject) < uint160(Currency.unwrap(high1)), "no inversion on member 0");
        (uint256 hi, uint256 lo) = _edges(s0 * s0 * (BPS + tol), s0 * s0 * (BPS - tol));
        assertLe(hi * hi * BPS, s0 * s0 * (BPS + tol));
        assertGt((hi + 1) * (hi + 1) * BPS, s0 * s0 * (BPS + tol));
        assertGe(lo * lo * BPS, s0 * s0 * (BPS - tol));
        assertLt((lo - 1) * (lo - 1) * BPS, s0 * s0 * (BPS - tol));
        uint256 low = FullMath.mulDivRoundingUp(s0 * (BPS - tol), s0, BPS << 96);
        uint256 high = FullMath.mulDiv(s0 * (BPS + tol), s0, BPS << 96);
        uint160[4] memory prices = [uint160(hi), uint160(hi + 1), uint160(lo), uint160(lo - 1)];
        bool[4] memory pass = [true, false, true, false];
        for (uint256 k; k < 4; ++k) {
            p.members[1].sqrtPriceX96 = prices[k];
            if (pass[k]) {
                uint256 snap = vm.snapshotState();
                _launchFamily(p);
                vm.revertToState(snap);
            } else {
                uint256 converted = FullMath.mulDiv(prices[k], prices[k], 1 << 96);
                _refuse(
                    p,
                    abi.encodeWithSelector(
                        IHookrLauncher.OpeningOutsideTolerance.selector, uint8(1), converted, low, high
                    )
                );
            }
        }
    }

    /// @notice Every orientation of member 0, member 1 and the reference converts to the same price: a family
    ///         priced consistently passes at 1 bp in all eight, and one 2% off is refused in all eight.
    function test_orientations() public {
        // One subject costs 3/2 quote0; one quote1 costs 5/4 quote0; so one subject costs 6/5 quote1.
        Currency[2] memory zeros = [low1, high1];
        Currency[2] memory ones = [low2, high2];
        for (uint256 a; a < 2; ++a) {
            for (uint256 b; b < 2; ++b) {
                (IHookrLauncher.LaunchParams memory p, address subject) = _pair(zeros[a], 3, 2, ones[b], 6, 5);
                assertEq(uint160(subject) > uint160(Currency.unwrap(zeros[a])), a == 0, "member 0 inverted iff low");
                PoolKey memory ref = _reference(ones[b], zeros[a], 5, 4);
                p = _opening(p, 1, ref);
                uint256 snap = vm.snapshotState();
                _launchFamily(p);
                vm.revertToState(snap);
                p.members[1].sqrtPriceX96 = _memberPrice(subject, ones[b], 6 * 102, 5 * 100);
                _refuseWith(p, IHookrLauncher.OpeningOutsideTolerance.selector);
                vm.revertToState(snap);
            }
        }
        // The reference's own orientation: quote1 below quote0 and above it.
        (IHookrLauncher.LaunchParams memory q, address s) = _pair(high2, 3, 2, high1, 6, 5);
        PoolKey memory r = _reference(high1, high2, 5, 4);
        assertTrue(Currency.unwrap(r.currency0) == Currency.unwrap(high1), "quote1 is the reference's currency0");
        q = _opening(q, 1, r);
        uint256 snap2 = vm.snapshotState();
        _launchFamily(q);
        vm.revertToState(snap2);
        q.members[1].sqrtPriceX96 = _memberPrice(s, high1, 6 * 98, 5 * 100);
        _refuseWith(q, IHookrLauncher.OpeningOutsideTolerance.selector);
    }

    /// @notice An eight-member family over eight quotes (native, below and above the subject), each with a
    ///         reference in its own orientation, passes when consistent; one member outside the tolerance is named.
    function test_eightMembers() public {
        Currency[8] memory quotes = [high1, ETH, low1, low2, low3, high2, high3, high4];
        IHookrLauncher.Token memory t;
        address subject;
        (t, subject) = _middleToken(1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](8);
        // Member 0's quote is high1; one subject costs 7/3 high1, and one quote i costs (i + 1) / 2 high1.
        members[0] = _priced(quotes[0], _memberPrice(subject, quotes[0], 7, 3));
        IHookrLauncher.LaunchParams memory p = _params(t, members);
        p.opening.toleranceBps = 5;
        p.opening.references = new PoolKey[](7);
        for (uint256 i = 1; i < 8; ++i) {
            // subject in quote i = (7/3) / ((i + 1) / 2) = 14 / (3 (i + 1)).
            p.members[i] = _priced(quotes[i], _memberPrice(subject, quotes[i], 14, 3 * (i + 1)));
            p.opening.references[i - 1] = _reference(quotes[i], quotes[0], i + 1, 2);
        }
        uint256 snap = vm.snapshotState();
        _launchFamily(p);
        vm.revertToState(snap);
        p.members[6].sqrtPriceX96 = _memberPrice(subject, quotes[6], 14 * 1001, 3 * 7 * 1000);
        _refuseWith(p, IHookrLauncher.OpeningOutsideTolerance.selector);
    }

    /// @notice Over random opening prices, reference prices, tolerances and orientations, the check accepts exactly the
    ///         members whose price in member 0's quote is within the tolerance of member 0's, away from a hair's width
    ///         (one part per million) around the band's edges, where the sqrt prices' rounding could decide.
    function testFuzz_openingDecision(uint256 seed) public {
        Currency quote0 = seed & 1 == 0 ? low1 : high1;
        Currency quote1 = seed & 2 == 0 ? low2 : high2;
        uint256 n0 = 1 + uint256(keccak256(abi.encode(seed, 1))) % 1000;
        uint256 d0 = 1 + uint256(keccak256(abi.encode(seed, 2))) % 1000;
        uint256 nr = 1 + uint256(keccak256(abi.encode(seed, 3))) % 1000;
        uint256 dr = 1 + uint256(keccak256(abi.encode(seed, 4))) % 1000;
        uint16 tol = uint16(1 + uint256(keccak256(abi.encode(seed, 5))) % 1000);
        // The member's deviation from the consistent price, in parts per million, within twice the tolerance.
        uint256 span = 400 * uint256(tol);
        int256 dev = int256(uint256(keccak256(abi.encode(seed, 6))) % (span + 1)) - int256(span / 2);
        uint256 edge = 100 * uint256(tol);
        uint256 magnitude = dev < 0 ? uint256(-dev) : uint256(dev);
        vm.assume(magnitude + 1 < edge || magnitude > edge + 1);
        // One subject costs n0/d0 quote0, one quote1 costs nr/dr quote0, so one subject costs (n0 dr)/(d0 nr) quote1,
        // off by `dev` ppm.
        (IHookrLauncher.LaunchParams memory p,) =
            _pair(quote0, n0, d0, quote1, n0 * dr * uint256(int256(1e6) + dev), d0 * nr * 1e6);
        PoolKey memory ref = _reference(quote1, quote0, nr, dr);
        p = _opening(p, tol, ref);
        if (magnitude <= edge) {
            _launchFamily(p);
        } else {
            _refuseWith(p, IHookrLauncher.OpeningOutsideTolerance.selector);
        }
    }

    /// @notice Known limit, recorded: the check reads the references when the launch runs, so moving a reference in
    ///         the same transaction moves the check. A creator contract that moves an empty reference first gets a
    ///         family priced to the moved reference through; the check guards only the creator's own launch.
    function test_referenceMovedInTheSameTransaction() public {
        ReferenceMover mover = new ReferenceMover(manager);
        IERC20(Currency.unwrap(high1)).transfer(address(mover), 1e27);
        IERC20(Currency.unwrap(high2)).transfer(address(mover), 1e27);
        mover.approve(Currency.unwrap(high1), address(launcher));
        mover.approve(Currency.unwrap(high2), address(launcher));
        (IHookrLauncher.Token memory t, address subject) = _middleTokenFor(address(mover), 1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _priced(high1, _memberPrice(subject, high1, 3, 2));
        // Member 1 priced at one high2 a subject: through the reference (one high2 costs 5/4 high1) that is 5/4 high1,
        // 1/6 below member 0's 3/2.
        members[1] = _priced(high2, _memberPrice(subject, high2, 1, 1));
        IHookrLauncher.LaunchParams memory p = _params(t, members);
        p.opening.references = new PoolKey[](1);
        PoolKey memory ref = _reference(high2, high1, 5, 4);
        p = _opening(p, 10, ref);
        vm.prank(address(mover));
        vm.expectPartialRevert(IHookrLauncher.OpeningOutsideTolerance.selector);
        launcher.launchFamily(p);
        // Moved first, to one high2 costing 3/2 high1, in the same transaction: the check passes.
        uint160 moved = Currency.unwrap(ref.currency0) == Currency.unwrap(high2) ? _sqrtX96(3, 2) : _sqrtX96(2, 3);
        bytes32 family = mover.moveThenLaunch(launcher, p, ref, moved);
        assertEq(launcher.familyOwner(family), address(mover), "launched through the moved reference");
        (uint160 price,,,) = manager.getSlot0(ref.toId());
        assertEq(price, moved);
    }
}

/// @notice The dynamic fee liquidity divisor's bounds, proven at both ends: at divisor 2 (the minimum dynamic fee
///         liquidity is half the launch liquidity) and 10,000 (a ten-thousandth of it), launched through
///         launchFamily, the dynamic fee attacks of DF-01, DF-02, F-003 and L-05 hold as at the default 100: a dust
///         trap or near-free pushes add nothing to the next buyers' fee, a split inside the window saves nothing, a
///         sandwich costs more than without dynamic fees, the charge covers the executed move and a launch at a band's
///         edge pays the in-range fee. Pure dynamic fee pool: base 3,000, maxFee 100,000, sens 5, share 2,500, launch
///         liquidity 1e24 at spacing 60; quote is currency0 unless stated, so a buy is zeroForOne.
contract LauncherFamilyDivisorBoundsTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BandLp internal dust;
    DustRangeSwapper internal swapper;
    address internal attacker = address(0xBAD);
    address internal victim = address(0xB0B);

    function setUp() public override {
        super.setUp();
        dust = new BandLp(manager);
        swapper = new DustRangeSwapper(manager);
        tokenA.transfer(address(dust), 1e18);
        tokenB.transfer(address(dust), 1e18);
        tokenA.transfer(address(swapper), 1e21);
        tokenB.transfer(address(swapper), 1e21);
        address[2] memory people = [attacker, victim];
        for (uint256 i; i < 2; ++i) {
            tokenA.transfer(people[i], 1e27);
            tokenB.transfer(people[i], 1e27);
            vm.startPrank(people[i]);
            tokenA.approve(address(router), type(uint256).max);
            tokenB.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _bounds() internal pure returns (uint16[2] memory) {
        return [uint16(2), 10_000];
    }

    /// @dev `m` launched alone through launchFamily at `divisor`, one parent block later.
    function _launchAt(IHookrLauncher.Member memory m, bool subjectFirst, uint16 divisor)
        internal
        returns (PoolKey memory key)
    {
        (HookrToken subject, Currency quote) = _pair(subjectFirst);
        m.quote = quote;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        IHookrLauncher.LaunchParams memory p;
        p.token = IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0));
        p.root = address(root);
        p.members = members;
        p.knobs = new IHookrLauncher.MemberKnobs[](1);
        p.knobs[0].dynamicFeeLiquidityDivisor = divisor;
        p.advisoryConfigs = new bytes[](1);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
        (bytes32 family,,) = launcher.launchFamily(p);
        key = launcher.position(family, 0).key;
        if (m.rules.dynamicFeeSens != 0) {
            (uint256 minimum,,,,,) = rules.referenceState(key.toId());
            assertEq(minimum, uint256(m.liquidity) / (divisor == 0 ? 100 : divisor), "the divisor's minimum");
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev The F-003 pool: band [-60,000, 0) under the launch price at tick 0.
    function _edgePool(uint16 divisor) internal returns (PoolKey memory key) {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickUpper = 0;
        key = _launchAt(m, false, divisor);
    }

    function _swapAs(address who, PoolKey memory key, bool buy, bool exactInput, uint128 amount)
        internal
        returns (HookrTypes.ExecutionReceipt memory r, uint256 output)
    {
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = who;
        r = quoter.quote(p, who);
        vm.prank(who);
        (, output) = router.swap(p, address(0), new uint256[](0));
    }

    // ------------------------------------------------------------------------------------------------ F-003

    /// @dev F-003's dust trap: a liquidity-1 range above the price and a near-free push to tick 16,200, then a buyer
    ///      after `blocks` blocks and `wait` seconds pays what it pays with no trap.
    function _trap(uint16 divisor, uint256 blocks, uint256 wait) internal {
        uint256 fresh = vm.snapshotState();
        PoolKey memory key = _edgePool(divisor);
        uint256 snap = vm.snapshotState();
        vm.warp(vm.getBlockTimestamp() + wait);
        uint256 ctlFee = _quoteBuy(key, 1e21).lpFeePips;
        (, uint256 ctlOut) = _buyAs(trader, key, 1e21);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        dust.modify(key, 60, 16_080, 1);
        swapper.swap(key, false, -1e6, TickMath.getSqrtPriceAtTick(16_200));
        vm.stopPrank();
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertGe(tick, 16_199, "price pushed");
        (,, int24 anchor,,,) = rules.referenceState(key.toId());
        assertEq(anchor, 0, "the push leaves the anchor");
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + wait);
        uint256 fee = _quoteBuy(key, 1e21).lpFeePips;
        (, uint256 out) = _buyAs(trader, key, 1e21);
        assertApproxEqAbs(fee, ctlFee, 1, "the trap adds nothing");
        assertGe(out * 1000, ctlOut * 999, "victim output");
        vm.revertToState(fresh);
    }

    function test_dustTrapAtBothBounds() public {
        uint16[2] memory ds = _bounds();
        for (uint256 i; i < 2; ++i) {
            _trap(ds[i], 0, 0);
            _trap(ds[i], 1, 12);
            _trap(ds[i], 10, _dynamicFeeWindow() + 1);
            _trap(ds[i], 40, _dynamicFeeReset() + 1);
        }
    }

    /// @notice F-003's widest residual: a liquidity-1 band from above the price to the top of the tick range and a
    ///         push to the edge, at the most sensitive setting and the widest span the reach bound admits there.
    function test_wideDustBandAtBothBounds() public {
        uint16[2] memory ds = _bounds();
        for (uint256 i; i < 2; ++i) {
            uint256 fresh = vm.snapshotState();
            IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
            m.tickSpacing = 16;
            m.rules.dynamicFeeSens = 10;
            m.rules.maxFeePips = uint24(3000 + RulesData.maxDynamicFeeSpan(10, 2_500, 3000));
            m.tickUpper = 0;
            m.tickLower = -(60_000 / 16) * 16;
            PoolKey memory key = _launchAt(m, false, ds[i]);
            uint256 snap = vm.snapshotState();
            uint256 ctlFee = _quoteBuy(key, 1e21).lpFeePips;
            (, uint256 ctlOut) = _buyAs(trader, key, 1e21);
            vm.revertToState(snap);
            vm.startPrank(attacker);
            dust.modify(key, 16, TickMath.maxUsableTick(16), 1);
            swapper.swap(key, false, -1e20, TickMath.MAX_SQRT_PRICE - 1);
            vm.stopPrank();
            vm.roll(vm.getBlockNumber() + 1);
            uint256 fee = _quoteBuy(key, 1e21).lpFeePips;
            (, uint256 out) = _buyAs(trader, key, 1e21);
            assertApproxEqAbs(fee, ctlFee, 1, "the band adds nothing");
            assertGe(out * 1000, ctlOut * 999, "victim output");
            vm.revertToState(fresh);
        }
    }

    // ------------------------------------------------------------------------------------------------ DF-01

    /// @dev DF-01's two near-free pushes through a thin range and back, then five victims, against five victims alone.
    function _roundTrip(uint16 divisor, uint24 maxFee, uint16 sens) internal {
        uint256 fresh = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickUpper = 0;
        m.rules.maxFeePips = maxFee;
        m.rules.dynamicFeeSens = sens;
        PoolKey memory key = _launchAt(m, false, divisor);
        uint256 snap = vm.snapshotState();
        uint256[5] memory ctl;
        for (uint256 i; i < 5; ++i) {
            (HookrTypes.ExecutionReceipt memory r,) = _swapAs(victim, key, true, true, 1e21);
            ctl[i] = r.lpFeePips;
        }
        vm.revertToState(snap);
        vm.startPrank(attacker);
        dust.modify(key, 60, 16_080, 1e12);
        swapper.swap(key, false, -1e18, TickMath.getSqrtPriceAtTick(16_200));
        swapper.swap(key, true, 1e18, TickMath.getSqrtPriceAtTick(0));
        dust.modify(key, 60, 16_080, -1e12);
        vm.stopPrank();
        for (uint256 i; i < 5; ++i) {
            (HookrTypes.ExecutionReceipt memory r,) = _swapAs(victim, key, true, true, 1e21);
            assertApproxEqAbs(r.lpFeePips, ctl[i], 1, "the pushes add nothing");
        }
        vm.revertToState(fresh);
    }

    /// The default pool and the most sensitive one at the widest span the reach bound admits there.
    function test_nearFreePushesAtBothBounds() public {
        uint16[2] memory ds = _bounds();
        uint24 widest = uint24(3000 + RulesData.maxDynamicFeeSpan(10, 2_500, 3000));
        for (uint256 i; i < 2; ++i) {
            _roundTrip(ds[i], 100_000, 5);
            _roundTrip(ds[i], widest, 10);
        }
    }

    /// @dev One 6e22 buy, or the same buy in `n` pieces `gap` seconds apart, on a fresh pool at `divisor`.
    function _split(uint16 divisor, uint256 n, uint256 gap) internal returns (uint256 out, uint256 protocolClaim) {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _launchAt(_dynamicFeeMember(Currency.wrap(address(0))), false, divisor);
        uint128 piece = uint128(6e22 / n);
        Currency subject = root.poolConfig(key.toId()).subject;
        uint256 before = IERC20(Currency.unwrap(subject)).balanceOf(victim);
        for (uint256 i; i < n; ++i) {
            if (i != 0) vm.warp(vm.getBlockTimestamp() + gap);
            _swapAs(victim, key, true, true, piece);
        }
        out = IERC20(Currency.unwrap(subject)).balanceOf(victim) - before;
        protocolClaim = rules.claimable(root.poolConfig(key.toId()).quote, protocol);
        vm.revertToState(snap);
    }

    /// @notice DF-01's split: the same 6e22 buy in 2 to 30 pieces at one timestamp, and spread over the reset period
    ///         with no gap as long as the window, gets no more subject than the single buy and pays its dynamic fee less
    ///         the single buy's simulation lead.
    function test_splitSavesNothingAtBothBounds() public {
        uint16[2] memory ds = _bounds();
        uint256[4] memory ns = [uint256(2), 5, 10, 30];
        for (uint256 i; i < 2; ++i) {
            (uint256 oneOut, uint256 oneFee) = _split(ds[i], 1, 0);
            for (uint256 k; k < 4; ++k) {
                uint256 spread = (_dynamicFeeReset() - 1) / (ns[k] - 1);
                if (spread >= _dynamicFeeWindow()) spread = _dynamicFeeWindow() - 1;
                for (uint256 g; g < 2; ++g) {
                    (uint256 out, uint256 fee) = _split(ds[i], ns[k], g == 0 ? 0 : spread);
                    assertLe(out * 10_000, oneOut * 10_003, "no more subject than the single buy");
                    assertGe(fee * 10_000, oneFee * 9_700, "the same dynamic fee, less the single buy's lead");
                }
            }
        }
    }

    /// @dev DF-01's sandwich: a 3e22 front-run, the victim's 1e22 buy and the back-run sell; the attacker's quote P&L.
    function _sandwich(IHookrLauncher.Member memory m, uint16 divisor)
        internal
        returns (int256 pnl, uint256 frontFee, uint256 backFee)
    {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _launchAt(m, false, divisor);
        address quote = Currency.unwrap(root.poolConfig(key.toId()).quote);
        uint256 quoteBefore = IERC20(quote).balanceOf(attacker);
        (HookrTypes.ExecutionReceipt memory front, uint256 got) = _swapAs(attacker, key, true, true, 3e22);
        _swapAs(victim, key, true, true, 1e22);
        (HookrTypes.ExecutionReceipt memory back,) = _swapAs(attacker, key, false, true, uint128(got));
        pnl = int256(IERC20(quote).balanceOf(attacker)) - int256(quoteBefore);
        (frontFee, backFee) = (front.lpFeePips, back.lpFeePips);
        vm.revertToState(snap);
    }

    function test_sandwichCostsMoreAtBothBounds() public {
        uint16[2] memory ds = _bounds();
        IHookrLauncher.Member memory flat = _dynamicFeeMember(Currency.wrap(address(0)));
        flat.rules.maxFeePips = 3000;
        flat.rules.dynamicFeeSens = 0;
        (int256 flatPnl,,) = _sandwich(flat, 0);
        for (uint256 i; i < 2; ++i) {
            (int256 pnl, uint256 frontFee, uint256 backFee) =
                _sandwich(_dynamicFeeMember(Currency.wrap(address(0))), ds[i]);
            assertGt(frontFee, 3000, "the front-run pays for its own move");
            assertEq(backFee, 3000, "the back-run pays the base fee only");
            assertLt(pnl, flatPnl, "dynamic fees make the sandwich cost more");
        }
    }

    /// @notice DF-01's parked gap: a 1-wei sell parks the price beyond all liquidity, against the buy direction; after
    ///         each wait the next buy pays what it pays with no park.
    function test_parkedGapAtBothBounds() public {
        uint16[2] memory ds = _bounds();
        uint256[3] memory waits = [uint256(0), _dynamicFeeWindow() + 1, _dynamicFeeReset() + 1];
        for (uint256 i; i < 2; ++i) {
            for (uint256 w; w < 3; ++w) {
                uint256 fresh = vm.snapshotState();
                PoolKey memory key = _edgePool(ds[i]);
                uint256 snap = vm.snapshotState();
                vm.warp(vm.getBlockTimestamp() + waits[w]);
                HookrTypes.ExecutionReceipt memory ctl = _quoteBuy(key, 1e22);
                vm.revertToState(snap);
                vm.prank(attacker);
                swapper.swap(key, false, -1, TickMath.MAX_SQRT_PRICE - 1);
                vm.warp(vm.getBlockTimestamp() + waits[w]);
                HookrTypes.ExecutionReceipt memory atk = _quoteBuy(key, 1e22);
                assertGt(ctl.lpFeePips, 3000, "control pays a dynamic fee");
                assertApproxEqAbs(atk.lpFeePips, ctl.lpFeePips, 1, "the parked gap adds nothing");
                assertEq(atk.outputAmount, ctl.outputAmount, "same fill");
                vm.revertToState(fresh);
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ L-05, DF-02

    /// @notice L-05: a pool opening at its band's edge pays the in-range dynamic fee on its first buy.
    function test_boundaryOpenAtBothBounds() public {
        uint16[2] memory ds = _bounds();
        for (uint256 i; i < 2; ++i) {
            for (uint256 k; k < 2; ++k) {
                uint128 amount = k == 0 ? 5e21 : 1e22;
                uint256 snap = vm.snapshotState();
                IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
                m.tickUpper = 0;
                HookrTypes.ExecutionReceipt memory boundary = _quoteBuy(_launchAt(m, false, ds[i]), amount);
                vm.revertToState(snap);
                m.tickUpper = 60;
                HookrTypes.ExecutionReceipt memory control = _quoteBuy(_launchAt(m, false, ds[i]), amount);
                vm.revertToState(snap);
                assertGt(boundary.lpFeePips, 3000, "dynamic fee charged at the boundary");
                assertGe(uint256(boundary.lpFeePips) * 100, uint256(control.lpFeePips) * 95, "LP fee");
                assertGe(boundary.quoteFee * 100, control.quoteFee * 95, "protocol");
            }
        }
    }

    /// @notice DF-02: over random pools and swaps at either bound, a fresh pool's first swap is charged at least the
    ///         dynamic fee its executed end price implies, and an exact-output buy exactly that.
    function testFuzz_chargeCoversTheMoveAtBothBounds(uint256 seed) public {
        uint16 divisor = _bounds()[seed % 2];
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.dynamicFeeSens = uint16(1 + uint256(keccak256(abi.encode(seed, 1))) % 10);
        uint24[4] memory spans = [uint24(10_000), 50_000, 100_000, 600_000];
        m.rules.maxFeePips = spans[uint256(keccak256(abi.encode(seed, 2))) % 4];
        // At most the widest span the reach bound admits at the pool's sensitivity and share.
        RulesData.clampToReach(m.rules, 3000);
        int24 tick = int24(int256(uint256(keccak256(abi.encode(seed, 5))) % 40_001)) - 20_000;
        m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        int24 aligned = tick / 60 * 60;
        m.tickLower = aligned - 30_000;
        m.tickUpper = aligned + 30_000;
        m.amount0Max = 1e27;
        m.amount1Max = 1e27;
        PoolKey memory key = _launchAt(m, uint256(keccak256(abi.encode(seed, 6))) % 2 == 1, divisor);
        bool buy = uint256(keccak256(abi.encode(seed, 40))) % 2 == 1;
        bool exactInput = uint256(keccak256(abi.encode(seed, 41))) % 2 == 1;
        uint128 amount = uint128(10 ** (15 + uint256(keccak256(abi.encode(seed, 42))) % 9));
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = victim;
        HookrTypes.ExecutionReceipt memory r;
        try quoter.quote(p, victim) returns (HookrTypes.ExecutionReceipt memory q) {
            r = q;
        } catch {
            return;
        }
        vm.prank(victim);
        router.swap(p, address(0), new uint256[](0));
        (uint160 end,,,) = manager.getSlot0(key.toId());
        int256 dist = HookrDynamicFee.distance(TickMath.getSqrtPriceAtTick(tick), end, p.zeroForOne);
        uint256 ideal;
        if (dist > 0) {
            ideal = uint256(m.rules.maxFeePips - 3000)
                * HookrDynamicFee.averageRate(0, uint256(dist), m.rules.dynamicFeeSens) / HookrDynamicFee.WAD;
        }
        // A pure dynamic fee pool: base 3,000 plus the dynamic fee less its 25% share.
        uint256 room = 600_000 - 3000;
        if (ideal > room) ideal = room;
        uint256 floorFee = 3000 + ideal - ideal * 2500 / 10_000;
        assertGe(uint256(r.lpFeePips) + 1, floorFee, "never below the executed move");
        if (buy && !exactInput) assertApproxEqAbs(r.lpFeePips, floorFee, 1, "an exact-output buy is exact");
    }
}

/// @dev A treasury target that tries to re-enter the launcher when it is paid, and records the answer.
contract ReenteringTarget {
    HookrLauncher internal immutable launcher;
    bytes public answer;

    constructor(HookrLauncher l) {
        launcher = l;
    }

    receive() external payable {
        try launcher.sweep(Currency.wrap(address(0)), address(this)) {
            answer = "swept";
        } catch (bytes memory reason) {
            answer = reason;
        }
    }
}

/// @dev A treasury target that refuses native payments.
contract RefusingTarget {}

/// @notice LA-14, the launch fee: zero at deploy, proposed by the registry's owner, applied after the registry's delay,
///         cleared at once by the owner or the guardian, at most 0.01 of the native currency, and paid by every launch
///         entry point to the treasury's target in the same call, with msg.value exact.
contract LauncherLaunchFeeTest is LauncherFamilyFixture {
    IHookrLaunchFee internal fees;
    HookrTreasury internal treasury;
    address internal target = address(0x7A7);
    address internal guardianAccount = address(0x6A7D);

    function setUp() public {
        _setUpPeriphery();
        fees = IHookrLaunchFee(address(launcher));
        treasury = new HookrTreasury(address(this), target, manager);
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
    }

    function _setFee(uint96 fee) internal {
        fees.proposeLaunchFee(fee, address(treasury));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        fees.acceptLaunchFee();
    }

    function _existing() internal view returns (IHookrLauncher.Token memory) {
        return IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
    }

    function _ethMember() internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH);
    }

    function test_storageSlotIsErc7201() public pure {
        assertEq(
            HookrLaunchChecks.FEE_SLOT,
            keccak256(abi.encode(uint256(keccak256("hookr.launcher.fee")) - 1)) & ~bytes32(uint256(0xff))
        );
    }

    /// @notice At deploy the fee is zero and every launch takes exactly its native budgets, as before.
    function test_zeroAtDeploy() public {
        (uint256 fee, address t, uint256 pendingFee, address pendingTreasury, uint256 readyAt) = fees.launchFee();
        assertEq(fee, 0);
        assertEq(t, address(0));
        assertEq(pendingFee, 0);
        assertEq(pendingTreasury, address(0));
        assertEq(readyAt, 0);
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch{value: 1e24 + 1}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        launcher.launch{value: 1e24}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        assertEq(target.balance, 0);
        assertEq(address(launcher).balance, 0);
    }

    /// @notice Only the registry's owner proposes and applies, within the ceiling, after the delay and inside the grace;
    ///         a new owner cannot apply its predecessor's proposal.
    function test_governance() public {
        uint256 max = 0.01 ether;
        vm.prank(guardianAccount);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.NotFeeGovernor.selector, guardianAccount));
        fees.proposeLaunchFee(1, address(treasury));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidLaunchFee.selector, max + 1, address(treasury)));
        fees.proposeLaunchFee(uint96(max + 1), address(treasury));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidLaunchFee.selector, uint256(1), target));
        fees.proposeLaunchFee(1, target);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.LaunchFeeNotReady.selector, uint256(0)));
        fees.acceptLaunchFee();

        vm.expectEmit(false, false, false, true, address(launcher));
        emit IHookrLauncher.LaunchFeeProposed(max, address(treasury), vm.getBlockTimestamp() + registry.delay());
        fees.proposeLaunchFee(uint96(max), address(treasury));
        (,, uint256 pendingFee, address pendingTreasury, uint256 readyAt) = fees.launchFee();
        assertEq(pendingFee, max);
        assertEq(pendingTreasury, address(treasury));
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.LaunchFeeNotReady.selector, readyAt));
        fees.acceptLaunchFee();
        vm.warp(readyAt);
        vm.prank(guardianAccount);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.NotFeeGovernor.selector, guardianAccount));
        fees.acceptLaunchFee();
        uint256 snap = vm.snapshotState();
        vm.warp(readyAt + 14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.LaunchFeeNotReady.selector, readyAt));
        fees.acceptLaunchFee();
        vm.revertToState(snap);
        vm.expectEmit(false, false, false, true, address(launcher));
        emit IHookrLauncher.LaunchFeeSet(max, address(treasury));
        fees.acceptLaunchFee();
        (uint256 fee, address t,,,) = fees.launchFee();
        assertEq(fee, max, "the ceiling is a valid fee");
        assertEq(t, address(treasury));

        // An owner change voids a pending proposal.
        fees.proposeLaunchFee(1, address(treasury));
        address next = address(0x0E1);
        registry.queue(registry.TRANSFER_OWNER(), abi.encode(next));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.transferOwnership(next);
        vm.prank(next);
        registry.acceptOwnership();
        (,,,, readyAt) = fees.launchFee();
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.LaunchFeeNotReady.selector, readyAt));
        fees.acceptLaunchFee();
    }

    /// @notice The owner or the guardian clears the fee at once, with any pending proposal; nobody else can.
    function test_clear() public {
        _setFee(1e15);
        fees.proposeLaunchFee(2e15, address(treasury));
        vm.prank(address(0x5757));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.NotFeeGovernor.selector, address(0x5757)));
        fees.clearLaunchFee();
        vm.prank(guardianAccount);
        fees.clearLaunchFee();
        (uint256 fee,, uint256 pendingFee,, uint256 readyAt) = fees.launchFee();
        assertEq(fee, 0);
        assertEq(pendingFee, 0);
        assertEq(readyAt, 0);
        launcher.launch{value: 1e24}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        _setFee(1e15);
        fees.clearLaunchFee();
        (fee,,,,) = fees.launchFee();
        assertEq(fee, 0, "the owner clears too");
    }

    /// @notice Every launch entry point pays the fee to the treasury's target in the same call, with msg.value exactly
    ///         its native budgets plus the fee; less or more is refused and the launcher keeps nothing.
    function test_everyLaunchPays() public {
        uint96 fee = 1e15;
        _setFee(fee);
        // launch, on a native member.
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch{value: 1e24 + fee - 1}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch{value: 1e24 + fee + 1}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        vm.expectEmit(false, true, false, true, address(launcher));
        emit IHookrLauncher.LaunchFeePaid(bytes32(0), target, fee);
        launcher.launch{value: 1e24 + fee}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        assertEq(target.balance, fee);
        // launchAdvised, on an ERC-20 member: msg.value is the fee alone.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launchAdvised(_existing(), address(root), members, new bytes[](1), vm.getBlockTimestamp());
        launcher.launchAdvised{value: fee}(_existing(), address(root), members, new bytes[](1), vm.getBlockTimestamp());
        assertEq(target.balance, 2 * fee);
        // launchWithBuy and launchFamily, on new tokens.
        (IHookrLauncher.Token memory t, address subject) = _newToken(ETH, false);
        IHookrLauncher.DevBuy memory buy = IHookrLauncher.DevBuy(0, 1e21, 1, 0);
        launcher.launchWithBuy{value: 1e21 + fee}(
            t, address(root), _one(subject, ETH), new bytes[](1), buy, vm.getBlockTimestamp()
        );
        assertEq(target.balance, 3 * fee);
        (t, subject) = _newToken(ETH, false);
        IHookrLauncher.LaunchParams memory p = _params(t, _one(subject, ETH));
        launcher.launchFamily{value: _value(p) + fee}(p);
        assertEq(target.balance, 4 * fee);
        assertEq(address(launcher).balance, 0, "the launcher keeps nothing");
        assertEq(tokenB.balanceOf(address(launcher)), 0);
    }

    /// @notice The fee follows the treasury's target, and a target that refuses it stops launches until the fee is
    ///         cleared, which the guardian can do at once.
    function test_targetRefusalAndClear() public {
        _setFee(1e15);
        RefusingTarget refusing = new RefusingTarget();
        treasury.proposeTarget(address(refusing));
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.LaunchFeeUndelivered.selector, address(refusing), 1e15));
        launcher.launch{value: 1e24 + 1e15}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        vm.prank(guardianAccount);
        fees.clearLaunchFee();
        launcher.launch{value: 1e24}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
    }

    /// @notice A target paid the fee cannot re-enter the launcher: the launch runs under its lock.
    function test_targetCannotReenter() public {
        ReenteringTarget reentering = new ReenteringTarget(launcher);
        _setFee(1e15);
        treasury.proposeTarget(address(reentering));
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
        launcher.launch{value: 1e24 + 1e15}(_existing(), address(root), _ethMember(), vm.getBlockTimestamp());
        assertEq(bytes4(reentering.answer()), IHookrLauncher.Reentered.selector);
        assertEq(address(reentering).balance, 1e15);
    }

    /// @notice The fallback serves the four fee functions only: any other unknown call, or value sent with no call,
    ///         reverts as before.
    function test_fallbackServesTheFeeTermsOnly() public {
        (bool ok,) = address(launcher).call(abi.encodeWithSignature("checkFamily()"));
        assertFalse(ok);
        (ok,) = address(launcher).call(abi.encodeWithSelector(HookrLaunchChecks.familyBounds.selector));
        assertFalse(ok, "the library's other functions are not served");
        (ok,) = address(launcher).call{value: 1}("");
        assertFalse(ok, "no plain native transfer");
        (ok,) = address(launcher).call{value: 1}(abi.encodeWithSelector(IHookrLaunchFee.launchFee.selector));
        assertFalse(ok, "no value with a fee call");
    }
}
