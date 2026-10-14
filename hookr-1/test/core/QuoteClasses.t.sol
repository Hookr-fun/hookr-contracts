// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @dev A stock-token implementation behind a beacon, shaped as Robinhood's Stock: balances live in the proxy, only
///      the issuer's minter mints, and `initialize` is open, so anyone can deploy and initialize a fresh proxy of the
///      beacon (the live `initialize(bytes32,string,string)` is an open `initializer` too).
contract QCStockImpl is ERC20 {
    address public immutable issuer;
    bool private _initialized;

    constructor(address issuer_) ERC20("", "") {
        issuer = issuer_;
    }

    function initialize() external {
        require(!_initialized, "initialized");
        _initialized = true;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == issuer, "issuer");
        _mint(to, amount);
    }
}

contract QCPlainToken is ERC20 {
    constructor(address to) ERC20("Plain", "PLN") {
        _mint(to, 1e30);
    }
}

contract QCMintableToken is ERC20 {
    constructor() ERC20("Mintable", "MNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A bridged-token proxy shaped as the bridge's ClonableBeaconProxy: its beacon, read from the deploying factory,
///      lives in the ERC-1967 beacon slot, so every instance has one runtime codehash whatever its beacon.
contract QCClonableProxy {
    bytes32 private constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    constructor() {
        address b = QCBeaconProxyFactory(msg.sender).beacon();
        assembly ("memory-safe") { sstore(BEACON_SLOT, b) }
    }

    fallback() external payable {
        address b;
        assembly ("memory-safe") { b := sload(BEACON_SLOT) }
        address impl = UpgradeableBeacon(b).implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @dev The bridge's beacon proxy factory: anyone may create a proxy, salted with the caller.
contract QCBeaconProxyFactory {
    address public immutable beacon;

    constructor(address beacon_) {
        beacon = beacon_;
    }

    function createProxy(bytes32 userSalt) external returns (address) {
        return address(new QCClonableProxy{salt: keccak256(abi.encode(msg.sender, userSalt))}());
    }

    function expected(address user, bytes32 userSalt) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(user, userSalt));
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(QCClonableProxy).creationCode))
        );
        return address(uint160(uint256(h)));
    }
}

contract QCBridgedImpl is ERC20 {
    address public l1Address;
    address public gateway;

    constructor() ERC20("Bridged", "BRG") {}

    function initialize(address l1, address gateway_) external {
        require(gateway == address(0), "initialized");
        (l1Address, gateway) = (l1, gateway_);
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == gateway, "gateway");
        _mint(to, amount);
    }
}

/// @dev The bridge's standard gateway: deploys each L1 token's L2 proxy at an address derived from the L1 token.
contract QCBridgeGateway {
    QCBeaconProxyFactory public immutable factory;

    constructor(QCBeaconProxyFactory factory_) {
        factory = factory_;
    }

    function beaconProxyFactory() external view returns (address) {
        return address(factory);
    }

    function calculateL2TokenAddress(address l1Token) public view returns (address) {
        return factory.expected(address(this), keccak256(abi.encode(l1Token)));
    }

    function deposit(address l1Token, address to, uint256 amount) external returns (address token) {
        token = calculateL2TokenAddress(l1Token);
        if (token.code.length == 0) {
            factory.createProxy(keccak256(abi.encode(l1Token)));
            QCBridgedImpl(token).initialize(l1Token, address(this));
        }
        QCBridgedImpl(token).mint(to, amount);
    }
}

