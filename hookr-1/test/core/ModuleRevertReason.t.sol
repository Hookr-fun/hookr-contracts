// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRootStorage} from "../../src/libraries/HookrRootStorage.sol";
import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @dev How a scripted module call fails: not at all, by reverting with the scripted data (empty included), by
///      spending every unit of its gas, by returning one byte more than the root reads, or (an advisory's swap answer)
///      by returning a word the root refuses.
library Scripted {
    uint8 internal constant NONE = 0;
    uint8 internal constant REVERT = 1;
    uint8 internal constant BURN = 2;
    uint8 internal constant LONG = 3;
    uint8 internal constant OUT_OF_RANGE = 4;
}

/// @dev A failure script shared by the two stand-ins: a mode and revert data per selector. Storage, so a script never
///      changes the code hash the registry pinned.
abstract contract ScriptedModule {
    mapping(bytes4 => uint8) public modeOf;
    mapping(bytes4 => bytes) internal reasonOf;

    function script(bytes4 selector, uint8 mode, bytes calldata reason) external {
        modeOf[selector] = mode;
        reasonOf[selector] = reason;
    }

    /// @dev Fails as scripted for `selector`; `size` is the return length the root reads.
    function _scripted(bytes4 selector, uint256 size) internal view {
        uint8 mode = modeOf[selector];
        if (mode == Scripted.NONE) return;
        if (mode == Scripted.REVERT) {
            bytes memory reason = reasonOf[selector];
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        if (mode == Scripted.BURN) {
            assembly ("memory-safe") {
                for {} 1 {} {}
            }
        }
        if (mode == Scripted.LONG) {
            assembly ("memory-safe") {
                return(0, add(size, 1))
            }
        }
        // OUT_OF_RANGE: an Advice whose `reject` word is 2.
        assembly ("memory-safe") {
            mstore(0, 0)
            mstore(32, 0)
            mstore(64, 0)
            mstore(96, 2)
            return(0, 128)
        }
    }
}

/// @dev Rules whose every call the root and HookrLane make on a pool without a lane can be scripted to fail; healthy,
///      they charge nothing.
contract ReasonRules is ScriptedModule {
    IPoolManager public immutable poolManager;
    address public immutable trustedRoot;

    constructor(IPoolManager manager, address root) {
        poolManager = manager;
        trustedRoot = root;
    }

    function configSchemaHash() external view returns (bytes32) {
        _scripted(IHookrRules.configSchemaHash.selector, 32);
        return keccak256("test.reason.rules");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        view
        returns (bytes32)
    {
        _scripted(IHookrRules.bind.selector, 32);
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external view {
        _scripted(IHookrRules.beforeAddLiquidity.selector, 0);
    }

    function removalLockedUntil(PoolId) external view returns (uint256) {
        _scripted(IHookrRules.removalLockedUntil.selector, 32);
        return 0;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external view returns (HookrTypes.FeeQuote memory q) {
        _scripted(IHookrRules.beforeSwap.selector, 96);
        return q;
    }

    function settleSwap(HookrTypes.SwapContext calldata, HookrTypes.Settlement calldata z)
        external
        view
        returns (uint256)
    {
        _scripted(IHookrRules.settleSwap.selector, 32);
        return z.rulesFee + z.advisoryFee + z.refund;
    }
}

/// @dev A fail-closed advisory whose every call can be scripted to fail; healthy, it advises nothing.
contract ReasonAdvisory is ScriptedModule {
    function configSchemaHash() external view returns (bytes32) {
        _scripted(IHookrAdvisory.configSchemaHash.selector, 32);
        return keccak256("test.reason.advisory");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        view
        returns (bytes32)
    {
        _scripted(IHookrAdvisory.bind.selector, 32);
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external view returns (bool) {
        _scripted(IHookrAdvisory.beforeAddLiquidity.selector, 32);
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external view returns (HookrTypes.Advice memory a) {
        _scripted(IHookrAdvisory.beforeSwap.selector, 128);
        return a;
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory a)
    {
        _scripted(IHookrAdvisory.afterSwap.selector, 128);
        return a;
    }
}

/// @notice N15: a module call the root or HookrLane requires surfaces the module's own reason. A module that reverts
///         with data raises ModuleCallReverted(module, selector, reason), `reason` that data cut to its first 132 bytes
///         (a selector and four words) and carried inside the error, so it never reads as the root's own. A module that
///         runs out of gas, reverts without data or answers in a shape the root refuses keeps
///         ModuleCallFailed(module, selector), selector and fields unchanged. Both errors are encoded by hand
///         (HookrRootStorage.revertModuleCall); every case here compares them byte for byte with the compiler's ABI
///         encoding. HookrLane raises the same pair for the calls it makes in the root's context at initialization
///         (the schema reads, bind, the removal lock, the advisory's bind); its arb recapture settlement and sweep are
///         covered in test/lane/ModuleRevertReasonLane.t.sol.
contract ModuleRevertReasonTest is RootSecurityBase {
    uint32 internal constant ADVISORY_GAS = 200_000;

    ReasonRules internal reasonRules;
    ReasonAdvisory internal advisory;

    function setUp() public {
        _setUpRootSecurity();
        reasonRules = new ReasonRules(manager, address(root));
        advisory = new ReasonAdvisory();
        IHookrRegistry.Admission memory r = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(reasonRules),
            codeHash: address(reasonRules).codehash,
            schemaHash: reasonRules.configSchemaHash(),
            caps: HookrTypes.Caps(100_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: advisory.configSchemaHash(),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: ADVISORY_GAS,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        ReleaseWiring.queueAdmission(registry, address(root), r);
        ReleaseWiring.queueAdmission(registry, address(root), a);
        ReleaseWiring.waitDelay(registry);
        ReleaseWiring.admit(registry, address(root), r);
        ReleaseWiring.admit(registry, address(root), a);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev `reason`'s first 132 bytes, or all of it.
    function _cut(bytes memory reason) internal pure returns (bytes memory cut) {
        uint256 n = reason.length < 132 ? reason.length : 132;
        cut = new bytes(n);
        for (uint256 i; i < n; ++i) {
            cut[i] = reason[i];
        }
    }

    /// @dev What the root raises for `module`'s failed call of `selector` that reverted with `reason`, as the compiler
    ///      encodes it.
    function _raised(address module, bytes4 selector, bytes memory reason) internal pure returns (bytes memory) {
        if (reason.length == 0) {
            return abi.encodeWithSelector(IHookrRootEvents.ModuleCallFailed.selector, module, selector);
        }
        return abi.encodeWithSelector(IHookrRootEvents.ModuleCallReverted.selector, module, selector, _cut(reason));
    }

    /// @dev The PoolManager's wrapping of a root error raised in `callback`.
    function _wrapped(bytes4 callback, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _reason(uint256 length, bytes32 seed) internal pure returns (bytes memory reason) {
        reason = new bytes(length);
        for (uint256 i; i < length; ++i) {
            reason[i] = bytes1(keccak256(abi.encode(seed, i)));
        }
    }

    /// @dev Reason lengths around every boundary: under a selector, a selector, the word edges, the cap and far past it.
    function _lengths() internal pure returns (uint256[15] memory) {
        return [uint256(1), 3, 4, 5, 31, 32, 33, 36, 64, 100, 131, 132, 133, 200, 1000];
    }

    /// @dev The config of a pool on ReasonRules, with the strict advisory when `advised`.
    function _reasonConfig(bool advised) internal view returns (HookrTypes.PoolConfig memory pc) {
        pc = _config(address(reasonRules));
        pc.caps = HookrTypes.Caps(100_000, 200_000, 1000);
        if (advised) {
            pc.advisory = address(advisory);
            pc.advisoryGasLimit = ADVISORY_GAS;
            pc.advisoryPhases = HookrTypes.BEFORE_SWAP | HookrTypes.AFTER_SWAP;
        }
    }

    function _initialize(int24 spacing, bool advised) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(root)
            .call(
                abi.encodeCall(
                    HookrRoot.initializePool, (_key(spacing), _reasonConfig(advised), bytes("r"), bytes(""), SQRT_ONE)
                )
            );
    }

    function _initialize(bool advised) internal returns (bool ok, bytes memory ret) {
        return _initialize(60, advised);
    }

    function _openReasonPool(bool advised) internal returns (PoolKey memory key) {
        key = _open(_reasonConfig(advised), bytes("r"), 60);
        _addLiquidity(key, -600, 600, 1e22);
    }

    /// @dev `ret` without its selector.
    function _body(bytes memory ret) internal pure returns (bytes memory body) {
        body = new bytes(ret.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = ret[i + 4];
        }
    }

    // ───────────────────────────── selectors ─────────────────────────────

    /// The two selectors, the library's copies of them and the cap. ModuleCallFailed keeps r31-final's selector.
    function test_errorSelectors() public pure {
        assertEq(IHookrRootEvents.ModuleCallFailed.selector, bytes4(0x66b1f70e), "ModuleCallFailed(address,bytes4)");
        assertEq(
            IHookrRootEvents.ModuleCallReverted.selector, bytes4(0xa3f86114), "ModuleCallReverted(address,bytes4,bytes)"
        );
        assertEq(IHookrRootEvents.ModuleCallFailed.selector, bytes4(keccak256("ModuleCallFailed(address,bytes4)")));
        assertEq(
            IHookrRootEvents.ModuleCallReverted.selector, bytes4(keccak256("ModuleCallReverted(address,bytes4,bytes)"))
        );
        assertEq(IHookrRootEvents.ModuleCallFailed.selector, IHookrRootEvents.ModuleCallFailed.selector);
        assertEq(IHookrRootEvents.ModuleCallReverted.selector, IHookrRootEvents.ModuleCallReverted.selector);
        assertEq(HookrRootStorage.MODULE_CALL_FAILED, IHookrRootEvents.ModuleCallFailed.selector);
        assertEq(HookrRootStorage.MODULE_CALL_REVERTED, IHookrRootEvents.ModuleCallReverted.selector);
        assertEq(HookrRootStorage.MAX_REASON, 4 + 4 * 32);
    }

    // ───────────────────────────── HookrLane: initialization ─────────────────────────────

    /// The cap: every reason up to 132 bytes arrives whole, every longer one cut to its first 132, its padding zero.
    function test_lane_bindReasonIsTheModulesOwnUpTo132Bytes() public {
        uint256[15] memory lengths = _lengths();
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory reason = _reason(lengths[i], bytes32(i));
            reasonRules.script(IHookrRules.bind.selector, Scripted.REVERT, reason);
            (bool ok, bytes memory ret) = _initialize(false);
            assertFalse(ok);
            assertEq(ret, _raised(address(reasonRules), IHookrRules.bind.selector, reason), "bind reason");
            assertEq(ret.length, 4 + 3 * 32 + 32 + ((_cut(reason).length + 31) / 32) * 32, "head, length, words");
        }
    }

    /// A 1,000-byte reason arrives as its first 132 bytes: the error is 292 bytes whatever the module sends, and decodes
    /// as (address, bytes4, bytes).
    function test_lane_aThousandByteReasonIsCut() public {
        bytes memory reason = _reason(1000, keccak256("long"));
        reasonRules.script(IHookrRules.bind.selector, Scripted.REVERT, reason);
        (bool ok, bytes memory ret) = _initialize(false);
        assertFalse(ok);
        assertEq(ret.length, 292);
        assertEq(bytes4(ret), IHookrRootEvents.ModuleCallReverted.selector);
        (address module, bytes4 selector, bytes memory cut) = abi.decode(_body(ret), (address, bytes4, bytes));
        assertEq(module, address(reasonRules));
        assertEq(selector, IHookrRules.bind.selector);
        assertEq(cut, _cut(reason));
        assertEq(cut.length, 132);
    }

    /// Every other call HookrLane requires at initialization: the removal lock, the advisory's bind and both schema
    /// reads.
    function test_lane_eachInitializationCallCarriesItsReason() public {
        bytes memory reason = abi.encodeWithSignature("Locked(uint256)", 7);
        reasonRules.script(IHookrRules.removalLockedUntil.selector, Scripted.REVERT, reason);
        (bool ok, bytes memory ret) = _initialize(false);
        assertFalse(ok);
        assertEq(ret, _raised(address(reasonRules), IHookrRules.removalLockedUntil.selector, reason), "lock");
        reasonRules.script(IHookrRules.removalLockedUntil.selector, Scripted.NONE, "");

        reason = abi.encodeWithSignature("Error(string)", "advisory refuses");
        advisory.script(IHookrAdvisory.bind.selector, Scripted.REVERT, reason);
        (ok, ret) = _initialize(true);
        assertFalse(ok);
        assertEq(ret, _raised(address(advisory), IHookrAdvisory.bind.selector, reason), "advisory bind");
        advisory.script(IHookrAdvisory.bind.selector, Scripted.NONE, "");

        reason = abi.encodeWithSignature("Panic(uint256)", 0x11);
        reasonRules.script(IHookrRules.configSchemaHash.selector, Scripted.REVERT, reason);
        (ok, ret) = _initialize(false);
        assertFalse(ok);
        assertEq(ret, _raised(address(reasonRules), IHookrRules.configSchemaHash.selector, reason), "rules schema");
        reasonRules.script(IHookrRules.configSchemaHash.selector, Scripted.NONE, "");

        advisory.script(IHookrAdvisory.configSchemaHash.selector, Scripted.REVERT, reason);
        (ok, ret) = _initialize(true);
        assertFalse(ok);
        assertEq(ret, _raised(address(advisory), IHookrAdvisory.configSchemaHash.selector, reason), "advisory schema");
        advisory.script(IHookrAdvisory.configSchemaHash.selector, Scripted.NONE, "");

        (ok,) = _initialize(true);
        assertTrue(ok, "healthy, the pool opens");
    }

    /// Empty data, running out of gas and an answer of the wrong length keep ModuleCallFailed, byte for byte.
    function test_lane_emptyOutOfGasAndMalformedKeepModuleCallFailed() public {
        bytes memory failed = abi.encodeWithSelector(
            IHookrRootEvents.ModuleCallFailed.selector, address(reasonRules), IHookrRules.bind.selector
        );
        reasonRules.script(IHookrRules.bind.selector, Scripted.REVERT, "");
        (bool ok, bytes memory ret) = _initialize(false);
        assertFalse(ok);
        assertEq(ret, failed, "empty revert");
        reasonRules.script(IHookrRules.bind.selector, Scripted.BURN, "");
        (ok, ret) = _initialize(false);
        assertFalse(ok);
        assertEq(ret, failed, "out of gas");
        reasonRules.script(IHookrRules.bind.selector, Scripted.LONG, "");
        (ok, ret) = _initialize(false);
        assertFalse(ok);
        assertEq(ret, failed, "33 bytes for 32");
        reasonRules.script(IHookrRules.bind.selector, Scripted.NONE, "");
        (ok,) = _initialize(false);
        assertTrue(ok, "healthy, the pool opens");
    }

    /// Arbitrary revert data from bind: the error is the compiler's encoding of the data cut to 132 bytes.
    function testFuzz_lane_bindReason(bytes calldata reason) public {
        reasonRules.script(IHookrRules.bind.selector, Scripted.REVERT, reason);
        (bool ok, bytes memory ret) = _initialize(false);
        assertFalse(ok);
        assertEq(ret, _raised(address(reasonRules), IHookrRules.bind.selector, reason));
    }

    // ───────────────────────────── HookrRoot: liquidity, swaps and the strict advisory ─────────────────────────────

    /// A liquidity refusal from the Rules or the strict advisory carries its reason; an answer of the wrong length keeps
    /// ModuleCallFailed.
    function test_root_beforeAddLiquidityReasons() public {
        PoolKey memory key = _openReasonPool(true);
        bytes memory reason = abi.encodeWithSignature("GuardLiquidity()");
        reasonRules.script(IHookrRules.beforeAddLiquidity.selector, Scripted.REVERT, reason);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeAddLiquidity.selector,
                _raised(address(reasonRules), IHookrRules.beforeAddLiquidity.selector, reason)
            )
        );
        _addLiquidity(key, -600, 600, 1e18);
        // One byte back where none is read.
        reasonRules.script(IHookrRules.beforeAddLiquidity.selector, Scripted.LONG, "");
        vm.expectRevert(
            _wrapped(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallFailed.selector,
                    address(reasonRules),
                    IHookrRules.beforeAddLiquidity.selector
                )
            )
        );
        _addLiquidity(key, -600, 600, 1e18);
        reasonRules.script(IHookrRules.beforeAddLiquidity.selector, Scripted.NONE, "");

        reason = abi.encodeWithSignature("NotListed(address)", address(this));
        advisory.script(IHookrAdvisory.beforeAddLiquidity.selector, Scripted.REVERT, reason);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeAddLiquidity.selector,
                _raised(address(advisory), IHookrAdvisory.beforeAddLiquidity.selector, reason)
            )
        );
        _addLiquidity(key, -600, 600, 1e18);
        advisory.script(IHookrAdvisory.beforeAddLiquidity.selector, Scripted.NONE, "");
        _addLiquidity(key, -600, 600, 1e18);
    }

    /// The Rules' swap calls, at every reason length; out of gas in settleSwap keeps ModuleCallFailed.
    function test_root_beforeSwapAndSettleSwapReasons() public {
        PoolKey memory key = _openReasonPool(false);
        uint256[15] memory lengths = _lengths();
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory reason = _reason(lengths[i], keccak256(abi.encode("swap", i)));
            reasonRules.script(IHookrRules.beforeSwap.selector, Scripted.REVERT, reason);
            vm.expectRevert(
                _wrapped(
                    IHooks.beforeSwap.selector, _raised(address(reasonRules), IHookrRules.beforeSwap.selector, reason)
                )
            );
            _genericSwap(key, true, -1e18, 0);
        }
        reasonRules.script(IHookrRules.beforeSwap.selector, Scripted.NONE, "");
        bytes memory guard = abi.encodeWithSignature("GuardBuyLimit(uint256,uint256)", 2e18, 1e18);
        reasonRules.script(IHookrRules.settleSwap.selector, Scripted.REVERT, guard);
        vm.expectRevert(
            _wrapped(IHooks.afterSwap.selector, _raised(address(reasonRules), IHookrRules.settleSwap.selector, guard))
        );
        _genericSwap(key, true, -1e18, 0);
        reasonRules.script(IHookrRules.settleSwap.selector, Scripted.BURN, "");
        vm.expectRevert(
            _wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallFailed.selector, address(reasonRules), IHookrRules.settleSwap.selector
                )
            )
        );
        _genericSwap(key, true, -1e18, 0);
        reasonRules.script(IHookrRules.settleSwap.selector, Scripted.NONE, "");
        _genericSwap(key, true, -1e18, 0);
    }

    /// Arbitrary revert data from the Rules' beforeSwap, through the PoolManager's wrapping.
    function testFuzz_root_beforeSwapReason(bytes calldata reason) public {
        PoolKey memory key = _openReasonPool(false);
        reasonRules.script(IHookrRules.beforeSwap.selector, Scripted.REVERT, reason);
        vm.expectRevert(
            _wrapped(IHooks.beforeSwap.selector, _raised(address(reasonRules), IHookrRules.beforeSwap.selector, reason))
        );
        _genericSwap(key, true, -1e18, 0);
    }

    /// A strict advisory: its reason surfaces from either phase; empty data, out of gas and a word the root refuses keep
    /// ModuleCallFailed.
    function test_root_strictAdvisoryReasons() public {
        PoolKey memory key = _openReasonPool(true);
        bytes memory closed = abi.encodeWithSignature("MarketClosed(uint256)", 1);
        advisory.script(IHookrAdvisory.beforeSwap.selector, Scripted.REVERT, closed);
        vm.expectRevert(
            _wrapped(IHooks.beforeSwap.selector, _raised(address(advisory), IHookrAdvisory.beforeSwap.selector, closed))
        );
        _genericSwap(key, true, -1e18, 0);
        bytes memory failed = abi.encodeWithSelector(
            IHookrRootEvents.ModuleCallFailed.selector, address(advisory), IHookrAdvisory.beforeSwap.selector
        );
        uint8[3] memory opaque = [Scripted.REVERT, Scripted.BURN, Scripted.OUT_OF_RANGE];
        for (uint256 i; i < opaque.length; ++i) {
            advisory.script(IHookrAdvisory.beforeSwap.selector, opaque[i], "");
            vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, failed));
            _genericSwap(key, true, -1e18, 0);
        }
        advisory.script(IHookrAdvisory.beforeSwap.selector, Scripted.NONE, "");
        bytes memory late = _reason(500, keccak256("late"));
        advisory.script(IHookrAdvisory.afterSwap.selector, Scripted.REVERT, late);
        vm.expectRevert(
            _wrapped(IHooks.afterSwap.selector, _raised(address(advisory), IHookrAdvisory.afterSwap.selector, late))
        );
        _genericSwap(key, true, -1e18, 0);
        advisory.script(IHookrAdvisory.afterSwap.selector, Scripted.OUT_OF_RANGE, "");
        vm.expectRevert(
            _wrapped(
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallFailed.selector, address(advisory), IHookrAdvisory.afterSwap.selector
                )
            )
        );
        _genericSwap(key, true, -1e18, 0);
        advisory.script(IHookrAdvisory.afterSwap.selector, Scripted.NONE, "");
        _genericSwap(key, true, -1e18, 0);
    }

    // ───────────────────────────── imitation ─────────────────────────────

    /// A module that reverts with the root's own errors, a nested ModuleCallReverted, the simulation's 132-byte
    /// SwapSimulated or the PoolManager's WrappedError is wrapped like any other reason: the root never re-throws it as
    /// its own, and `module` names the module that reverted.
    function test_aReasonThatImitatesARootErrorIsWrapped() public {
        bytes[6] memory imitations = [
            abi.encodeWithSelector(IHookrRootState.SwapRejected.selector),
            abi.encodeWithSelector(IHookrRootEvents.ModuleCallFailed.selector, address(0xBAD), bytes4(0xdeadbeef)),
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector, address(0xBAD), bytes4(0xdeadbeef), bytes("x")
            ),
            abi.encodeWithSelector(IHookrRootState.SwapSimulated.selector, uint160(1), int24(2), uint160(3), int24(4)),
            abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(root)),
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector, address(root), IHooks.beforeSwap.selector, bytes(""), bytes("")
            )
        ];
        assertEq(imitations[3].length, 132, "SwapSimulated is exactly the cap");
        PoolKey memory key = _openReasonPool(false);
        for (uint256 i; i < imitations.length; ++i) {
            bytes memory imitation = imitations[i];
            reasonRules.script(IHookrRules.bind.selector, Scripted.REVERT, imitation);
            (bool ok, bytes memory ret) = _initialize(10, false);
            assertFalse(ok);
            assertEq(bytes4(ret), IHookrRootEvents.ModuleCallReverted.selector, "bind: wrapped");
            assertEq(ret, _raised(address(reasonRules), IHookrRules.bind.selector, imitation), "bind: exact");
            reasonRules.script(IHookrRules.beforeSwap.selector, Scripted.REVERT, imitation);
            vm.expectRevert(
                _wrapped(
                    IHooks.beforeSwap.selector,
                    _raised(address(reasonRules), IHookrRules.beforeSwap.selector, imitation)
                )
            );
            _genericSwap(key, true, -1e18, 0);
        }
    }
}
