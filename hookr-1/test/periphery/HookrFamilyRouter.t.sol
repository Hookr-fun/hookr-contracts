// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrSwapGate} from "../../src/interfaces/IHookrSwapGate.sol";
import {IHookrFamilyRouter} from "../../src/interfaces/IHookrFamilyRouter.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {IPermit2Signature} from "../../src/interfaces/external/IPermit2Signature.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrFamilyRouter} from "../../src/periphery/HookrFamilyRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {GasBenchFixture, IUniversalRouter, IPermit2Bench} from "../utils/GasBenchFixture.sol";
import {ReferenceLP} from "../utils/ReferenceLP.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";

/// @dev A subject token that, while armed, calls back into the family router and HookrRouter on every transfer and
///      records the first four bytes of each refusal.
/// @dev A caller that, paid native, forces everything it holds straight back into `target` by SELFDESTRUCT (which
///      cannot be refused): a donation to the family router in the middle of its trade.
contract ForceBack {
    address payable internal immutable target;

    constructor(address target_) {
        target = payable(target_);
    }

    receive() external payable {
        selfdestruct(target);
    }
}

contract HostileSubject is ERC20 {
    IHookrFamilyRouter public fam;
    IHookrRouter public router;
    bool public armed;
    bytes4[] public refusals;

    constructor() ERC20("Hostile", "HOS") {
        _mint(msg.sender, 1e30);
    }

    function arm(IHookrFamilyRouter fam_, IHookrRouter router_) external {
        (fam, router, armed) = (fam_, router_, true);
    }

    function refusalCount() external view returns (uint256) {
        return refusals.length;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (!armed) return;
        armed = false;
        IHookrFamilyRouter.FamilyTrade memory empty;
        _try(address(fam), abi.encodeCall(IHookrFamilyRouter.trade, (empty, "")));
        _try(address(fam), abi.encodeCall(IHookrFamilyRouter.sweep, (Currency.wrap(address(this)), from)));
        PoolKey memory key;
        _try(address(fam), abi.encodeCall(IHookrSwapGate.beforeUnlock, (address(fam), from, key, true, -1, "")));
        IHookrRouter.Swap memory p;
        _try(address(router), abi.encodeCall(IHookrRouter.swap, (p, address(0), new uint256[](0))));
        armed = true;
    }

    function _try(address target, bytes memory data) internal {
        (bool ok, bytes memory reason) = target.call(data);
        require(!ok, "reentry succeeded");
        refusals.push(bytes4(reason));
    }
}

