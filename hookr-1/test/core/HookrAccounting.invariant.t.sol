// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";

uint160 constant MIN_LIMIT = 4295128740;
uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341;

/// @dev Curated router stand-in: reports the locker through msgSender() and settles the locker's exact deltas.
///      Inside the unlock it checks that the swap left no delta on the root or its Rules.
contract MockCuratedRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public root;
    address public rules;
    address private _locker;

    constructor(IPoolManager manager_) {
        poolManager = manager_;
    }

    function wire(address root_, address rules_) external {
        root = root_;
        rules = rules_;
    }

    function msgSender() external view returns (address) {
        return _locker;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount) external {
        _locker = msg.sender;
        poolManager.unlock(abi.encode(key, zeroForOne, amount));
        _locker = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "manager");
        (PoolKey memory key, bool zeroForOne, int256 amount) = abi.decode(data, (PoolKey, bool, int256));
        BalanceDelta d = poolManager.swap(key, SwapParams(zeroForOne, amount, zeroForOne ? MIN_LIMIT : MAX_LIMIT), "");
        require(poolManager.currencyDelta(root, key.currency0) == 0, "root delta0");
        require(poolManager.currencyDelta(root, key.currency1) == 0, "root delta1");
        require(poolManager.currencyDelta(rules, key.currency0) == 0, "rules delta0");
        require(poolManager.currencyDelta(rules, key.currency1) == 0, "rules delta1");
        require(poolManager.currencyDelta(address(this), key.currency0) == d.amount0(), "locker delta0");
        require(poolManager.currencyDelta(address(this), key.currency1) == d.amount1(), "locker delta1");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            poolManager.sync(c);
            HookrToken(Currency.unwrap(c)).transferFrom(_locker, address(poolManager), uint128(-amount));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(c, _locker, uint128(amount));
        }
    }
}

