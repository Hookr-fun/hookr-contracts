// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @title ReleaseWiring
/// @notice The release wiring the test fixtures share (PeripheryFixture, GasBenchFixture, SystemDeploy, LpBoostFixture
///         and OwnedRootsFixture, and the suites that wire more than their fixture): HookrRoot deployed by CREATE2 at
///         the first salt whose address carries its permission flags, the Rules admission a fixture grants a root, the
///         GATE admission the release grants a gate, and the registry's timelocked operations that register a root,
///         activate the launcher, admit a module and enter quotes in the catalog, each queued with exactly the
///         arguments it executes with.
/// @dev Internal functions only, so every call runs in the calling fixture: the fixture deploys (its nonce, its CREATE2
///      addresses), owns the registry and moves the clock. No function deploys anything but the roots it is asked for,
///      and only waitDelay and the rounds built on it move the clock, by the registry's delay. Each function makes the
///      registry calls it names in the order the fixtures' own code made them (the operation's constant getter, then
///      the queue or the execution), so a fixture keeps its addresses, nonces and timestamps, under --isolate too,
///      where every top-level call is a transaction that spends one of the fixture's nonces and the order of its
///      creations and calls fixes every later address (test/utils/FixtureAddresses.t.sol pins them).
library ReleaseWiring {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice HookrRoot's permission flags, the low 14 bits of its address (HookrRoot.PERMISSION_FLAGS, 0x2acc):
    ///         before initialize, before add and remove liquidity, before and after swap, and both swap deltas.
    uint160 internal constant ROOT_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    /// @notice The salt counters a root search tries before it gives up; a match is expected within about 16,384.
    uint256 internal constant MAX_SALT_SEARCH = 1 << 20;

    /// @notice No salt counter from `from` on, within MAX_SALT_SEARCH, gives an address with `flags`.
    error NoSalt(bytes32 initHash, uint160 flags, uint256 from);

    // ───────────────────────────── HookrRoot ─────────────────────────────

    /// @notice HookrRoot's creation code followed by its constructor arguments, as `new HookrRoot(...)` sends it.
    function rootInitCode(IPoolManager manager, HookrRegistry registry, address router, address quoter, address ur)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(type(HookrRoot).creationCode, abi.encode(manager, registry, router, quoter, ur));
    }

    /// @notice HookrRoot's init code hash for these constructor arguments.
    function rootInitHash(IPoolManager manager, HookrRegistry registry, address router, address quoter, address ur)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(rootInitCode(manager, registry, router, quoter, ur));
    }

    /// @notice The first salt counter at or after `from` whose CREATE2 address from `deployer` for `initHash` carries
    ///         `flags` in its low 14 bits (v4-periphery's HookMiner search, without its code check: a fixture's predicted
    ///         addresses hold no code).
    function mineSalt(address deployer, bytes32 initHash, uint160 flags, uint256 from)
        internal
        pure
        returns (uint256 counter)
    {
        uint256 end = from + MAX_SALT_SEARCH;
        for (counter = from; counter < end; ++counter) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(counter), initHash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) return counter;
        }
        revert NoSalt(initHash, flags, from);
    }

    /// @notice Deploys `count` HookrRoots from this contract by CREATE2, at the first `count` salt counters from 0 whose
    ///         addresses carry the permission flags, in that order.
    function deployRoots(
        IPoolManager manager,
        HookrRegistry registry,
        address router,
        address quoter,
        address ur,
        uint256 count
    ) internal returns (HookrRoot[] memory roots) {
        bytes memory init = rootInitCode(manager, registry, router, quoter, ur);
        bytes32 initHash = keccak256(init);
        roots = new HookrRoot[](count);
        uint256 counter;
        for (uint256 i; i < count; ++i) {
            counter = mineSalt(address(this), initHash, ROOT_FLAGS, i == 0 ? 0 : counter + 1);
            roots[i] = HookrRoot(_create2(init, bytes32(counter)));
        }
    }

    /// @notice Deploys one HookrRoot from this contract by CREATE2 at the first salt counter whose address carries the
    ///         permission flags.
    function deployRoot(IPoolManager manager, HookrRegistry registry, address router, address quoter, address ur)
        internal
        returns (HookrRoot)
    {
        return deployRoots(manager, registry, router, quoter, ur, 1)[0];
    }

    /// @dev CREATE2 of `init` at `salt` from this contract, exactly as `new HookrRoot{salt: salt}(...)` deploys it, with
    ///      a failed creation's revert data passed on. Kept apart so the deploy loop holds few stack slots under via-IR.
    function _create2(bytes memory init, bytes32 salt) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(init, 0x20), mload(init), salt)
            if iszero(deployed) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    // ───────────────────────────── admissions ─────────────────────────────

    /// @notice The Rules admission the fixtures grant a root: a 600,000-pip LP fee ceiling, `maxQuoteTakePips` of the
    ///         quote and 1,000 bps of the subject per swap, a 2,000,000 gas limit, both phases, not fee-only and fail
    ///         closed, with the module's runtime code hash and config schema.
    function rulesAdmission(HookrRules rules, uint24 maxQuoteTakePips)
        internal
        view
        returns (IHookrRegistry.Admission memory)
    {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(rules),
            codeHash: address(rules).codehash,
            schemaHash: rules.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, maxQuoteTakePips, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    /// @notice The GATE admission the release grants a gate (HookrFamilyRouter on the shared root): its runtime code
    ///         hash, the IHookrSwapGate schema, no caps and no phases, `gasLimit` (the registry admits 25,000 to
    ///         200,000), not fee-only and fail closed.
    function gateAdmission(address gate, uint32 gasLimit) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.GATE,
            implementation: gate,
            codeHash: gate.codehash,
            schemaHash: keccak256("IHookrSwapGate"),
            caps: HookrTypes.Caps(0, 0, 0),
            gasLimit: gasLimit,
            phaseMask: 0,
            feeOnly: false,
            failOpen: false
        });
    }

    // ───────────────────────────── timelocked operations ─────────────────────────────

    /// @notice Queues the registration of `root` at its current runtime code hash.
    function queueRoot(HookrRegistry registry, address root) internal {
        registry.queue(registry.REGISTER_ROOT(), abi.encode(root, root.codehash));
    }

    /// @notice Executes the registration `queueRoot` queued.
    function registerRoot(HookrRegistry registry, address root) internal {
        registry.registerRoot(root, root.codehash);
    }

    /// @notice Queues the activation of `launcher`.
    function queueLauncher(HookrRegistry registry, address launcher) internal {
        registry.queue(registry.SET_LAUNCHER(), abi.encode(launcher, true));
    }

    /// @notice Executes the activation `queueLauncher` queued.
    function activateLauncher(HookrRegistry registry, address launcher) internal {
        registry.setLauncher(launcher, true);
    }

    /// @notice Queues the addition of `asset` to the quote catalog.
    function queueQuote(HookrRegistry registry, address asset) internal {
        registry.queue(registry.SET_QUOTE(), abi.encode(asset, true));
    }

    /// @notice Executes the addition `queueQuote` queued.
    function addQuote(HookrRegistry registry, address asset) internal {
        registry.setQuote(asset, true);
    }

    /// @notice Queues the admission `a` for `scope` (a root, or a root factory for its pair roots' advisories).
    function queueAdmission(HookrRegistry registry, address scope, IHookrRegistry.Admission memory a) internal {
        registry.queue(registry.ADMIT(), abi.encode(scope, a));
    }

    /// @notice Executes the admission `queueAdmission` queued.
    function admit(HookrRegistry registry, address scope, IHookrRegistry.Admission memory a) internal {
        registry.admit(scope, a);
    }

    /// @notice Moves the clock by the registry's delay, when everything queued before it is ready.
    function waitDelay(HookrRegistry registry) internal {
        vm.warp(vm.getBlockTimestamp() + registry.delay());
    }

    // ───────────────────────────── rounds: queue, wait the delay, execute ─────────────────────────────

    /// @notice Registers `root` and activates `launcher` in one timelock round.
    function registerRootAndLauncher(HookrRegistry registry, address root, address launcher) internal {
        queueRoot(registry, root);
        queueLauncher(registry, launcher);
        waitDelay(registry);
        registerRoot(registry, root);
        activateLauncher(registry, launcher);
    }

    /// @notice Admits `a` for `scope` in one timelock round.
    function admitAfterDelay(HookrRegistry registry, address scope, IHookrRegistry.Admission memory a) internal {
        queueAdmission(registry, scope, a);
        waitDelay(registry);
        admit(registry, scope, a);
    }

    /// @notice Enters `asset` in the quote catalog in one timelock round.
    function catalogQuote(HookrRegistry registry, address asset) internal {
        queueQuote(registry, asset);
        waitDelay(registry);
        addQuote(registry, asset);
    }

    /// @notice Enters `assets` in the quote catalog, in this order, in one timelock round.
    function catalogQuotes(HookrRegistry registry, address[] memory assets) internal {
        for (uint256 i; i < assets.length; ++i) {
            queueQuote(registry, assets[i]);
        }
        waitDelay(registry);
        for (uint256 i; i < assets.length; ++i) {
            addQuote(registry, assets[i]);
        }
    }
}
