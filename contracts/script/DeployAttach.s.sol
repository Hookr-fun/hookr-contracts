// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrAttachHook} from "../src/HookrAttachHook.sol";
import {HookrExistingTokenFactory} from "../src/HookrExistingTokenFactory.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title DeployAttach
/// @notice The gen-5 attach pair, wired at construction rather than after it.
///
///         The circularity the leverage deploy resolved with a one-shot `setFactory` is resolved
///         here the stricter way: `HookrAttachHook.factory` is a constructor immutable, so the
///         factory's address must exist BEFORE the hook does. The script therefore
///           1. predicts this broadcast's factory address from the sender's nonce (the factory
///              is a plain CREATE, one transaction after the hook's CREATE2),
///           2. mines the hook's CREATE2 salt against that prediction so the address carries
///              HookrHook's exact permission flags,
///           3. deploys hook then factory — and the factory's own constructor re-runs every
///              `setHook`-style check (flag bits, hook.factory() == address(this), shared
///              PoolManager) and refuses to construct on any mismatch.
///
///         Unlike the leverage generation there is no linked external library here (the factory
///         inlines its math, measured well under EIP-170), so the broadcast is exactly two
///         transactions and the nonce arithmetic below cannot be shifted by a prepended
///         library deploy.
///
///         Dry-run first, always:
///           POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951 \
///           forge script script/DeployAttach.s.sol \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <deployer>
///         then add --broadcast (and your signer flags) to send it.
contract DeployAttach is Script {
    /// HookrHook's REQUIRED_FLAGS — the attach hook is a mechanical rename and declares the same.
    uint160 internal constant FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    /// The deployer `forge script` broadcasts CREATE2 through.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");

        // The hook's CREATE2 goes through the deterministic deployer but still consumes ONE
        // sender nonce (the transaction that calls it); the factory's plain CREATE is the next.
        uint64 nonce = vm.getNonce(msg.sender);
        address predictedFactory = vm.computeCreateAddress(msg.sender, nonce + 1);

        bytes memory creation = abi.encodePacked(
            type(HookrAttachHook).creationCode, abi.encode(IPoolManager(poolManager), predictedFactory)
        );
        (address predictedHook, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, creation);

        console2.log("sender             ", msg.sender);
        console2.log("factory (predicted)", predictedFactory);
        console2.log("hook (predicted)   ", predictedHook);

        vm.startBroadcast();

        HookrAttachHook hook = new HookrAttachHook{salt: salt}(IPoolManager(poolManager), predictedFactory);
        require(address(hook) == predictedHook, "mined hook address drifted");
        require(uint160(address(hook)) & 0x3FFF == FLAGS, "hook address lacks the declared flags");

        HookrExistingTokenFactory factory = new HookrExistingTokenFactory(IPoolManager(poolManager), hook);
        // The constructor above already reverted on any wiring mismatch; these are receipts for
        // the console, not the safety net.
        require(address(factory) == predictedFactory, "factory landed off its predicted address");
        require(hook.factory() == address(factory), "hook does not point at the factory");

        vm.stopBroadcast();

        console2.log("hook   ", address(hook));
        console2.log("factory", address(factory));
        console2.log("HookrAttachHook runtime codehash");
        console2.logBytes32(address(hook).codehash);
        console2.log("HookrExistingTokenFactory runtime codehash");
        console2.logBytes32(address(factory).codehash);
    }
}