/// @dev Real swaps on three pools (ERC-20 quote with dynamic fees, native quote with dynamic fees, curated-root ERC-20 quote),
///      through the pinned router, a generic PoolManager caller and the curated router, plus partial fills,
///      backed claims and unrelated LP donations, all on one PoolManager.
contract AccountingHandler is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    error InvalidCallback();

    IPoolManager public immutable manager;
    HookrRouter public immutable router;
    MockCuratedRouter public immutable curated;
    HookrRules public immutable rules;
    HookrRules public immutable rules2;
    address public immutable root;
    Currency public immutable subject;
    Currency public immutable quote;
    PoolKey private _erc20;
    PoolKey private _native;
    PoolKey private _curatedKey;
    uint8 private _mode;
    uint256 public tradeCalls;
    uint256 public partialFills;
    uint256 public genericCalls;
    uint256 public curatedCalls;
    uint256 public claimCalls;
    uint256 public donationCalls;
    uint256 public deltaChecks;

    constructor(
        IPoolManager manager_,
        HookrRouter router_,
        MockCuratedRouter curated_,
        HookrRules rules_,
        HookrRules rules2_,
        PoolKey memory erc20_,
        PoolKey memory native_,
        PoolKey memory curatedKey_,
        Currency subject_,
        Currency quote_
    ) {
        manager = manager_;
        router = router_;
        curated = curated_;
        rules = rules_;
        rules2 = rules2_;
        root = address(erc20_.hooks);
        _erc20 = erc20_;
        _native = native_;
        _curatedKey = curatedKey_;
        subject = subject_;
        quote = quote_;
        HookrToken(Currency.unwrap(subject_)).approve(address(router_), type(uint256).max);
        HookrToken(Currency.unwrap(quote_)).approve(address(router_), type(uint256).max);
        HookrToken(Currency.unwrap(subject_)).approve(address(curated_), type(uint256).max);
        HookrToken(Currency.unwrap(quote_)).approve(address(curated_), type(uint256).max);
    }

    function _buyZeroForOne(PoolKey memory key, Currency q) private pure returns (bool) {
        return Currency.unwrap(key.currency0) == Currency.unwrap(q);
    }

    function trade(uint96 rawAmount, bool native, bool buy, bool exactInput, uint8 advance) external {
        uint128 amount = uint128(bound(rawAmount, 1e15, 1e19));
        vm.roll(vm.getBlockNumber() + bound(advance, 0, 2));
        PoolKey memory key = native ? _native : _erc20;
        Currency q = native ? CurrencyLibrary.ADDRESS_ZERO : quote;
        bool zeroForOne = buy == _buyZeroForOne(key, q);
        uint128 bound_ = exactInput ? uint128(1) : amount * 2;
        IHookrRouter.Swap memory params = IHookrRouter.Swap(
            key,
            zeroForOne,
            exactInput ? -int128(amount) : int128(amount),
            bound_,
            zeroForOne ? MIN_LIMIT : MAX_LIMIT,
            address(this),
            vm.getBlockTimestamp()
        );
        uint256 value = native && buy ? (exactInput ? amount : bound_) : 0;
        router.swap{value: value}(params, address(0), new uint256[](0));
        ++tradeCalls;
    }

    /// An authenticated exact-input buy that stops at a price limit 0.1% away leaves a backed refund claim.
    function partialBuy(uint96 rawAmount) external {
        uint128 amount = uint128(bound(rawAmount, 1e22, 5e22));
        bool zeroForOne = _buyZeroForOne(_erc20, quote);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolIdLibrary.toId(_erc20));
        uint160 limit = zeroForOne ? price - price / 1000 : price + price / 1000;
        uint256 before = rules.claimable(quote, address(this));
        router.swap(
            IHookrRouter.Swap(_erc20, zeroForOne, -int128(amount), 1, limit, address(this), vm.getBlockTimestamp()),
            address(0),
            new uint256[](0)
        );
        assertGt(rules.claimable(quote, address(this)), before, "partial fill credits a refund");
        ++partialFills;
    }

    /// An unauthenticated PoolManager caller: deltas are checked inside the unlock, right after the swap.
    function genericTrade(uint96 rawAmount, bool buy, bool exactInput) external {
        uint128 amount = uint128(bound(rawAmount, 1e15, 1e19));
        bool zeroForOne = buy == _buyZeroForOne(_erc20, quote);
        _mode = 1;
        manager.unlock(abi.encode(zeroForOne, exactInput ? -int256(uint256(amount)) : int256(uint256(amount))));
        _mode = 0;
        ++genericCalls;
    }

    function curatedTrade(uint96 rawAmount, bool buy, bool exactInput) external {
        uint128 amount = uint128(bound(rawAmount, 1e15, 1e19));
        bool zeroForOne = buy == _buyZeroForOne(_curatedKey, quote);
        curated.swap(_curatedKey, zeroForOne, exactInput ? -int256(uint256(amount)) : int256(uint256(amount)));
        ++curatedCalls;
    }

    function claim(uint8 which) external {
        which = uint8(bound(which, 0, 2));
        HookrRules r = which == 2 ? rules2 : rules;
        Currency c = which == 1 ? CurrencyLibrary.ADDRESS_ZERO : quote;
        if (r.claimable(c, address(this)) == 0) return;
        uint256 beforeBalance = c.balanceOf(address(this));
        uint256 amount = r.claim(c);
        assertEq(c.balanceOf(address(this)), beforeBalance + amount);
        ++claimCalls;
    }

    function donate(uint96 rawAmount) external {
        uint256 amount = bound(rawAmount, 1, 1e18);
        _mode = 2;
        manager.unlock(abi.encode(amount));
        _mode = 0;
        ++donationCalls;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || _mode == 0) revert InvalidCallback();
        if (_mode == 1) {
            (bool zeroForOne, int256 amount) = abi.decode(data, (bool, int256));
            BalanceDelta d =
                manager.swap(_erc20, SwapParams(zeroForOne, amount, zeroForOne ? MIN_LIMIT : MAX_LIMIT), "");
            // Non-vacuous: inside the unlock, the root and Rules hold no open delta and the caller owes exactly
            // the swap's delta.
            assertEq(manager.currencyDelta(root, subject), 0, "root subject delta");
            assertEq(manager.currencyDelta(root, quote), 0, "root quote delta");
            assertEq(manager.currencyDelta(address(rules), quote), 0, "rules quote delta");
            assertEq(manager.currencyDelta(address(this), _erc20.currency0), d.amount0(), "caller delta0");
            assertEq(manager.currencyDelta(address(this), _erc20.currency1), d.amount1(), "caller delta1");
            ++deltaChecks;
            _settle(_erc20.currency0, d.amount0());
            _settle(_erc20.currency1, d.amount1());
            return "";
        }
        uint256 donation = abi.decode(data, (uint256));
        manager.donate(
            _erc20, _erc20.currency0 == quote ? donation : 0, _erc20.currency1 == quote ? donation : 0, bytes("")
        );
        manager.sync(quote);
        quote.transfer(address(manager), donation);
        assertEq(manager.settle(), donation);
        return "";
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            manager.sync(c);
            c.transfer(address(manager), uint128(-amount));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, address(this), uint128(amount));
        }
    }

    receive() external payable {}
}

