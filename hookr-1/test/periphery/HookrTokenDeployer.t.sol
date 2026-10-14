// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTokenDeployer} from "../../src/libraries/HookrTokenDeployer.sol";
import {HookrLaunchChecks} from "../../src/libraries/HookrLaunchChecks.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrToken} from "../../src/interfaces/IHookrToken.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @notice HookrTokenDeployer, the linked library the launcher runs by DELEGATECALL to create its tokens, and that
///         predicts them. Tokens keep the address and first holder the launcher gave them when it created them itself:
///         CREATE2 from the launcher's address, salt keccak256(abi.encode(creator, salt)), HookrToken's creation code
///         with the launcher as holder.
contract HookrTokenDeployerTest is PeripheryFixture {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev The launcher's own prediction before the library: the same CREATE2 inputs, computed here.
    function _expected(address creator, IHookrLauncher.Token memory t) internal view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(HookrToken).creationCode, abi.encode(t.name, t.symbol, t.supply, address(launcher)))
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(launcher), keccak256(abi.encode(creator, t.salt)), initHash
                        )
                    )
                )
            )
        );
    }

    function _one(uint256 supply) internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].liquidity = 1e7;
        members[0].amount0Max = 1e18;
        members[0].amount1Max = uint128(supply);
    }

    /// @notice predictToken gives the CREATE2 address the launcher always gave, and the launch deploys exactly there
    ///         with the whole supply first minted to the launcher, which keeps none of it.
    function test_predictionAndDeploymentUnchanged() public {
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Deployer", "DPL", 1e24, bytes32(uint256(42)));
        address predicted = launcher.predictToken(address(this), t);
        assertEq(predicted, _expected(address(this), t), "the same CREATE2 inputs");
        assertEq(predicted.code.length, 0);
        vm.recordLogs();
        (, address subject) = launcher.launch{value: 1e18}(t, address(root), _one(t.supply), vm.getBlockTimestamp());
        assertEq(subject, predicted, "deployed at the prediction");
        assertEq(subject.codehash, keccak256(type(HookrToken).runtimeCode));
        assertEq(HookrToken(subject).totalSupply(), 1e24);
        assertEq(HookrToken(subject).balanceOf(address(launcher)), 0, "the launcher keeps nothing");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool minted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != subject || logs[i].topics[0] != TRANSFER_TOPIC) continue;
            if (logs[i].topics[1] != bytes32(0)) continue;
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(launcher), "first holder");
            assertEq(abi.decode(logs[i].data, (uint256)), t.supply);
            minted = true;
        }
        assertTrue(minted, "the supply was minted once, to the launcher");
    }

    /// @notice Over creators, salts, names, symbols and supplies the prediction is the old formula's.
    function testFuzz_predictionUnchanged(
        address creator,
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint256 supply
    ) public view {
        vm.assume(creator != address(0) && supply != 0);
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), name, symbol, supply, salt);
        assertEq(launcher.predictToken(creator, t), _expected(creator, t));
    }

    /// @notice A salt belongs to its creator: two creators get two tokens from one salt, and a creator cannot reuse
    ///         one. The refusals predictToken always had stay.
    function test_saltsAreNamespacedAndSingleUse() public {
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Shared", "SHR", 1e24, bytes32(uint256(7)));
        address other = address(0x0DD);
        vm.deal(other, 1e18);
        address mine = launcher.predictToken(address(this), t);
        address theirs = launcher.predictToken(other, t);
        assertTrue(mine != theirs);
        (, address a) = launcher.launch{value: 1e18}(t, address(root), _one(t.supply), vm.getBlockTimestamp());
        vm.prank(other);
        (, address b) = launcher.launch{value: 1e18}(t, address(root), _one(t.supply), vm.getBlockTimestamp());
        assertEq(a, mine);
        assertEq(b, theirs);
        // The same creator and salt again: CREATE2 finds the address taken and the launch reverts. A colliding CREATE2
        // spends all the gas it is given, so the call is capped.
        vm.expectRevert();
        launcher.launch{value: 1e18, gas: 5_000_000}(t, address(root), _one(t.supply), vm.getBlockTimestamp());

        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.predictToken(address(0), t);
        t.supply = 0;
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.predictToken(address(this), t);
        t.supply = 1;
        t.existing = address(tokenA);
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.predictToken(address(this), t);
    }

    /// @notice HookrToken's refusals reach the launch caller through the library.
    function test_tokenRefusalsBubbleThroughTheLibrary() public {
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "", "BAD", 1e24, bytes32(uint256(8)));
        vm.expectRevert(IHookrToken.InvalidMetadata.selector);
        launcher.launch{value: 1e18}(t, address(root), _one(t.supply), vm.getBlockTimestamp());
        t.name = "Bad";
        t.symbol = "SEVENTEEN_BYTES_X";
        vm.expectRevert(IHookrToken.InvalidMetadata.selector);
        launcher.launch{value: 1e18}(t, address(root), _one(t.supply), vm.getBlockTimestamp());
    }

    /// @notice The library's state-changing entry point runs only by DELEGATECALL: called directly it reverts, so it
    ///         never creates a token from its own address. Its `predict` is pure and answers for any launcher.
    function test_deployRefusesADirectCallAndPredictIsPure() public {
        address library_ = deployCode("HookrTokenDeployer.sol:HookrTokenDeployer");
        (bool ok,) = library_.call(
            abi.encodeWithSelector(HookrTokenDeployer.deploy.selector, address(this), bytes32(0), "X", "X", uint256(1))
        );
        assertFalse(ok, "call guard");
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Lib", "LIB", 7, bytes32(uint256(3)));
        bytes memory answer;
        (ok, answer) = library_.staticcall(
            abi.encodeWithSelector(
                HookrTokenDeployer.predict.selector,
                address(launcher),
                address(this),
                t.salt,
                t.name,
                t.symbol,
                t.supply
            )
        );
        assertTrue(ok);
        assertEq(abi.decode(answer, (address)), launcher.predictToken(address(this), t));
    }

    /// @notice The launcher refuses to deploy before its linked libraries: with either library's address empty, its
    ///         constructor reverts, so a deployment that skips or misorders them fails instead of leaving a launcher
    ///         that refuses every new-token launch and answers the launch fee's functions with nothing.
    function test_launcherRefusesToDeployWithoutItsLibraries() public {
        address[2] memory libraries = [address(HookrTokenDeployer), address(HookrLaunchChecks)];
        for (uint256 i; i < 2; ++i) {
            bytes memory code = libraries[i].code;
            assertGt(code.length, 0, "linked and deployed");
            vm.etch(libraries[i], "");
            vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
            new HookrLauncher(manager, registry);
            vm.etch(libraries[i], code);
        }
        HookrLauncher fresh = new HookrLauncher(manager, registry);
        assertEq(address(fresh.registry()), address(registry));
    }

    /// @notice HookrToken's creation code is no longer part of the launcher's runtime; the library holds it.
    function test_launcherRuntimeHoldsNoTokenCreationCode() public {
        bytes memory creation = type(HookrToken).creationCode;
        bytes memory needle = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            needle[i] = creation[i + 32];
        }
        assertFalse(_contains(address(launcher).code, needle), "launcher");
        address library_ = deployCode("HookrTokenDeployer.sol:HookrTokenDeployer");
        assertTrue(_contains(library_.code, needle), "library");
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (haystack.length < needle.length) return false;
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            bool matched = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
