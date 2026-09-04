// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageExistingTokenFactory} from "../src/LeverageExistingTokenFactory.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title DeployByoLeverage
/// @notice The BYO leverage generation: LeverageExistingTokenFactory behind a FRESH mined
///         LeverageHook instance.
///
///         The live gen-1 leverage hook cannot serve this factory — its one-shot `setFactory`
///         is consumed by the live LeverageFactory — so this script mines and deploys a new
///         hook instance of the same reviewed bytecode and wires it to the BYO factory with
///         the same admin-gated one-shot. The engine (`LeverageMarket`) is byte-identical and
///         instantiated per market by the factory, exactly as in gen-1.
///
///         The DeployLeverage lessons carry over verbatim: the admin is an explicit constructor
///         argument mined into the salt (never inferred from the CREATE2 deployer), and if the
///         broadcasting key is not the admin, `setFactory` reverts here rather than shipping a
///         half-wired deployment. One extra gotcha inherited from the gen-1 mainnet deploy:
///         `forge` PREPENDS a CREATE2 deploy of any linked library it cannot find on chain, and
///         the shared library already exists on Robinhood Chain — so expect the broadcast to be
///         three transactions (hook, factory, setFactory), not four, and treat a fourth as a
///         sign the RPC did not show forge the existing library.
///
///         Dry-run first, always:
///           POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951 \
///           forge script script/DeployByoLeverage.s.sol \
///             --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <deployer>
///         then add --broadcast (and your signer flags) to send it.
contract DeployByoLeverage is Script {
    /// Every permission the leverage hook declares, and the exact set its address must carry.
    uint160 internal constant FLAGS = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));

    /// The deployer `forge script` broadcasts CREATE2 through.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        // Who may wire the factory exactly once. Defaults to the broadcasting key — the
        // operator — never the CREATE2 deployer.
        address admin = vm.envOr("LEVERAGE_ADMIN", msg.sender);
        require(admin != address(0), "LEVERAGE_ADMIN must be set");

        bytes memory creation =
            abi.encodePacked(type(LeverageHook).creationCode, abi.encode(IPoolManager(poolManager), admin));
        (address predicted, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, creation);

        console2.log("admin           ", admin);
        console2.log("hook (predicted)", predicted);

        vm.startBroadcast();

        LeverageHook hook = new LeverageHook{salt: salt}(IPoolManager(poolManager), admin);
        require(address(hook) == predicted, "mined address drifted");
        require(uint160(address(hook)) & 0x3FFF == FLAGS, "hook address lacks the declared flags");

        LeverageExistingTokenFactory factory = new LeverageExistingTokenFactory(IPoolManager(poolManager), hook);

        // One-shot, admin-only. Reverting here beats shipping a half-wired deployment.
        hook.setFactory(address(factory));
        require(hook.factory() == address(factory), "factory not wired");

        vm.stopBroadcast();

        console2.log("hook   ", address(hook));
        console2.log("factory", address(factory));
        console2.log("LeverageHook (BYO instance) runtime codehash");
        console2.logBytes32(address(hook).codehash);
        console2.log("LeverageExistingTokenFactory runtime codehash");
        console2.logBytes32(address(factory).codehash);
    }
}