contract HookrAccountingInvariantTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    AccountingHandler private handler;
    MockCuratedRouter private curated;
    HookrRoot private root2;
    HookrRules private rules2;
    Currency private subjectCurrency;
    Currency private quoteCurrency;
    uint256 private initialQuote;
    uint256 private initialSubject;
    uint256 private initialNative;

    function _dynamicFee(Currency quote) private view returns (IHookrLauncher.Member memory m) {
        m = _member(quote);
        m.rules.maxFeePips = 100_000;
        m.rules.dynamicFeeSens = 5;
    }

    function _open(address rootAddr, IHookrLauncher.Member memory m) private returns (PoolKey memory) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (bytes32 family,) = launcher.launch{value: Currency.unwrap(m.quote) == address(0) ? 1e24 : 0}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), rootAddr, members, vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    function _curatedRoot() private {
        curated = new MockCuratedRouter(manager);
        bytes memory args = abi.encode(manager, registry, address(router), address(quoter), address(curated));
        bytes32 initHash = keccak256(abi.encodePacked(type(HookrRoot).creationCode, args));
        bytes32 salt;
        for (uint256 i = 3_000_000;; ++i) {
            if (uint160(vm.computeCreate2Address(bytes32(i), initHash, address(this))) & 0x3fff == 0x2acc) {
                salt = bytes32(i);
                break;
            }
        }
        root2 = new HookrRoot{salt: salt}(manager, registry, address(router), address(quoter), address(curated));
        rules2 = new HookrRules(manager, registry, protocol, address(root2), 0);
        curated.wire(address(root2), address(rules2));
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(root2), address(root2).codehash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(root2), address(root2).codehash);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(rules2),
            codeHash: address(rules2).codehash,
            schemaHash: rules2.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root2), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root2), a);
    }

    function setUp() public {
        _setUpPeriphery();
        _curatedRoot();
        subjectCurrency = Currency.wrap(address(tokenA));
        quoteCurrency = Currency.wrap(address(tokenB));
        PoolKey memory erc20 = _open(address(root), _dynamicFee(quoteCurrency));
        PoolKey memory native = _open(address(root), _dynamicFee(CurrencyLibrary.ADDRESS_ZERO));
        IHookrLauncher.Member memory c = _dynamicFee(quoteCurrency);
        c.config.rules = address(rules2);
        PoolKey memory curatedKey = _open(address(root2), c);
        handler = new AccountingHandler(
            manager, router, curated, rules, rules2, erc20, native, curatedKey, subjectCurrency, quoteCurrency
        );
        tokenA.transfer(address(handler), 1e25);
        tokenB.transfer(address(handler), 1e25);
        vm.deal(address(handler), 1e25);
        initialQuote = _quoteCash();
        initialSubject = _subjectCash();
        initialNative = _nativeCash();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = AccountingHandler.trade.selector;
        selectors[1] = AccountingHandler.partialBuy.selector;
        selectors[2] = AccountingHandler.genericTrade.selector;
        selectors[3] = AccountingHandler.curatedTrade.selector;
        selectors[4] = AccountingHandler.claim.selector;
        selectors[5] = AccountingHandler.donate.selector;
        selectors[6] = AccountingHandler.trade.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // Every fuzzed call comes from one account no invariant reads: on a fork, whose base fee is not zero, a call's
        // sender is left holding ETH for its gas, which would read as a balance of a checked contract.
        targetSender(address(uint160(uint256(keccak256("hookr.invariant.sender")))));
    }

    /// Every path runs and settles once, so the invariants below are never vacuous.
    function testEveryHandlerPathSettles() public {
        handler.trade(1e18, false, true, true, 0);
        handler.trade(1e18, false, true, false, 1);
        handler.trade(1e18, false, false, true, 0);
        handler.trade(1e18, false, false, false, 1);
        handler.trade(1e18, true, true, true, 0);
        handler.trade(1e18, true, true, false, 1);
        handler.trade(1e18, true, false, true, 0);
        handler.trade(1e18, true, false, false, 1);
        handler.partialBuy(2e22);
        handler.genericTrade(1e18, true, true);
        handler.genericTrade(1e18, true, false);
        handler.genericTrade(1e18, false, true);
        handler.genericTrade(1e18, false, false);
        handler.curatedTrade(1e18, true, true);
        handler.curatedTrade(1e18, false, false);
        handler.donate(1e18);
        handler.claim(0);
        handler.claim(1);
        handler.claim(2);
        assertEq(handler.deltaChecks(), 4);
        assertGt(rules.claimable(quoteCurrency, address(handler)) + handler.claimCalls(), 0);
        assertGt(rules.totalLiability(CurrencyLibrary.ADDRESS_ZERO), 0, "native pool paid fees");
        assertGt(rules2.totalLiability(quoteCurrency), 0, "curated pool paid fees");
        invariantEveryRuleLiabilityHasAnOwnedClaim();
        invariantCashConservedAcrossSwapsBurnsClaimsAndDonations();
        invariantNothingIsHeldOrLeftUnlocked();
    }

    function _accounted(HookrRules r, Currency c) private view returns (uint256) {
        return r.claimable(c, protocol) + r.claimable(c, royalty) + r.claimable(c, address(handler));
    }

    function invariantEveryRuleLiabilityHasAnOwnedClaim() public view {
        Currency native = CurrencyLibrary.ADDRESS_ZERO;
        assertEq(_accounted(rules, quoteCurrency), rules.totalLiability(quoteCurrency));
        assertEq(_accounted(rules, native), rules.totalLiability(native));
        assertEq(_accounted(rules2, quoteCurrency), rules2.totalLiability(quoteCurrency));
        assertEq(manager.balanceOf(address(rules), quoteCurrency.toId()), rules.totalLiability(quoteCurrency));
        assertEq(manager.balanceOf(address(rules), native.toId()), rules.totalLiability(native));
        assertEq(manager.balanceOf(address(rules2), quoteCurrency.toId()), rules2.totalLiability(quoteCurrency));
        assertEq(rules.totalLiability(subjectCurrency), 0);
        assertEq(manager.balanceOf(address(root), quoteCurrency.toId()), 0);
        assertEq(manager.balanceOf(address(root), native.toId()), 0);
        assertEq(manager.balanceOf(address(root2), quoteCurrency.toId()), 0);
    }

    function invariantCashConservedAcrossSwapsBurnsClaimsAndDonations() public view {
        assertEq(_quoteCash(), initialQuote);
        assertEq(_subjectCash(), initialSubject);
        assertEq(_nativeCash(), initialNative);
    }

    function invariantNothingIsHeldOrLeftUnlocked() public view {
        address[6] memory holders =
            [address(root), address(root2), address(rules), address(rules2), address(router), address(curated)];
        for (uint256 i; i < holders.length; ++i) {
            assertEq(quoteCurrency.balanceOf(holders[i]), 0);
            assertEq(subjectCurrency.balanceOf(holders[i]), 0);
            assertEq(holders[i].balance, 0);
        }
        assertFalse(manager.isUnlocked());
    }

    function _quoteCash() private view returns (uint256) {
        return quoteCurrency.balanceOf(address(handler)) + quoteCurrency.balanceOf(address(manager));
    }

    function _subjectCash() private view returns (uint256) {
        return subjectCurrency.balanceOf(address(handler)) + subjectCurrency.balanceOf(address(manager))
            + subjectCurrency.balanceOf(root.DEAD());
    }

    function _nativeCash() private view returns (uint256) {
        return address(handler).balance + address(manager).balance;
    }
}
