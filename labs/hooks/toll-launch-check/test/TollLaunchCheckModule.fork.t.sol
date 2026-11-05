// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";

import {TollLaunchCheckModule, ILaunchObservationsReader} from "../src/TollLaunchCheckModule.sol";
import {KernelCallHarness} from "./KernelCallHarness.sol";

/// @dev The ERC-8470 `getObservation` read, used only to pin observations by id.
interface ILaunchObservationsById {
    struct Tally {
        uint16 against;
        uint16 careful;
        uint16 clear;
    }

    struct Observation {
        bytes32 launchKey;
        uint256 chainId;
        address token;
        uint8 kind;
        uint64 observedBlock;
        bool hashChecked;
        address detector;
        uint64 recordedAt;
        address identityRegistry;
        Tally tally;
        uint256 agentId;
        uint256 supersedes;
        bytes32 reportHash;
        bytes32 evidenceRoot;
        bytes32 declarationId;
        string reportURI;
    }

    struct Finding {
        bytes32 kind;
        uint256 value;
        uint64 param;
        uint8 lean;
    }

    function getObservation(uint256 observationId)
        external
        view
        returns (Observation memory observation, Finding[] memory findings);
}

/// @dev Reads the live ERC-8470 registry on Robinhood Chain (4663) and Toll's detector. The RPC comes
///      from `--fork-url` only; without a Robinhood Chain fork every test here skips.
///
///      forge test --root labs --fork-url <robinhood chain rpc> --match-path 'hooks/toll-launch-check/*' -vv
///
///      The tests run at whatever block the fork starts at. Observations 114 and 77 are pinned by id
///      (their findings never change once recorded). The module reads the detector's latest observation
///      of each token, which is 114 and 77 at the time of writing; if the detector records a newer one,
///      `test_fork_thePinnedObservationsAreTheLatest` fails and says so.
contract TollLaunchCheckModuleForkTest is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint32 internal constant PROPOSED_CALLBACK_GAS = 150_000;

    ILaunchObservationsReader internal constant REGISTRY =
        ILaunchObservationsReader(0x730E3C356299c9203cB042F6C0A9274aeABf9AF3);
    address internal constant DETECTOR = 0x02593AbFf31f4E8eC1D5c2F297a347C51ef06E5c;

    /// @dev Observation 114: 3,356 bps of supply bought in its first block; 0 bps funding-linked.
    uint256 internal constant OVER_LIMIT_OBSERVATION = 114;
    address internal constant OVER_LIMIT = 0x4Ad0d62059eE0F4A5D7483E81B82fF40c4a7091C;
    uint256 internal constant OVER_LIMIT_FIRST_BLOCK_BPS = 3356;
    /// @dev Observation 77: 209 bps of supply bought in its first block; 0 bps funding-linked.
    uint256 internal constant UNDER_LIMIT_OBSERVATION = 77;
    address internal constant UNDER_LIMIT = 0x4EC65c12f4a02cf4A4A4a9843a2e995A42215Eae;
    uint256 internal constant UNDER_LIMIT_FIRST_BLOCK_BPS = 209;
    address internal constant UNSEEN = address(0xdead);

    bytes32 internal constant POOL_ID = keccak256("pool");
    address internal constant KERNEL = address(0xB3CA);
    address internal constant QUOTE = address(0);

    TollLaunchCheckModule internal module;
    KernelCallHarness internal harness;

    modifier onlyRobinhoodFork() {
        // Only the chain id: touching the registry here would warm it before the gas tests.
        if (block.chainid != ROBINHOOD_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        module = new TollLaunchCheckModule(REGISTRY, DETECTOR);
        harness = new KernelCallHarness();
        _;
    }

    function _config(address subject, uint16 maxFirstBlockBps, uint16 maxFundingLinkedBps, bool blockUnread)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            TollLaunchCheckModule.Config({
                poolId: POOL_ID,
                kernel: KERNEL,
                subject: subject,
                quote: QUOTE,
                maxFirstBlockBps: maxFirstBlockBps,
                maxFundingLinkedBps: maxFundingLinkedBps,
                blockUnread: blockUnread
            })
        );
    }

    function _swap(address subject, bool isBuy) internal pure returns (HookrModuleTypesV1.SwapContext memory c) {
        c.poolId = POOL_ID;
        c.subject = subject;
        c.quote = QUOTE;
        c.isBuy = isBuy;
        c.exactInput = true;
        c.amountSpecified = -int256(1 ether);
    }

    function _finding(address token, bytes32 kind, uint64 param) internal view returns (uint256 id, uint256 value) {
        (id,,, value,) = REGISTRY.latestFinding(block.chainid, token, DETECTOR, kind, param);
    }

    function _pinned(uint256 observationId, address token, uint256 firstBlockBps, uint256 fundingLinkedBps)
        internal
        view
    {
        (ILaunchObservationsById.Observation memory o, ILaunchObservationsById.Finding[] memory f) =
            ILaunchObservationsById(address(REGISTRY)).getObservation(observationId);
        assertEq(o.chainId, ROBINHOOD_CHAIN_ID);
        assertEq(o.token, token);
        assertEq(o.detector, DETECTOR);
        bool sawFirst;
        bool sawLinked;
        for (uint256 i; i < f.length; ++i) {
            if (f[i].kind == module.FIRST_BLOCK_SHARE() && f[i].param == 0) {
                assertEq(f[i].value, firstBlockBps);
                sawFirst = true;
            }
            if (f[i].kind == module.FUNDING_LINKED_SHARE() && f[i].param == 1) {
                assertEq(f[i].value, fundingLinkedBps);
                sawLinked = true;
            }
        }
        assertTrue(sawFirst);
        assertTrue(sawLinked);
    }

    function test_fork_thePinnedObservationsHoldThePinnedFacts() public onlyRobinhoodFork {
        _pinned(OVER_LIMIT_OBSERVATION, OVER_LIMIT, OVER_LIMIT_FIRST_BLOCK_BPS, 0);
        _pinned(UNDER_LIMIT_OBSERVATION, UNDER_LIMIT, UNDER_LIMIT_FIRST_BLOCK_BPS, 0);
    }

    function test_fork_thePinnedObservationsAreTheLatest() public onlyRobinhoodFork {
        (uint256 id, uint256 value) = _finding(OVER_LIMIT, module.FIRST_BLOCK_SHARE(), 0);
        assertEq(id, OVER_LIMIT_OBSERVATION);
        assertEq(value, OVER_LIMIT_FIRST_BLOCK_BPS);
        (id, value) = _finding(OVER_LIMIT, module.FUNDING_LINKED_SHARE(), 1);
        assertEq(id, OVER_LIMIT_OBSERVATION);
        assertEq(value, 0);
        (id, value) = _finding(UNDER_LIMIT, module.FIRST_BLOCK_SHARE(), 0);
        assertEq(id, UNDER_LIMIT_OBSERVATION);
        assertEq(value, UNDER_LIMIT_FIRST_BLOCK_BPS);
        (id,) = _finding(UNSEEN, module.FIRST_BLOCK_SHARE(), 0);
        assertEq(id, 0);
    }

    function test_fork_buyOverTheFirstBlockLimitIsRefused() public onlyRobinhoodFork {
        vm.expectRevert(
            abi.encodeWithSelector(
                TollLaunchCheckModule.LaunchCheckRefused.selector,
                OVER_LIMIT,
                module.FIRST_BLOCK(),
                OVER_LIMIT_FIRST_BLOCK_BPS
            )
        );
        module.beforeSwap(_swap(OVER_LIMIT, true), _config(OVER_LIMIT, 2500, 2000, false));
    }

    function test_fork_sellOverTheLimitPasses() public onlyRobinhoodFork {
        HookrModuleTypesV1.ModuleResult memory r =
            module.beforeSwap(_swap(OVER_LIMIT, false), _config(OVER_LIMIT, 2500, 2000, true));
        assertEq(r.lpFeeSurchargePips, 0);
        assertEq(r.quoteTakeBps, 0);
    }

    function test_fork_buyUnderTheLimitsPasses() public onlyRobinhoodFork {
        HookrModuleTypesV1.ModuleResult memory r =
            module.beforeSwap(_swap(UNDER_LIMIT, true), _config(UNDER_LIMIT, 2500, 2000, true));
        assertEq(r.lpFeeSurchargePips, 0);
        assertEq(r.quoteTakeBps, 0);
        assertEq(r.claimRecipient, address(0));
    }

    function test_fork_unseenTokenFollowsThePolicy() public onlyRobinhoodFork {
        module.beforeSwap(_swap(UNSEEN, true), _config(UNSEEN, 2500, 2000, false));
        vm.expectRevert(
            abi.encodeWithSelector(
                TollLaunchCheckModule.LaunchCheckRefused.selector, UNSEEN, module.NOT_OBSERVED(), uint256(0)
            )
        );
        module.beforeSwap(_swap(UNSEEN, true), _config(UNSEEN, 2500, 2000, true));
    }

    function test_fork_aLimitAtTheShareOrOffLetsTheBuyThrough() public onlyRobinhoodFork {
        module.beforeSwap(_swap(OVER_LIMIT, true), _config(OVER_LIMIT, 3356, 2000, false));
        module.beforeSwap(_swap(OVER_LIMIT, true), _config(OVER_LIMIT, 0, 2000, false));
    }

    /// @dev The gas of the kernel-style STATICCALL into `beforeSwap`, one case per test so the registry
    ///      is cold in each, with the registry's real observations. Logged for the README and held under
    ///      the proposed `callbackGasLimit`. The module itself is warm (deployed in the same test).
    function test_fork_gas_buyUnderTheLimitsBothReads() public onlyRobinhoodFork {
        (bool ok,, uint256 gasUsed) = harness.callBeforeSwap(
            address(module), PROPOSED_CALLBACK_GAS, _swap(UNDER_LIMIT, true), _config(UNDER_LIMIT, 2500, 2000, false)
        );
        assertTrue(ok);
        emit log_named_uint("buy under the limits, both reads (gas)", gasUsed);
        assertLt(gasUsed, PROPOSED_CALLBACK_GAS);
    }

    function test_fork_gas_buyRefusedOnTheFirstRead() public onlyRobinhoodFork {
        (bool ok, bytes memory out, uint256 gasUsed) = harness.callBeforeSwap(
            address(module), PROPOSED_CALLBACK_GAS, _swap(OVER_LIMIT, true), _config(OVER_LIMIT, 2500, 2000, false)
        );
        assertFalse(ok);
        assertEq(
            keccak256(out),
            keccak256(
                abi.encodeWithSelector(
                    TollLaunchCheckModule.LaunchCheckRefused.selector,
                    OVER_LIMIT,
                    module.FIRST_BLOCK(),
                    OVER_LIMIT_FIRST_BLOCK_BPS
                )
            )
        );
        emit log_named_uint("buy refused on the first read (gas)", gasUsed);
        assertLt(gasUsed, PROPOSED_CALLBACK_GAS);
    }

    function test_fork_gas_unseenBuyOneRead() public onlyRobinhoodFork {
        (bool ok,, uint256 gasUsed) = harness.callBeforeSwap(
            address(module), PROPOSED_CALLBACK_GAS, _swap(UNSEEN, true), _config(UNSEEN, 2500, 2000, false)
        );
        assertTrue(ok);
        emit log_named_uint("buy, unseen token, one read (gas)", gasUsed);
        assertLt(gasUsed, PROPOSED_CALLBACK_GAS);
    }

    function test_fork_gas_sellNoRead() public onlyRobinhoodFork {
        (bool ok,, uint256 gasUsed) = harness.callBeforeSwap(
            address(module), PROPOSED_CALLBACK_GAS, _swap(OVER_LIMIT, false), _config(OVER_LIMIT, 2500, 2000, false)
        );
        assertTrue(ok);
        emit log_named_uint("sell (gas)", gasUsed);
    }
}
