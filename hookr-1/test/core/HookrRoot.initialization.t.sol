// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";
import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// Root initialization hardening. This test contract is a second admitted launcher on the fixture root.
/// Audit findings F-007, F-016, F-025 and F-030.
contract RootInitializationTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;

    address internal creator = address(0xC0FFEE);
    address internal scammer = address(0xBAD);
    Currency internal constant NATIVE = Currency.wrap(address(0));

    function setUp() public {
        _setUpRootSecurity();
        vm.deal(creator, 1e25);
    }

    function _predicted() internal view returns (address) {
        return launcher.predictToken(creator, IHookrLauncher.Token(address(0), "Creator", "CRC", 1e27, bytes32("s")));
    }

    function _keyOf(Currency a, Currency b, int24 spacing) internal view returns (PoolKey memory) {
        bool aFirst = Currency.unwrap(a) < Currency.unwrap(b);
        return PoolKey(aFirst ? a : b, aFirst ? b : a, 0x800000, spacing, IHooks(address(root)));
    }

    // ------------------------------------------------------------------------------------------ F-007

    /// F-007: a second admitted launcher initialized a not-yet-deployed token's canonical key for a few wei, and the
    /// creator's launch then reverted PoolExists.
    function testCodelessSubjectCannotBeSquatted() public {
        address predicted = _predicted();
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        pc.subject = Currency.wrap(predicted);
        pc.quote = NATIVE;
        PoolKey memory key = _keyOf(pc.subject, NATIVE, 60);
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        root.initializePool(key, pc, abi.encode(_rulesConfig()), bytes(""), SQRT_ONE);
        // The creator's own launch of that token still opens the canonical key.
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(NATIVE);
        vm.prank(creator);
        (, address subject) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(0), "Creator", "CRC", 1e27, bytes32("s")),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        assertEq(subject, predicted);
        assertTrue(root.knownPool(key.toId()));
    }

    /// F-007, role-inverted: an existing subject against the codeless predicted token as quote.
    function testCodelessQuoteCannotBeSquatted() public {
        address predicted = _predicted();
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        pc.quote = Currency.wrap(predicted);
        PoolKey memory key = _keyOf(pc.subject, pc.quote, 60);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, predicted));
        root.initializePool(key, pc, abi.encode(_rulesConfig()), bytes(""), SQRT_ONE);
    }

    // ------------------------------------------------------------------------------------------ F-030

    /// F-030: nothing on chain read the quote catalog, so a HookrToken-template "USDG" quoted a real subject.
    function testUncataloguedQuoteRefusedOnChain() public {
        vm.prank(scammer);
        HookrToken fakeUsdg = new HookrToken("Global Dollar", "USDG", 1e30, address(this));
        fakeUsdg.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(fakeUsdg)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, address(fakeUsdg)));
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        // Every launcher inherits the check, not only HookrLauncher.
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        pc.quote = Currency.wrap(address(fakeUsdg));
        PoolKey memory key = _keyOf(pc.subject, pc.quote, 60);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, address(fakeUsdg)));
        root.initializePool(key, pc, abi.encode(_rulesConfig()), bytes(""), SQRT_ONE);
        // Once reviewed into the catalog, the same quote opens; native is always a quote.
        _catalogQuote(address(fakeUsdg));
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        members[0] = _member(NATIVE);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    // ------------------------------------------------------------------------------------------ F-025

    /// F-025: LP exits trusted whatever removal lock Rules returned on every removal. The lock is now read once at
    /// initialization and bounded to 100,000 blocks.
    function testRemovalLockIsBoundedToTheGuardWindow() public {
        mock.setLock(type(uint256).max, false);
        uint256 opened = vm.getBlockNumber();
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        vm.roll(opened + 100_000 - 1);
        vm.expectRevert();
        _addLiquidity(key, -600, 600, -1e22);
        vm.roll(opened + 100_000);
        _addLiquidity(key, -600, 600, -1e22);
    }

    // ------------------------------------------------------------------------------------------ F-016

    function _admitAdvice(FixedAdvice a, uint24 lpCap, uint24 quoteCap) internal {
        IHookrRegistry.Admission memory ad = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(a),
            codeHash: address(a).codehash,
            schemaHash: a.configSchemaHash(),
            caps: HookrTypes.Caps(lpCap, quoteCap, 0),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), ad));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), ad);
    }

    function _advised(FixedAdvice a, HookrTypes.Caps memory caps, int24 spacing)
        internal
        returns (HookrTypes.PoolConfig memory pc, PoolKey memory key)
    {
        pc = _config(address(rules));
        pc.caps = caps;
        pc.advisory = address(a);
        pc.advisoryGasLimit = 2_000_000;
        pc.advisoryPhases = 1;
        key = _key(spacing);
    }

    /// F-016: a pool whose cap covered only the Rules maximum bound an advisory with its own surcharge, and valid
    /// advice then reverted swaps AggregateCapExceeded. The fixture member's Rules maximum is (17,250, 8,250, 75).
    function testAdvisoryMaximumMustFitBesideTheRulesMaximum() public {
        FixedAdvice a = new FixedAdvice(
            HookrTypes.Advice(10_000, 5_000, address(0xabc), false),
            HookrTypes.Advice(0, 0, address(0), false),
            false,
            false
        );
        _admitAdvice(a, 10_000, 5_000);
        bytes memory rulesData = abi.encode(_rulesConfig());
        (HookrTypes.PoolConfig memory pc, PoolKey memory key) = _advised(a, HookrTypes.Caps(17_250, 13_250, 75), 60);
        vm.expectRevert();
        root.initializePool(key, pc, rulesData, bytes(""), SQRT_ONE);
        (pc, key) = _advised(a, HookrTypes.Caps(27_250, 8_250, 75), 60);
        vm.expectRevert();
        root.initializePool(key, pc, rulesData, bytes(""), SQRT_ONE);
        (pc, key) = _advised(a, HookrTypes.Caps(27_249, 13_250, 75), 60);
        vm.expectRevert();
        root.initializePool(key, pc, rulesData, bytes(""), SQRT_ONE);
        // Caps that cover both maxima bind, and the advisory's full surcharge and take then settle.
        (pc, key) = _advised(a, HookrTypes.Caps(27_250, 13_250, 75), 60);
        root.initializePool(key, pc, rulesData, bytes(""), SQRT_ONE);
        _addLiquidity(key, -6000, 6000, 1e24);
        _genericSwap(key, true, -1e21, 0);
        _genericSwap(key, false, -1e21, 0);
    }

    /// The advisory's admitted maximum alone above the pool cap is refused before any module binds.
    function testAdvisoryAboveThePoolCapRefused() public {
        FixedAdvice a = new FixedAdvice(
            HookrTypes.Advice(0, 0, address(0), false), HookrTypes.Advice(0, 0, address(0), false), false, false
        );
        _admitAdvice(a, 30_000, 0);
        (HookrTypes.PoolConfig memory pc, PoolKey memory key) = _advised(a, HookrTypes.Caps(20_000, 8_250, 75), 60);
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        root.initializePool(key, pc, abi.encode(_rulesConfig()), bytes(""), SQRT_ONE);
    }
}

