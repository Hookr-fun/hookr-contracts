// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title DeployLeverage
/// @notice Mines the hook, deploys the factory and the route, and wires them.
///
///         This script is the reason a fatal defect existed for five audit passes. The hook's
///         address must carry its permission bits, so it can only be created by CREATE2 — i.e.
///         by a contract. `forge script` routes CREATE2 through the canonical deterministic
///         deployer at 0x4e59b448..., so anything the hook infers from `msg.sender` in its
///         constructor belongs to that stateless contract, not to the operator.
///
///         The hook used to take its admin that way. `setFactory` would therefore have been
///         unreachable by every address forever, `factory` would have stayed zero, and
///         `createMarket` would have reverted for everyone on mainnet with no recovery short of
///         re-mining and redeploying. Every test deployed the hook from the test contract, which
///         was also the address calling `setFactory`, so the gate was satisfied by accident and
///         nothing failed.
///
///         The admin is now an explicit constructor argument, mined into the salt. The
///         regression lives in test/LeverageDeployShape.t.sol, which deploys through a
///         third-party CREATE2 deployer rather than from the test contract.
contract DeployLeverage is Script {
    /// Every permission the hook declares, and the exact set its address must carry.
    uint160 internal constant FLAGS = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));

    /// The deployer `forge script` broadcasts CREATE2 through.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        // Who may wire the factory exactly once. Defaults to the broadcasting key, which is the
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

        LeverageFactory factory = new LeverageFactory(IPoolManager(poolManager), hook);
        LeverageRouter router = new LeverageRouter(IPoolManager(poolManager));

        // One-shot, and only the admin may do it. If the broadcasting key is not the admin this
        // reverts here rather than leaving a half-wired deployment — which is the failure the
        // whole script exists to make impossible to ship silently.
        hook.setFactory(address(factory));
        require(hook.factory() == address(factory), "factory not wired");

        vm.stopBroadcast();

        console2.log("hook            ", address(hook));
        console2.log("factory         ", address(factory));
        console2.log("router          ", address(router));
    }
}
