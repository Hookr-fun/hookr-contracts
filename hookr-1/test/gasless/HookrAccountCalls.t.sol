// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookrAccountCalls} from "../../src/libraries/HookrAccountCalls.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";

contract AccountCallsHarness {
    function decode(bytes calldata d) external pure returns (HookrAccountCalls.Call[] memory) {
        return HookrAccountCalls.decode(d);
    }
}

contract HookrAccountCallsTest is Test {
    /// @dev An ERC-7579 / SimpleAccount v0.8 execution tuple, as executeBatch((address,uint256,bytes)[]) takes it.
    struct Execution {
        address target;
        uint256 value;
        bytes callData;
    }

    AccountCallsHarness h = new AccountCallsHarness();
    address constant T = address(0xBEEF);
    bytes constant INNER = hex"19b36adf0000000000000000000000000000000000000000000000000000000000000001";

    function test_execute() public view {
        HookrAccountCalls.Call[] memory c = h.decode(abi.encodeWithSelector(0xb61d27f6, T, 5, INNER));
        assertEq(c.length, 1);
        assertEq(c[0].target, T);
        assertEq(c[0].value, 5);
        assertEq(c[0].selector, bytes4(0x19b36adf));
    }

    function test_executeBatch_emptyValues() public view {
        address[] memory ts = new address[](2);
        ts[0] = T;
        ts[1] = T;
        bytes[] memory ds = new bytes[](2);
        ds[0] = INNER;
        ds[1] = INNER;
        HookrAccountCalls.Call[] memory c = h.decode(abi.encodeWithSelector(0x47e1da2a, ts, new uint256[](0), ds));
        assertEq(c.length, 2);
        assertEq(c[1].value, 0);
    }

    function test_executeBatch_lengthMismatch() public {
        address[] memory ts = new address[](2);
        bytes[] memory ds = new bytes[](1);
        ds[0] = INNER;
        vm.expectRevert(IHookrPaymaster.NonCanonicalCallData.selector);
        h.decode(abi.encodeWithSelector(0x47e1da2a, ts, new uint256[](1), ds));
    }

    function test_tooManyCalls() public {
        Execution[] memory xs = new Execution[](5);
        for (uint256 i; i < 5; ++i) {
            xs[i] = Execution(T, 0, INNER);
        }
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.TooManyCalls.selector, 5));
        h.decode(abi.encodeWithSelector(0x34fcd5be, xs));
    }

    function test_7579_single_and_badMode() public {
        bytes memory exec = abi.encodePacked(T, uint256(7), INNER);
        HookrAccountCalls.Call[] memory c = h.decode(abi.encodeWithSelector(0xe9ae5c53, bytes32(0), exec));
        assertEq(c[0].target, T);
        assertEq(c[0].value, 7);
        assertEq(c[0].selector, bytes4(0x19b36adf));
        // delegatecall callType 0xff rejected
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedAccountCall.selector, bytes4(0xe9ae5c53)));
        h.decode(abi.encodeWithSelector(0xe9ae5c53, bytes32(uint256(0xff) << 248), exec));
        // try exec type rejected
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedAccountCall.selector, bytes4(0xe9ae5c53)));
        h.decode(abi.encodeWithSelector(0xe9ae5c53, bytes32(uint256(1) << 240), exec));
    }

    function test_safe_operationOneRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedAccountCall.selector, bytes4(0x7bb37428)));
        h.decode(abi.encodeWithSelector(0x7bb37428, T, 0, INNER, uint8(1)));
    }

    function test_nonCanonicalOffset() public {
        bytes memory good = abi.encodeWithSelector(0xb61d27f6, T, 0, INNER);
        // point the bytes offset one word further and append a word of padding before the data
        bytes memory bad = bytes.concat(
            bytes4(0xb61d27f6),
            bytes32(uint256(uint160(T))),
            bytes32(0),
            bytes32(uint256(0x80)),
            bytes32(0),
            _slice(good, 100)
        );
        vm.expectRevert(IHookrPaymaster.NonCanonicalCallData.selector);
        h.decode(bad);
    }

    function test_unknownSelector() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedAccountCall.selector, bytes4(0x8dd7712f)));
        h.decode(abi.encodeWithSelector(0x8dd7712f, T));
    }

    function _slice(bytes memory b, uint256 from) private pure returns (bytes memory r) {
        r = new bytes(b.length - from);
        for (uint256 i; i < r.length; ++i) {
            r[i] = b[from + i];
        }
    }
}
