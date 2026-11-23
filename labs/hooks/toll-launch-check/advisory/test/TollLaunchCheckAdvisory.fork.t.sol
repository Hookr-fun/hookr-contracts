// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "hookr-1/src/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr-1/src/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr-1/src/interfaces/IHookrRegistry.sol";

import {TollLaunchCheckAdvisory, ILaunchObservationsReader} from "../src/TollLaunchCheckAdvisory.sol";

/// @dev The ERC-8470 write used to record a worst-case observation on the fork, and the read used to pin
///      observations by id.
interface ILaunchObservationsWriter {
    struct Tally {
        uint16 against;
        uint16 careful;
        uint16 clear;
    }

    struct Finding {
        bytes32 kind;
        uint256 value;
        uint64 param;
        uint8 lean;
    }

    struct ObservationInput {
        uint8 kind;
        bytes32 launchId;
        uint256 chainId;
        address token;
        uint64 observedBlock;
        bytes32 observedBlockHash;
        Tally tally;
        bytes32 reportHash;
        string reportURI;
        bytes32 evidenceRoot;
    }

    function recordObservation(ObservationInput calldata input, Finding[] calldata findings)
        external
        returns (uint256 observationId, bytes32 launchKey);

    function MAX_FINDINGS() external view returns (uint256);
}

/// @dev Stands in for HookrRoot's registry: it reports this advisory admitted as an ADVISORY for the stand-in root.
contract StandInRegistry {
    function admission(address, address implementation) external view returns (IHookrRegistry.Admission memory a) {
        a.kind = IHookrRegistry.Kind.ADVISORY;
        a.implementation = implementation;
        a.codeHash = implementation.codehash;
        a.gasLimit = 250_000;
        a.phaseMask = HookrTypes.BEFORE_SWAP;
    }
}

/// @dev Stands in for HookrRoot: it binds pools on its own address and calls `beforeSwap` the way
///      `HookrRoot._advice` does, through HookrRootStorage.bounded's assembly: a STATICCALL with the pool's advisory
///      gas limit that copies 128 bytes and is ok only when exactly 128 bytes come back. It is not HookrRoot.
contract StandInRoot {
    StandInRegistry public immutable registry = new StandInRegistry();

    function bind(IHookrAdvisory advisory, PoolKey memory key, HookrTypes.PoolConfig memory pc, bytes memory data)
        external
        returns (bytes32)
    {
        return advisory.bind(key, pc, data);
    }

    function advise(address advisory, uint256 gasLimit, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool ok, HookrTypes.Advice memory advice, uint256 gasUsed)
    {
        bytes memory input = abi.encodeCall(IHookrAdvisory.beforeSwap, (x));
        bytes memory output = new bytes(128);
        uint256 start = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, advisory, add(input, 32), mload(input), add(output, 32), 128)
            ok := and(ok, eq(returndatasize(), 128))
        }
        gasUsed = start - gasleft();
        if (ok) advice = abi.decode(output, (HookrTypes.Advice));
    }
}

