// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {CyclingExecutor} from "../fixtures/CyclingExecutor.sol";
import {PushExecutor} from "../fixtures/PushExecutor.sol";
import {ExecutorAdmission} from "../kit/ExecutorAdmission.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";

/// @notice An executor whose runtime code never changes but whose behaviour does: every call is DELEGATECALLed to an
///         implementation its owner can repoint at any time. The registry pins only the proxy's codehash.
contract ProxyExecutor {
    address public owner;
    address public impl;

    constructor(address _impl) {
        owner = msg.sender;
        impl = _impl;
    }

    function upgrade(address next) external {
        require(msg.sender == owner, "owner");
        impl = next;
    }

    fallback() external payable {
        address i = impl;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), i, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    receive() external payable {}
}

/// @notice The implementation swapped in later: burns every unit of the grant it gets (any behaviour would do).
contract BurnImpl {
    function executeArbitrage(PoolKey calldata, address) external pure returns (uint256) {
        uint256 i;
        while (true) {
            unchecked {
                ++i;
            }
        }
        return i;
    }
}

/// @notice ATK-EX-3 (codehash drift). The lane's on-chain pin is the executor's runtime codehash, and the registry
///         refuses an EIP-7702 delegated executor because its code can be re-pointed. A DELEGATECALL proxy passes the
///         pin and can be re-pointed by its owner with no timelock: pinned here as the on-chain known limit. The fix is
///         the release-manifest admission scan (test/kit/ExecutorAdmission.sol), which Rehearse.s.sol runs
///         before OPEN_LANE is queued: it refuses the proxy and passes the stand-in executors.
contract ExecutorCodeDriftTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;

    ProxyExecutor internal proxy;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        /// @dev The implementation reviewed at opening returns at once.
        proxy = new ProxyExecutor(address(new MockIdleExecutor()));
        _openLane(address(proxy), 3_000_000);
        (, key) = _one(_newSubject(), true, false, 0);
        _nextBlock();
    }

    function test_pinned_proxyExecutorPassesTheOnChainPin_andItsOwnerSwapsBehaviourWithoutTheTimelock() public {
        (address executor, bytes32 codeHash,,, bool on, uint32 cap,) = IHookrLaneRoot(address(root)).laneOf(key.toId());
        assertEq(executor, address(proxy));
        assertEq(codeHash, address(proxy).codehash, "the pin is the proxy's code");
        assertTrue(on);

        vm.recordLogs();
        _sell(key, ETH, whale, 1e18);
        uint256 idleGas = vm.lastCallGas().gasTotalUsed;
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "the reviewed implementation runs");

        // The proxy's owner repoints it: no registry operation, no delay, no brake involved.
        proxy.upgrade(address(new BurnImpl()));
        assertEq(address(proxy).codehash, codeHash, "the runtime codehash is unchanged");

        vm.recordLogs();
        _sell(key, ETH, whale, 1e18);
        uint256 burnGas = vm.lastCallGas().gasTotalUsed;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        o = _outcome(logs);
        bytes32 codeChanged = keccak256("LaneCodeChanged(bytes32,uint8)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != codeChanged, "no LaneCodeChanged");
        }
        assertEq(o.failed, 2, "the new implementation ran in both phases");
        console2.log("cap; sell gas with the reviewed impl, after the owner's swap", cap, idleGas, burnGas);
        assertGt(burnGas, idleGas + 5_000_000, "every trader now pays for the swapped-in behaviour");
    }
}

/// @notice A contract that SELFDESTRUCTs on call: refused by the admission scan.
contract SelfdestructExecutor {
    function executeArbitrage(PoolKey calldata, address) external returns (uint256) {
        selfdestruct(payable(msg.sender));
    }
}

/// @dev Writes slot 0 of whoever DELEGATECALLs it.
contract SlotSetter {
    fallback() external {
        assembly ("memory-safe") {
            sstore(0, 1)
        }
    }
}

