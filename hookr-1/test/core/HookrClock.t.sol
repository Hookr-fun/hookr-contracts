// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookrClock} from "../../src/libraries/HookrClock.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";

contract ClockHarness {
    function l2Block() external view returns (uint256) {
        return HookrClock.l2Block();
    }
}

/// @notice HookrClock reads Robinhood Chain's L2 height from ArbSys at 0x64 and never falls back: an empty 0x64, the
///         Nitro placeholder 0xfe a fork holds, a return of the wrong length, zero and a height above uint64 all
///         revert ClockUnavailable, and the read never forwards more than READ_GAS.
contract HookrClockTest is Test {
    ClockHarness internal h;

    function setUp() public {
        h = new ClockHarness();
        vm.roll(26_069_826);
    }

    function test_clock_readsTheMockedL2Height() public {
        ArbSysKit.install(vm, ArbSysKit.L2_BASE, vm.getBlockNumber());
        assertEq(h.l2Block(), ArbSysKit.L2_BASE);
        ArbSysKit.stepL2(vm, 7);
        assertEq(h.l2Block(), ArbSysKit.L2_BASE + 7, "L2 moves inside one parent block");
        assertEq(vm.getBlockNumber(), 26_069_826, "block.number did not move");
        ArbSysKit.nextParent(vm, 2);
        assertEq(h.l2Block(), ArbSysKit.L2_BASE + 7 + 240, "120 L2 blocks per parent block");
        assertTrue(h.l2Block() != vm.getBlockNumber(), "the two clocks differ");
    }

    function test_clock_emptyCodeReverts() public {
        vm.etch(address(100), "");
        vm.expectRevert(HookrClock.ClockUnavailable.selector);
        h.l2Block();
    }

    function test_clock_placeholderRevertsWithinTheCap() public {
        vm.etch(address(100), hex"fe");
        uint256 g = gasleft();
        vm.expectRevert(HookrClock.ClockUnavailable.selector);
        h.l2Block{gas: 1_000_000}();
        uint256 used = g - gasleft();
        // INVALID burns what the read forwards: READ_GAS, plus the call's own overhead.
        assertLe(used, HookrClock.READ_GAS + 15_000, "the read burned no more than its cap");
        assertEq(HookrClock.READ_GAS, 20_000);
    }

    function test_clock_malformedAnswersRevert() public {
        bytes[4] memory answers = [
            abi.encode(uint256(5), uint256(6)), // 64 bytes
            abi.encode(uint256(0)), // zero
            abi.encode(uint256(type(uint64).max) + 1), // above uint64
            abi.encodePacked(bytes20(address(0x1234))) // 20 bytes
        ];
        for (uint256 i; i < answers.length; ++i) {
            vm.etch(address(100), _returning(answers[i]));
            vm.expectRevert(HookrClock.ClockUnavailable.selector);
            h.l2Block();
        }
        // A 32-byte answer at the top of the range is accepted.
        vm.etch(address(100), _returning(abi.encode(uint256(type(uint64).max))));
        assertEq(h.l2Block(), type(uint64).max);
    }

    /// @dev Runtime code that returns `answer` whatever it is called with: each 32-byte word PUSH32 / MSTORE, then
    ///      RETURN of the answer's length.
    function _returning(bytes memory answer) internal pure returns (bytes memory code) {
        uint256 words = (answer.length + 31) / 32;
        for (uint256 i; i < words; ++i) {
            bytes32 w;
            assembly ("memory-safe") {
                w := mload(add(add(answer, 32), mul(i, 32)))
            }
            code = abi.encodePacked(code, hex"7f", w, hex"60", uint8(i * 32), hex"52");
        }
        code = abi.encodePacked(code, hex"60", uint8(answer.length), hex"6000f3");
    }
}
