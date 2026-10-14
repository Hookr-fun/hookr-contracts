// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

//  H   H   OOO    OOO   K   K  RRRR
//  H   H  O   O  O   O  K  K   R   R
//  HHHHH  O   O  O   O  KKK    RRRR
//  H   H  O   O  O   O  K  K   R  R
//  H   H   OOO    OOO   K   K  R   R

/// @title ExecutorAdmission
/// @notice The release-manifest check a recapture executor passes before its `OPEN_LANE` is queued. The registry pins
///         the executor's runtime codehash, which does not cover code the executor reaches through a pointer it can
///         change: a DELEGATECALL proxy keeps its codehash while its owner swaps what runs. This check refuses
///         DELEGATECALL, CALLCODE and SELFDESTRUCT in any instruction of the executor's runtime that can run, and an
///         EIP-7702 delegated account.
/// @dev What it proves: no instruction the EVM can execute in the executor's runtime is DELEGATECALL, CALLCODE or
///      SELFDESTRUCT. The EVM executes only the instructions of the runtime's linear decoding from byte 0 (PUSH data
///      never runs): it starts at byte 0, falls through from one instruction to the next, and jumps only to a
///      JUMPDEST that starts one of them. The scan reads every instruction of that decoding except some in one
///      trailing tail with solc's exact metadata layout (bytecode_hash = ipfs: the CBOR map
///      `a2 64 "ipfs" 58 22 1220 <digest> 64 "solc" 43 <version>` and its length 0x0033, 53 bytes in all). An
///      instruction in that tail can run only (a) from the tail's start, when the instruction before the tail can
///      fall through into it, or (b) from the tail's first JUMPDEST onward, where a jump can land and run forward.
///      So when the instruction before the tail cannot fall through (STOP, JUMP, RETURN, REVERT or INVALID; solc
///      places INVALID there), the scan leaves out the tail's instructions before its first JUMPDEST, which no
///      execution reaches, and reads every one from that JUMPDEST on; otherwise it reads the whole tail. The tail's
///      instructions and its JUMPDEST are those of the linear decoding from byte 0: a PUSH before the tail keeps
///      the data it carries into it, and a tail whose previous byte starts no instruction (PUSH data ends there or
///      runs on) counts as reached from its start. The trailing length alone is never trusted. Every other byte is
///      read as an instruction: data after the code, a tail of any other shape, and a solc-shaped tail after a PUSH
///      or an instruction that falls through. A digest byte read as an instruction can raise a false alarm, which
///      a human reviews against the verified source; no byte left out can run. Code starting with 0xef is refused:
///      no contract's code does (EIP-3541), and an EIP-7702 delegated account's (0xef0100 and an address) runs the
///      delegate's code, which the scan never sees.
///      What it does not prove: that the executor's behaviour is fixed or safe. It does not see a CALL to an address
///      the owner can set (a venue list, a strategy, a router), what the contracts the executor calls or creates do,
///      that a JUMPDEST in the tail is ever jumped to (a digest byte after one can still raise a false alarm), or
///      that the tail is the metadata of the verified source (its digest and version are not checked).
///      The review compares the runtime with a build of the verified source and bounds in code how venues are
///      chosen. A DELEGATECALL to an immutable library is refused too and cleared by that review.
library ExecutorAdmission {
    error MutableExecutor(address executor, uint256 offset, uint8 opcode);

    uint8 internal constant CALLCODE = 0xf2;
    uint8 internal constant DELEGATECALL = 0xf4;
    uint8 internal constant SELFDESTRUCT = 0xff;
    /// @dev The first byte of an EIP-7702 delegation designator.
    uint8 internal constant DELEGATED = 0xef;
    uint8 private constant JUMPDEST = 0x5b;
    /// @dev solc's metadata tail with bytecode_hash = ipfs: the 51-byte CBOR map and its two-byte length.
    uint256 internal constant SOLC_TAIL = 53;

    /// @notice The offset and opcode of the first DELEGATECALL, CALLCODE or SELFDESTRUCT among the instructions of
    ///         `code` that the scan reads, or (type(uint256).max, 0) when there is none; (0, 0xef) for code starting
    ///         with 0xef, such as an EIP-7702 delegation designator.
    function scan(bytes memory code) internal pure returns (uint256 offset, uint8 opcode) {
        uint256 end = code.length;
        if (end != 0 && uint8(code[0]) == DELEGATED) return (0, DELEGATED);
        // The start of a solc-shaped metadata tail, or the end when there is none.
        uint256 tail = solcTail(code) ? end - SOLC_TAIL : end;
        // Whether execution never falls into the tail: set only when an instruction starts at the byte before it.
        bool sealedTail;
        // Whether a JUMPDEST of the tail has been passed: every instruction from it on can run.
        bool landing;
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            if (i >= tail && op == JUMPDEST) landing = true;
            if ((op == DELEGATECALL || op == CALLCODE || op == SELFDESTRUCT) && (i < tail || !sealedTail || landing)) {
                return (i, op);
            }
            if (i + 1 == tail) {
                // STOP, JUMP, RETURN, REVERT, INVALID: execution never falls from here into the tail.
                sealedTail = op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe;
            }
            // PUSH1..PUSH32 carry 1..32 bytes of data.
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        return (type(uint256).max, 0);
    }

    /// @notice `scan` for code deployed from this build's own creation code, given `built`, the same contract's
    ///         runtime in this build's artifact (immutables zeroed): when `code` has `built`'s length and ends in the
    ///         same solc metadata tail, the tail is this build's metadata, which solc appends after the code and none
    ///         of this build's code jumps into, so it is left out whole and only the code before it is scanned;
    ///         otherwise this is `scan`. A digest byte can then never fail a stand-in the suites or the rehearsal deploy
    ///         themselves, while every instruction of their code is read.
    /// @dev Only for code this repository's build deployed: the code before the tail is not compared with `built`, so
    ///      code someone else deployed could reuse this build's tail and jump into it. A partner's executor is checked
    ///      with `check`, and a false alarm in its tail is cleared by comparing its runtime with a build of its
    ///      verified source, which is what this function stands for here.
    function scanOwnBuild(bytes memory code, bytes memory built) internal pure returns (uint256 offset, uint8 opcode) {
        uint256 n = code.length;
        if (n != built.length || !solcTail(code)) return scan(code);
        for (uint256 i = n - SOLC_TAIL; i < n; ++i) {
            if (code[i] != built[i]) return scan(code);
        }
        bytes memory body = new bytes(n - SOLC_TAIL);
        for (uint256 i; i < body.length; ++i) {
            body[i] = code[i];
        }
        return scan(body);
    }

    /// @notice Whether `code` ends in solc's exact metadata layout for bytecode_hash = ipfs, after at least one byte of
    ///         code. The 32-byte digest and the 3-byte compiler version are not constrained.
    function solcTail(bytes memory code) internal pure returns (bool) {
        uint256 n = code.length;
        if (n <= SOLC_TAIL) return false;
        uint256 t = n - SOLC_TAIL;
        // a2 (a map of two), 64 "ipfs", 58 22 (34 bytes), 12 20 (sha2-256, 32 bytes).
        bytes memory head = hex"a2646970667358221220";
        for (uint256 i; i < head.length; ++i) {
            if (code[t + i] != head[i]) return false;
        }
        // After the digest: 64 "solc", 43 (3 bytes), then the version.
        bytes memory solc = hex"64736f6c6343";
        for (uint256 i; i < solc.length; ++i) {
            if (code[t + 42 + i] != solc[i]) return false;
        }
        return code[n - 2] == 0x00 && code[n - 1] == 0x33;
    }

    /// @notice Reverts `MutableExecutor` unless `executor` holds code that passes `scan`.
    function check(address executor) internal view {
        bytes memory code = executor.code;
        if (code.length == 0) revert MutableExecutor(executor, 0, 0);
        (uint256 offset, uint8 opcode) = scan(code);
        if (opcode != 0) revert MutableExecutor(executor, offset, opcode);
    }
}