/// @notice Curated-router stand-ins that report a PoolManager.
contract CuratedRouterStub {
    address public immutable poolManager;

    constructor(address manager_) {
        poolManager = manager_;
    }

    function msgSender() external pure returns (address) {
        return address(0x1234);
    }
}

contract CuratedRouterWithoutManager {
    function msgSender() external pure returns (address) {
        return address(0x1234);
    }
}

/// PC-01 (contract part): the Root refuses a curated router wired to another PoolManager.
contract HookrRootCuratedRouterWiringTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function _salt(address curated) internal view returns (bytes32 salt) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(HookrRoot).creationCode, abi.encode(manager, registry, address(router), address(quoter), curated)
            )
        );
        for (uint256 i = 2_000_000;; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(predicted) & 0x3fff == root.PERMISSION_FLAGS()) return bytes32(i);
        }
    }

    function _deploy(address curated) internal returns (HookrRoot) {
        return new HookrRoot{salt: _salt(curated)}(
            IPoolManager(address(manager)), registry, address(router), address(quoter), curated
        );
    }

    function testCuratedRouterOnAnotherManagerRefused() public {
        address other = deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
        address wrong = address(new CuratedRouterStub(other));
        bytes32 salt = _salt(wrong);
        vm.expectRevert(IHookrRootState.InvalidWiring.selector);
        new HookrRoot{salt: salt}(IPoolManager(address(manager)), registry, address(router), address(quoter), wrong);
    }

    function testCuratedRouterWithoutManagerGetterRefused() public {
        address bare = address(new CuratedRouterWithoutManager());
        bytes32 salt = _salt(bare);
        vm.expectRevert(IHookrRootState.InvalidWiring.selector);
        new HookrRoot{salt: salt}(IPoolManager(address(manager)), registry, address(router), address(quoter), bare);
    }

    function testCuratedRouterOnThisManagerAccepted() public {
        address good = address(new CuratedRouterStub(address(manager)));
        HookrRoot r = _deploy(good);
        assertEq(r.curatedRouter(), good);
        assertEq(_deploy(address(0)).curatedRouter(), address(0));
    }
}
