// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrExternalHooks} from "../../src/interfaces/IHookrExternalHooks.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @dev A hook Hookr did not write, as the registry sees it: code it pins and never calls.
contract ExternalHookStub {
    function getHookPermissions() external pure returns (uint256) {
        return 0;
    }
}

/// @dev The same hook with other runtime code, to model a codehash drift at its address.
contract ExternalHookStubV2 {
    function getHookPermissions() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Any contract with code, as a bond reference or an advisory.
contract BondRefStub {}

/// @notice External-hook records: a timelocked `RECORD_EXTERNAL_HOOK` records a hook that is not a Hookr root as
///         LISTED (discovery and attribution) or CUSTODY_ROOT, pinned to its runtime codehash and naming an optional
///         bond reference; `dropSingleExternalHookRecordNow` (owner or guardian) withdraws it at once and outlives every
///         record queued before it. A record is inert until it executes, and it never makes a hook a root or grants it
///         an admission.
contract RegistryExternalHooksTest is PeripheryFixture {
    bytes32 internal constant RECORD = keccak256("RECORD_EXTERNAL_HOOK");
    address internal guardian = address(0x6A7D);
    address internal stranger = address(0x5757);
    ExternalHookStub internal hook;
    BondRefStub internal bond;
    uint256 internal nextSalt = 1 << 128;

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
        hook = new ExternalHookStub();
        bond = new BondRefStub();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _args(address h, IHookrExternalHooks.HookKind kind, bytes32 codeHash, address bondRef)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(h, kind, codeHash, bondRef);
    }

    function _queue(address h, IHookrExternalHooks.HookKind kind, address bondRef) internal returns (bytes32) {
        return registry.queue(RECORD, _args(h, kind, h.codehash, bondRef));
    }

    function _record(address h, IHookrExternalHooks.HookKind kind, address bondRef) internal {
        _queue(h, kind, bondRef);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setExternalHook(h, kind, h.codehash, bondRef);
    }

    function _expectQueueRefused(bytes memory arguments, bytes memory reason) internal {
        vm.expectRevert(reason);
        registry.queue(RECORD, arguments);
    }

    function _assertRecord(address h, IHookrExternalHooks.HookKind kind, address bondRef, bool matches) internal view {
        (IHookrExternalHooks.ExternalHook memory r, bool codeHashMatches) = registry.findExternalHookWithCodeCheck(h);
        assertEq(uint8(r.kind), uint8(kind), "kind");
        assertEq(r.bondRef, bondRef, "bondRef");
        assertEq(r.codeHash, kind == IHookrExternalHooks.HookKind.NONE ? bytes32(0) : h.codehash, "codeHash");
        assertEq(codeHashMatches, matches, "matches");
    }

    /// @dev An unmodified HookrRoot at a fresh CREATE2 address with the root's permission flags, unregistered.
    function _deployRoot() internal returns (HookrRoot r) {
        bytes memory args = abi.encode(manager, registry, address(router), address(quoter), address(0));
        bytes32 initHash = keccak256(abi.encodePacked(type(HookrRoot).creationCode, args));
        for (uint256 i = nextSalt;; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(predicted) & 0x3fff == 0x2acc) {
                nextSalt = i + 1;
                return new HookrRoot{salt: bytes32(i)}(manager, registry, address(router), address(quoter), address(0));
            }
        }
    }

    // ───────────────────────────── records ─────────────────────────────

    /// A LISTED record executes only from the owner and only after the delay, pinned to the hook's codehash.
    function test_recordListsAHookAfterTheDelay() public {
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.NONE, address(0), false);
        bytes32 operation = _queue(address(hook), IHookrExternalHooks.HookKind.LISTED, address(0));
        bytes32 pinned = address(hook).codehash;
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, operation));
        registry.setExternalHook(address(hook), IHookrExternalHooks.HookKind.LISTED, pinned, address(0));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.setExternalHook(address(hook), IHookrExternalHooks.HookKind.LISTED, pinned, address(0));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrExternalHooks.ExternalHookRecorded(
            address(hook), IHookrExternalHooks.HookKind.LISTED, pinned, address(0)
        );
        registry.setExternalHook(address(hook), IHookrExternalHooks.HookKind.LISTED, pinned, address(0));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.LISTED, address(0), true);
        assertEq(registry.readyAt(operation), 0);
    }

    /// A record is inert until it executes, and once it does it never makes the hook a root or grants it anything: the
    /// hook is no root, opens no pool, is no scope for an admission and holds none.
    function test_recordIsInertAndNeverMakesARootOrAnAdmission() public {
        bytes32 operation = _queue(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(bond));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.NONE, address(0), false);
        registry.cancel(operation);
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.NONE, address(0), false);

        _record(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(bond));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(bond), true);
        assertFalse(registry.isRoot(address(hook)));
        assertFalse(registry.rootOpen(address(hook)));
        assertEq(registry.rootFactoryOf(address(hook)), address(0));
        (address advisory, bool verified) = registry.rootStatus(address(hook));
        assertEq(advisory, address(0));
        assertFalse(verified);
        assertEq(registry.admission(address(root), address(hook)).implementation, address(0));
        BondRefStub module = new BondRefStub();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(module),
            codeHash: address(module).codehash,
            schemaHash: keccak256("test.advisory.v1"),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        bytes32 admit = registry.ADMIT();
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(admit, abi.encode(address(hook), a));
    }

    /// A CUSTODY_ROOT record with a bond reference; a later record of the same hook replaces it.
    function test_recordCarriesItsKindAndBondAndALaterOneReplacesIt() public {
        _record(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(bond));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(bond), true);
        _record(address(hook), IHookrExternalHooks.HookKind.LISTED, address(0));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.LISTED, address(0), true);
    }

    /// The codehash is checked when queued and again when executed, and the view reports a later drift.
    function test_codeHashIsCheckedAtQueueAndExecute() public {
        _expectQueueRefused(
            _args(address(hook), IHookrExternalHooks.HookKind.LISTED, keccak256("other"), address(0)),
            abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(hook))
        );
        bytes32 pinned = address(hook).codehash;
        _queue(address(hook), IHookrExternalHooks.HookKind.LISTED, address(0));
        bytes memory original = address(hook).code;
        vm.etch(address(hook), address(new ExternalHookStubV2()).code);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(hook)));
        registry.setExternalHook(address(hook), IHookrExternalHooks.HookKind.LISTED, pinned, address(0));

        vm.etch(address(hook), original);
        registry.setExternalHook(address(hook), IHookrExternalHooks.HookKind.LISTED, pinned, address(0));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.LISTED, address(0), true);
        vm.etch(address(hook), address(new ExternalHookStubV2()).code);
        (IHookrExternalHooks.ExternalHook memory r, bool matches) =
            registry.findExternalHookWithCodeCheck(address(hook));
        assertEq(r.codeHash, pinned);
        assertFalse(matches);
    }

    /// The hook must hold code that is not an EIP-7702 delegation, and must not be a registered root.
    function test_hookMustBeNonDelegatedCodeAndNotARoot() public {
        address eoa = address(0xE0A);
        _expectQueueRefused(
            _args(eoa, IHookrExternalHooks.HookKind.LISTED, bytes32(0), address(0)),
            abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, eoa)
        );
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(hook)));
        _expectQueueRefused(
            _args(delegated, IHookrExternalHooks.HookKind.LISTED, delegated.codehash, address(0)),
            abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated)
        );
        _expectQueueRefused(
            _args(address(root), IHookrExternalHooks.HookKind.LISTED, address(root).codehash, address(0)),
            abi.encodeWithSelector(IHookrExternalHooks.InvalidRecord.selector)
        );
    }

    /// The record set and the root set never share an address: a queued REGISTER_ROOT of a recorded hook is refused,
    /// when queued and when it executes, until the record is withdrawn; a record of a hook registered as a root after
    /// it was queued does not execute.
    function test_recordedHookIsNeverRegisteredAsARoot() public {
        HookrRoot other = _deployRoot();
        bytes32 codeHash = address(other).codehash;
        bytes32 register = registry.REGISTER_ROOT();
        registry.queue(register, abi.encode(address(other), codeHash));
        _record(address(other), IHookrExternalHooks.HookKind.LISTED, address(0));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.registerRoot(address(other), codeHash);
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(register, abi.encode(address(other), codeHash));

        registry.dropSingleExternalHookRecordNow(address(other));
        registry.registerRoot(address(other), codeHash);
        assertTrue(registry.isRoot(address(other)));

        HookrRoot later = _deployRoot();
        _queue(address(later), IHookrExternalHooks.HookKind.LISTED, address(0));
        registry.queue(register, abi.encode(address(later), address(later).codehash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(later), address(later).codehash);
        vm.expectRevert(IHookrExternalHooks.InvalidRecord.selector);
        registry.setExternalHook(
            address(later), IHookrExternalHooks.HookKind.LISTED, address(later).codehash, address(0)
        );
    }

    /// The kind is LISTED or CUSTODY_ROOT: NONE is refused and an out-of-range kind does not decode. A bond reference is
    /// zero or holds code that is not an EIP-7702 delegation. The arguments must be canonical.
    function test_kindAndBondReferenceBounds() public {
        _expectQueueRefused(
            _args(address(hook), IHookrExternalHooks.HookKind.NONE, address(hook).codehash, address(0)),
            abi.encodeWithSelector(IHookrExternalHooks.InvalidRecord.selector)
        );
        vm.expectRevert();
        registry.queue(RECORD, abi.encode(address(hook), uint8(3), address(hook).codehash, address(0)));
        _expectQueueRefused(
            _args(address(hook), IHookrExternalHooks.HookKind.LISTED, address(hook).codehash, address(0xB0D)),
            abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xB0D))
        );
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(bond)));
        _expectQueueRefused(
            _args(address(hook), IHookrExternalHooks.HookKind.LISTED, address(hook).codehash, delegated),
            abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated)
        );
        _expectQueueRefused(
            bytes.concat(
                _args(address(hook), IHookrExternalHooks.HookKind.LISTED, address(hook).codehash, address(0)), hex"00"
            ),
            abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, RECORD)
        );
    }

    // ───────────────────────────── the brake ─────────────────────────────

    /// The brake withdraws a record at once and outlives every record queued before it; one queued after it executes.
    function test_brakeWithdrawsARecordAndOutlivesEarlierQueues() public {
        _record(address(hook), IHookrExternalHooks.HookKind.LISTED, address(bond));
        _queue(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(0));

        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.dropSingleExternalHookRecordNow(address(hook));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrExternalHooks.ExternalHookDelisted(address(hook), guardian);
        vm.prank(guardian);
        registry.dropSingleExternalHookRecordNow(address(hook));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.NONE, address(0), false);

        vm.warp(vm.getBlockTimestamp() + registry.delay());
        bytes32 early = registry.operationHash(
            RECORD, _args(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(hook).codehash, address(0))
        );
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, early));
        registry.setExternalHook(
            address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(hook).codehash, address(0)
        );

        registry.cancel(early);
        _record(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(0));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.CUSTODY_ROOT, address(0), true);
    }

    /// The record entry points sort after every registry read a launch, a swap, a lane swap or a pair-root deployment
    /// makes, so they cost those calls nothing in the dispatcher.
    function test_dispatch_recordSelectorsSortAfterEveryOnChainRegistryCall() public pure {
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
        bytes4[3] memory added = [
            HookrRegistry.setExternalHook.selector,
            HookrRegistry.dropSingleExternalHookRecordNow.selector,
            HookrRegistry.findExternalHookWithCodeCheck.selector
        ];
        assertEq(added[0], bytes4(0xffbde089));
        assertEq(added[1], bytes4(0xff604574));
        assertEq(added[2], bytes4(0xffc11238));
        for (uint256 i; i < hot.length; ++i) {
            for (uint256 j; j < added.length; ++j) {
                assertLt(uint32(hot[i]), uint32(added[j]));
            }
        }
    }

    /// The brake also pre-empts a record queued for a hook that has none yet.
    function test_brakePreemptsAQueuedFirstRecord() public {
        bytes32 operation = _queue(address(hook), IHookrExternalHooks.HookKind.LISTED, address(0));
        registry.dropSingleExternalHookRecordNow(address(hook));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, operation));
        registry.setExternalHook(address(hook), IHookrExternalHooks.HookKind.LISTED, address(hook).codehash, address(0));
        _assertRecord(address(hook), IHookrExternalHooks.HookKind.NONE, address(0), false);
    }
}
