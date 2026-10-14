// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {mineSalt} from "../../script/HookrPairRootSalt.s.sol";

/// @notice AG-08: the pair root salt miner skips addresses carrying Uniswap's 0x91 routing opt-out prefix.
contract HookrPairRootSaltPrefixTest is Test {
    address internal constant FACTORY = address(0xFAC7);
    address internal constant WHO = address(0xD3);
    bytes32 internal constant INIT_HASH = keccak256("pair-root-init");
    /// @dev The lowest salt at or above this one with the pair root flags lands on a 0x91-prefixed address.
    uint256 internal constant DECLINED_SALT = 9_344_952;

    function _root(bytes32 salt) internal pure returns (address) {
        bytes32 fin = keccak256(abi.encode(WHO, salt));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, fin, INIT_HASH)))));
    }

    function test_minerSkipsDeclinedPrefix() public pure {
        address declined = _root(bytes32(DECLINED_SALT));
        assertEq(uint160(declined) & 0x3fff, 0x2080, "flags match");
        assertEq(uint160(declined) >> 152, 0x91, "routing opt-out prefix");
        bytes32 salt = mineSalt(FACTORY, WHO, INIT_HASH, DECLINED_SALT);
        assertGt(uint256(salt), DECLINED_SALT);
        address root = _root(salt);
        assertEq(uint160(root) & 0x3fff, 0x2080);
        assertTrue(uint160(root) >> 152 != 0x91);
    }
}