/// @notice HookrFamilyRouter on the real 4663 PoolManager, Universal Router 2.1.1 and Permit2 runtimes: one trade split
///         across a four-member family (members quoted in ETH and three ERC-20 quotes), each leg converting through
///         a hookless or a Hookr reference pool when its member is quoted in another asset than the trade's own
///         currency; the caller pays exactly the legs' sum, the recipient receives exactly the legs' outputs and the
///         router keeps nothing, native included; every leg's minimum and the total minimum hold; any failing leg
///         reverts the whole trade; every Hookr swap runs through HookrRouter.swapGated with the family router as the
///         root's GATE vouching only for its own caller; and the same split as one Universal Router V4_SWAP gives the
///         same per-leg outputs.
contract HookrFamilyRouterTest is GasBenchFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant POOL_SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    Currency internal constant ETH = Currency.wrap(address(0));

    /// @dev Universal Router 2.1.1's PathKey and SWAP_EXACT_IN parameters.
    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        IHooks hooks;
        bytes hookData;
    }

    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    HookrFamilyRouter internal fam;
    HookrToken internal famSubject;
    bytes32 internal family;
    /// @dev The family's members, quoted in ETH, Q0, Q1 and Q2.
    PoolKey[4] internal members;
    Currency[4] internal memberQuotes;
    ReferenceLP internal lp;
    address internal recipient = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        fam = new HookrFamilyRouter(router, IHookrLauncherView(address(launcher)), permit2);
        _admitGate(address(root), address(fam));
        famSubject = new HookrToken("Family", "FAM", 1e30, address(this));
        famSubject.approve(address(launcher), type(uint256).max);
        memberQuotes = [
            ETH, Currency.wrap(address(quotes[0])), Currency.wrap(address(quotes[1])), Currency.wrap(address(quotes[2]))
        ];
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](4);
        for (uint256 i; i < 4; ++i) {
            m[i] = _member(memberQuotes[i], 60, false);
        }
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(famSubject), "", "", 0, bytes32(0)), address(root), m, vm.getBlockTimestamp()
        );
        for (uint256 i; i < 4; ++i) {
            members[i] = launcher.position(family, uint8(i)).key;
        }
        lp = new ReferenceLP(manager);
        vm.deal(address(lp), 1e28);
        for (uint256 i; i < 3; ++i) {
            quotes[i].transfer(address(lp), 1e27);
        }
        // Hookless conversion pools between every two of ETH, Q0, Q1 and Q2.
        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                _seed(_hookless(memberQuotes[i], memberQuotes[j]));
            }
        }
        // The trader holds and approved everything: the family router (transferFrom), Permit2 and, through Permit2,
        // the Universal Router.
        famSubject.transfer(trader, 1e27);
        vm.deal(trader, 1e28);
        vm.startPrank(trader);
        famSubject.approve(address(fam), type(uint256).max);
        famSubject.approve(permit2, type(uint256).max);
        IPermit2Bench(permit2).approve(address(famSubject), ur, type(uint160).max, type(uint48).max);
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            quotes[i].transfer(trader, 1e27);
            vm.startPrank(trader);
            quotes[i].approve(address(fam), type(uint256).max);
            quotes[i].approve(permit2, type(uint256).max);
            IPermit2Bench(permit2).approve(address(quotes[i]), ur, type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
        _nextBlock();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _admitGate(address scope, address gate) internal {
        ReleaseWiring.admitAfterDelay(registry, scope, ReleaseWiring.gateAdmission(gate, 100_000));
    }

    /// @dev The hookless 0.3% pool of `a` and `b`, spacing 60.
    function _hookless(Currency a, Currency b) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey(c0, c1, 3000, 60, IHooks(address(0)));
    }

    /// @dev Initializes `key` at price 1 and adds 1e24 of liquidity over ticks -60,000 to 60,000.
    function _seed(PoolKey memory key) internal {
        manager.initialize(key, SQRT_ONE);
        lp.modify(key, -60_000, 60_000, 1e24);
    }

    function _empty() internal pure returns (PoolKey memory k) {}

    function _leg(uint256 member, Currency own, uint128 amountIn, uint128 minOut)
        internal
        view
        returns (IHookrFamilyRouter.Leg memory leg)
    {
        leg.key = members[member];
        leg.conversion = Currency.unwrap(memberQuotes[member]) == Currency.unwrap(own)
            ? _empty()
            : _hookless(own, memberQuotes[member]);
        leg.amountIn = amountIn;
        leg.minOut = minOut;
    }

    /// @dev A trade of the family over every member, each leg `amountIn`, converting through hookless pools.
    function _trade(Currency input, Currency output, uint128 amountIn)
        internal
        view
        returns (IHookrFamilyRouter.FamilyTrade memory t)
    {
        bool buy = Currency.unwrap(output) == address(famSubject);
        Currency own = buy ? input : output;
        t.familyId = family;
        t.input = input;
        t.output = output;
        t.legs = new IHookrFamilyRouter.Leg[](4);
        for (uint256 i; i < 4; ++i) {
            t.legs[i] = _leg(i, own, amountIn, 1);
        }
        t.minTotalOut = 4;
        t.recipient = buy ? recipient : trader;
        t.deadline = vm.getBlockTimestamp() + 1000;
    }

    function _balance(Currency c, address who) internal view returns (uint256) {
        return Currency.unwrap(c) == address(0) ? who.balance : ERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _send(IHookrFamilyRouter.FamilyTrade memory t) internal returns (uint256 amountIn, uint256 amountOut) {
        uint256 value;
        if (Currency.unwrap(t.input) == address(0)) {
            for (uint256 i; i < t.legs.length; ++i) {
                value += t.legs[i].amountIn;
            }
        }
        vm.prank(trader);
        return fam.trade{value: value}(t, "");
    }

    function _expectTrade(IHookrFamilyRouter.FamilyTrade memory t, bytes memory reason) internal {
        uint256 value;
        if (Currency.unwrap(t.input) == address(0)) {
            for (uint256 i; i < t.legs.length; ++i) {
                value += t.legs[i].amountIn;
            }
        }
        vm.prank(trader);
        vm.expectRevert(reason);
        fam.trade{value: value}(t, "");
    }

    /// @dev Every currency the trade touches, with the family router's, the trader's and the recipient's balances.
    struct Books {
        Currency[5] currencies;
        uint256[5] router;
        uint256[5] traderHeld;
        uint256[5] recipientHeld;
    }

    function _books(address to) internal view returns (Books memory b) {
        b.currencies = [ETH, memberQuotes[1], memberQuotes[2], memberQuotes[3], Currency.wrap(address(famSubject))];
        for (uint256 i; i < 5; ++i) {
            b.router[i] = _balance(b.currencies[i], address(fam));
            b.traderHeld[i] = _balance(b.currencies[i], trader);
            b.recipientHeld[i] = _balance(b.currencies[i], to);
        }
    }

    function _index(Currency c) internal view returns (uint256) {
        if (Currency.unwrap(c) == address(0)) return 0;
        if (Currency.unwrap(c) == address(famSubject)) return 4;
        for (uint256 i = 1; i < 4; ++i) {
            if (Currency.unwrap(memberQuotes[i]) == Currency.unwrap(c)) return i;
        }
        revert("unknown currency");
    }

    /// @dev The trade conserved both currencies to the wei: the trader paid exactly `amountIn`, the recipient received
    ///      exactly `amountOut`, nothing else moved for either, and the family router holds what it held.
    function _assertConserved(
        Books memory before,
        Currency input,
        Currency output,
        address to,
        uint256 amountIn,
        uint256 amountOut
    ) internal view {
        Books memory now_ = _books(to);
        uint256 i = _index(input);
        uint256 o = _index(output);
        for (uint256 k; k < 5; ++k) {
            assertEq(now_.router[k], before.router[k], "the family router keeps nothing");
            if (k == i) {
                assertEq(before.traderHeld[k] - now_.traderHeld[k], amountIn, "the trader paid the legs' sum");
            } else if (k == o) {
                assertEq(now_.recipientHeld[k] - before.recipientHeld[k], amountOut, "the recipient got the outputs");
            } else if (to != trader) {
                assertEq(now_.traderHeld[k], before.traderHeld[k], "no other currency moved for the trader");
            }
        }
        if (to != trader) assertEq(now_.traderHeld[o], before.traderHeld[o], "the trader is not the recipient");
    }

    /// @dev The member pools' Swap events in `logs`: for each member, the output of its swap in `output`.
    function _memberOutputs(Vm.Log[] memory logs, Currency output) internal view returns (uint256[4] memory outs) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(manager) || l.topics.length != 3 || l.topics[0] != POOL_SWAP) continue;
            for (uint256 m; m < 4; ++m) {
                if (l.topics[1] != PoolId.unwrap(members[m].toId())) continue;
                (int128 amount0, int128 amount1) = abi.decode(l.data, (int128, int128));
                bool outIs0 = Currency.unwrap(members[m].currency0) == Currency.unwrap(output);
                int128 out = outIs0 ? amount0 : amount1;
                if (out > 0) outs[m] = uint256(uint128(out));
            }
        }
    }

    // ───────────────────────────── splits ─────────────────────────────

    /// A buy split across the four members, paid in Q0: one leg direct, three converting through hookless pools; the
    /// trader pays exactly the legs' sum, the recipient receives exactly their outputs, the router keeps nothing, and
    /// each leg's FamilyLeg names its member and conversion.
    function test_buySplitAcrossFourMembers() public {
        Currency q0 = memberQuotes[1];
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, Currency.wrap(address(famSubject)), 1e21);
        Books memory before = _books(recipient);
        vm.recordLogs();
        (uint256 amountIn, uint256 amountOut) = _send(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(amountIn, 4e21);
        _assertConserved(before, q0, t.output, recipient, amountIn, amountOut);
        uint256[4] memory outs = _memberOutputs(logs, t.output);
        uint256 legs;
        uint256 sum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(fam) || logs[i].topics[0] != IHookrFamilyRouter.FamilyLeg.selector) {
                continue;
            }
            uint256 m = legs++;
            assertEq(logs[i].topics[1], family, "family");
            assertEq(logs[i].topics[2], PoolId.unwrap(members[m].toId()), "member");
            bytes32 conversion = m == 1 ? bytes32(0) : PoolId.unwrap(_hookless(q0, memberQuotes[m]).toId());
            assertEq(logs[i].topics[3], conversion, "conversion");
            (uint256 legIn, uint256 legOut) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(legIn, 1e21);
            assertEq(legOut, outs[m], "the leg's output is its member swap's");
            sum += legOut;
        }
        assertEq(legs, 4);
        assertEq(sum, amountOut);
    }

    /// A sell split across the four members, paid out in Q0 to the trader: one leg direct, three converting.
    function test_sellSplitAcrossFourMembers() public {
        Currency q0 = memberQuotes[1];
        IHookrFamilyRouter.FamilyTrade memory t = _trade(Currency.wrap(address(famSubject)), q0, 1e21);
        Books memory before = _books(trader);
        (uint256 amountIn, uint256 amountOut) = _send(t);
        assertEq(amountIn, 4e21);
        assertGt(amountOut, 0);
        Books memory now_ = _books(trader);
        assertEq(before.traderHeld[4] - now_.traderHeld[4], amountIn, "the trader paid the legs' sum of subject");
        assertEq(now_.traderHeld[1] - before.traderHeld[1], amountOut, "the trader received the outputs in Q0");
        for (uint256 k; k < 5; ++k) {
            assertEq(now_.router[k], before.router[k], "the family router keeps nothing");
            if (k != 1 && k != 4) assertEq(now_.traderHeld[k], before.traderHeld[k], "nothing else moved");
        }
    }

    /// Native input: the call's value is exactly the legs' sum, the native member's leg is direct and the others
    /// convert ETH; any other value is refused.
    function test_nativeInputBuy() public {
        IHookrFamilyRouter.FamilyTrade memory t = _trade(ETH, Currency.wrap(address(famSubject)), 1e20);
        Books memory before = _books(recipient);
        vm.prank(trader);
        vm.expectRevert(IHookrFamilyRouter.InvalidTrade.selector);
        fam.trade{value: 4e20 - 1}(t, "");
        vm.prank(trader);
        vm.expectRevert(IHookrFamilyRouter.InvalidTrade.selector);
        fam.trade{value: 4e20 + 1}(t, "");
        (uint256 amountIn, uint256 amountOut) = _send(t);
        assertEq(amountIn, 4e20);
        _assertConserved(before, ETH, t.output, recipient, amountIn, amountOut);
        assertEq(address(fam).balance, 0);
        assertEq(address(router).balance, 0);
    }

    /// Native output: a sell paid out in ETH to the trader, one leg direct and three converting into ETH.
    function test_nativeOutputSell() public {
        IHookrFamilyRouter.FamilyTrade memory t = _trade(Currency.wrap(address(famSubject)), ETH, 1e20);
        Books memory before = _books(trader);
        (uint256 amountIn, uint256 amountOut) = _send(t);
        Books memory now_ = _books(trader);
        assertEq(before.traderHeld[4] - now_.traderHeld[4], amountIn);
        assertEq(now_.traderHeld[0] - before.traderHeld[0], amountOut, "the ETH outputs, to the wei");
        assertEq(address(fam).balance, 0);
        assertEq(address(router).balance, 0);
    }

    /// A trade must leave the router with exactly the native balance it began with: an amount forced into it during the
    /// trade, here by a recipient that destroys itself back into the router, reverts the trade as a shortfall would.
    /// Mutation gate FR-5 (the check read `<`, which let a gain through).
    function test_aTradeThatLeavesTheRouterMoreNativeIsRefused() public {
        IHookrFamilyRouter.FamilyTrade memory t = _trade(Currency.wrap(address(famSubject)), ETH, 1e20);
        // A sell pays its caller, so the caller is the contract that gives the native back.
        vm.etch(trader, address(new ForceBack(address(fam))).code);
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.BalanceChanged.selector, ETH));
    }

    /// An ERC-20 input sent with a value is refused.
    function test_aValueWithAnErc20InputIsRefused() public {
        IHookrFamilyRouter.FamilyTrade memory t = _trade(memberQuotes[1], Currency.wrap(address(famSubject)), 1e20);
        vm.prank(trader);
        vm.expectRevert(IHookrFamilyRouter.InvalidTrade.selector);
        fam.trade{value: 1}(t, "");
    }

    // ───────────────────────────── currencies ─────────────────────────────

    /// A member quoted in another asset with no conversion named, or one quoted in the trade's own currency with a
    /// conversion named, is refused; a conversion pool of other currencies, or hooked by a contract that is not a
    /// registered root, is refused; an input equal to the output, or neither of them the subject, is refused.
    function test_currencyRefusals() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e20);
        t.legs[0].conversion = _empty();
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.MixedCurrencies.selector, members[0].toId()));

        t = _trade(q0, s, 1e20);
        t.legs[1].conversion = _hookless(q0, memberQuotes[2]);
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.MixedCurrencies.selector, members[1].toId()));

        t = _trade(q0, s, 1e20);
        t.legs[2].conversion = _hookless(memberQuotes[3], memberQuotes[2]);
        _expectTrade(
            t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidConversion.selector, t.legs[2].conversion.toId())
        );

        t = _trade(q0, s, 1e20);
        t.legs[3].conversion.hooks = IHooks(address(router));
        _expectTrade(
            t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidConversion.selector, t.legs[3].conversion.toId())
        );

        t = _trade(q0, s, 1e20);
        t.output = q0;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
        t = _trade(q0, s, 1e20);
        t.output = memberQuotes[2];
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
    }

    // ───────────────────────────── membership ─────────────────────────────

    /// Every leg's pool belongs to the trade's family and is named once: a pool of another family, a key with any field
    /// changed, the right pools under another family id and a pool named twice are refused.
    function test_membership() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e20);
        t.legs[0].key = feeKey;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.NotFamilyMember.selector, feeKey.toId()));

        t = _trade(q0, s, 1e20);
        t.legs[1].key.tickSpacing = 10;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.NotFamilyMember.selector, t.legs[1].key.toId()));

        t = _trade(q0, s, 1e20);
        t.familyId = feeFamily;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.NotFamilyMember.selector, members[0].toId()));

        t = _trade(q0, s, 1e20);
        t.legs[3] = t.legs[1];
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.DuplicatePool.selector, members[1].toId()));
    }

    /// The trade's shape: no leg, nine legs, a zero leg, a passed deadline and recipients that cannot receive are
    /// refused, and a sell with a converting leg pays only its caller.
    function test_shapeRefusals() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e20);
        t.legs = new IHookrFamilyRouter.Leg[](0);
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
        t = _trade(q0, s, 1e20);
        IHookrFamilyRouter.Leg[] memory nine = new IHookrFamilyRouter.Leg[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = t.legs[i % 4];
        }
        t.legs = nine;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
        t = _trade(q0, s, 1e20);
        t.legs[2].amountIn = 0;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
        t = _trade(q0, s, 1e20);
        t.deadline = vm.getBlockTimestamp() - 1;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
        address[4] memory unpayable = [address(0), address(fam), address(router), address(manager)];
        for (uint256 i; i < 4; ++i) {
            t = _trade(q0, s, 1e20);
            t.recipient = unpayable[i];
            _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
        }
        // A sell whose legs convert pays only the trader; one whose legs are all direct pays anyone.
        t = _trade(s, q0, 1e20);
        t.recipient = recipient;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InvalidTrade.selector));
        IHookrFamilyRouter.Leg[] memory direct = new IHookrFamilyRouter.Leg[](1);
        direct[0] = t.legs[1];
        t.legs = direct;
        uint256 before = ERC20(Currency.unwrap(q0)).balanceOf(recipient);
        (, uint256 out) = _send(t);
        assertEq(ERC20(Currency.unwrap(q0)).balanceOf(recipient) - before, out);
    }

    // ───────────────────────────── minimums and atomicity ─────────────────────────────

    /// A leg below its minimum reverts the trade: a direct leg in HookrRouter's own bound, a sell leg converting
    /// through a hookless pool at the family router's check; and the legs' total below minTotalOut reverts it.
    function test_minimums() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e20);
        uint256 snap = vm.snapshotState();
        (, uint256 total) = _send(t);
        vm.revertToState(snap);

        t.legs[1].minOut = type(uint128).max;
        _expectTrade(t, abi.encodeWithSelector(IHookrRouter.Slippage.selector));

        t = _trade(q0, s, 1e20);
        t.minTotalOut = total + 1;
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.TotalBelowMinimum.selector, total, total + 1));
        t.minTotalOut = total;
        _send(t);

        vm.revertToState(snap);
        t = _trade(s, q0, 1e20);
        snap = vm.snapshotState();
        vm.recordLogs();
        _send(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 legOut;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(fam) && logs[i].topics[0] == IHookrFamilyRouter.FamilyLeg.selector) {
                if (logs[i].topics[2] == PoolId.unwrap(members[2].toId())) {
                    (, legOut) = abi.decode(logs[i].data, (uint256, uint256));
                }
            }
        }
        vm.revertToState(snap);
        t.legs[2].minOut = uint128(legOut + 1);
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.LegBelowMinimum.selector, 2, legOut, legOut + 1));
        t.legs[2].minOut = uint128(legOut);
        _send(t);
    }

    /// A leg the pool cannot fill whole is refused: a member swap HookrRouter fills in part, and a conversion through a
    /// hookless pool that runs out of liquidity.
    function test_partialFillsAreRefused() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e20);
        t.legs[1].amountIn = 1e26;
        vm.prank(trader);
        vm.expectPartialRevert(IHookrFamilyRouter.LegPartiallyFilled.selector);
        fam.trade(t, "");

        t = _trade(q0, s, 1e20);
        t.legs[2].amountIn = 1e26;
        vm.prank(trader);
        vm.expectPartialRevert(IHookrFamilyRouter.LegPartiallyFilled.selector);
        fam.trade(t, "");
    }

    /// Atomic: a failing middle leg reverts the legs before it; no balance and no pool price moved.
    function test_aFailingMiddleLegRevertsTheEarlierLegs() public {
        Currency q0 = memberQuotes[1];
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, Currency.wrap(address(famSubject)), 1e20);
        t.legs[2].minOut = type(uint128).max;
        Books memory before = _books(recipient);
        uint160[4] memory prices;
        for (uint256 i; i < 4; ++i) {
            (prices[i],,,) = manager.getSlot0(members[i].toId());
        }
        _expectTrade(t, abi.encodeWithSelector(IHookrRouter.Slippage.selector));
        Books memory now_ = _books(recipient);
        for (uint256 k; k < 5; ++k) {
            assertEq(now_.traderHeld[k], before.traderHeld[k]);
            assertEq(now_.recipientHeld[k], before.recipientHeld[k]);
            assertEq(now_.router[k], before.router[k]);
        }
        for (uint256 i; i < 4; ++i) {
            (uint160 price,,,) = manager.getSlot0(members[i].toId());
            assertEq(price, prices[i], "no member's price moved");
        }
    }

    // ───────────────────────────── the input ─────────────────────────────

    /// A fee-on-transfer input is refused: the family router credits only what arrived and requires the legs' sum.
    function test_aFeeOnTransferInputIsRefused() public {
        MockFeeOnTransferToken taxed = new MockFeeOnTransferToken("Taxed", "TAX", 1e30, 0, address(0));
        Currency tx_ = Currency.wrap(address(taxed));
        taxed.transfer(address(lp), 1e27);
        _seed(_hookless(tx_, memberQuotes[1]));
        taxed.transfer(trader, 1e24);
        vm.prank(trader);
        taxed.approve(address(fam), type(uint256).max);
        IHookrFamilyRouter.FamilyTrade memory t;
        t.familyId = family;
        t.input = tx_;
        t.output = Currency.wrap(address(famSubject));
        t.legs = new IHookrFamilyRouter.Leg[](1);
        t.legs[0] = _leg(1, tx_, 1e20, 1);
        t.recipient = recipient;
        t.deadline = vm.getBlockTimestamp() + 1000;
        taxed.setFeeBps(100);
        _expectTrade(t, abi.encodeWithSelector(IHookrFamilyRouter.InputNotReceived.selector, 99e18, 1e20));
        taxed.setFeeBps(0);
        (, uint256 out) = _send(t);
        assertGt(out, 0, "the same token without its fee converts and buys");
    }

    /// Permit2's signature transfer: a permit for the input token covering the legs' sum pulls the input without an
    /// allowance to the family router; a permit for another token or a smaller amount, a permit with native input,
    /// and a permit's replay are refused.
    function test_permitSignatureTransfer() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        quotes[0].transfer(owner, 1e24);
        vm.prank(owner);
        quotes[0].approve(permit2, type(uint256).max);
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e20);
        uint256 deadline = vm.getBlockTimestamp() + 1000;
        bytes memory permit = _permit(address(quotes[0]), 4e20, 7, deadline);
        uint256 before = quotes[0].balanceOf(owner);
        vm.prank(owner);
        (uint256 amountIn,) = fam.trade(t, permit);
        assertEq(before - quotes[0].balanceOf(owner), amountIn);
        assertEq(quotes[0].allowance(owner, address(fam)), 0, "no allowance to the family router was needed");

        // Permit2 refuses the used nonce.
        vm.prank(owner);
        vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
        fam.trade(t, permit);

        // Each permit is signed before the expected revert is armed: signing reads Permit2's domain separator, which
        // would otherwise be the call the expectation catches.
        bytes memory otherToken = _permit(address(quotes[1]), 4e20, 8, deadline);
        vm.prank(owner);
        vm.expectRevert(IHookrFamilyRouter.InvalidPermit.selector);
        fam.trade(t, otherToken);
        bytes memory tooSmall = _permit(address(quotes[0]), 4e20 - 1, 9, deadline);
        vm.prank(owner);
        vm.expectRevert(IHookrFamilyRouter.InvalidPermit.selector);
        fam.trade(t, tooSmall);
        IHookrFamilyRouter.FamilyTrade memory native = _trade(ETH, s, 1e20);
        bytes memory withNative = _permit(address(quotes[0]), 4e20, 10, deadline);
        vm.deal(owner, 1e21);
        vm.prank(owner);
        vm.expectRevert(IHookrFamilyRouter.InvalidPermit.selector);
        fam.trade{value: 4e20}(native, withNative);
    }

    function _permit(address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        IPermit2Signature.PermitTransferFrom memory p = IPermit2Signature.PermitTransferFrom(
            IPermit2Signature.TokenPermissions(token, amount), nonce, deadline
        );
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount)),
                address(fam),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2Bench(permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(ownerPk, digest);
        return abi.encode(p, abi.encodePacked(r, sig, v));
    }

    // ───────────────────────────── the gate ─────────────────────────────

    /// A family router the root never admitted as its GATE is refused on every leg, so it is inert until its ADMIT
    /// executes.
    function test_anUnadmittedFamilyRouterIsRefused() public {
        HookrFamilyRouter other = new HookrFamilyRouter(router, IHookrLauncherView(address(launcher)), permit2);
        vm.prank(trader);
        quotes[0].approve(address(other), type(uint256).max);
        IHookrFamilyRouter.FamilyTrade memory t = _trade(memberQuotes[1], Currency.wrap(address(famSubject)), 1e20);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.GateNotAdmitted.selector, address(root), address(other)));
        other.trade(t, "");
    }

    /// The family router vouches only for its own swaps: HookrRouter asked for a swap someone else called (naming the
    /// family router as gate and any payer) is refused, and nobody but HookrRouter can ask it.
    function test_theGateVouchesOnlyForItsOwnSwaps() public {
        address attacker = address(0xBAD);
        quotes[0].transfer(attacker, 1e24);
        vm.startPrank(attacker);
        quotes[0].approve(address(router), type(uint256).max);
        bool zeroForOne = Currency.unwrap(members[1].currency0) == address(quotes[0]);
        IHookrRouter.Swap memory p = IHookrRouter.Swap(
            members[1], zeroForOne, -1e20, 1, zeroForOne ? MIN_PRICE : MAX_PRICE, attacker, vm.getBlockTimestamp()
        );
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.GateRefused.selector, address(fam)));
        router.swapGated(p, trader, address(fam), "", address(0), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.GateRefused.selector, address(fam)));
        router.swapGated(p, attacker, address(fam), "", address(0), new uint256[](0));
        vm.expectRevert(IHookrFamilyRouter.InvalidCallback.selector);
        fam.beforeUnlock(address(fam), attacker, members[1], true, -1e20, "");
        vm.stopPrank();
        vm.prank(address(router));
        vm.expectRevert(IHookrFamilyRouter.InvalidCallback.selector);
        fam.beforeUnlock(address(fam), trader, members[1], true, -1e20, "");
    }

    /// Every Hookr swap of a trade runs through HookrRouter.swapGated for the trader: the receipt payer is the trader,
    /// the funder is the family router, and the family router is the gate.
    function test_everyHookrSwapIsGatedForTheTrader() public {
        IHookrFamilyRouter.FamilyTrade memory t = _trade(memberQuotes[1], Currency.wrap(address(famSubject)), 1e20);
        vm.recordLogs();
        _send(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 gated;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != IHookrRouter.SwapGated.selector) continue;
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(trader))), "payer");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(fam)))), "gate");
            assertEq(abi.decode(logs[i].data, (address)), address(fam), "funder");
            ++gated;
        }
        assertEq(gated, 4, "one gated swap per member");
    }

    /// A conversion through a Hookr pool runs through HookrRouter.swapGated too: the Q0 to Q1 conversion takes a Hookr
    /// pool of another family (Q0 as subject, Q1 as quote), gated for the trader like the member swap after it.
    function test_aConversionThroughAHookrPool() public {
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](1);
        m[0] = _member(memberQuotes[2], 60, false);
        quotes[0].approve(address(launcher), type(uint256).max);
        (bytes32 otherFamily,) = launcher.launch(
            IHookrLauncher.Token(address(quotes[0]), "", "", 0, bytes32(0)), address(root), m, vm.getBlockTimestamp()
        );
        PoolKey memory conversion = launcher.position(otherFamily, 0).key;
        _nextBlock();
        IHookrFamilyRouter.FamilyTrade memory t;
        t.familyId = family;
        t.input = memberQuotes[1];
        t.output = Currency.wrap(address(famSubject));
        t.legs = new IHookrFamilyRouter.Leg[](1);
        t.legs[0].key = members[2];
        t.legs[0].conversion = conversion;
        t.legs[0].amountIn = 1e20;
        t.legs[0].minOut = 1;
        t.recipient = recipient;
        t.deadline = vm.getBlockTimestamp() + 1000;
        Books memory before = _books(recipient);
        vm.recordLogs();
        (uint256 amountIn, uint256 amountOut) = _send(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertConserved(before, t.input, t.output, recipient, amountIn, amountOut);
        uint256 gated;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IHookrRouter.SwapGated.selector) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(trader))));
                ++gated;
            }
        }
        assertEq(gated, 2, "the conversion and the member swap");
    }

    // ───────────────────────────── reentrancy ─────────────────────────────

    /// A hostile subject that calls back on every transfer finds every entry refused: the family router's trade and
    /// sweep (it is trading), its gate (only HookrRouter may ask), and HookrRouter's swap (it is swapping); the sell
    /// then completes and conserves.
    function test_reentryThroughAHostileSubjectIsRefused() public {
        HostileSubject hostile = new HostileSubject();
        hostile.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](2);
        m[0] = _member(memberQuotes[1], 60, false);
        m[1] = _member(memberQuotes[2], 60, false);
        (bytes32 hostileFamily,) = launcher.launch(
            IHookrLauncher.Token(address(hostile), "", "", 0, bytes32(0)), address(root), m, vm.getBlockTimestamp()
        );
        _nextBlock();
        hostile.transfer(trader, 1e24);
        vm.prank(trader);
        hostile.approve(address(fam), type(uint256).max);
        IHookrFamilyRouter.FamilyTrade memory t;
        t.familyId = hostileFamily;
        t.input = Currency.wrap(address(hostile));
        t.output = memberQuotes[1];
        t.legs = new IHookrFamilyRouter.Leg[](2);
        t.legs[0].key = launcher.position(hostileFamily, 0).key;
        t.legs[0].amountIn = 1e20;
        t.legs[0].minOut = 1;
        t.legs[1].key = launcher.position(hostileFamily, 1).key;
        t.legs[1].conversion = _hookless(memberQuotes[1], memberQuotes[2]);
        t.legs[1].amountIn = 1e20;
        t.legs[1].minOut = 1;
        t.recipient = trader;
        t.deadline = vm.getBlockTimestamp() + 1000;
        hostile.arm(fam, router);
        uint256 before = hostile.balanceOf(trader);
        (uint256 amountIn, uint256 amountOut) = _send(t);
        assertEq(before - hostile.balanceOf(trader), amountIn);
        assertGt(amountOut, 0);
        assertEq(hostile.balanceOf(address(fam)), 0);
        uint256 n = hostile.refusalCount();
        assertGt(n, 0);
        for (uint256 i; i < n; i += 4) {
            assertEq(hostile.refusals(i), IHookrFamilyRouter.Reentered.selector, "trade");
            assertEq(hostile.refusals(i + 1), IHookrFamilyRouter.Reentered.selector, "sweep");
            assertEq(hostile.refusals(i + 2), IHookrFamilyRouter.InvalidCallback.selector, "beforeUnlock");
            assertTrue(
                hostile.refusals(i + 3) == IHookrRouter.Reentered.selector
                    || hostile.refusals(i + 3) == IHookrRouter.InvalidSwap.selector,
                "router swap"
            );
        }
    }

    // ───────────────────────────── stray funds ─────────────────────────────

    /// The family router holds nothing between trades: a stray transfer is anyone's to sweep, never during a trade,
    /// and does not disturb a trade's conservation check.
    function test_strayFundsAndSweep() public {
        quotes[0].transfer(address(fam), 5);
        IHookrFamilyRouter.FamilyTrade memory t = _trade(memberQuotes[1], Currency.wrap(address(famSubject)), 1e20);
        _send(t);
        assertEq(quotes[0].balanceOf(address(fam)), 5, "the stray balance is left where it was");
        vm.expectRevert(IHookrFamilyRouter.InvalidTrade.selector);
        fam.sweep(memberQuotes[1], address(fam));
        vm.expectEmit(true, true, true, true, address(fam));
        emit IHookrFamilyRouter.Swept(memberQuotes[1], address(0xD00D), 5);
        assertEq(fam.sweep(memberQuotes[1], address(0xD00D)), 5);
        assertEq(quotes[0].balanceOf(address(0xD00D)), 5);
        vm.deal(address(this), 1e18);
        (bool ok,) = address(fam).call{value: 1}("");
        assertFalse(ok, "native arrives only during a trade");
    }

    // ───────────────────────────── a stale sync ─────────────────────────────

    /// A sync a stranger left earlier in the same transaction fails no leg of a family trade (SYS-01): each member swap
    /// runs through HookrRouter.unlockCallback, which clears it, and a conversion settles in this router's own unlock
    /// after syncing its own input. A buy split across a burning two-member family, one direct leg and one converting
    /// through a hookless pool, clears on both legs, burns and leaves the router empty. Left in place, the sync would
    /// make the root refuse the direct leg's Auto Burn take (UnsupportedBurnSync).
    function test_aStaleSyncFailsNoLegOfAFamilyTrade() public {
        HookrToken burning = new HookrToken("Burning", "BRN", 1e30, address(this));
        burning.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory m = new IHookrLauncher.Member[](2);
        m[0] = _member(memberQuotes[1], 60, true);
        m[1] = _member(memberQuotes[2], 60, true);
        (bytes32 burningFamily,) = launcher.launch(
            IHookrLauncher.Token(address(burning), "", "", 0, bytes32(0)), address(root), m, vm.getBlockTimestamp()
        );
        _nextBlock();
        IHookrFamilyRouter.FamilyTrade memory t;
        t.familyId = burningFamily;
        t.input = memberQuotes[1];
        t.output = Currency.wrap(address(burning));
        t.legs = new IHookrFamilyRouter.Leg[](2);
        t.legs[0].key = launcher.position(burningFamily, 0).key;
        t.legs[0].amountIn = 1e20;
        t.legs[0].minOut = 1;
        t.legs[1].key = launcher.position(burningFamily, 1).key;
        t.legs[1].conversion = _hookless(memberQuotes[1], memberQuotes[2]);
        t.legs[1].amountIn = 1e20;
        t.legs[1].minOut = 1;
        t.recipient = recipient;
        t.deadline = vm.getBlockTimestamp() + 1000;
        vm.prank(address(0xBAD5));
        manager.sync(Currency.wrap(address(burning)));
        uint256 deadBefore = burning.balanceOf(root.DEAD());
        (uint256 amountIn, uint256 amountOut) = _send(t);
        assertEq(amountIn, 2e20, "the trader paid both legs");
        assertEq(burning.balanceOf(recipient), amountOut, "both legs paid the recipient");
        assertGt(amountOut, 0);
        assertGt(burning.balanceOf(root.DEAD()), deadBefore, "with their burns");
        assertEq(burning.balanceOf(address(fam)), 0, "the router keeps nothing");
    }

    // ───────────────────────────── the Universal Router ─────────────────────────────

    /// The same split as one Universal Router 2.1.1 V4_SWAP (SWAP_EXACT_IN_SINGLE for the direct leg, a two-hop
    /// SWAP_EXACT_IN for each converting leg, SETTLE_ALL of the input and TAKE_ALL of the output with the total
    /// minimum) gives the same per-leg outputs for full fills, and a leg under its minimum reverts the whole Universal
    /// Router transaction.
    function test_theUniversalRouterPathGivesTheSamePerLegOutputs() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e21);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        (, uint256 total) = _send(t);
        uint256[4] memory famOuts = _memberOutputs(vm.getRecordedLogs(), s);
        vm.revertToState(snap);

        (bytes memory actions, bytes[] memory params) = _urSplit(t, total, [uint256(1), 1, 1, 1]);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 before = famSubject.balanceOf(trader);
        vm.recordLogs();
        vm.prank(trader, trader);
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        uint256[4] memory urOuts = _memberOutputs(vm.getRecordedLogs(), s);
        assertEq(famSubject.balanceOf(trader) - before, total, "the same total");
        for (uint256 i; i < 4; ++i) {
            assertEq(urOuts[i], famOuts[i], "the same output on every leg");
            console2.log("leg output, family router and Universal Router", famOuts[i], urOuts[i]);
        }
        vm.revertToState(snap);
        (actions, params) = _urSplit(t, total, [uint256(1), 1, famOuts[2] + 1, 1]);
        inputs[0] = abi.encode(actions, params);
        vm.prank(trader, trader);
        vm.expectRevert();
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
        assertEq(famSubject.balanceOf(trader), before, "the whole Universal Router transaction reverted");
    }

    function _urSplit(IHookrFamilyRouter.FamilyTrade memory t, uint256 minTotal, uint256[4] memory minimums)
        internal
        pure
        returns (bytes memory actions, bytes[] memory params)
    {
        params = new bytes[](t.legs.length + 2);
        for (uint256 i; i < t.legs.length; ++i) {
            IHookrFamilyRouter.Leg memory leg = t.legs[i];
            if (Currency.unwrap(leg.conversion.currency1) == address(0)) {
                bool zeroForOne = Currency.unwrap(leg.key.currency0) == Currency.unwrap(t.input);
                actions = abi.encodePacked(actions, uint8(0x06));
                params[i] =
                    abi.encode(ExactInputSingleParams(leg.key, zeroForOne, leg.amountIn, uint128(minimums[i]), 0, ""));
            } else {
                Currency quote = Currency.unwrap(leg.conversion.currency0) == Currency.unwrap(t.input)
                    ? leg.conversion.currency1
                    : leg.conversion.currency0;
                PathKey[] memory path = new PathKey[](2);
                path[0] = PathKey(quote, leg.conversion.fee, leg.conversion.tickSpacing, leg.conversion.hooks, "");
                path[1] = PathKey(t.output, leg.key.fee, leg.key.tickSpacing, leg.key.hooks, "");
                actions = abi.encodePacked(actions, uint8(0x07));
                params[i] =
                    abi.encode(ExactInputParams(t.input, path, new uint256[](0), leg.amountIn, uint128(minimums[i])));
            }
        }
        uint256 sum;
        for (uint256 i; i < t.legs.length; ++i) {
            sum += t.legs[i].amountIn;
        }
        actions = abi.encodePacked(actions, uint8(0x0c), uint8(0x0f));
        params[t.legs.length] = abi.encode(t.input, sum);
        params[t.legs.length + 1] = abi.encode(t.output, minTotal);
    }

    // ───────────────────────────── gas ─────────────────────────────

    /// Gas of a buy over one to four legs (one direct, the rest converting through hookless pools), next to the same
    /// legs as single router swaps.
    function test_gasPerLeg() public {
        Currency q0 = memberQuotes[1];
        Currency s = Currency.wrap(address(famSubject));
        uint8[4] memory order = [1, 0, 2, 3];
        uint256 previous;
        for (uint256 n = 1; n <= 4; ++n) {
            IHookrFamilyRouter.FamilyTrade memory t = _trade(q0, s, 1e20);
            IHookrFamilyRouter.Leg[] memory legs = new IHookrFamilyRouter.Leg[](n);
            for (uint256 i; i < n; ++i) {
                legs[i] = _leg(order[i], q0, 1e20, 1);
            }
            t.legs = legs;
            uint256 snap = vm.snapshotState();
            _send(t);
            uint256 gas = vm.lastCallGas().gasTotalUsed;
            vm.revertToState(snap);
            console2.log("family trade legs, gas, gas of the last leg", n, gas, gas - previous);
            previous = gas;
        }
    }
}