/// @notice ATK-EX-3 regression: the release-manifest admission scan refuses every executor whose code can change what
///         runs (DELEGATECALL, CALLCODE, SELFDESTRUCT), skips PUSH data and a solc metadata tail no instruction can
///         reach, and passes the stand-in executors the suites and the fork rehearsal open the lane for. VERIFY-3:
///         it once trusted the trailing length and left out whatever tail it pointed at, so hand-built code there ran
///         unscanned. A JUMPDEST in a sealed solc tail does not make it read the whole tail, the digest bytes before
///         that JUMPDEST included, which no execution reaches: it reads such a tail from its first JUMPDEST on, and the
///         stand-in CyclingExecutor with a digest that holds a CALLCODE byte before a JUMPDEST byte passes.
contract ExecutorAdmissionTest is LaneRootFixture {
    function setUp() public {
        _setUpLane();
    }

    function scanOf(bytes memory code) external pure returns (uint256, uint8) {
        return ExecutorAdmission.scan(code);
    }

    function checkOf(address executor) external view {
        ExecutorAdmission.check(executor);
    }

    /// @dev `check` for a stand-in this test deployed from this build: its own solc metadata tail is left out.
    function checkOwnBuildOf(address executor, string memory artifact) external view {
        (uint256 offset, uint8 opcode) = ExecutorAdmission.scanOwnBuild(executor.code, vm.getDeployedCode(artifact));
        if (opcode != 0) revert ExecutorAdmission.MutableExecutor(executor, offset, opcode);
    }

    function test_regression_theAdmissionScanRefusesTheProxy() public {
        ProxyExecutor proxy = new ProxyExecutor(address(new MockIdleExecutor()));
        (uint256 offset, uint8 op) = ExecutorAdmission.scan(address(proxy).code);
        assertEq(op, ExecutorAdmission.DELEGATECALL, "the proxy's DELEGATECALL is found");
        console2.log("proxy: DELEGATECALL at byte", offset);
        vm.expectRevert(
            abi.encodeWithSelector(ExecutorAdmission.MutableExecutor.selector, address(proxy), offset, uint8(0xf4))
        );
        this.checkOf(address(proxy));
        (, op) = ExecutorAdmission.scan(address(new SelfdestructExecutor()).code);
        assertEq(op, ExecutorAdmission.SELFDESTRUCT, "SELFDESTRUCT is found");
        vm.expectRevert(abi.encodeWithSelector(ExecutorAdmission.MutableExecutor.selector, address(0xdead), 0, 0));
        this.checkOf(address(0xdead));
    }

    /// The executors the suites and the fork rehearsal open the lane for, as this build compiles them: both rehearsal
    /// stand-ins (CyclingExecutor at WTH's 25%, PushExecutor), the two-venue executor and the idle mock. Each is this
    /// build's own code, so its solc metadata tail is left out (scanOwnBuild) and every instruction before it is read:
    /// a byte of a digest, which moves with any edit to a source the contract compiles with, cannot fail it.
    function test_regression_theStandInExecutorsPass() public {
        this.checkOwnBuildOf(
            address(new CyclingExecutor(manager, address(root), partner)), "CyclingExecutor.sol:CyclingExecutor"
        );
        this.checkOwnBuildOf(
            address(new PushExecutor(manager, address(root), address(this))), "PushExecutor.sol:PushExecutor"
        );
        this.checkOwnBuildOf(address(_twoVenueExecutor(1e24)), "TwoVenueExecutor.sol:TwoVenueExecutor");
        this.checkOwnBuildOf(address(new MockIdleExecutor()), "MockIdleExecutor.sol:MockIdleExecutor");
    }

    /// scanOwnBuild leaves out only a tail equal to the build's: a stand-in whose tail differs from the artifact's, or
    /// whose length does, is read whole, as scan reads it.
    function test_scanOwnBuild_leavesOutOnlyTheBuildsOwnTail() public view {
        // CALLER, INVALID, then solc's exact tail with a JUMPDEST and a CALLCODE in its digest.
        bytes memory code = bytes.concat(
            hex"33fea2646970667358221220", bytes32(uint256(0x5bf2) << 240), hex"64736f6c6343080025", hex"0033"
        );
        (uint256 offset, uint8 op) = this.scanOf(code);
        assertEq(op, ExecutorAdmission.CALLCODE, "scan reads the tail from its JUMPDEST on");
        assertEq(offset, 13);
        (, op) = this.scanOwnBuildOf(code, code);
        assertEq(op, 0, "the build's own tail is left out");
        bytes memory other = bytes.concat(code);
        other[other.length - 3] = 0x26;
        (, op) = this.scanOwnBuildOf(code, other);
        assertEq(op, ExecutorAdmission.CALLCODE, "another build's tail is read");
        (, op) = this.scanOwnBuildOf(code, bytes.concat(code, hex"00"));
        assertEq(op, ExecutorAdmission.CALLCODE, "another length is read");
        // The code before the tail is always read.
        bytes memory early = bytes.concat(hex"f4", code);
        (offset, op) = this.scanOwnBuildOf(early, early);
        assertEq(op, ExecutorAdmission.DELEGATECALL);
        assertEq(offset, 0);
    }

    function scanOwnBuildOf(bytes memory code, bytes memory built) external pure returns (uint256, uint8) {
        return ExecutorAdmission.scanOwnBuild(code, built);
    }

    function test_scan_readsInstructionsNotData() public view {
        // PUSH4 0xf4f4f4f4, STOP: the bytes are PUSH data.
        (, uint8 op) = this.scanOf(hex"63f4f4f4f400");
        assertEq(op, 0);
        // CALLER, CALLCODE.
        (uint256 offset, uint8 op2) = this.scanOf(hex"33f2");
        assertEq(op2, ExecutorAdmission.CALLCODE);
        assertEq(offset, 1);
        // STOP, then a two-byte "map" holding 0xff and a length pointing at it: not solc's layout, so it is read.
        (uint256 at3, uint8 op3) = this.scanOf(hex"00a1ff0002");
        assertEq(op3, ExecutorAdmission.SELFDESTRUCT);
        assertEq(at3, 2);
    }

    /// @dev Deploys `runtime` as is and returns its address.
    function _deploy(bytes memory runtime) internal returns (address deployed) {
        // PUSH2 len, DUP1, PUSH1 12, PUSH1 0, CODECOPY, PUSH1 0, RETURN, then the runtime.
        bytes memory init = abi.encodePacked(hex"61", uint16(runtime.length), hex"80600c6000396000f3", runtime);
        assembly ("memory-safe") {
            deployed := create(0, add(init, 32), mload(init))
        }
        assertEq(keccak256(deployed.code), keccak256(runtime), "deployed as crafted");
    }

    /// @dev solc's 53-byte metadata tail around a 32-byte digest.
    function _solcTail(bytes32 digest) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"a2646970667358221220", digest, hex"64736f6c6343000825", hex"0033");
    }

    /// @dev Whether `code` ends in solc's layout: every byte but the digest's and the version's matches.
    function _isSolcTail(bytes memory code) internal pure returns (bool) {
        if (code.length <= 53) return false;
        bytes memory tail = new bytes(53);
        for (uint256 i; i < 53; ++i) {
            if ((i < 10 || i >= 42) && (i < 48 || i >= 51)) tail[i] = code[code.length - 53 + i];
        }
        return keccak256(tail)
            == keccak256(abi.encodePacked(hex"a2646970667358221220", bytes32(0), hex"64736f6c6343000000", hex"0033"));
    }

    /// VERIFY-3: a fake trailing length (0x0022) pointing at a 0xa2 byte the code jumps over hid a reachable
    /// DELEGATECALL. The tail is not solc's layout, so every instruction is read.
    function test_regression_aFakeMetadataLengthNoLongerHidesADelegatecall() public {
        SlotSetter target = new SlotSetter();
        // 0: PUSH1 4  2: JUMP  3: 0xa2 (jumped over)  4: JUMPDEST  5-12: four PUSH1 0  13: PUSH20 target  34: GAS
        // 35: DELEGATECALL  36: STOP  37-38: 0x0022.
        bytes memory code = abi.encodePacked(hex"600456a25b600060006000600073", address(target), hex"5af4000022");
        (uint256 offset, uint8 op) = this.scanOf(code);
        assertEq(op, ExecutorAdmission.DELEGATECALL, "the DELEGATECALL is found");
        assertEq(offset, 35);
        address deployed = _deploy(code);
        (bool ok,) = deployed.call("");
        assertTrue(ok);
        assertEq(uint256(vm.load(deployed, bytes32(0))), 1, "and it is the one that runs");
        vm.expectRevert(abi.encodeWithSelector(ExecutorAdmission.MutableExecutor.selector, deployed, 35, uint8(0xf4)));
        this.checkOf(deployed);
    }

    /// VERIFY-3, with solc's exact layout: the digest holds a JUMPDEST the code jumps to and a DELEGATECALL after it.
    /// A tail a jump can land in is read.
    function test_regression_aSolcShapedTailAJumpLandsInIsRead() public {
        SlotSetter target = new SlotSetter();
        // 0: PUSH1 14  2: JUMP  3: INVALID  4: the tail. Its digest (14-45): JUMPDEST, four PUSH0, PUSH20 target, GAS,
        // DELEGATECALL (41), STOP and padding.
        bytes32 digest = bytes32(abi.encodePacked(hex"5b5f5f5f5f73", address(target), hex"5af400000000"));
        bytes memory code = abi.encodePacked(hex"600e56fe", _solcTail(digest));
        assertTrue(_isSolcTail(code), "solc's layout");
        (uint256 offset, uint8 op) = this.scanOf(code);
        assertEq(op, ExecutorAdmission.DELEGATECALL, "the DELEGATECALL in the digest is found");
        assertEq(offset, 41);
        address deployed = _deploy(code);
        (bool ok,) = deployed.call("");
        assertTrue(ok);
        assertEq(uint256(vm.load(deployed, bytes32(0))), 1, "and it runs");
    }

    /// An EIP-7702 delegated account runs its delegate's code, which the scan never sees: refused by its 0xef prefix,
    /// which no contract's code has.
    function test_scan_refusesADelegatedAccount() public {
        bytes memory designator = abi.encodePacked(hex"ef0100", address(new MockIdleExecutor()));
        (uint256 offset, uint8 op) = this.scanOf(designator);
        assertEq(op, ExecutorAdmission.DELEGATED);
        assertEq(offset, 0);
        address delegated = makeAddr("delegated");
        vm.etch(delegated, designator);
        vm.expectRevert(abi.encodeWithSelector(ExecutorAdmission.MutableExecutor.selector, delegated, 0, uint8(0xef)));
        this.checkOf(delegated);
    }

    /// A solc tail no instruction reaches is left out, whatever its digest holds; the same tail after an instruction
    /// that falls through is read.
    function test_scan_leavesOutOnlyAnUnreachableSolcTail() public {
        bytes32 digest = 0xf4f2ff00f4f2ff00f4f2ff00f4f2ff00f4f2ff00f4f2ff00f4f2ff00f4f2ff00;
        (, uint8 op) = this.scanOf(abi.encodePacked(hex"00fe", _solcTail(digest)));
        assertEq(op, 0, "after INVALID, with no JUMPDEST in it: metadata");
        (uint256 offset, uint8 op2) = this.scanOf(abi.encodePacked(hex"0001", _solcTail(digest)));
        assertEq(op2, ExecutorAdmission.DELEGATECALL, "after ADD, which falls through: read");
        assertEq(offset, 2 + 10);
        // A genuine build: its own metadata is left out.
        bytes memory idle = address(new MockIdleExecutor()).code;
        assertTrue(_isSolcTail(idle));
        (, uint8 op3) = this.scanOf(idle);
        assertEq(op3, 0);
    }

    /// @dev The linear decoding of `code` from byte 0: whether an instruction starts at each byte.
    function _starts(bytes memory code) internal pure returns (bool[] memory starts) {
        starts = new bool[](code.length);
        uint256 i;
        while (i < code.length) {
            starts[i] = true;
            uint8 op = uint8(code[i]);
            i += op >= 0x60 && op <= 0x7f ? op - 0x5e : 1;
        }
    }

    /// @dev STOP, JUMP, RETURN, REVERT, INVALID.
    function _halts(uint8 op) internal pure returns (bool) {
        return op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe;
    }

    function _mutable(uint8 op) internal pure returns (bool) {
        return op == 0xf2 || op == 0xf4 || op == 0xff;
    }

    /// @dev The reference model of the instructions that can run: every instruction before the solc tail (or of the
    ///      whole code when there is none) and, in the tail, (a) all of them when the last instruction before it does
    ///      not halt, (b) every one from a JUMPDEST of the tail on. Returns the first DELEGATECALL, CALLCODE or
    ///      SELFDESTRUCT among them, as `scan` does. With `exact`, the tail's instructions are instead those execution
    ///      reaches: a JUMPDEST, or the instruction after a reached one that does not halt (a finer set, inside the
    ///      first).
    function _reference(bytes memory code, bool exact) internal pure returns (uint256, uint8) {
        uint256 n = code.length;
        if (n != 0 && uint8(code[0]) == 0xef) return (0, 0xef);
        uint256 tail = _isSolcTail(code) ? n - 53 : n;
        bool[] memory starts = _starts(code);
        bool entered;
        bool live;
        bool prevReached = true;
        uint8 prev;
        for (uint256 i; i < n; ++i) {
            if (!starts[i]) continue;
            uint8 op = uint8(code[i]);
            bool reached = true;
            if (i >= tail) {
                if (exact) {
                    reached = op == 0x5b || (prevReached && !_halts(prev));
                } else {
                    if (!entered) (entered, live) = (true, !_halts(prev));
                    if (op == 0x5b) live = true;
                    reached = live;
                }
            }
            if (reached && _mutable(op)) return (i, op);
            (prev, prevReached) = (op, reached);
        }
        return (type(uint256).max, 0);
    }

    /// A sealed solc tail whose digest holds CALLCODE, DELEGATECALL and SELFDESTRUCT bytes before a JUMPDEST byte
    /// passes. No execution reaches those bytes: the INVALID before the tail never falls into it, and a jump can only
    /// land on the JUMPDEST and run forward from there. It reads the tail from the JUMPDEST on, not the whole tail.
    function test_scan_aSealedTailsDigestBeforeItsJumpdestIsLeftOut() public view {
        // The digest: CALLCODE, DELEGATECALL, SELFDESTRUCT, zeros, JUMPDEST last. After it: PUSH5 "solc" 43, the
        // version 00 08 25, and 00 33, none of them mutable.
        bytes32 digest = bytes32(abi.encodePacked(hex"f2f4ff", bytes28(0), hex"5b"));
        bytes memory code = abi.encodePacked(hex"00fe", _solcTail(digest));
        assertTrue(_isSolcTail(code));
        bool[] memory starts = _starts(code);
        assertTrue(starts[12] && starts[13] && starts[14] && starts[43], "each byte is an instruction");
        (uint256 offset, uint8 op) = this.scanOf(code);
        assertEq(op, 0, "left out");
        assertEq(offset, type(uint256).max);
        // The same digest after STOP, JUMP, RETURN or REVERT as well.
        bytes memory sealers = hex"0056f3fd";
        for (uint256 k; k < sealers.length; ++k) {
            (, op) = this.scanOf(abi.encodePacked(hex"00", sealers[k], _solcTail(digest)));
            assertEq(op, 0, "sealed");
        }
    }

    /// In a sealed tail, a mutable instruction after the tail's first JUMPDEST is refused at its offset, and the
    /// one before that JUMPDEST is not: the jump lands on the JUMPDEST and runs the DELEGATECALL after it.
    function test_scan_aMutableInstructionAfterATailJumpdestIsRefusedAtItsOffset() public {
        SlotSetter target = new SlotSetter();
        // 0: PUSH1 15  2: JUMP  3: INVALID  4: the tail. Its digest (14-45): DELEGATECALL (14, never reached),
        // JUMPDEST (15), four PUSH0, PUSH20 target, GAS, DELEGATECALL (42), STOP and padding.
        bytes32 digest = bytes32(abi.encodePacked(hex"f45b5f5f5f5f73", address(target), hex"5af4000000"));
        bytes memory code = abi.encodePacked(hex"600f56fe", _solcTail(digest));
        assertTrue(_isSolcTail(code));
        assertTrue(_starts(code)[14], "the first DELEGATECALL byte is an instruction");
        (uint256 offset, uint8 op) = this.scanOf(code);
        assertEq(op, ExecutorAdmission.DELEGATECALL);
        assertEq(offset, 42, "the one after the JUMPDEST");
        address deployed = _deploy(code);
        (bool ok,) = deployed.call("");
        assertTrue(ok);
        assertEq(uint256(vm.load(deployed, bytes32(0))), 1, "and it runs");
        vm.expectRevert(abi.encodeWithSelector(ExecutorAdmission.MutableExecutor.selector, deployed, 42, uint8(0xf4)));
        this.checkOf(deployed);
        // A later JUMPDEST does not hide an earlier one: the scan reads from the first.
        digest = bytes32(abi.encodePacked(hex"005bff005b", bytes27(0)));
        (offset, op) = this.scanOf(abi.encodePacked(hex"00fe", _solcTail(digest)));
        assertEq(op, ExecutorAdmission.SELFDESTRUCT);
        assertEq(offset, 2 + 10 + 2);
    }

    /// A tail the instruction before it falls into is read whole, whichever byte of it is mutable, a JUMPDEST in
    /// it or not. A PUSH whose data ends right before the tail leaves no instruction at that byte and falls through.
    function test_scan_anUnsealedTailIsReadWhole() public view {
        bytes memory mut = hex"f2f4ff";
        for (uint256 m; m < mut.length; ++m) {
            // At the digest's first byte, at its middle, and at its last, with a JUMPDEST after it or none.
            uint256[3] memory offsets = [uint256(0), 16, 31];
            for (uint256 k; k < offsets.length; ++k) {
                bytes memory d = new bytes(32);
                d[offsets[k]] = mut[m];
                if (offsets[k] < 31) d[31] = 0x5b;
                // ADD, then PUSH1 0, then CALLER: each falls through.
                for (uint256 b; b < 3; ++b) {
                    bytes memory prefix = b == 0 ? bytes(hex"0001") : b == 1 ? bytes(hex"006000") : bytes(hex"0033");
                    bytes memory code = abi.encodePacked(prefix, _solcTail(bytes32(d)));
                    (uint256 off, uint8 op) = this.scanOf(code);
                    assertEq(op, uint8(mut[m]), "read");
                    assertEq(off, prefix.length + 10 + offsets[k]);
                }
            }
        }
    }

    /// The tail's instructions are those of the linear decoding from byte 0. A PUSH3 before the tail carries its
    /// first three bytes, so the tail decodes as PUSH17 at its fourth and a DELEGATECALL byte at the digest's sixth is
    /// PUSH data, never run; the SELFDESTRUCT at the digest's twelfth is an instruction and is refused. The same tail
    /// after ADD decodes from its start and the DELEGATECALL byte is an instruction.
    function test_scan_aPushIntoTheTailKeepsTheLinearDecoding() public {
        bytes32 digest = bytes32(abi.encodePacked(hex"0000000000f40000000000ff", bytes20(0)));
        (uint256 offset, uint8 op) = this.scanOf(abi.encodePacked(hex"0062", _solcTail(digest)));
        assertEq(op, ExecutorAdmission.SELFDESTRUCT, "the DELEGATECALL byte is PUSH17 data");
        assertEq(offset, 2 + 10 + 11);
        (offset, op) = this.scanOf(abi.encodePacked(hex"0001", _solcTail(digest)));
        assertEq(op, ExecutorAdmission.DELEGATECALL, "decoded from the tail's start");
        assertEq(offset, 2 + 10 + 5);
        // In a sealed tail, a JUMPDEST byte that is PUSH data is no landing: the DELEGATECALL byte after it is left
        // out, and a jump to it fails.
        digest = bytes32(abi.encodePacked(hex"605bf4", bytes29(0)));
        bytes memory code = abi.encodePacked(hex"600f56fe", _solcTail(digest));
        (, op) = this.scanOf(code);
        assertEq(op, 0, "no JUMPDEST in the tail's decoding");
        (bool ok,) = _deploy(code).call{gas: 100_000}("");
        assertFalse(ok, "a jump to PUSH data is invalid");
    }

    /// Code starting with 0xef is refused at byte 0 whatever follows, a sealed solc tail included.
    function test_scan_refusesTheDelegatedPrefixWithATail() public view {
        (uint256 offset, uint8 op) = this.scanOf(abi.encodePacked(hex"ef00fe", _solcTail(bytes32(0))));
        assertEq(op, ExecutorAdmission.DELEGATED);
        assertEq(offset, 0);
        (offset, op) = this.scanOf(hex"ef");
        assertEq(op, ExecutorAdmission.DELEGATED);
        assertEq(offset, 0);
    }

    /// `scan` equals the reference model of the instructions that can run on random bytecode, most of it ending in
    /// a solc-shaped tail, and refuses the code at or before the first mutable instruction execution can reach.
    /// forge-config: default.fuzz.runs = 4096
    function testFuzz_scan_equalsTheReachabilityModel(uint256 seed) public view {
        bytes memory code = _randomCode(seed);
        (uint256 offset, uint8 op) = this.scanOf(code);
        (uint256 refAt, uint8 refOp) = _reference(code, false);
        assertEq(op, refOp, "opcode");
        assertEq(offset, refAt, "offset");
        (uint256 exactAt, uint8 exactOp) = _reference(code, true);
        if (exactOp != 0) {
            assertTrue(op != 0, "nothing that runs is hidden");
            assertLe(offset, exactAt);
        }
    }

    /// @dev Random bytecode biased to the bytes that matter: halting, PUSH, JUMPDEST and mutable opcodes. Seven times in
    ///      eight it ends in solc's layout around a random digest and version; otherwise the layout is broken or absent.
    function _randomCode(uint256 seed) internal pure returns (bytes memory code) {
        bytes memory alphabet = hex"0001335657585b5f60616270737f7ff2f3f4fdfeffef";
        uint256 r = uint256(keccak256(abi.encode(seed)));
        uint256 len = 1 + r % 48;
        uint256 shape = (r >> 8) % 8;
        bytes memory prefix = new bytes(len);
        bytes32 digest;
        bytes3 version;
        for (uint256 i; i < len + 35; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            bytes1 b = x % 4 == 0 ? bytes1(uint8(x >> 8)) : alphabet[(x >> 8) % alphabet.length];
            if (i < len) prefix[i] = b;
            else if (i < len + 32) digest |= bytes32(b) >> (8 * (i - len));
            else version |= bytes3(b) >> (8 * (i - len - 32));
        }
        code = abi.encodePacked(prefix, hex"a2646970667358221220", digest, hex"64736f6c6343", version, hex"0033");
        if (shape == 0) code[len] = 0xa1;
        if (shape == 1) code = prefix;
    }

    /// The stand-in CyclingExecutor as this build compiles it, with its metadata digest replaced by one whose tenth
    /// byte is CALLCODE and whose last byte is a JUMPDEST, both instructions of the linear decoding (the shape a
    /// package build of the stand-in once had: CALLCODE at the tail's byte 19, JUMPDEST at its byte 41). The INVALID
    /// before the tail seals it, so the CALLCODE byte never runs: the executor passes, where a scan of the whole tail
    /// would refuse it. The digest is set here, not taken from a build, so the case holds for every build of the
    /// stand-in; the same tail after an instruction that falls through is refused at the CALLCODE.
    function test_regression_theStandInWithACallcodeInItsDigestPasses() public {
        bytes memory code = address(new CyclingExecutor(manager, address(root), partner)).code;
        assertTrue(_isSolcTail(code), "built with metadata");
        (, uint8 op) = this.scanOf(code);
        assertEq(op, 0, "this build passes");
        uint256 tail = code.length - 53;
        assertEq(uint8(code[tail - 1]), 0xfe, "INVALID before the tail");
        bytes32 digest = bytes32(abi.encodePacked(bytes9(0), hex"f2", bytes21(0), hex"5b"));
        for (uint256 i; i < 32; ++i) {
            code[tail + 10 + i] = digest[i];
        }
        assertTrue(_isSolcTail(code));
        uint256 callcodeAt = tail + 10 + 9;
        uint256 jumpdestAt = tail + 10 + 31;
        bool[] memory starts = _starts(code);
        assertTrue(starts[tail - 1], "the INVALID is an instruction");
        assertTrue(starts[callcodeAt] && uint8(code[callcodeAt]) == 0xf2, "CALLCODE instruction in the digest");
        assertTrue(starts[jumpdestAt] && uint8(code[jumpdestAt]) == 0x5b, "JUMPDEST instruction in the digest");
        (uint256 offset, uint8 op2) = this.scanOf(code);
        assertEq(op2, 0, "passes");
        assertEq(offset, type(uint256).max);
        (uint256 refAt, uint8 refOp) = _reference(code, false);
        assertEq(refOp, 0);
        assertEq(refAt, type(uint256).max);
        address deployed = makeAddr("stand-in with a CALLCODE in its digest");
        vm.etch(deployed, code);
        this.checkOf(deployed);
        // Unsealed (the INVALID turned into a JUMPDEST, which falls through), the same tail is read and refused.
        code[tail - 1] = 0x5b;
        (offset, op2) = this.scanOf(code);
        assertEq(op2, ExecutorAdmission.CALLCODE, "read whole once unsealed");
        assertEq(offset, callcodeAt);
    }
}
