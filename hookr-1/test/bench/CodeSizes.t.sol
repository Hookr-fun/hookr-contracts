// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

/// @notice Pins what each deployable's code is, the way Uniswap's snapshots pin the PoolManager's bytecode size: the
///         runtime size of every deployable src contract and the hash of its runtime code with the compiler's metadata
///         tail removed, into snapshots/CodeSizes.json. The check (FORGE_SNAPSHOT_CHECK=true) fails when any figure
///         differs, so a change to deployed code cannot go unnoticed in review. Only the code's last metadata tail is
///         removed, and a code that carries other contracts' code keeps the tails before it: a comment or NatSpec edit
///         in a source of HookrFamilyRelease, HookrMilestoneNFT, HookrPairRoot, HookrToken or HookrRoot moves the hash
///         of HookrFamilyLock, HookrMilestoneNFTFactory, HookrRootFactory, HookrTokenDeployer or the root's creation
///         code, which carry them, as it moves the codehash of what they deploy. Any other comment or NatSpec edit
///         moves only the metadata and passes. The root's creation code is pinned the same way, because the registry
///         pins the root's code hash and every owned root deploys that creation code.
/// @dev Reads the build artifacts (`fs_permissions` allows ./out), so it runs on a build of the current sources:
///      `forge build --force` first when `out/` is warm. Hookr's release tooling checks that the list below names
///      every deployable. Refresh with
///      `FORGE_SNAPSHOT_EMIT=true forge test --match-path test/bench/CodeSizes.t.sol`.
contract CodeSizes is Test {
    /// @dev The Ethereum runtime ceiling (EIP-170); every contract here is held to it, though Robinhood Chain allows more.
    uint256 internal constant LIMIT = 24_576;

    function test_codeSizes_everyDeployable() public {
        _pin("HookrAccountCalls.sol", "HookrAccountCalls");
        _pin("HookrCompliance.sol", "HookrCompliance");
        _pin("HookrComplianceGuard.sol", "HookrComplianceGuard");
        _pin("HookrFamilyLock.sol", "HookrFamilyLock");
        _pin("HookrFamilyRelease.sol", "HookrFamilyRelease");
        _pin("HookrFamilyRouter.sol", "HookrFamilyRouter");
        _pin("HookrFeeAdvisory.sol", "HookrFeeAdvisory");
        _pin("HookrForwarder.sol", "HookrForwarder");
        _pin("HookrLane.sol", "HookrLane");
        _pin("HookrLaunchChecks.sol", "HookrLaunchChecks");
        _pin("HookrLauncher.sol", "HookrLauncher");
        _pin("HookrLiquidityVault.sol", "HookrLiquidityVault");
        _pin("HookrLpBoost.sol", "HookrLpBoost");
        _pin("HookrMilestoneNFT.sol", "HookrMilestoneNFT");
        _pin("HookrMilestoneNFTFactory.sol", "HookrMilestoneNFTFactory");
        _pin("HookrOwnedProfiles.sol", "HookrOwnedProfiles");
        _pin("HookrOwnedRootFactory.sol", "HookrOwnedRootFactory");
        _pin("HookrOwnedRootsLens.sol", "HookrOwnedRootsLens");
        _pin("HookrPairRoot.sol", "HookrPairRoot");
        _pin("HookrPaymaster.sol", "HookrPaymaster");
        _pin("HookrPaymasterAdmin.sol", "HookrPaymasterAdmin");
        _pin("HookrProgramValidator.sol", "HookrProgramValidator");
        _pin("HookrPrograms.sol", "HookrPrograms");
        _pin("HookrProgramsAdmin.sol", "HookrProgramsAdmin");
        _pin("HookrQuoter.sol", "HookrQuoter");
        _pin("HookrRecapture.sol", "HookrRecapture");
        _pin("HookrReferralDistributor.sol", "HookrReferralDistributor");
        _pin("HookrReferralRegistry.sol", "HookrReferralRegistry");
        _pin("HookrRegistry.sol", "HookrRegistry");
        _pin("HookrRegistryAdmin.sol", "HookrRegistryAdmin");
        _pin("HookrRegistryChecks.sol", "HookrRegistryChecks");
        _pin("HookrRoot.sol", "HookrRoot");
        _pin("HookrRootFactory.sol", "HookrRootFactory");
        _pin("HookrRouter.sol", "HookrRouter");
        _pin("HookrRules.sol", "HookrRules");
        _pin("HookrSessionAdvisory.sol", "HookrSessionAdvisory");
        _pin("HookrToken.sol", "HookrToken");
        _pin("HookrTokenDeployer.sol", "HookrTokenDeployer");
        _pin("HookrTreasury.sol", "HookrTreasury");
    }

    function test_codeSizes_rootCreationCode() public {
        bytes memory creation = vm.getCode("HookrRoot.sol:HookrRoot");
        vm.snapshotValue("creation size HookrRoot", creation.length);
        vm.snapshotValue("creation codehash HookrRoot", uint256(keccak256(_withoutMetadata(creation))));
    }

    function _pin(string memory file, string memory name) internal {
        bytes memory code = vm.getDeployedCode(string.concat(file, ":", name));
        assertLt(code.length, LIMIT, string.concat(name, " is over the runtime size limit"));
        vm.snapshotValue(string.concat("runtime size ", name), code.length);
        vm.snapshotValue(string.concat("runtime codehash ", name), uint256(keccak256(_withoutMetadata(code))));
    }

    /// @dev `code` without the CBOR metadata tail: the last two bytes hold the tail's length.
    function _withoutMetadata(bytes memory code) internal pure returns (bytes memory trimmed) {
        uint256 tail = (uint256(uint8(code[code.length - 2])) << 8 | uint256(uint8(code[code.length - 1]))) + 2;
        require(tail < code.length, "no metadata tail");
        trimmed = new bytes(code.length - tail);
        for (uint256 i; i < trimmed.length; ++i) {
            trimmed[i] = code[i];
        }
    }
}
