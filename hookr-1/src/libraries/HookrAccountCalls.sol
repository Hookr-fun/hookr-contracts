// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrPaymaster} from "../interfaces/IHookrPaymaster.sol";

/// @title HookrAccountCalls
/// @notice Decodes a 4337 account's callData into the calls it will make and checks them against the paymaster's
///         call-data policy.
/// @dev Supported: SimpleAccount v0.7 execute / executeBatch, SimpleAccount v0.8 executeBatch(Call[]), ERC-7579 execute
///      (single or batch CALL, default exec type) and Safe4337Module executeUserOp(WithErrorString) with operation 0.
///      A strict parser reads callData in place and accepts only the canonical ABI encoding that re-encoding the
///      decoded arguments with the same selector would produce: every offset equals its canonical value, addresses
///      and uint8 are clean, `bytes` padding is zero and nothing trails the encoding (closes parser differentials).
///      No TIMESTAMP, NUMBER, BALANCE or external calls: safe inside ERC-7562 validation.
///      Deployed as an external (linked) library so the paymaster stays under the EIP-170 runtime limit: it is
///      deployed through CREATE3 and linked into the paymaster's bytecode before the paymaster is deployed, and the
///      paymaster reaches it by DELEGATECALL during validation. `check` reads only the two paymaster mappings it is
///      passed, in the paymaster's own storage; the library writes no storage.
library HookrAccountCalls {
    /// @notice One decoded inner call.
    struct Call {
        address target;
        uint256 value;
        bytes4 selector;
        bytes data;
    }

    uint256 internal constant MAX_CALLS = 4;
    /// @dev approve(address,uint256)
    bytes4 internal constant APPROVE = 0x095ea7b3;

    bytes4 internal constant EXECUTE = 0xb61d27f6; // execute(address,uint256,bytes)
    bytes4 internal constant EXECUTE_BATCH = 0x47e1da2a; // executeBatch(address[],uint256[],bytes[])
    bytes4 internal constant EXECUTE_BATCH_TUPLES = 0x34fcd5be; // executeBatch((address,uint256,bytes)[])
    bytes4 internal constant EXECUTE_7579 = 0xe9ae5c53; // execute(bytes32,bytes)
    bytes4 internal constant SAFE_EXECUTE = 0x7bb37428; // executeUserOp(address,uint256,bytes,uint8)
    bytes4 internal constant SAFE_EXECUTE_ERR = 0x541d63c8; // executeUserOpWithErrorString(address,uint256,bytes,uint8)

    /// @notice Reverts unless every call in `callData` is allowed by `policy`: the target and selector are allowed,
    ///         value is sent only where allowed, and an approve is exactly approve(spender, amount) with no value to a
    ///         spender in `spenders`.
    /// @dev Reverts as `decode`, then CallNotAllowed, ValueNotAllowed or ApprovalNotAllowed. `policy` holds bit 0
    ///      (allowed) and bit 1 (value allowed) under `callKey(target, selector)`.
    /// @param policy The paymaster's call policy.
    /// @param spenders The paymaster's approval spenders.
    /// @param callData The account's callData.
    function check(
        mapping(bytes24 => uint8) storage policy,
        mapping(address => bool) storage spenders,
        bytes calldata callData
    ) external view {
        Call[] memory calls = _decode(callData);
        for (uint256 i; i < calls.length; ++i) {
            Call memory c = calls[i];
            uint8 flags = policy[callKey(c.target, c.selector)];
            if (flags & 1 == 0) revert IHookrPaymaster.CallNotAllowed(c.target, c.selector);
            if (c.value != 0 && flags & 2 == 0) revert IHookrPaymaster.ValueNotAllowed(c.target, c.value);
            if (c.selector == APPROVE) {
                // approve(spender, amount) on an allowed target, exactly 68 bytes, to an allowed spender.
                bytes memory d = c.data;
                uint256 word;
                if (d.length == 68) {
                    assembly ("memory-safe") {
                        word := mload(add(d, 36))
                    }
                }
                address spender = address(uint160(word));
                if (d.length != 68 || c.value != 0 || word >> 160 != 0 || !spenders[spender]) {
                    revert IHookrPaymaster.ApprovalNotAllowed(spender);
                }
            }
        }
    }

    /// @notice Decodes `callData` into at most MAX_CALLS calls.
    /// @dev Reverts UnsupportedAccountCall, NonCanonicalCallData, TooManyCalls or CallNotAllowed (inner call < 4 bytes).
    function decode(bytes calldata callData) external pure returns (Call[] memory calls) {
        return _decode(callData);
    }

    /// @notice The call-policy key of `selector` on `target`.
    function callKey(address target, bytes4 selector) internal pure returns (bytes24) {
        return bytes24(bytes20(target)) | (bytes24(selector) >> 160);
    }

    /// @dev All offsets below are absolute positions in `callData`; ABI offsets are relative to byte 4 (the arguments).
    function _decode(bytes calldata callData) private pure returns (Call[] memory calls) {
        uint256 size = callData.length;
        if (size < 4) revert IHookrPaymaster.UnsupportedAccountCall(bytes4(0));
        bytes4 sel = bytes4(callData[:4]);
        uint256 end;
        if (sel == EXECUTE || sel == SAFE_EXECUTE || sel == SAFE_EXECUTE_ERR) {
            // (address target, uint256 value, bytes data[, uint8 operation]): head of 3 or 4 words, then the bytes tail.
            uint256 head = sel == EXECUTE ? 0x60 : 0x80;
            address t = _address(callData, 4, size);
            uint256 v = _word(callData, 36, size);
            _offset(callData, 68, size, head);
            if (sel != EXECUTE) {
                uint256 operation = _word(callData, 100, size);
                if (operation >> 8 != 0) revert IHookrPaymaster.NonCanonicalCallData();
                if (operation != 0) revert IHookrPaymaster.UnsupportedAccountCall(sel);
            }
            uint256 start;
            uint256 len;
            (start, len, end) = _bytes(callData, 4 + head, size);
            calls = new Call[](1);
            calls[0] = _call(callData, t, v, start, len);
        } else if (sel == EXECUTE_BATCH) {
            // (address[] ts, uint256[] vs, bytes[] ds): three offsets, then the three arrays back to back.
            _offset(callData, 4, size, 0x60);
            uint256 n = _length(callData, 100, size);
            uint256 vsAt = 0x80 + n * 32; // relative to byte 4
            _offset(callData, 36, size, vsAt);
            uint256 m = _length(callData, 4 + vsAt, size);
            uint256 dsAt = vsAt + 32 + m * 32;
            _offset(callData, 68, size, dsAt);
            uint256 k = _length(callData, 4 + dsAt, size);
            if ((m != 0 && m != n) || k != n) revert IHookrPaymaster.NonCanonicalCallData();
            _bound(n);
            calls = new Call[](n);
            uint256 heads = 36 + dsAt;
            uint256 next = n * 32; // relative to `heads`
            for (uint256 i; i < n; ++i) {
                address t = _address(callData, 132 + i * 32, size);
                uint256 v = m == 0 ? 0 : _word(callData, 36 + vsAt + i * 32, size);
                _offset(callData, heads + i * 32, size, next);
                (uint256 start, uint256 len, uint256 tail) = _bytes(callData, heads + next, size);
                calls[i] = _call(callData, t, v, start, len);
                next = tail - heads;
            }
            end = heads + next;
        } else if (sel == EXECUTE_BATCH_TUPLES) {
            (calls, end) = _executions(callData, 4, size);
        } else if (sel == EXECUTE_7579) {
            // (bytes32 mode, bytes execData).
            uint256 mode = _word(callData, 4, size);
            // callType byte 0 ∈ {0x00 single, 0x01 batch}; execType, unused, mode selector and payload all zero.
            if (mode << 8 != 0) revert IHookrPaymaster.UnsupportedAccountCall(sel);
            _offset(callData, 36, size, 0x40);
            uint256 start;
            uint256 len;
            (start, len, end) = _bytes(callData, 68, size);
            uint256 callType = mode >> 248;
            if (callType == 0x00) {
                // Packed target (20 bytes) ‖ value (32 bytes) ‖ data.
                if (len < 52) revert IHookrPaymaster.NonCanonicalCallData();
                address t;
                uint256 v;
                assembly ("memory-safe") {
                    t := shr(96, calldataload(add(callData.offset, start)))
                    v := calldataload(add(callData.offset, add(start, 20)))
                }
                calls = new Call[](1);
                calls[0] = _call(callData, t, v, start + 52, len - 52);
            } else if (callType == 0x01) {
                // abi.encode((address,uint256,bytes)[]), ERC-7579 Execution[], filling execData exactly.
                uint256 inner;
                (calls, inner) = _executions(callData, start, start + len);
                if (inner != start + len) revert IHookrPaymaster.NonCanonicalCallData();
            } else {
                revert IHookrPaymaster.UnsupportedAccountCall(sel);
            }
        } else {
            revert IHookrPaymaster.UnsupportedAccountCall(sel);
        }
        if (end != size) revert IHookrPaymaster.NonCanonicalCallData();
    }

    /// @dev Parses a canonical `abi.encode((address,uint256,bytes)[])` (target, value, callData: ERC-7579 Execution[]
    ///      and SimpleAccount v0.8 Call[]) starting at `pos`, reading nothing at or past `limit`.
    ///      Returns the calls and the position just past the encoding.
    function _executions(bytes calldata cd, uint256 pos, uint256 limit)
        private
        pure
        returns (Call[] memory calls, uint256 end)
    {
        _offset(cd, pos, limit, 32);
        uint256 n = _length(cd, pos + 32, limit);
        _bound(n);
        calls = new Call[](n);
        uint256 heads = pos + 64;
        uint256 next = n * 32; // relative to `heads`
        for (uint256 i; i < n; ++i) {
            _offset(cd, heads + i * 32, limit, next);
            uint256 x = heads + next;
            address t = _address(cd, x, limit);
            uint256 v = _word(cd, x + 32, limit);
            _offset(cd, x + 64, limit, 0x60);
            (uint256 start, uint256 len, uint256 tail) = _bytes(cd, x + 96, limit);
            calls[i] = _call(cd, t, v, start, len);
            next = tail - heads;
        }
        end = heads + next;
    }

    /// @dev Canonical `bytes` tail at `pos`: length word, data, zero padding to a word. Returns the data's start,
    ///      its length and the position just past the padding.
    function _bytes(bytes calldata cd, uint256 pos, uint256 limit)
        private
        pure
        returns (uint256 start, uint256 len, uint256 end)
    {
        len = _length(cd, pos, limit);
        start = pos + 32;
        end = start + ((len + 31) & ~uint256(31));
        if (end > limit) revert IHookrPaymaster.NonCanonicalCallData();
        uint256 rem = len & 31;
        if (rem != 0 && _word(cd, start + len - rem, limit) << (rem * 8) != 0) {
            revert IHookrPaymaster.NonCanonicalCallData();
        }
    }

    /// @dev Copies the inner call at [start, start + len) into memory; it must hold at least a selector.
    function _call(bytes calldata cd, address t, uint256 v, uint256 start, uint256 len)
        private
        pure
        returns (Call memory c)
    {
        if (len < 4) revert IHookrPaymaster.CallNotAllowed(t, bytes4(0));
        c = Call({target: t, value: v, selector: bytes4(cd[start:start + 4]), data: cd[start:start + len]});
    }

    /// @dev Reads the word at `pos`, which must lie wholly before `limit` (itself never past the end of `cd`).
    function _word(bytes calldata cd, uint256 pos, uint256 limit) private pure returns (uint256 w) {
        if (pos + 32 > limit) revert IHookrPaymaster.NonCanonicalCallData();
        assembly ("memory-safe") {
            w := calldataload(add(cd.offset, pos))
        }
    }

    /// @dev A length word; no canonical length can exceed `limit` (this also keeps later arithmetic from overflowing).
    function _length(bytes calldata cd, uint256 pos, uint256 limit) private pure returns (uint256 n) {
        n = _word(cd, pos, limit);
        if (n > limit) revert IHookrPaymaster.NonCanonicalCallData();
    }

    /// @dev An offset word, which must equal its canonical value.
    function _offset(bytes calldata cd, uint256 pos, uint256 limit, uint256 expected) private pure {
        if (_word(cd, pos, limit) != expected) revert IHookrPaymaster.NonCanonicalCallData();
    }

    /// @dev A left-padded address word with clean upper bits.
    function _address(bytes calldata cd, uint256 pos, uint256 limit) private pure returns (address) {
        uint256 w = _word(cd, pos, limit);
        if (w >> 160 != 0) revert IHookrPaymaster.NonCanonicalCallData();
        return address(uint160(w));
    }

    function _bound(uint256 n) private pure {
        if (n > MAX_CALLS) revert IHookrPaymaster.TooManyCalls(n);
    }
}