/// @dev Reads the live ERC-8470 registry on Robinhood Chain (4663) and Toll's detector. The RPC comes from
///      `--fork-url` only; without a Robinhood Chain fork every test here skips.
///
///      forge test --root labs/hooks/toll-launch-check/advisory --fork-url <robinhood chain rpc> -vv
///
///      Observations 114 and 77 are pinned by id, as in the module's fork test. The worst case records, on the
///      fork only, an observation of a fresh token by the detector with the registry's maximum number of findings
///      and the two shares last, so both reads scan every finding. Every measured call starts with the advisory and
///      the registry cold (`vm.cool`).
contract TollLaunchCheckAdvisoryForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant REGISTRY = 0x730E3C356299c9203cB042F6C0A9274aeABf9AF3;
    address internal constant DETECTOR = 0x02593AbFf31f4E8eC1D5c2F297a347C51ef06E5c;
    address internal constant HISTORY_STORAGE = 0x0000F90827F1C53a10cb7A02335B175320002935;

    /// @dev Observation 114: 3,356 bps of supply bought in its first block; 0 bps funding-linked.
    address internal constant OVER_LIMIT = 0x4Ad0d62059eE0F4A5D7483E81B82fF40c4a7091C;
    /// @dev Observation 77: 209 bps of supply bought in its first block; 0 bps funding-linked.
    address internal constant UNDER_LIMIT = 0x4EC65c12f4a02cf4A4A4a9843a2e995A42215Eae;
    address internal constant UNSEEN = address(0xdead);
    address internal constant WORST = address(0xC0FFEE);
    address internal constant QUOTE = address(0x0A11);
    uint32 internal constant ACTIVE = 7_200;

    TollLaunchCheckAdvisory internal advisory;
    StandInRoot internal root;
    uint32 internal limit;

    modifier onlyRobinhoodFork() {
        // Only the chain id: touching the registry here would warm it before the gas tests.
        if (block.chainid != ROBINHOOD_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        advisory = new TollLaunchCheckAdvisory(ILaunchObservationsReader(REGISTRY), DETECTOR);
        root = new StandInRoot();
        limit = advisory.MIN_ADVISORY_GAS();
        _;
    }

    function _key(address subject) internal view returns (PoolKey memory key) {
        key.currency0 = Currency.wrap(subject < QUOTE ? subject : QUOTE);
        key.currency1 = Currency.wrap(subject < QUOTE ? QUOTE : subject);
        key.fee = 0x800000;
        key.tickSpacing = 60;
        key.hooks = IHooks(address(root));
    }

    function _bind(address subject, bool blockUnread) internal returns (PoolKey memory key) {
        key = _key(subject);
        HookrTypes.PoolConfig memory pc;
        pc.subject = Currency.wrap(subject);
        pc.quote = Currency.wrap(QUOTE);
        pc.advisory = address(advisory);
        pc.advisoryGasLimit = limit;
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP;
        root.bind(advisory, key, pc, abi.encode(TollLaunchCheckAdvisory.Config(2500, 2000, blockUnread, ACTIVE)));
    }

    function _context(PoolKey memory key, address subject, bool isBuy)
        internal
        pure
        returns (HookrTypes.SwapContext memory x)
    {
        x.id = key.toId();
        x.subject = Currency.wrap(subject);
        x.quote = Currency.wrap(QUOTE);
        x.isBuy = isBuy;
        x.exactInput = true;
        x.amountSpecified = -1e18;
        x.authenticated = true;
    }

    /// @dev The root-style call, cold, with exactly the advisory's minimum gas limit; it must answer.
    function _measure(address subject, bool isBuy, bool blockUnread, string memory label)
        internal
        returns (HookrTypes.Advice memory advice)
    {
        PoolKey memory key = _bind(subject, blockUnread);
        HookrTypes.SwapContext memory x = _context(key, subject, isBuy);
        vm.cool(address(advisory));
        vm.cool(REGISTRY);
        bool ok;
        uint256 gasUsed;
        (ok, advice, gasUsed) = root.advise(address(advisory), limit, x);
        assertTrue(ok, "the call did not answer within the gas limit");
        assertEq(advice.lpFeeSurchargePips, 0);
        assertEq(advice.quoteTakePips, 0);
        assertEq(advice.recipient, address(0));
        emit log_named_uint(label, gasUsed);
        assertLt(gasUsed, limit);
    }

    /// @dev Records, as the detector, an observation of `token` with the registry's maximum number of findings and
    ///      the funding-linked share (param 1) last. Without `sameKind`: 30 findings of other kinds, then the
    ///      first-block share, then the funding-linked share, so both reads scan everything. With `sameKind`, the
    ///      worst case: the 30 are funding-linked shares under other params (2..31). The registry compares the kind
    ///      first and reads the param only on a kind match, so the second read also reads 31 params, and the first
    ///      read finds the first-block share last and reads its value.
    function _recordWorst(address token, uint256 firstBlock, uint256 linked, bool sameKind) internal {
        ILaunchObservationsWriter w = ILaunchObservationsWriter(REGISTRY);
        uint256 n = w.MAX_FINDINGS();
        ILaunchObservationsWriter.Finding[] memory f = new ILaunchObservationsWriter.Finding[](n);
        for (uint256 i; i < n - 2; ++i) {
            f[i] = sameKind
                ? ILaunchObservationsWriter.Finding(advisory.FUNDING_LINKED_SHARE(), 0, uint64(i + 2), 0)
                : ILaunchObservationsWriter.Finding(keccak256(abi.encode("toll.filler", i)), i, 0, 0);
        }
        f[n - 2] = ILaunchObservationsWriter.Finding(advisory.FIRST_BLOCK_SHARE(), firstBlock, 0, 0);
        f[n - 1] = ILaunchObservationsWriter.Finding(advisory.FUNDING_LINKED_SHARE(), linked, 1, 0);
        uint64 observed = uint64(block.number - 1);
        bytes32 hash = blockhash(observed);
        if (HISTORY_STORAGE.code.length != 0) {
            (bool ok, bytes memory ret) = HISTORY_STORAGE.staticcall(abi.encode(uint256(observed)));
            if (ok && ret.length >= 32 && bytes32(ret) != bytes32(0)) hash = bytes32(ret);
        }
        if (hash == bytes32(0)) hash = keccak256("unchecked");
        ILaunchObservationsWriter.ObservationInput memory input = ILaunchObservationsWriter.ObservationInput({
            kind: 2, // KeyKind.Token
            launchId: bytes32(0),
            chainId: block.chainid,
            token: token,
            observedBlock: observed,
            observedBlockHash: hash,
            tally: ILaunchObservationsWriter.Tally(0, 0, 0),
            reportHash: keccak256("fork-only worst case"),
            reportURI: "fork-only",
            evidenceRoot: bytes32(0)
        });
        vm.prank(DETECTOR);
        w.recordObservation(input, f);
        (uint256 id,,, uint256 value,) =
            ILaunchObservationsReader(REGISTRY).latestFinding(block.chainid, token, DETECTOR, f[n - 1].kind, 1);
        assertGt(id, 0);
        assertEq(value, linked);
    }

    // --- decisions against the live registry ---------------------------------------------------------------------

    function test_fork_buyOverTheFirstBlockLimitIsRejected() public onlyRobinhoodFork {
        HookrTypes.Advice memory a = _measure(OVER_LIMIT, true, false, "buy refused on the first read (gas)");
        assertTrue(a.reject);
        PoolKey memory key = _key(OVER_LIMIT);
        (bool allowed, bytes32 reason, uint256 value) = advisory.check(address(root), key.toId(), OVER_LIMIT);
        assertFalse(allowed);
        assertEq(reason, advisory.FIRST_BLOCK());
        assertEq(value, 3356);
    }

    function test_fork_buyUnderTheLimitsBothReads() public onlyRobinhoodFork {
        assertFalse(_measure(UNDER_LIMIT, true, true, "buy, both shares read, passes (gas)").reject);
    }

    function test_fork_unreadCoinFailsOpen() public onlyRobinhoodFork {
        assertFalse(_measure(UNSEEN, true, false, "buy, unread coin, one read (gas)").reject);
    }

    function test_fork_unreadCoinWithBlockUnreadIsRejected() public onlyRobinhoodFork {
        assertTrue(_measure(UNSEEN, true, true, "buy, unread coin, blockUnread (gas)").reject);
    }

    function test_fork_sellOverTheLimitPasses() public onlyRobinhoodFork {
        assertFalse(_measure(OVER_LIMIT, false, true, "sell (gas)").reject);
    }

    function test_fork_buyAfterTheWindowPasses() public onlyRobinhoodFork {
        PoolKey memory key = _bind(OVER_LIMIT, true);
        vm.roll(block.number + ACTIVE - 1);
        (bool ok, HookrTypes.Advice memory a,) = root.advise(address(advisory), limit, _context(key, OVER_LIMIT, true));
        assertTrue(ok);
        assertTrue(a.reject, "inside the window");
        vm.roll(block.number + 1);
        vm.cool(address(advisory));
        vm.cool(REGISTRY);
        uint256 gasUsed;
        (ok, a, gasUsed) = root.advise(address(advisory), limit, _context(key, OVER_LIMIT, true));
        assertTrue(ok);
        assertFalse(a.reject, "at the window's end");
        emit log_named_uint("buy after the window, no read (gas)", gasUsed);
    }

    // --- worst case: an observation with the registry's maximum number of findings --------------------------------

    function test_fork_32FindingsBothReadsWithinTheLimit() public onlyRobinhoodFork {
        _recordWorst(WORST, 2500, 2000, false);
        assertFalse(_measure(WORST, true, false, "32 findings, other kinds: both reads, passes (gas)").reject);
    }

    function test_fork_worstCaseBothReadsWithinTheLimit() public onlyRobinhoodFork {
        _recordWorst(WORST, 2500, 2000, true);
        assertFalse(
            _measure(WORST, true, false, "worst case, 30 other funding-linked findings first: passes (gas)").reject
        );
    }

    /// @dev The worst case's whole cost, with the registry's maximum gas limit, so MIN_ADVISORY_GAS can be read
    ///      against it.
    function test_fork_worstCaseCostUnderTheRegistryMaximum() public onlyRobinhoodFork {
        _recordWorst(WORST, 2500, 2001, true);
        limit = 2_000_000;
        assertTrue(_measure(WORST, true, false, "worst case under a 2,000,000 limit (gas)").reject);
    }

    function test_fork_worstCaseRefusedOnTheSecondRead() public onlyRobinhoodFork {
        _recordWorst(WORST, 2500, 2001, true);
        assertTrue(_measure(WORST, true, false, "worst case, refused on the second read (gas)").reject);
    }
}
