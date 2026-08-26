// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice A stand-in for the canonical deterministic deployer 0x4e59b448..., which is what
///         `forge script` routes CREATE2 through. It is stateless and owned by nobody.
contract DeterministicDeployer {
    function deploy(bytes32 salt, bytes memory creation) external returns (address addr) {
        assembly {
            addr := create2(0, add(creation, 0x20), mload(creation), salt)
        }
        require(addr != address(0), "create2 failed");
    }
}

/// @notice The deployment shape the product actually ships in.
///
///         Every other test in this repo deploys the hook with `new LeverageHook{salt:}` FROM
///         the test contract, which is also the address that calls `setFactory` — so the
///         deployer gate was satisfied by accident and a fatal defect went unseen through five
///         audit passes. The hook's address must be MINED, so it can only be created by
///         CREATE2, i.e. by a contract; under `forge script` that contract is the canonical
///         deterministic deployer. If the hook takes its admin from `msg.sender`, that stateless
///         deployer becomes the admin and `setFactory` is unreachable by every address forever:
///         `createMarket` then reverts for everyone, on mainnet, permanently.
contract LeverageDeployShapeTest is Test {
    IPoolManager manager;
    DeterministicDeployer dd;

    uint160 constant FLAGS = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        dd = new DeterministicDeployer();
    }

    function test_theHookIsUsableWhenMinedThroughAThirdPartyDeployer() public {
        address admin = address(0xADEE);

        // Mined against the DEPLOYER's address, exactly as a script would.
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, admin));
        (address predicted, bytes32 salt) = HookMiner.find(address(dd), FLAGS, creation);

        address hookAddr = dd.deploy(salt, creation);
        assertEq(hookAddr, predicted, "mined address must match");
        assertEq(uint160(hookAddr) & 0x3FFF, FLAGS, "the mined address carries the declared flags");

        LeverageHook hook = LeverageHook(hookAddr);
        LeverageFactory factory = new LeverageFactory(manager, hook);

        // The admin — not the deployer contract, and not this test — can wire the factory.
        vm.prank(admin);
        hook.setFactory(address(factory));
        assertEq(hook.factory(), address(factory), "the factory must be reachable by its admin");
    }

    function test_theDeployerContractItselfCannotClaimTheHook() public {
        address admin = address(0xADEE);
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, admin));
        (, bytes32 salt) = HookMiner.find(address(dd), FLAGS, creation);
        LeverageHook hook = LeverageHook(dd.deploy(salt, creation));
        LeverageFactory factory = new LeverageFactory(manager, hook);

        // Whoever performed the CREATE2 has no standing. Under the old constructor this was the
        // only address with standing, and it is a stateless contract that can never use it.
        vm.prank(address(dd));
        vm.expectRevert(ILeverage.NotFactory.selector);
        hook.setFactory(address(factory));

        // Nor does anyone else who has not been named admin — including this test contract.
        vm.expectRevert(ILeverage.NotFactory.selector);
        hook.setFactory(address(factory));
    }
}