/// @notice Quote classes (every contract with an admitted runtime codehash) and any-quote mode (any account holding
///         code other than an EIP-7702 delegation designator), both timelocked, each with an instant brake that only
///         stops new pools.
contract QuoteClassesTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SET_QUOTE_CLASS = keccak256("SET_QUOTE_CLASS");
    bytes32 internal constant ANY_QUOTE = keccak256("ANY_QUOTE");
    bytes32 internal constant REOPEN_QUOTE = keccak256("REOPEN_QUOTE");
    address internal guardianAccount = address(0x6A7D);
    address internal stranger = address(0x5757);
    address internal issuer = address(0x155E);

    UpgradeableBeacon internal beacon;
    address internal stockA;
    address internal stockB;
    address internal stockC;
    address internal otherBeaconStock;
    bytes32 internal stockHash;
    QCPlainToken internal plain;

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
        QCStockImpl impl = new QCStockImpl(issuer);
        beacon = new UpgradeableBeacon(address(impl), issuer);
        stockA = _stock(beacon);
        stockB = _stock(beacon);
        stockC = _stock(beacon);
        otherBeaconStock = _stock(new UpgradeableBeacon(address(impl), issuer));
        stockHash = stockA.codehash;
        plain = new QCPlainToken(address(this));
        plain.approve(address(launcher), type(uint256).max);
        plain.transfer(trader, 1e27);
        vm.prank(trader);
        plain.approve(address(router), type(uint256).max);
    }

    function _stock(UpgradeableBeacon b) internal returns (address proxy) {
        proxy = address(new BeaconProxy(address(b), abi.encodeCall(QCStockImpl.initialize, ())));
        vm.startPrank(issuer);
        QCStockImpl(proxy).mint(address(this), 1e30);
        QCStockImpl(proxy).mint(trader, 1e27);
        vm.stopPrank();
        ERC20(proxy).approve(address(launcher), type(uint256).max);
        vm.prank(trader);
        ERC20(proxy).approve(address(router), type(uint256).max);
    }

    function _admitClass(address witness) internal {
        registry.queue(SET_QUOTE_CLASS, abi.encode(witness.codehash, witness));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.installQuoteClass(witness.codehash, witness);
    }

    function _anyQuote() internal {
        registry.queue(ANY_QUOTE, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.authorizeAnyQuote();
    }

    /// @dev One tokenA member quoted in `quote`, funded on both sides.
    function _launchQuoted(address quote) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(quote));
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function launchQuotedExternal(address quote) external returns (PoolKey memory) {
        return _launchQuoted(quote);
    }

    function _expectUnqualified(address quote) internal {
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, quote));
        this.launchQuotedExternal(quote);
    }

    /// @dev A new-token family on `quote`: its pool key is fresh even where a tokenA pool on `quote` exists.
    function launchFreshExternal(address quote) external returns (bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(quote));
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(0), "Fresh", "FRS", 1e24, keccak256(abi.encode(quote, gasleft()))),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
    }

    function _expectUnqualifiedFresh(address quote) internal {
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, quote));
        this.launchFreshExternal(quote);
    }

    function _buy(PoolKey memory key) internal returns (uint256 amountOut) {
        IHookrRouter.Swap memory s = _swap(key, true, true, 1e18);
        vm.prank(trader);
        (, amountOut) = router.swap(s, address(0), new uint256[](0));
    }

    function _badge(address asset) internal view returns (IHookrRegistry.QuoteBadge) {
        return registry.badgeForQuote(asset);
    }

    // ───────────────────────────── quote classes ─────────────────────────────

    function test_class_beaconProxiesShareOneCodehashPerBeacon() public view {
        assertEq(stockB.codehash, stockHash);
        assertEq(stockC.codehash, stockHash);
        assertTrue(otherBeaconStock.codehash != stockHash, "the beacon is part of the runtime");
    }

    function test_class_admitsEveryProxyOfTheBeaconAndNothingElse() public {
        assertFalse(registry.isQuote(stockB));
        assertEq(uint8(_badge(stockB)), uint8(IHookrRegistry.QuoteBadge.NONE));
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockA));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectEmit(address(registry));
        emit IHookrRegistry.QuoteClassSet(stockHash, stockA, true);
        registry.installQuoteClass(stockHash, stockA);
        assertTrue(registry.isQuote(stockA) && registry.isQuote(stockB) && registry.isQuote(stockC));
        assertEq(uint8(_badge(stockB)), uint8(IHookrRegistry.QuoteBadge.CLASS));
        assertFalse(registry.isQuote(otherBeaconStock));
        assertFalse(registry.isQuote(address(plain)));
        // A proxy deployed after the admission qualifies too: the class is the code, not a list.
        address late = _stock(beacon);
        assertTrue(registry.isQuote(late));
        (bool anyQuote, uint48 stoppedAt, bytes32[] memory classes) = registry.openQuoteTerms();
        assertFalse(anyQuote);
        assertEq(stoppedAt, 0);
        assertEq(classes.length, 1);
        assertEq(classes[0], stockHash);
        // The catalog is untouched, and its assets and native ETH keep their badges.
        assertEq(registry.quoteAssets().length, 2);
        assertEq(uint8(_badge(address(tokenB))), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        assertEq(uint8(_badge(address(0))), uint8(IHookrRegistry.QuoteBadge.NATIVE));
    }

    /// @dev Anyone can deploy and initialize another proxy of the admitted beacon, or copy its runtime, but only the
    ///      issuer's minter can give it supply, and a class member must report a nonzero supply: the copy is no member
    ///      and never carries the CLASS badge. Once the issuer mints it, it joins the class like any other proxy.
    function test_class_aSpoofProxyOfTheBeaconHasNoSupplyAndIsNoMember() public {
        _admitClass(stockA);
        vm.prank(stranger);
        address spoof = address(new BeaconProxy(address(beacon), abi.encodeCall(QCStockImpl.initialize, ())));
        assertEq(spoof.codehash, stockHash);
        assertEq(ERC20(spoof).totalSupply(), 0);
        assertFalse(registry.isQuote(spoof));
        assertEq(uint8(_badge(spoof)), uint8(IHookrRegistry.QuoteBadge.NONE));
        vm.prank(stranger);
        vm.expectRevert(bytes("issuer"));
        QCStockImpl(spoof).mint(stranger, 1);
        // In any-quote mode it is a quote like any contract, badged UNREVIEWED.
        _anyQuote();
        assertEq(uint8(_badge(spoof)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        vm.prank(issuer);
        QCStockImpl(spoof).mint(address(this), 1);
        assertEq(uint8(_badge(spoof)), uint8(IHookrRegistry.QuoteBadge.CLASS));
    }

    /// @dev A class member's supply is read under a gas cap in scratch space: a reverting, short, oversized or
    ///      zero answer is no member, whatever the codehash.
    function test_class_memberSupplyReadFailsClosed() public {
        _admitClass(stockA);
        assertTrue(registry.isQuote(stockB));
        bytes memory totalSupply = abi.encodeWithSignature("totalSupply()");
        vm.mockCallRevert(stockB, totalSupply, "");
        assertFalse(registry.isQuote(stockB));
        vm.clearMockedCalls();
        vm.mockCall(stockB, totalSupply, abi.encodePacked(uint128(1)));
        assertFalse(registry.isQuote(stockB));
        vm.mockCall(stockB, totalSupply, abi.encode(uint256(1), uint256(1)));
        assertFalse(registry.isQuote(stockB));
        vm.mockCall(stockB, totalSupply, abi.encode(uint256(0)));
        assertFalse(registry.isQuote(stockB));
        assertEq(uint8(_badge(stockB)), uint8(IHookrRegistry.QuoteBadge.NONE));
        vm.mockCall(stockB, totalSupply, abi.encode(uint256(1)));
        assertTrue(registry.isQuote(stockB));
        vm.clearMockedCalls();
        assertTrue(registry.isQuote(stockB) && registry.isQuote(stockC));
    }

    function test_class_memberOpensAPoolThatTrades() public {
        _expectUnqualified(stockB);
        _admitClass(stockA);
        PoolKey memory key = _launchQuoted(stockB);
        assertTrue(root.knownPool(key.toId()));
        assertEq(Currency.unwrap(root.poolConfig(key.toId()).quote), stockB);
        assertGt(_buy(key), 0);
        assertGt(rules.claimable(Currency.wrap(stockB), protocol), 0, "the protocol claim accrues in the stock");
        assertTrue(rules.accountingInvariant(Currency.wrap(stockB)));
    }

    function test_class_queueChecks() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, stranger));
        registry.queue(SET_QUOTE_CLASS, abi.encode(bytes32(uint256(1)), stranger));
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", stockA));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.queue(SET_QUOTE_CLASS, abi.encode(delegated.codehash, delegated));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, stockA));
        registry.queue(SET_QUOTE_CLASS, abi.encode(address(plain).codehash, stockA));
        bytes memory padded = abi.encodePacked(abi.encode(stockHash, stockA), uint256(0));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, SET_QUOTE_CLASS));
        registry.queue(SET_QUOTE_CLASS, padded);
        // The bridged-class encoding (gateway and beacon pins) is gone: it is refused as non-canonical.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, SET_QUOTE_CLASS));
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockA, address(0), address(0)));
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockA));
        // Not queued: nothing executes.
        vm.expectRevert();
        registry.installQuoteClass(stockHash, stockA);
        _admitClass(stockA);
        // Admitted: no second admission can be queued, by any witness.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QuoteClassActive.selector, stockHash));
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockB));
    }

    function test_class_onlyTheOwnerExecutes() public {
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockA));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.installQuoteClass(stockHash, stockA);
        // The witness's code is checked again at execution.
        bytes memory original = stockA.code;
        vm.etch(stockA, address(plain).code);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, stockA));
        registry.installQuoteClass(stockHash, stockA);
        vm.etch(stockA, original);
        registry.installQuoteClass(stockHash, stockA);
        assertTrue(registry.isQuote(stockC));
    }

    function test_class_brakeStopsNewPoolsOnly() public {
        _admitClass(stockA);
        PoolKey memory before = _launchQuoted(stockB);
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.dropWholeQuoteClass(stockHash);
        vm.expectEmit(address(registry));
        emit IHookrRegistry.QuoteClassSet(stockHash, address(0), false);
        vm.expectEmit(address(registry));
        emit IHookrRegistry.QuoteClassDropped(stockHash, guardianAccount);
        vm.prank(guardianAccount);
        registry.dropWholeQuoteClass(stockHash);
        assertFalse(registry.isQuote(stockB) || registry.isQuote(stockC) || registry.isQuote(stockA));
        assertEq(uint8(_badge(stockA)), uint8(IHookrRegistry.QuoteBadge.NONE));
        (,, bytes32[] memory classes) = registry.openQuoteTerms();
        assertEq(classes.length, 0);
        _expectUnqualified(stockC);
        // The pool opened before the brake keeps trading.
        assertGt(_buy(before), 0);
    }

    function test_class_brakeRemovesOneOfSeveral() public {
        _admitClass(stockA);
        _admitClass(otherBeaconStock);
        _admitClass(address(plain));
        vm.prank(guardianAccount);
        registry.dropWholeQuoteClass(stockHash);
        (,, bytes32[] memory classes) = registry.openQuoteTerms();
        assertEq(classes.length, 2);
        assertTrue(registry.isQuote(otherBeaconStock) && registry.isQuote(address(plain)));
        assertFalse(registry.isQuote(stockB));
        // Dropping the last one leaves the list consistent.
        vm.prank(guardianAccount);
        registry.dropWholeQuoteClass(address(plain).codehash);
        (,, classes) = registry.openQuoteTerms();
        assertEq(classes.length, 1);
        assertEq(classes[0], otherBeaconStock.codehash);
    }

    function test_class_admissionQueuedBeforeTheBrakeCannotLiftIt() public {
        // Queued while the class is off, then pre-empted by a brake.
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockA));
        bytes32 early = registry.operationHash(SET_QUOTE_CLASS, abi.encode(stockHash, stockA));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.dropWholeQuoteClass(stockHash);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, early));
        registry.installQuoteClass(stockHash, stockA);
        // A second witness queued in the brake's own second is refused too.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.dropWholeQuoteClass(stockHash);
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockB));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRegistry.QueuedBeforeBrake.selector,
                registry.operationHash(SET_QUOTE_CLASS, abi.encode(stockHash, stockB))
            )
        );
        registry.installQuoteClass(stockHash, stockB);
        // Queued after the brake, it waits the full delay and then executes.
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.queue(SET_QUOTE_CLASS, abi.encode(stockHash, stockC));
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
        vm.expectRevert();
        registry.installQuoteClass(stockHash, stockC);
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.installQuoteClass(stockHash, stockC);
        assertTrue(registry.isQuote(stockA));
    }

    function test_class_catalogEntryOutlivesAClassBrake() public {
        _catalogQuote(stockB);
        _admitClass(stockA);
        vm.prank(guardianAccount);
        registry.dropWholeQuoteClass(stockHash);
        assertTrue(registry.isQuote(stockB));
        assertEq(uint8(_badge(stockB)), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        assertFalse(registry.isQuote(stockC));
    }

    function test_class_templateTokensShareACodehash() public {
        // Why a class must never be a permissionless template: every Launcher token shares one runtime, so its
        // codehash as a class would admit any copy a scammer launches.
        HookrToken copy = new HookrToken("Global Dollar", "USDG", 1e30, stranger);
        assertEq(address(copy).codehash, address(tokenA).codehash);
    }

    // ───────────────────────────── any-quote mode ─────────────────────────────

    function test_any_offByDefault() public {
        assertFalse(registry.isQuote(address(plain)));
        assertEq(uint8(_badge(address(plain))), uint8(IHookrRegistry.QuoteBadge.NONE));
        _expectUnqualified(address(plain));
    }

    function test_any_anyContractQualifiesAndIsBadgedUnreviewed() public {
        registry.queue(ANY_QUOTE, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectEmit(address(registry));
        emit IHookrRegistry.AnyQuoteSet(true, address(this));
        registry.authorizeAnyQuote();
        (bool anyQuote,,) = registry.openQuoteTerms();
        assertTrue(anyQuote);
        assertTrue(registry.isQuote(address(plain)));
        assertEq(uint8(_badge(address(plain))), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        assertTrue(registry.isQuote(otherBeaconStock));
        assertTrue(registry.isQuote(address(0)));
        assertEq(uint8(_badge(address(tokenB))), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        // No code, a delegation designator and any other 0xEF code are refused.
        assertFalse(registry.isQuote(stranger));
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(plain)));
        assertFalse(registry.isQuote(delegated));
        assertEq(uint8(_badge(delegated)), uint8(IHookrRegistry.QuoteBadge.NONE));
        vm.etch(delegated, hex"ef");
        assertFalse(registry.isQuote(delegated));
        PoolKey memory key = _launchQuoted(address(plain));
        assertTrue(root.knownPool(key.toId()));
        assertGt(_buy(key), 0);
    }

    function test_any_classMemberKeepsItsClassBadge() public {
        _admitClass(stockA);
        _anyQuote();
        assertEq(uint8(_badge(stockB)), uint8(IHookrRegistry.QuoteBadge.CLASS));
        // Dropped from its class while any-quote mode is on, a member stays a quote but loses the review.
        vm.prank(guardianAccount);
        registry.dropWholeQuoteClass(stockHash);
        assertTrue(registry.isQuote(stockB));
        assertEq(uint8(_badge(stockB)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
    }

    function test_any_queueChecks() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, ANY_QUOTE));
        registry.queue(ANY_QUOTE, hex"00");
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(ANY_QUOTE, "");
        vm.expectRevert();
        registry.authorizeAnyQuote();
        _anyQuote();
        vm.expectRevert(IHookrRegistry.AnyQuoteActive.selector);
        registry.queue(ANY_QUOTE, "");
    }

    function test_any_brakeStopsNewPoolsOnly() public {
        _anyQuote();
        PoolKey memory before = _launchQuoted(address(plain));
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.dismissAnyQuoteNow();
        vm.expectEmit(address(registry));
        emit IHookrRegistry.AnyQuoteSet(false, guardianAccount);
        vm.prank(guardianAccount);
        registry.dismissAnyQuoteNow();
        (bool anyQuote, uint48 stoppedAt,) = registry.openQuoteTerms();
        assertFalse(anyQuote);
        assertEq(stoppedAt, vm.getBlockTimestamp());
        assertFalse(registry.isQuote(address(plain)));
        assertTrue(registry.isQuote(address(tokenB)), "the catalog still qualifies");
        QCPlainToken other = new QCPlainToken(address(this));
        other.approve(address(launcher), type(uint256).max);
        _expectUnqualified(address(other));
        assertGt(_buy(before), 0);
    }

    function test_any_switchOnQueuedBeforeTheBrakeCannotLiftIt() public {
        registry.queue(ANY_QUOTE, "");
        bytes32 op = registry.operationHash(ANY_QUOTE, "");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.dismissAnyQuoteNow();
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, op));
        registry.authorizeAnyQuote();
        // The stale switch-on is cancelled and queued again after the brake: a full delay, then it opens.
        registry.cancel(op);
        registry.queue(ANY_QUOTE, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.authorizeAnyQuote();
        registry.authorizeAnyQuote();
        assertTrue(registry.isQuote(address(plain)));
    }

    function test_any_catalogRemovalLeavesAnUnreviewedQuote() public {
        _anyQuote();
        registry.queue(registry.SET_QUOTE(), abi.encode(address(tokenB), false));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(address(tokenB), false);
        assertTrue(registry.isQuote(address(tokenB)));
        assertEq(uint8(_badge(address(tokenB))), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
    }

    /// @dev `isQuote` and `badgeForQuote` agree for any account, code and mode.
    function testFuzz_badgeMatchesIsQuote(address asset, bytes memory code, bool any, bool klass, bool braked) public {
        vm.assume(asset.code.length == 0 && uint160(asset) > 0x100_000 && asset != address(this));
        vm.assume(code.length < 64);
        // The EVM holds 0xEF-prefixed code only as an EIP-7702 delegation designator.
        if (code.length != 0 && code[0] == 0xef) code = abi.encodePacked(hex"ef0100", address(plain));
        if (code.length != 0) vm.etch(asset, code);
        bool own = code.length != 0 && code[0] != 0xef;
        if (klass && own) _admitClass(asset);
        if (any) _anyQuote();
        if (braked) {
            vm.prank(guardianAccount);
            registry.brakeOneQuoteInstantly(asset);
        }
        bool supplied;
        if (own) {
            (bool ok, bytes memory ret) = asset.staticcall{gas: 50_000}(abi.encodeWithSignature("totalSupply()"));
            supplied = ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0;
        }
        bool expected = !braked && own && (any || (klass && supplied));
        assertEq(registry.isQuote(asset), expected);
        assertEq(registry.badgeForQuote(asset) != IHookrRegistry.QuoteBadge.NONE, expected);
    }

    // ───────────────────────────── bridged tokens ─────────────────────────────

    struct Bridge {
        UpgradeableBeacon beacon;
        QCBridgeGateway gateway;
        address usdc;
        address usdt;
        bytes32 codeHash;
    }

    function _bridge() internal returns (Bridge memory b) {
        b.beacon = new UpgradeableBeacon(address(new QCBridgedImpl()), issuer);
        b.gateway = new QCBridgeGateway(new QCBeaconProxyFactory(address(b.beacon)));
        b.usdc = _bridged(b.gateway, address(0xA0b8));
        b.usdt = _bridged(b.gateway, address(0xdAC1));
        b.codeHash = b.usdc.codehash;
    }

    function _bridged(QCBridgeGateway gateway, address l1) internal returns (address token) {
        token = gateway.deposit(l1, address(this), 1e30);
        gateway.deposit(l1, trader, 1e27);
        ERC20(token).approve(address(launcher), type(uint256).max);
        vm.prank(trader);
        ERC20(token).approve(address(router), type(uint256).max);
    }

    /// @dev The bridge's gateway deploys a token, with the one shared runtime and beacon, for any L1 token anyone
    ///      deposits, with any supply: a permissionless template. The reviewed bridged tokens are catalog entries by
    ///      address; every other bridged token is an any-quote mode quote, badged UNREVIEWED, and
    ///      `dismissAnyQuoteNow` stops it while the reviewed ones stay.
    function test_bridged_reviewedByAddressAndLookAlikesStopWithOpenQuotes() public {
        Bridge memory b = _bridge();
        _catalogQuote(b.usdc);
        _catalogQuote(b.usdt);
        // Anyone bridges a look-alike through the same gateway: the same runtime, beacon and gateway derivation.
        vm.prank(stranger);
        address fake = b.gateway.deposit(address(0xFA4E), address(this), 1e30);
        ERC20(fake).approve(address(launcher), type(uint256).max);
        assertEq(fake.codehash, b.codeHash);
        assertEq(b.gateway.calculateL2TokenAddress(QCBridgedImpl(fake).l1Address()), fake);
        assertFalse(registry.isQuote(fake));
        assertEq(uint8(_badge(fake)), uint8(IHookrRegistry.QuoteBadge.NONE));
        _anyQuote();
        assertTrue(registry.isQuote(fake));
        assertEq(uint8(_badge(fake)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        assertEq(uint8(_badge(b.usdc)), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        // A token bridged later, in no catalog, trades through any-quote mode as it does live.
        address late = _bridged(b.gateway, address(0x2260));
        PoolKey memory key = _launchQuoted(late);
        assertGt(_buy(key), 0);
        assertTrue(rules.accountingInvariant(Currency.wrap(late)));
        vm.prank(guardianAccount);
        registry.dismissAnyQuoteNow();
        assertFalse(registry.isQuote(fake) || registry.isQuote(late));
        assertEq(uint8(_badge(fake)), uint8(IHookrRegistry.QuoteBadge.NONE));
        _expectUnqualifiedFresh(fake);
        assertTrue(registry.isQuote(b.usdc) && registry.isQuote(b.usdt));
        assertEq(uint8(_badge(b.usdt)), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        assertGt(_buy(key), 0, "a pool opened before the brake keeps trading");
        (,, bytes32[] memory classes) = registry.openQuoteTerms();
        assertEq(classes.length, 0);
    }

    // ───────────────────────────── per-asset brake ─────────────────────────────

    function test_brake_catalogAssetLeavesAtOnceAndOldPoolsTrade() public {
        PoolKey memory before = _launchQuoted(address(tokenB));
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.brakeOneQuoteInstantly(address(tokenB));
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidAddress.selector);
        registry.brakeOneQuoteInstantly(address(0));
        vm.expectEmit(address(registry));
        emit IHookrRegistry.QuoteSet(address(tokenB), false);
        vm.expectEmit(address(registry));
        emit IHookrRegistry.QuoteBraked(address(tokenB), true, guardianAccount);
        vm.prank(guardianAccount);
        registry.brakeOneQuoteInstantly(address(tokenB));
        assertFalse(registry.isQuote(address(tokenB)));
        assertEq(uint8(_badge(address(tokenB))), uint8(IHookrRegistry.QuoteBadge.NONE));
        assertEq(registry.quoteAssets().length, 1);
        (bool braked, uint48 brakedAt) = registry.quoteIsBraked(address(tokenB));
        assertTrue(braked);
        assertEq(brakedAt, vm.getBlockTimestamp());
        _expectUnqualifiedFresh(address(tokenB));
        assertGt(_buy(before), 0);
        // Any-quote mode does not bring it back either.
        _anyQuote();
        assertFalse(registry.isQuote(address(tokenB)));
        assertTrue(registry.isQuote(address(plain)));
    }

    function test_brake_overridesClassAndAnyQuoteForOneAssetOnly() public {
        _admitClass(stockA);
        _anyQuote();
        PoolKey memory before = _launchQuoted(stockB);
        vm.startPrank(guardianAccount);
        registry.brakeOneQuoteInstantly(stockB);
        registry.brakeOneQuoteInstantly(address(plain));
        vm.stopPrank();
        assertFalse(registry.isQuote(stockB) || registry.isQuote(address(plain)));
        assertTrue(registry.isQuote(stockC) && registry.isQuote(stockA) && registry.isQuote(otherBeaconStock));
        assertEq(uint8(_badge(stockB)), uint8(IHookrRegistry.QuoteBadge.NONE));
        _expectUnqualifiedFresh(stockB);
        _expectUnqualified(address(plain));
        assertGt(_buy(_launchQuoted(stockC)), 0);
        assertGt(_buy(before), 0, "a pool opened before the brake keeps trading");
    }

    function test_brake_liftIsTimelockedAndQueuedAfterTheBrake() public {
        _anyQuote();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QuoteNotBraked.selector, address(plain)));
        registry.queue(REOPEN_QUOTE, abi.encode(address(plain)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QuoteNotBraked.selector, address(plain)));
        registry.reopenSingleQuote(address(plain));
        vm.prank(guardianAccount);
        registry.brakeOneQuoteInstantly(address(plain));
        registry.queue(REOPEN_QUOTE, abi.encode(address(plain)));
        bytes32 op = registry.operationHash(REOPEN_QUOTE, abi.encode(address(plain)));
        // Braked again while the lift waits: the lift is stale.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.brakeOneQuoteInstantly(address(plain));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, op));
        registry.reopenSingleQuote(address(plain));
        registry.cancel(op);
        registry.queue(REOPEN_QUOTE, abi.encode(address(plain)));
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.reopenSingleQuote(address(plain));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.reopenSingleQuote(address(plain));
        vm.expectEmit(address(registry));
        emit IHookrRegistry.QuoteBraked(address(plain), false, address(this));
        registry.reopenSingleQuote(address(plain));
        assertTrue(registry.isQuote(address(plain)));
        (bool braked,) = registry.quoteIsBraked(address(plain));
        assertFalse(braked);
    }

    function test_brake_catalogReAdditionMustBeQueuedAfterTheBrake() public {
        bytes memory add = abi.encode(address(tokenB), true);
        // An addition queued (here while the asset is still listed) before the brake cannot undo it.
        registry.queue(registry.SET_QUOTE(), add);
        bytes32 op = registry.operationHash(registry.SET_QUOTE(), add);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.brakeOneQuoteInstantly(address(tokenB));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, op));
        registry.setQuote(address(tokenB), true);
        registry.cancel(op);
        registry.queue(registry.SET_QUOTE(), add);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(address(tokenB), true);
        assertTrue(registry.isQuote(address(tokenB)));
        assertEq(uint8(_badge(address(tokenB))), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        (bool braked, uint48 brakedAt) = registry.quoteIsBraked(address(tokenB));
        assertFalse(braked);
        assertGt(brakedAt, 0);
    }

    // ───────────────────────────── EIP-7702 accounts ─────────────────────────────

    /// @dev An EIP-7702 delegated account holds a 23-byte designator, so it has code, but its key holder can re-point
    ///      it at any time: the root refuses it as a subject, and no quote path admits it.
    function test_7702_delegatedAccountIsNeitherSubjectNorQuote() public {
        address delegated = address(0x7702);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(new QCMintableToken())));
        assertEq(delegated.code.length, 23);
        QCMintableToken(delegated).mint(address(this), 1e30);
        ERC20(delegated).approve(address(launcher), type(uint256).max);
        // As the subject of an existing-token family on ETH.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        uint256 budget = members[0].amount0Max;
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        launcher.launch{value: budget}(
            IHookrLauncher.Token(delegated, "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        // The same code deployed as a contract is a subject.
        QCMintableToken real = new QCMintableToken();
        real.mint(address(this), 1e30);
        real.approve(address(launcher), type(uint256).max);
        (bytes32 family,) = launcher.launch{value: budget}(
            IHookrLauncher.Token(address(real), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        assertTrue(root.knownPool(launcher.position(family, 0).key.toId()));
        // As a quote: the catalog, a class and open quotes all refuse it.
        bytes32 setQuoteKind = registry.SET_QUOTE();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.queue(setQuoteKind, abi.encode(delegated, true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.queue(SET_QUOTE_CLASS, abi.encode(delegated.codehash, delegated));
        _anyQuote();
        assertFalse(registry.isQuote(delegated));
        _expectUnqualified(delegated);
    }

    // ───────────────────────────── dispatch ─────────────────────────────

    /// @dev Every new quote selector sorts after every registry read on a launch, swap or pair-root deployment,
    ///      including the recapture lane's `executorLane` (every swap of a lane pool) and `activeLaneOf` (a lane pool's
    ///      initialization), so the linear dispatcher reaches those reads as before, here and after the lanes merge.
    function test_dispatch_quoteSelectorsSortAfterEveryOnChainRegistryCall() public pure {
        bytes4[9] memory hot = [
            HookrRegistry.isRoot.selector,
            HookrRegistry.admission.selector,
            HookrRegistry.isQuote.selector,
            HookrRegistry.rootOpen.selector,
            HookrRegistry.isLauncher.selector,
            HookrRegistry.rootFactoryOf.selector,
            HookrRegistry.registerFactoryRoot.selector,
            HookrRegistry.activeLaneOf.selector,
            bytes4(keccak256("executorLane(address,address)"))
        ];
        bytes4[9] memory added = [
            HookrRegistry.badgeForQuote.selector,
            HookrRegistry.openQuoteTerms.selector,
            HookrRegistry.quoteIsBraked.selector,
            HookrRegistry.brakeOneQuoteInstantly.selector,
            HookrRegistry.reopenSingleQuote.selector,
            HookrRegistry.installQuoteClass.selector,
            HookrRegistry.dropWholeQuoteClass.selector,
            HookrRegistry.authorizeAnyQuote.selector,
            HookrRegistry.dismissAnyQuoteNow.selector
        ];
        for (uint256 i; i < hot.length; ++i) {
            for (uint256 j; j < added.length; ++j) {
                assertLt(uint32(hot[i]), uint32(added[j]));
            }
        }
    }
}
