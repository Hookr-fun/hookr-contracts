// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdmissions} from "../../src/interfaces/IHookrAdmissions.sol";
import {IHookrModuleBond} from "../../src/interfaces/IHookrModuleBond.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {MockModuleBond} from "../mocks/MockModuleBond.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @dev A Rules module that reports the fixture's root, to open a part scope.
contract BondChainStub {
    address public immutable trustedRoot;

    constructor(address root_) {
        trustedRoot = root_;
    }
}

/// @dev A part or an advisory as the registry sees it: any contract with code.
contract BondPartStub {}

/// @dev Reports the registry it names, which is all `registerFactoryRoot` asks of a root.
contract BondPairRootStub {
    address public immutable registry;

    constructor(address registry_) {
        registry = registry_;
    }
}

/// @dev A root factory as the registry sees it: code that registers roots.
contract BondFactoryStub {
    function register(HookrRegistry registry, address root, address advisory) external {
        registry.registerFactoryRoot(root, advisory);
    }
}

/// @notice Admission bonds: a timelocked `SET_ADMISSION_BOND` attaches a bond to a live admission for good, and from
///         then on the registry reports the admission only while the bond covers it, so roots refuse new pools for a
///         module its bond no longer backs. An unbonded admission reads exactly as before, a bond attaches only while it
///         covers, open pools keep their modules, and a bond that answers badly reads as not covering.
contract RegistryAdmissionBondsTest is PeripheryFixture {
    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    address internal guardian = address(0x6A7D);
    MockModuleBond internal bond;

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
        bond = new MockModuleBond();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _args(address scope, address implementation, address bondRef) internal pure returns (bytes memory) {
        return abi.encode(scope, implementation, bondRef);
    }

    /// @dev Attaches `bondRef` to the admission through the timelock; the bond covers it while it attaches.
    function _bond(address scope, address implementation, MockModuleBond bondRef) internal {
        bondRef.setCovered(scope, implementation, true);
        registry.queue(SET_ADMISSION_BOND, _args(scope, implementation, address(bondRef)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.pinModuleBondFor(scope, implementation, address(bondRef));
    }

    function _expectQueueRefused(bytes memory arguments, bytes memory reason) internal {
        vm.expectRevert(reason);
        registry.queue(SET_ADMISSION_BOND, arguments);
    }

    /// @dev One native-quote pool of `tokenA` on the root at `spacing`, bound to the fixture's Rules.
    function _launchNative(int24 spacing) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].tickSpacing = spacing;
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _expectLaunchRefused(int24 spacing, bytes memory reason) internal {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].tickSpacing = spacing;
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp();
        vm.expectRevert(reason);
        launcher.launch{value: 1e24}(token, address(root), members, deadline);
    }

    function _chainAdmission(address chain) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: chain,
            codeHash: chain.codehash,
            schemaHash: keccak256("test.chain.v1"),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    function _partAdmission(address part) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: part,
            codeHash: part.codehash,
            schemaHash: keccak256("test.part.v1"),
            caps: HookrTypes.Caps(10_000, 5_000, 0),
            gasLimit: 60_000,
            phaseMask: 1,
            feeOnly: false,
            failOpen: false
        });
    }

    // ───────────────────────────── bonds ─────────────────────────────

    /// A bond is inert until its queued SET_ADMISSION_BOND executes: an unbonded admission reads exactly as before,
    /// queued, matured or cancelled, and no read of it asks the bond.
    function test_bondIsInertUntilItExecutes() public {
        IHookrRegistry.Admission memory before = registry.admission(address(root), address(rules));
        (address none, bool covering) = registry.findBondForAdmission(address(root), address(rules));
        assertEq(none, address(0));
        assertFalse(covering);
        bond.setCovered(address(root), address(rules), true);
        bytes32 operation = registry.queue(SET_ADMISSION_BOND, _args(address(root), address(rules), address(bond)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectCall(address(bond), abi.encodeWithSelector(IHookrModuleBond.covers.selector), 0);
        assertEq(abi.encode(registry.admission(address(root), address(rules))), abi.encode(before));
        _launchNative(60);
        registry.cancel(operation);
        (none, covering) = registry.findBondForAdmission(address(root), address(rules));
        assertEq(none, address(0));
        assertFalse(covering);
        assertEq(abi.encode(registry.admission(address(root), address(rules))), abi.encode(before));
    }

    /// The bond executes after the delay, only from the owner; the admission then reads only while the bond covers it,
    /// new pools are refused while it does not, and the pool already open keeps trading.
    function test_bondGatesTheAdmissionForNewPools() public {
        bond.setCovered(address(root), address(rules), true);
        bytes32 operation = registry.queue(SET_ADMISSION_BOND, _args(address(root), address(rules), address(bond)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, operation));
        registry.pinModuleBondFor(address(root), address(rules), address(bond));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.pinModuleBondFor(address(root), address(rules), address(bond));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrAdmissions.AdmissionBondSet(address(root), address(rules), address(bond));
        registry.pinModuleBondFor(address(root), address(rules), address(bond));
        assertEq(registry.readyAt(operation), 0);

        (address bondRef, bool covering) = registry.findBondForAdmission(address(root), address(rules));
        assertEq(bondRef, address(bond));
        assertTrue(covering);
        IHookrRegistry.Admission memory a = registry.admission(address(root), address(rules));
        assertEq(a.implementation, address(rules));
        assertEq(a.codeHash, address(rules).codehash);
        PoolKey memory key = _launchNative(60);

        // The bond stops covering: the admission reads empty, new pools are refused, the open pool keeps trading.
        bond.setCovered(address(root), address(rules), false);
        (, covering) = registry.findBondForAdmission(address(root), address(rules));
        assertFalse(covering);
        IHookrRegistry.Admission memory empty;
        assertEq(abi.encode(registry.admission(address(root), address(rules))), abi.encode(empty));
        _expectLaunchRefused(120, abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, rules));
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        vm.prank(trader);
        (uint256 input, uint256 output) = router.swap{value: 1e18}(p, address(0), new uint256[](0));
        assertGt(input, 0);
        assertGt(output, 0);

        // It covers again: new pools open again.
        bond.setCovered(address(root), address(rules), true);
        assertEq(registry.admission(address(root), address(rules)).implementation, address(rules));
        _launchNative(120);
    }

    /// Only a clean 32-byte true covers: a revert, a short, long or dirty answer, or a bond that burns its gas reads as
    /// not covering.
    function test_badAnswersReadAsNotCovering() public {
        _bond(address(root), address(rules), bond);
        assertEq(registry.admission(address(root), address(rules)).implementation, address(rules));
        MockModuleBond.Mode[5] memory bad = [
            MockModuleBond.Mode.REVERT,
            MockModuleBond.Mode.SHORT,
            MockModuleBond.Mode.LONG,
            MockModuleBond.Mode.DIRTY,
            MockModuleBond.Mode.BURN
        ];
        for (uint256 i; i < bad.length; ++i) {
            bond.setMode(bad[i]);
            assertEq(registry.admission(address(root), address(rules)).implementation, address(0));
            (, bool covering) = registry.findBondForAdmission(address(root), address(rules));
            assertFalse(covering);
        }
        bond.setMode(MockModuleBond.Mode.ANSWER);
        assertEq(registry.admission(address(root), address(rules)).implementation, address(rules));
    }

    /// A bond needs a live admission without one and a bond reference holding code that is not an EIP-7702
    /// delegation, which covers the admission when it is queued and when it executes; it is attached for good.
    function test_bondBounds() public {
        _expectQueueRefused(
            _args(address(root), address(0x1234), address(bond)),
            abi.encodeWithSelector(IHookrRegistry.InvalidAdmission.selector)
        );
        _expectQueueRefused(
            _args(address(root), address(rules), address(0xB0D)),
            abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xB0D))
        );
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(bond)));
        _expectQueueRefused(
            _args(address(root), address(rules), delegated),
            abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated)
        );
        // A bond that does not cover the admission now, when queued or when it executes.
        _expectQueueRefused(
            _args(address(root), address(rules), address(bond)),
            abi.encodeWithSelector(IHookrAdmissions.BondNotCovering.selector, address(bond))
        );
        bond.setCovered(address(root), address(rules), true);
        // The arguments must be canonical.
        _expectQueueRefused(
            bytes.concat(_args(address(root), address(rules), address(bond)), hex"00"),
            abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, SET_ADMISSION_BOND)
        );
        registry.queue(SET_ADMISSION_BOND, _args(address(root), address(rules), address(bond)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        bond.setCovered(address(root), address(rules), false);
        vm.expectRevert(abi.encodeWithSelector(IHookrAdmissions.BondNotCovering.selector, address(bond)));
        registry.pinModuleBondFor(address(root), address(rules), address(bond));
        bond.setCovered(address(root), address(rules), true);
        registry.pinModuleBondFor(address(root), address(rules), address(bond));

        // Attached for good: no second bond, queued before or after.
        MockModuleBond other = new MockModuleBond();
        other.setCovered(address(root), address(rules), true);
        bytes memory already =
            abi.encodeWithSelector(IHookrAdmissions.AlreadyBonded.selector, address(root), address(rules));
        _expectQueueRefused(_args(address(root), address(rules), address(other)), already);
        _expectQueueRefused(_args(address(root), address(rules), address(bond)), already);
    }

    /// A second bond queued before the first one executed cannot execute after it.
    function test_bondIsPermanentAgainstAnEarlierQueue() public {
        MockModuleBond other = new MockModuleBond();
        other.setCovered(address(root), address(rules), true);
        bond.setCovered(address(root), address(rules), true);
        registry.queue(SET_ADMISSION_BOND, _args(address(root), address(rules), address(other)));
        registry.queue(SET_ADMISSION_BOND, _args(address(root), address(rules), address(bond)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.pinModuleBondFor(address(root), address(rules), address(bond));
        vm.expectRevert(abi.encodeWithSelector(IHookrAdmissions.AlreadyBonded.selector, address(root), address(rules)));
        registry.pinModuleBondFor(address(root), address(rules), address(other));
        (address bondRef,) = registry.findBondForAdmission(address(root), address(rules));
        assertEq(bondRef, address(bond));
    }

    /// A revoked admission takes no bond; a bonded one is still revoked by the brake, for good, whatever its bond says.
    function test_bondAndRevocation() public {
        _bond(address(root), address(rules), bond);
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(rules));
        assertTrue(registry.isRevokedAdmission(address(root), address(rules)));
        MockModuleBond other = new MockModuleBond();
        other.setCovered(address(root), address(rules), true);
        _expectQueueRefused(
            _args(address(root), address(rules), address(other)),
            abi.encodeWithSelector(IHookrRegistry.InvalidAdmission.selector)
        );
        assertEq(registry.admission(address(root), address(rules)).implementation, address(0));
    }

    /// A part scope takes no new part admission while its module's bond does not cover the module's admission on the
    /// root; parts already admitted stay as they are.
    function test_partScopeFollowsTheModulesBond() public {
        BondChainStub chain = new BondChainStub(address(root));
        IHookrRegistry.Admission memory a = _chainAdmission(address(chain));
        BondPartStub kept = new BondPartStub();
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        registry.queue(registry.ADMIT(), abi.encode(address(chain), _partAdmission(address(kept))));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(chain), _partAdmission(address(kept)));

        _bond(address(root), address(chain), bond);
        (bool eligible, address scopeRoot) = registry.partScopeEligible(address(chain));
        assertTrue(eligible);
        assertEq(scopeRoot, address(root));

        bond.setCovered(address(root), address(chain), false);
        (eligible, scopeRoot) = registry.partScopeEligible(address(chain));
        assertFalse(eligible);
        assertEq(scopeRoot, address(0));
        BondPartStub part = new BondPartStub();
        bytes32 admit = registry.ADMIT();
        bytes memory arguments = abi.encode(address(chain), _partAdmission(address(part)));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(admit, arguments);
        assertEq(registry.admission(address(chain), address(kept)).implementation, address(kept));

        bond.setCovered(address(root), address(chain), true);
        (eligible, scopeRoot) = registry.partScopeEligible(address(chain));
        assertTrue(eligible);
        assertEq(scopeRoot, address(root));
        registry.queue(admit, arguments);
    }

    /// A bonded pair advisory reads as empty for its factory, so the factory deploys no new pair root naming it, and its
    /// pair roots read as unverified, while the bond does not cover it.
    function test_bondReachesPairAdvisoriesAndRootStatus() public {
        BondFactoryStub factory = new BondFactoryStub();
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        BondPartStub advisory = new BondPartStub();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: keccak256("test.pair.v1"),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 100_000,
            phaseMask: 1,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(factory), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(factory), a);
        address pairRoot = address(new BondPairRootStub(address(registry)));
        factory.register(registry, pairRoot, address(advisory));
        (address recorded, bool verified) = registry.rootStatus(pairRoot);
        assertEq(recorded, address(advisory));
        assertTrue(verified);

        _bond(address(factory), address(advisory), bond);
        (, verified) = registry.rootStatus(pairRoot);
        assertTrue(verified);
        bond.setCovered(address(factory), address(advisory), false);
        (, verified) = registry.rootStatus(pairRoot);
        assertFalse(verified);
        assertEq(registry.admission(address(factory), address(advisory)).implementation, address(0));
        bond.setCovered(address(factory), address(advisory), true);
        (, verified) = registry.rootStatus(pairRoot);
        assertTrue(verified);
        assertEq(registry.admission(address(factory), address(advisory)).implementation, address(advisory));
    }

    /// The bond entry points sort after every registry read a launch, a swap, a lane swap or a pair-root deployment
    /// makes, so they cost those calls nothing in the dispatcher.
    function test_dispatch_bondSelectorsSortAfterEveryOnChainRegistryCall() public pure {
        bytes4[10] memory hot = [
            HookrRegistry.isRoot.selector,
            HookrRegistry.admission.selector,
            HookrRegistry.isQuote.selector,
            HookrRegistry.rootOpen.selector,
            HookrRegistry.isLauncher.selector,
            HookrRegistry.rootFactoryOf.selector,
            HookrRegistry.registerFactoryRoot.selector,
            HookrRegistry.executorLane.selector,
            HookrRegistry.activeLaneOf.selector,
            HookrRegistry.settlementCurrencies.selector
        ];
        bytes4[2] memory added = [HookrRegistry.pinModuleBondFor.selector, HookrRegistry.findBondForAdmission.selector];
        assertEq(added[0], bytes4(0xfff88201));
        assertEq(added[1], bytes4(0xfff24c73));
        for (uint256 i; i < hot.length; ++i) {
            for (uint256 j; j < added.length; ++j) {
                assertLt(uint32(hot[i]), uint32(added[j]));
            }
        }
    }
}

