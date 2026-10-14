// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

contract CatalogHookr is ERC20 {
    constructor(address to) ERC20("Hookr", "HOOKR") {
        _mint(to, 1e27);
    }
}

contract CatalogUsdg is ERC20 {
    constructor(address to) ERC20("Global Dollar", "USDG") {
        _mint(to, 1e15);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Launch front door that consults the registry's reviewed quote catalog before calling the Launcher, as the
///         app (and a Launcher-side check, which belongs to the Launcher lane) is expected to.
contract CatalogGate {
    error UnqualifiedQuote(address quote);

    IHookrRegistry internal immutable registry;

    constructor(IHookrRegistry registry_) {
        registry = registry_;
    }

    function check(IHookrLauncher.Member[] calldata members) external view {
        for (uint256 i; i < members.length; ++i) {
            address quote = Currency.unwrap(members[i].quote);
            if (!registry.isQuote(quote)) revert UnqualifiedQuote(quote);
        }
    }
}

/// @notice M-07 (on-chain registry side): nothing on chain named the reviewed quote assets, so any HookrToken-template
///         "USDG" looked as qualified as the catalog asset.
/// @dev Original exploit (base b7aeae64, ReproGovernance.testM07_FakeUsdgQuoteTakesRealSubject): a scammer's
///      HookrToken("Global Dollar","USDG") quoted a real-HOOKR family; the victim sold 1,000e18 HOOKR for
///      996.900609009281774607e18 fake USDG and the scammer withdrew 999.999999999999999998e18 real HOOKR.
///      The registry now keeps a timelocked quote catalog (`isQuote`, `quoteAssets`) that the app and the Launcher
///      can read. Launcher enforcement and the UI badge are owned by the Launcher and app lanes.
contract HookrRegistryQuoteCatalogTest is GovernanceSecurityBase {
    address internal scammer = address(0xBAD);

    function setUp() public {
        _setUpPeriphery();
        // Start from an empty catalog: the fixture lists its two tokens.
        registry.queue(registry.SET_QUOTE(), abi.encode(address(tokenA), false));
        registry.queue(registry.SET_QUOTE(), abi.encode(address(tokenB), false));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(address(tokenA), false);
        registry.setQuote(address(tokenB), false);
    }

    function _admitQuote(address asset) internal {
        registry.queue(registry.SET_QUOTE(), abi.encode(asset, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(asset, true);
    }

    function testFakeUsdgIsNotACatalogQuote() public {
        CatalogHookr realHookr = new CatalogHookr(address(this));
        CatalogUsdg realUsdg = new CatalogUsdg(address(this));
        _admitQuote(address(realUsdg));
        vm.prank(scammer);
        HookrToken fakeUsdg = new HookrToken("Global Dollar", "USDG", 1e30, scammer);
        // Same template runtime as every launch token, same symbol as the catalog asset.
        assertEq(address(fakeUsdg).codehash, address(tokenA).codehash);
        assertEq(fakeUsdg.symbol(), realUsdg.symbol());
        assertTrue(registry.isQuote(address(realUsdg)));
        assertTrue(registry.isQuote(address(0)));
        assertFalse(registry.isQuote(address(fakeUsdg)));
        address[] memory catalog = registry.quoteAssets();
        assertEq(catalog.length, 1);
        assertEq(catalog[0], address(realUsdg));

        // The original launch, routed through a front door that reads the catalog, loses its edge.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(fakeUsdg)));
        CatalogGate gate = new CatalogGate(registry);
        vm.expectRevert(abi.encodeWithSelector(CatalogGate.UnqualifiedQuote.selector, address(fakeUsdg)));
        gate.check(members);
        members[0] = _member(Currency.wrap(address(realUsdg)));
        gate.check(members);
        members[0] = _member(Currency.wrap(address(0)));
        gate.check(members);
        assertTrue(address(realHookr).code.length != 0);
    }

    function testCatalogChangesAreTimelockedAndPublished() public {
        CatalogUsdg realUsdg = new CatalogUsdg(address(this));
        bytes32 op = registry.operationHash(registry.SET_QUOTE(), abi.encode(address(realUsdg), true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setQuote(address(realUsdg), true);
        vm.prank(scammer);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.setQuote(address(realUsdg), true);
        bytes32 setQuote = registry.SET_QUOTE();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0x1234)));
        registry.queue(setQuote, abi.encode(address(0x1234), true));
        vm.expectRevert(IHookrRegistry.InvalidAddress.selector);
        registry.queue(setQuote, abi.encode(address(0), true));
        _admitQuote(address(realUsdg));
        assertTrue(registry.isQuote(address(realUsdg)));
    }

    function testCatalogRemovalKeepsTheListExact() public {
        address a = address(new CatalogUsdg(address(this)));
        address b = address(new CatalogUsdg(address(this)));
        address c = address(new CatalogUsdg(address(this)));
        registry.queue(registry.SET_QUOTE(), abi.encode(a, true));
        registry.queue(registry.SET_QUOTE(), abi.encode(b, true));
        registry.queue(registry.SET_QUOTE(), abi.encode(c, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(a, true);
        registry.setQuote(b, true);
        registry.setQuote(c, true);
        registry.queue(registry.SET_QUOTE(), abi.encode(a, false));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(a, false);
        address[] memory catalog = registry.quoteAssets();
        assertEq(catalog.length, 2);
        assertEq(catalog[0], c);
        assertEq(catalog[1], b);
        assertFalse(registry.isQuote(a));
        assertTrue(registry.isQuote(b) && registry.isQuote(c));
        // Re-adding and removing an absent asset are both harmless.
        registry.queue(registry.SET_QUOTE(), abi.encode(a, false));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setQuote(a, false);
        assertEq(registry.quoteAssets().length, 2);
    }
}
