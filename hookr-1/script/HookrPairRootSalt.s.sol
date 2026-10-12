// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {IHookrPairRoot} from "../src/interfaces/IHookrPairRoot.sol";
import {IHookrRootFactory} from "../src/interfaces/IHookrRootFactory.sol";

/// @dev Lowest salt at or above `start` for which the factory deploys `who`'s root at an address carrying exactly
///      the pair root flags and not starting with 0x91, the prefix that opts a hook out of Uniswap routing. Runs
///      locally; no transaction is sent.
function mineSalt(address factory, address who, bytes32 initHash, uint256 start) pure returns (bytes32 salt) {
    assembly ("memory-safe") {
        let ptr := mload(0x40)
        let b := add(ptr, 0x40)
        mstore(ptr, who)
        mstore8(b, 0xff)
        mstore(add(b, 1), shl(96, factory))
        mstore(add(b, 53), initHash)
        for { let i := start } 1 { i := add(i, 1) } {
            mstore(add(ptr, 0x20), i)
            mstore(add(b, 21), keccak256(ptr, 0x40))
            let h := keccak256(b, 85)
            if and(eq(and(h, 0x3fff), 0x2080), iszero(eq(byte(12, h), 0x91))) {
                salt := i
                break
            }
        }
    }
}

/// @notice Mines a pair root salt for `deployer` against a deployed HookrRootFactory. Read-only.
/// @dev forge script script/HookrPairRootSalt.s.sol --rpc-url <url> --sig
///      "run(address,address,(address,address,int24,uint24,uint24,address,uint24,uint32,bool),uint256)" ...
contract HookrPairRootSalt is Script {
    function run(address factory, address deployer, IHookrPairRoot.Params calldata params, uint256 start)
        external
        view
        returns (bytes32 salt, address root)
    {
        salt = mineSalt(factory, deployer, IHookrRootFactory(factory).initCodeHash(params), start);
        root = IHookrRootFactory(factory).computeAddress(deployer, salt, params);
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("root", root);
    }
}