/// @notice A lapsed bond, like a revoke, refuses new binds only and never silently disables a live pool: a pool opened
///         while its Rules' bond covered trades, adds and removes liquidity, collects fees and pays every claim exactly
///         as it would had the bond kept covering, and no registry admission or bond is read on any of those paths.
contract RegistryAdmissionBondsLivePoolTest is PeripheryFixture {
    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    MockModuleBond internal bond;
    bytes32 internal family;
    PoolKey internal key;
    HookrToken internal subject;
    Currency internal quote;

    function setUp() public {
        _setUpPeriphery();
        bond = new MockModuleBond();
        bond.setCovered(address(root), address(rules), true);
        registry.queue(SET_ADMISSION_BOND, abi.encode(address(root), address(rules), address(bond)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.pinModuleBondFor(address(root), address(rules), address(bond));
        (family, key, subject, quote) = _launch(true, false);
    }

    function _next() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function _trade(bool buy, uint128 amount) internal returns (uint256 input, uint256 output) {
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        vm.prank(trader);
        (input, output) = router.swap(p, address(0), new uint256[](0));
        _next();
    }

    /// @dev Trades both ways, an add, a fee collection and a principal removal, then every claim the trades credited:
    ///      the protocol's and the royalty's from the Rules and the liquidity owner's accrual; then what the Rules still
    ///      owes and every balance the payments reach.
    function _exercise() internal returns (uint256[] memory out) {
        out = new uint256[](25);
        uint256 n;
        uint256 lockedUntil = launcher.principalLockedUntil(family);
        if (vm.getBlockNumber() <= lockedUntil) vm.roll(lockedUntil + 1);
        for (uint256 i; i < 3; ++i) {
            (out[n++], out[n++]) = _trade(true, 1e18);
            (out[n++], out[n++]) = _trade(false, 1e17);
        }
        uint256 deadline = vm.getBlockTimestamp() + 1000;
        (out[n++], out[n++]) = launcher.addLiquidity(family, 0, 1e20, 1e22, 1e22, deadline);
        (out[n++], out[n++]) = launcher.withdraw(family, 0, 0, 0, 0, address(this), deadline);
        (out[n++], out[n++]) = launcher.withdraw(family, 0, 5e19, 0, 0, address(this), deadline);
        out[n++] = launcher.claimRecapture(family, 0, address(this));
        uint256 owed = rules.claimable(quote, protocol);
        assertGt(owed, 0, "the protocol is owed");
        vm.prank(protocol);
        out[n++] = rules.claim(quote);
        owed = rules.claimable(quote, royalty);
        assertGt(owed, 0, "the royalty is owed");
        vm.prank(royalty);
        out[n++] = rules.claim(quote);
        out[n++] = rules.totalLiability(quote);
        out[n++] = quote.balanceOf(protocol);
        out[n++] = quote.balanceOf(royalty);
        out[n++] = subject.balanceOf(trader);
        assertEq(n, out.length, "every value recorded");
    }

    function test_livePoolTradesExitsAndClaimsIdenticallyAfterItsBondLapses() public {
        uint256 snapshot = vm.snapshotState();
        uint256[] memory expected = _exercise();
        assertEq(expected[expected.length - 4], 0, "every claim paid");
        vm.revertToState(snapshot);

        bond.setCovered(address(root), address(rules), false);
        assertEq(registry.admission(address(root), address(rules)).implementation, address(0));
        (, bool covering) = registry.findBondForAdmission(address(root), address(rules));
        assertFalse(covering);

        vm.expectCall(address(registry), abi.encodeWithSelector(IHookrRegistry.admission.selector), 0);
        vm.expectCall(address(bond), abi.encodeWithSelector(IHookrModuleBond.covers.selector), 0);
        uint256[] memory got = _exercise();
        assertEq(got, expected);
    }
}
