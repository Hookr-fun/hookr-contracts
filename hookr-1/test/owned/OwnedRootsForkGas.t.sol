// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice One owned-root deployment on a Robinhood Chain 4663 fork, against the live PoolManager: the gas of the whole
///         transaction (21,000, the calldata's 16 and 4 gas per byte, and the execution of the root, its lane module,
///         the companion, its recapture module and the registration) must stay under 30,000,000, below Nitro's
///         per-transaction cap of 32,000,000. The calldata carries both creation codes, so it must also stay under the
///         95,000 bytes Nitro's sequencer accepts by default. Skipped unless ALCHEMY_RPC_URL is set; the fork URL is
///         the `robinhood` alias in foundry.toml.
contract OwnedRootsForkGasTest is OwnedRootsFixture {
    uint256 internal constant FORK_BLOCK = 71_811_725;
    /// @dev eth_getBlockByNumber(71_811_725).l1BlockNumber: what `block.number` returns inside a contract on Nitro.
    uint256 internal constant FORK_L1_BLOCK = 26_050_989;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint256 internal constant GAS_CEILING = 30_000_000;
    /// @dev Nitro's default sequencer limit on a transaction's data (execution.sequencer.max-tx-data-size).
    uint256 internal constant SEQUENCER_DATA_LIMIT = 95_000;
    bool internal live;

    function setUp() public {
        if (bytes(vm.envOr("ALCHEMY_RPC_URL", string(""))).length == 0) return;
        vm.createSelectFork("robinhood", FORK_BLOCK);
        vm.roll(FORK_L1_BLOCK);
        _setUpOwnedOn(PM);
        live = true;
    }

    function test_fork_oneOwnedRootDeploymentStaysUnder30M() public {
        if (!live) return;
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        bytes memory data = abi.encodeCall(
            IHookrOwnedRootFactory.deploy, (type(HookrRoot).creationCode, type(HookrRules).creationCode, sel, salt)
        );
        uint256 fee = _fee(factory);
        vm.deal(brand, brand.balance + fee);
        vm.prank(brand);
        (bool ok, bytes memory out) = address(factory).call{value: fee}(data);
        assertTrue(ok, "deployed");
        uint256 execution = vm.lastCallGas().gasTotalUsed;
        uint256 intrinsic = 21_000 + _calldataGas(data);
        uint256 total = intrinsic + execution;
        address owned = abi.decode(out, (address));
        assertTrue(IHookrOwnedRoots(address(registry)).isOwnedRoot(owned));
        console2.log("owned-root deployment: calldata bytes", data.length);
        console2.log("owned-root deployment: intrinsic gas (21,000 and calldata)", intrinsic);
        console2.log("owned-root deployment: execution gas", execution);
        console2.log("owned-root deployment: transaction gas", total);
        console2.log("root initcode bytes", type(HookrRoot).creationCode.length);
        console2.log("rules initcode bytes", type(HookrRules).creationCode.length);
        assertLt(total, GAS_CEILING, "one transaction: root, companion and registration");
        assertLt(data.length, SEQUENCER_DATA_LIMIT, "the sequencer takes the transaction");
    }

    /// @dev The EVM's calldata charge: 16 gas per non-zero byte, 4 per zero byte (the floor of EIP-7623 is below it
    ///      here, since execution dominates).
    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }
}
