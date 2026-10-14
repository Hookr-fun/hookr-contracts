// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {GaslessToken} from "./GaslessMocks.sol";
import {EntryPointV07Code} from "./EntryPointV07Code.sol";
import {IEntryPointV07, TransientRules, FeeTarget, TestAccount} from "./HookrPaymaster.postOp.t.sol";
import {PaymasterFixtures} from "../utils/PaymasterFixtures.sol";

/// @dev A call a paymaster may not make in validation: it reads the clock and writes its own storage.
contract ClockStamp {
    uint256 public last;

    function stamp() external {
        last = block.timestamp;
    }
}

interface IEntryPointStakeInfo {
    function getDepositInfo(address account)
        external
        view
        returns (uint256 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime);
}

/// @notice N19 coverage: the gasless fork qualification and the ERC-7562 trace qualification of HookrPaymaster, which
///         the phase-one review left uncovered ("the gasless fork and ERC-7562 trace qualification").
/// @dev On a Robinhood Chain 4663 fork at foundry.toml's block, against the live canonical EntryPoint v0.7
///      (whose runtime equals the one the unit suites etch), with the release's HookrCompliance as the screen:
///      sponsored operations in both modes run through `handleOps` and settle with balanced books, and the
///      validation phase is traced opcode by opcode and checked against the ERC-7562 rules a bundler applies to a
///      paymaster: banned opcodes (OP-011, BALANCE and SELFBALANCE only for a staked entity, OP-080), GAS only before
///      a call (OP-012), no out-of-gas (OP-020), no value-bearing call (OP-061), no call or code read on an address
///      without code (OP-041), and storage (STO-010, STO-021, STO-031, STO-032, STO-033; transient storage as storage,
///      OP-070): the sender's own and associated slots, the staked paymaster's own and associated slots, and read-only
///      access elsewhere. Validation reads the paymaster's own storage, so the paymaster must be staked before any
///      bundler accepts it; the release plan stakes nothing (activation is a separate owner step after a 4663 bundler
///      is qualified), so the test stakes it as that step would. Skipped unless ALCHEMY_RPC_URL is set; the two trace
///      tests are also skipped unless forge's tracer runs (-vvv):
///      `forge test --match-path test/gasless/HookrPaymaster.erc7562Fork.t.sol -vvv`.
contract HookrPaymasterErc7562ForkTest is PaymasterFixtures {
    address internal constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    /// @dev A fresh bundler account, empty on the fork.
    address payable internal constant BUNDLER = payable(address(uint160(uint256(keccak256("hookr.n19.bundler")))));
    /// @dev foundry.toml's fork_block_number.
    uint256 internal constant FORK_BLOCK = 74_062_645;
    uint128 internal constant PVG = 60_000;
    uint128 internal constant VGL = 150_000;
    uint128 internal constant CGL = 200_000;
    uint128 internal constant PM_VGL = 250_000;
    uint128 internal constant POST_OP = 240_000;
    uint256 internal constant FEE = 0.0005 ether;
    bytes32 internal constant USER_OP_EVENT =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");

    HookrCompliance internal compliance;
    TransientRules internal rules;
    FeeTarget internal target;
    TestAccount internal bob;
    TestAccount internal alice;
    bool internal live;

    // Trace audit state.
    bytes32[] internal preimageHashes;
    bytes32[] internal preimageKeys;
    uint256 internal violations;

    function setUp() public {
        if (bytes(vm.envOr("ALCHEMY_RPC_URL", string(""))).length == 0) return;
        vm.createSelectFork("robinhood", FORK_BLOCK);
        assertEq(EP.codehash, EntryPointV07Code.CODEHASH, "the live EntryPoint runs the runtime the unit suites etch");
        compliance = new HookrCompliance(OWNER, DELAY);
        pm = new HookrPaymaster(EP, address(compliance), OWNER, DELAY, TREASURY);
        usd = new GaslessToken();
        rules = new TransientRules();
        target = new FeeTarget(rules);
        _setPolicy(_policy(true, 0.05 ether));
        _allowCall(address(target), FeeTarget.ping.selector);
        _allowCall(address(target), FeeTarget.pay.selector);
        _setToken(address(usd), _usdConfig(), USD_PER_ETH);
        _addRules(address(rules));
        _setQuotes(new address[](1));
        _gov(keccak256("GRANT_KEEPER"), abi.encode(KEEPER));
        vm.prank(OWNER);
        pm.grantKeeper(KEEPER);
        _fundRebates(1 ether);
        vm.deal(address(this), 100 ether);
        IEntryPointV07(EP).depositTo{value: 5 ether}(address(pm));
        // The activation step the plan leaves to the owner: stake with the bundlers' one-day unstake delay.
        vm.deal(OWNER, OWNER.balance + 1 ether);
        vm.prank(OWNER);
        pm.addStake{value: 1 ether}(1 days);
        bob = new TestAccount(EP);
        alice = new TestAccount(EP);
        pm.depositCredit{value: 1 ether}(address(bob));
        usd.mint(address(alice), 100_000e18);
        alice.approveToken(usd, address(pm));
        live = true;
    }

    /// @dev Debug trace recording needs forge's tracer, which `forge test` starts only at -vvv or above. Without it
    ///      the trace tests are reported skipped, never passed: run this file with -vvv.
    function _requireTracer() internal {
        try vm.startDebugTraceRecording() {
            vm.stopAndReturnDebugTraceRecording();
        } catch {
            vm.skip(true, "ERC-7562 trace needs forge's tracer: run with -vvv");
        }
    }

    /// @dev The keeper's rate update a token operation needs within its TTL.
    function _refreshRate() internal {
        vm.prank(KEEPER);
        pm.setRate(address(usd), USD_PER_ETH, 3_600);
    }

    function _op(TestAccount who, bytes memory inner, uint8 mode)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(who);
        op.nonce = IEntryPointV07(EP).getNonce(address(who), 0);
        op.callData = abi.encodeWithSelector(TestAccount.execute.selector, address(target), uint256(0), inner);
        op.accountGasLimits = bytes32((uint256(VGL) << 128) | uint256(CGL));
        op.preVerificationGas = PVG;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(20 gwei));
        op.paymasterAndData = abi.encodePacked(
            address(pm),
            PM_VGL,
            POST_OP,
            mode,
            mode == 0 ? address(0) : address(usd),
            type(uint128).max,
            uint48(block.timestamp + 1 days)
        );
    }

    /// @dev Both modes through the live EntryPoint: each operation succeeds, the paymaster pays the bundler from its
    ///      deposit, and the token books hold every unit the paymaster holds.
    function test_fork_sponsoredOperationsSettleOnTheLiveEntryPoint() public {
        if (!live) return;
        (, bool staked, uint112 stake, uint32 delay,) = IEntryPointStakeInfo(EP).getDepositInfo(address(pm));
        assertTrue(staked && stake == 1 ether && delay == 1 days, "staked as the activation step would");
        _refreshRate();
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _op(bob, abi.encodeCall(FeeTarget.pay, (FEE)), 0);
        ops[1] = _op(alice, abi.encodeCall(FeeTarget.pay, (FEE)), 1);
        uint256 deposit = IEntryPointV07(EP).balanceOf(address(pm));
        uint256 budget = pm.rebateBudget();
        vm.recordLogs();
        vm.prank(BUNDLER, BUNDLER);
        IEntryPointV07(EP).handleOps{gas: 5_000_000}(ops, BUNDLER);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != EP || logs[i].topics[0] != USER_OP_EVENT) continue;
            (, bool success, uint256 cost,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
            assertTrue(success, "the sponsored operation succeeded");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(pm), "sponsored by the paymaster");
            paid += cost;
            ++n;
        }
        assertEq(n, 2, "two operations");
        assertEq(deposit - IEntryPointV07(EP).balanceOf(address(pm)), paid, "the deposit paid exactly the gas cost");
        assertEq(BUNDLER.balance, paid, "and the bundler received it");
        assertLt(pm.rebateBudget(), budget, "the fees were rebated from the budget");
        uint256 held = usd.balanceOf(address(pm));
        assertEq(held, pm.totalCredit(address(usd)) + pm.revenue(address(usd)), "token books balanced");
        assertGt(pm.revenue(address(usd)), 0, "the token operation was charged");
        assertGt(pm.revenue(address(0)), 0, "the credit operation was charged");
    }

    /// @dev Negative control: the audit catches a banned opcode and a write outside the allowed slots.
    function test_fork_auditCatchesABannedOpcodeAndAForeignWrite() public {
        if (!live) return;
        _requireTracer();
        ClockStamp clock = new ClockStamp();
        vm.startDebugTraceRecording();
        clock.stamp();
        Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();
        _audit(steps, address(bob), address(pm));
        assertEq(violations, 2, "TIMESTAMP and a foreign SSTORE");
    }

    /// @dev The validation phase of both modes, traced and checked against ERC-7562.
    function test_fork_validationFollowsErc7562() public {
        if (!live) return;
        _requireTracer();
        _refreshRate();
        _auditValidation(_op(bob, abi.encodeCall(FeeTarget.ping, ()), 0), address(bob));
        _auditValidation(_op(alice, abi.encodeCall(FeeTarget.ping, ()), 1), address(alice));
        assertEq(violations, 0, "no ERC-7562 violation in validation");
    }

    function _auditValidation(PackedUserOperation memory op, address sender) internal {
        vm.startDebugTraceRecording();
        vm.prank(EP);
        pm.validatePaymasterUserOp(op, keccak256(abi.encode(op.sender, op.nonce)), 0.01 ether);
        Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();
        _audit(steps, sender, address(pm));
    }

    /// @dev Counts every ERC-7562 rule a traced validation breaks for `entity` (a staked paymaster) and `sender`.
    function _audit(Vm.DebugStep[] memory steps, address sender, address entity) internal {
        delete preimageHashes;
        delete preimageKeys;
        assertGt(steps.length, 0, "validation traced");
        // Keccak preimages first: a slot is associated with an address when it is keccak(address || x) + n.
        for (uint256 i; i < steps.length; ++i) {
            if (steps[i].opcode != 0x20 || steps[i].memoryInput.length < 32) continue;
            bytes memory input = steps[i].memoryInput;
            bytes32 key;
            assembly ("memory-safe") {
                key := mload(add(input, 32))
            }
            preimageHashes.push(keccak256(input));
            preimageKeys.push(key);
        }
        uint256 own;
        uint256 associated;
        uint256 readOnly;
        for (uint256 i; i < steps.length; ++i) {
            Vm.DebugStep memory s = steps[i];
            // The recording also holds this test's own steps around the call (loading `pm`, encoding the call).
            if (s.contractAddr == address(this)) continue;
            uint8 op_ = s.opcode;
            if (s.isOutOfGas) _violation("OP-020 out of gas", s);
            if (_banned(op_)) _violation("OP-011 banned opcode", s);
            if ((op_ == 0x31 || op_ == 0x47) && s.contractAddr != entity) _violation("OP-080 balance", s);
            if (op_ == 0x5a) {
                uint8 next = i + 1 < steps.length ? steps[i + 1].opcode : 0;
                if (next != 0xf1 && next != 0xf2 && next != 0xf4 && next != 0xfa) _violation("OP-012 GAS", s);
            }
            if (op_ == 0xf1 || op_ == 0xf2) {
                if (s.stack.length > 2 && s.stack[2] != 0) _violation("OP-061 value", s);
            }
            if (op_ == 0xf1 || op_ == 0xf2 || op_ == 0xf4 || op_ == 0xfa) {
                address callee = address(uint160(s.stack[1]));
                if (callee.code.length == 0 && uint160(callee) > 0x11) _violation("OP-041 call without code", s);
            }
            if (op_ == 0x3b || op_ == 0x3c || op_ == 0x3f) {
                address read = address(uint160(s.stack[0]));
                if (read.code.length == 0 && read != sender) _violation("OP-041 code read without code", s);
            }
            if (op_ == 0x54 || op_ == 0x55 || op_ == 0x5c || op_ == 0x5d) {
                bool write = op_ == 0x55 || op_ == 0x5d;
                address account = s.contractAddr;
                bytes32 slot = bytes32(s.stack[0]);
                if (account == entity) {
                    ++own; // STO-031: the staked entity's own storage
                } else if (account == sender || _associated(slot, sender)) {
                    ++associated; // STO-010, STO-021
                } else if (_associated(slot, entity)) {
                    ++associated; // STO-032: the staked entity's associated slots elsewhere
                } else if (!write) {
                    ++readOnly; // STO-033: read-only elsewhere, for a staked entity
                    emit log_named_address("read-only slot of", account);
                    emit log_named_bytes32("  slot", slot);
                } else {
                    _violation("STO write outside the sender's and the paymaster's slots", s);
                }
            }
        }
        emit log_named_uint("validation steps", steps.length);
        emit log_named_uint("paymaster's own slots touched (needs stake)", own);
        emit log_named_uint("sender- or paymaster-associated slots", associated);
        emit log_named_uint("read-only slots elsewhere (needs stake)", readOnly);
    }

    function _associated(bytes32 slot, address who) internal view returns (bool) {
        for (uint256 j; j < preimageHashes.length; ++j) {
            if (address(uint160(uint256(preimageKeys[j]))) != who || uint256(preimageKeys[j]) >> 160 != 0) continue;
            uint256 base = uint256(preimageHashes[j]);
            if (uint256(slot) >= base && uint256(slot) - base <= 128) return true;
        }
        return false;
    }

    /// @dev ERC-7562 OP-011, with CREATE2 (OP-031) and BALANCE/SELFBALANCE (OP-080) checked separately.
    function _banned(uint8 op_) internal pure returns (bool) {
        return op_ == 0x3a || op_ == 0x45 || op_ == 0x44 || op_ == 0x42 || op_ == 0x48 || op_ == 0x40 || op_ == 0x43
            || op_ == 0x32 || op_ == 0xf0 || op_ == 0xf5 || op_ == 0x41 || op_ == 0xff || op_ == 0x49 || op_ == 0x4a;
    }

    function _violation(string memory rule, Vm.DebugStep memory s) internal {
        ++violations;
        emit log_named_string("ERC-7562 violation", rule);
        emit log_named_address("  at", s.contractAddr);
        emit log_named_uint("  opcode", s.opcode);
    }
}
