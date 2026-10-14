// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrDelegation} from "../../src/libraries/HookrDelegation.sol";
import {HookrGoverned} from "../../src/base/HookrGoverned.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {HookrComplianceGuard} from "../../src/compliance/HookrComplianceGuard.sol";
import {IHookrComplianceGuard} from "../../src/interfaces/IHookrComplianceGuard.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRegistryChecks} from "../../src/libraries/HookrRegistryChecks.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {MockEntryPoint} from "../gasless/GaslessMocks.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @dev The six EIP-7702 checks src carried before HookrDelegation gathered them, copied verbatim from r31-all
///      (HookrGoverned._code, HookrTreasury._delegated, HookrComplianceGuard's constructor, HookrRegistryChecks'
///      holdsOwnCode and requireUndelegated, HookrLane._holdsOwnCode).
library PriorDelegationChecks {
    function governedCode(address account) internal view returns (uint256 size, bool delegated) {
        assembly ("memory-safe") {
            size := extcodesize(account)
            if size {
                let free := mload(0x40)
                extcodecopy(account, free, 0, 1)
                delegated := eq(byte(0, mload(free)), 0xef)
            }
        }
    }

    function treasuryDelegated(address account) internal view returns (bool delegated) {
        assembly ("memory-safe") {
            if extcodesize(account) {
                let free := mload(0x40)
                extcodecopy(account, free, 0, 1)
                delegated := eq(byte(0, mload(free)), 0xef)
            }
        }
    }

    function guardRefuses(address compliance_) internal view returns (bool) {
        uint256 size;
        bool delegated;
        assembly ("memory-safe") {
            size := extcodesize(compliance_)
            if size {
                let free := mload(0x40)
                extcodecopy(compliance_, free, 0, 1)
                delegated := eq(byte(0, mload(free)), 0xef)
            }
        }
        return size == 0 || delegated;
    }

    function registryHoldsOwnCode(address account) internal view returns (bool ok) {
        assembly ("memory-safe") {
            if extcodesize(account) {
                extcodecopy(account, 0, 0, 1)
                ok := iszero(eq(byte(0, mload(0)), 0xef))
            }
        }
    }

    function registryDesignator(address account) internal view returns (bool delegated) {
        assembly ("memory-safe") {
            if eq(extcodesize(account), 23) {
                extcodecopy(account, 0, 0, 3)
                delegated := eq(shr(232, mload(0)), 0xef0100)
            }
        }
    }

    function laneHoldsOwnCode(address account) internal view returns (bool ok) {
        assembly ("memory-safe") {
            let size := extcodesize(account)
            ok := iszero(iszero(size))
            if eq(size, 23) {
                extcodecopy(account, 0, 0, 1)
                ok := iszero(eq(byte(0, mload(0)), 0xef))
            }
        }
    }
}

/// @dev HookrGoverned's two checks, called the way HookrCompliance, HookrPaymaster and the extensions call them.
contract GovernedDelegationProbe is HookrGoverned {
    constructor() HookrGoverned(msg.sender, 1 days) {}

    function refuseDelegated(address account) external view {
        _refuseDelegated(account);
    }

    function requireDeployedCode(address account) external view {
        _requireDeployedCode(account);
    }
}

/// @dev HookrRegistryChecks' three account checks, compiled in as the registry and its linked libraries compile them.
contract RegistryDelegationProbe {
    function requireContract(address account) external view {
        HookrRegistryChecks.requireContract(account);
    }

    function requireUndelegated(address account) external view {
        HookrRegistryChecks.requireUndelegated(account);
    }

    function holdsOwnCode(address account) external view returns (bool) {
        return HookrRegistryChecks.holdsOwnCode(account);
    }
}

/// @dev Any contract code: a quote asset the registry has not qualified.
contract UnqualifiedQuoteStub {
    function totalSupply() external pure returns (uint256) {
        return 1;
    }
}

/// @dev A delegate an EIP-7702 authorization points at.
contract DelegationTarget {
    fallback() external payable {}
}

/// @notice B094: the EIP-7702 checks run through one internal library, HookrDelegation, and every site answers what it
///         answered before, on every code an account can hold.
/// @dev Two predicates, because the checks were never one: on Robinhood Chain 4663 code that starts with 0xEF is an
///      EIP-7702 delegation designator (0xef0100 || target, 23 bytes) or a Stylus program (0xeff0, a format byte and
///      the program, at least 4 bytes). The chain's EIP-3541 refuses every other 0xEF-prefixed code but lets a Stylus
///      program deploy: read through the RPC at blocks 79,347,301 to 79,348,440 (ArbWasm.stylusVersion() = 3), a
///      simulated CREATE returning 0xeff00000, 0xeff00100, 0xeff00200, 0xeff000ff or 23 bytes that start 0xeff000
///      succeeds, while 0xeff000, 0xeff00f00, 0xeff0ff00, 0xeff10000, 0xef000000, 0xef010000, 0xef0100aa and 23 bytes
///      that start 0xef0100 fail with "invalid code: must not begin with 0xef". HookrGoverned, HookrTreasury,
///      HookrComplianceGuard and the registry's requireContract and
///      holdsOwnCode refuse both (isDelegated); the registry's owner, nominee and guardian check refuses the designator
///      only (isDesignator); HookrLane refuses a pool subject whose 23 bytes start with 0xEF and accepts a Stylus token
///      of any other length. Each keeps that answer: the fuzz cases compare every site with its verbatim prior copy.
contract DelegationPredicateTest is PeripheryFixture {
    uint8 internal constant ACCEPTED = 0;
    uint8 internal constant NOT_A_CONTRACT = 1;
    uint8 internal constant REFUSED = 2;
    uint256 internal constant DELEGATOR_KEY = 0xB094;

    address internal probe = makeAddr("delegation-probe");
    GovernedDelegationProbe internal governed;
    RegistryDelegationProbe internal checks;
    HookrTreasury internal treasury;
    UnqualifiedQuoteStub internal quoteStub;
    DelegationTarget internal target;

    function setUp() public {
        _setUpPeriphery();
        vm.setEvmVersion("prague");
        governed = new GovernedDelegationProbe();
        checks = new RegistryDelegationProbe();
        treasury = new HookrTreasury(address(this), address(0xBEEF), IPoolManager(address(new MockEntryPoint())));
        quoteStub = new UnqualifiedQuoteStub();
        target = new DelegationTarget();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev The outcome of a call that may revert NotAContract(account) or a refusal carrying `refused`.
    function _outcome(address callee, bytes memory data, bytes4 notAContract, bytes4 refused) internal returns (uint8) {
        (bool ok, bytes memory ret) = callee.call(data);
        if (ok) return ACCEPTED;
        if (bytes4(ret) == notAContract) {
            assertEq(ret, abi.encodeWithSelector(notAContract, probe), "NotAContract names the account");
            return NOT_A_CONTRACT;
        }
        assertEq(ret, abi.encodeWithSelector(refused, probe), "only the delegation refusal, naming the account");
        return REFUSED;
    }

    /// @dev Whether HookrComplianceGuard's constructor refuses `compliance_`.
    function _guardRefuses(address compliance_) internal returns (bool) {
        try new HookrComplianceGuard(compliance_) {
            return false;
        } catch (bytes memory ret) {
            assertEq(ret, abi.encodeWithSelector(IHookrComplianceGuard.InvalidCompliance.selector, compliance_));
            return true;
        }
    }

    /// @dev Whether HookrLane accepts `subject` as a pool subject: initializePool from the launcher with an otherwise
    ///      valid shape and an unqualified quote fails InvalidConfig when the subject check refuses and
    ///      UnqualifiedQuote(quote), the next check, when it passes.
    function _laneAccepts(address subject) internal returns (bool) {
        address quote = address(quoteStub);
        (address c0, address c1) = subject < quote ? (subject, quote) : (quote, subject);
        PoolKey memory key =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        HookrTypes.PoolConfig memory pc;
        pc.subject = Currency.wrap(subject);
        pc.quote = Currency.wrap(quote);
        pc.rules = address(rules);
        pc.liquidityOwner = address(this);
        pc.baseLpFeePips = 3000;
        pc.caps = HookrTypes.Caps(600_000, 0, 0);
        pc.rulesGasLimit = 2_000_000;
        vm.prank(address(launcher));
        (bool ok, bytes memory ret) =
            address(root).call(abi.encodeCall(HookrRoot.initializePool, (key, pc, bytes(""), bytes(""), SQRT_ONE)));
        assertFalse(ok, "the probe never opens a pool");
        if (bytes4(ret) == IHookrRootEvents.InvalidConfig.selector) return false;
        assertEq(ret, abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, quote), "the next check");
        return true;
    }

    /// @dev Every site's answer for the code `probe` now holds, against its prior copy.
    function _assertEverySiteAsBefore() internal {
        bytes memory code = probe.code;
        (uint256 size, bool broad) = PriorDelegationChecks.governedCode(probe);
        assertEq(size, code.length);
        bool designator = PriorDelegationChecks.registryDesignator(probe);

        // The two predicates, against their definitions.
        assertEq(HookrDelegation.isDelegated(probe), code.length != 0 && uint8(code[0]) == 0xef, "isDelegated");
        assertEq(
            HookrDelegation.isDesignator(probe),
            code.length == 23 && uint8(code[0]) == 0xef && uint8(code[1]) == 0x01 && uint8(code[2]) == 0x00,
            "isDesignator"
        );
        assertEq(HookrDelegation.isDelegated(probe), broad, "isDelegated is the prior 0xEF read");
        assertEq(HookrDelegation.isDesignator(probe), designator, "isDesignator is the prior 0xef0100 read");

        // HookrGoverned: owner, nominee, acceptor, guardian and source checks.
        bytes4 governedDelegated = IHookrGoverned.DelegatedAccount.selector;
        bytes4 governedNoCode = IHookrGoverned.NotAContract.selector;
        assertEq(
            _outcome(
                address(governed),
                abi.encodeCall(GovernedDelegationProbe.refuseDelegated, (probe)),
                governedNoCode,
                governedDelegated
            ),
            broad ? REFUSED : ACCEPTED,
            "HookrGoverned._refuseDelegated"
        );
        assertEq(
            _outcome(
                address(governed),
                abi.encodeCall(GovernedDelegationProbe.requireDeployedCode, (probe)),
                governedNoCode,
                governedDelegated
            ),
            size == 0 ? NOT_A_CONTRACT : broad ? REFUSED : ACCEPTED,
            "HookrGoverned._requireDeployedCode"
        );

        // HookrTreasury: a nominee (the owner and acceptor checks run the same private function).
        assertEq(
            _outcome(
                address(treasury),
                abi.encodeCall(HookrTreasury.proposeOwner, (probe)),
                bytes4(0),
                IHookrTreasury.DelegatedAccount.selector
            ),
            PriorDelegationChecks.treasuryDelegated(probe) ? REFUSED : ACCEPTED,
            "HookrTreasury._refuseDelegated"
        );

        // HookrComplianceGuard: its compliance registry.
        assertEq(_guardRefuses(probe), PriorDelegationChecks.guardRefuses(probe), "HookrComplianceGuard");

        // HookrRegistryChecks: modules, roots, launchers, executors, quotes; owner and guardian; any-quote mode.
        bool held = PriorDelegationChecks.registryHoldsOwnCode(probe);
        assertEq(
            _outcome(
                address(checks),
                abi.encodeCall(RegistryDelegationProbe.requireContract, (probe)),
                HookrRegistryChecks.NotAContract.selector,
                HookrRegistryChecks.DelegatedAccount.selector
            ),
            size == 0 ? NOT_A_CONTRACT : held ? ACCEPTED : REFUSED,
            "HookrRegistryChecks.requireContract"
        );
        assertEq(
            _outcome(
                address(checks),
                abi.encodeCall(RegistryDelegationProbe.requireUndelegated, (probe)),
                bytes4(0),
                HookrRegistryChecks.DelegatedAccount.selector
            ),
            designator ? REFUSED : ACCEPTED,
            "HookrRegistryChecks.requireUndelegated"
        );
        assertEq(checks.holdsOwnCode(probe), held, "HookrRegistryChecks.holdsOwnCode");

        // HookrLane: the pool subject.
        assertEq(_laneAccepts(probe), PriorDelegationChecks.laneHoldsOwnCode(probe), "HookrLane._holdsOwnCode");
    }

    /// @dev Code of `length` bytes starting with `prefix` (at most `length` of it), the rest from `seed`.
    function _code(bytes memory prefix, uint256 length, bytes32 seed) internal pure returns (bytes memory code) {
        code = new bytes(length);
        for (uint256 i; i < length; ++i) {
            code[i] = i < prefix.length ? prefix[i] : bytes1(keccak256(abi.encode(seed, i)));
        }
    }

    /// @dev Whether an account can hold `code`: anything but code that starts 0xef01 and is not a well-formed
    ///      designator (23 bytes, 0xef0100 || target). The chain refuses to create such code (EIP-3541) and EIP-7702
    ///      writes only well-formed designators; revm refuses to etch it.
    function _holdable(bytes memory code) internal pure returns (bool) {
        if (code.length < 2 || uint8(code[0]) != 0xef || uint8(code[1]) != 0x01) return true;
        return code.length == 23 && uint8(code[2]) == 0x00;
    }

    function _prefixes() internal pure returns (bytes[10] memory) {
        return [
            bytes(hex""),
            hex"00",
            hex"60",
            hex"ef",
            hex"ef00",
            hex"ef01",
            hex"ef0100",
            hex"eff000",
            hex"eff001",
            hex"eff002"
        ];
    }

    // ───────────────────────────── equivalence ─────────────────────────────

    /// Every length from 0 to 48 bytes with every prefix of interest (none, a plain opcode, 0xEF, the EOF magic
    /// 0xef00, 0xef01, the designator's 0xef0100 and the three Stylus formats 4663 deploys, 0xeff000, 0xeff001 and
    /// 0xeff002) that an account can hold.
    function test_everySiteAnswersAsBefore_everyPrefixAndLength() public {
        bytes[10] memory prefixes = _prefixes();
        uint256 cases;
        for (uint256 p; p < prefixes.length; ++p) {
            for (uint256 length; length <= 48; ++length) {
                bytes memory code = _code(prefixes[p], length, bytes32(p));
                if (!_holdable(code)) continue;
                vm.etch(probe, code);
                _assertEverySiteAsBefore();
                ++cases;
            }
        }
        // 10 x 49 shapes less those that start 0xef01 and are not a 23-byte designator: lengths 2 to 48 with the 0xef01
        // prefix (47) and lengths 2 to 48 but 23 with the 0xef0100 prefix (46).
        assertEq(cases, 10 * 49 - 47 - 46);
    }

    /// Arbitrary code.
    function testFuzz_everySiteAnswersAsBefore(bytes calldata code) public {
        vm.assume(_holdable(code));
        vm.etch(probe, code);
        _assertEverySiteAsBefore();
    }

    /// Code around the designator's length with a prefix of interest.
    function testFuzz_everySiteAnswersAsBefore_aroundTheDesignator(uint8 prefix, uint8 length, bytes32 seed) public {
        bytes[10] memory prefixes = _prefixes();
        uint256 n = bound(length, 0, 64);
        if (length % 3 == 0) n = 23;
        bytes memory code = _code(prefixes[prefix % prefixes.length], n, seed);
        vm.assume(_holdable(code));
        vm.etch(probe, code);
        _assertEverySiteAsBefore();
    }

    // ───────────────────────────── real designators ─────────────────────────────

    /// A designator written by a signed EIP-7702 authorization: every site refuses it, and the same key holding no code
    /// again passes every site that accepts an account without code.
    function test_realDesignatorFromASignedAuthorization() public {
        address delegator = vm.addr(DELEGATOR_KEY);
        Vm.SignedDelegation memory signed = vm.signDelegation(address(target), DELEGATOR_KEY);
        vm.attachDelegation(signed);
        (bool ok,) = delegator.call("");
        assertTrue(ok);
        assertEq(delegator.code, abi.encodePacked(hex"ef0100", address(target)));
        probe = delegator;
        assertTrue(HookrDelegation.isDelegated(delegator));
        assertTrue(HookrDelegation.isDesignator(delegator));
        _assertEverySiteAsBefore();
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegator));
        governed.refuseDelegated(delegator);
        vm.expectRevert(abi.encodeWithSelector(HookrRegistryChecks.DelegatedAccount.selector, delegator));
        checks.requireUndelegated(delegator);
        assertFalse(_laneAccepts(delegator));

        // An authorization to the zero address clears the designator: the account is a plain EOA again.
        vm.signAndAttachDelegation(address(0), DELEGATOR_KEY);
        (ok,) = delegator.call("");
        assertTrue(ok);
        assertEq(delegator.code.length, 0);
        assertFalse(HookrDelegation.isDelegated(delegator));
        assertFalse(HookrDelegation.isDesignator(delegator));
        _assertEverySiteAsBefore();
        governed.refuseDelegated(delegator);
        checks.requireUndelegated(delegator);
    }

    // ───────────────────────────── the two predicates ─────────────────────────────

    /// A Stylus program (0xeff000 ...), deployable on 4663, is where the two predicates differ, as the prior checks did:
    /// refused by every check that refuses 0xEF-prefixed code, accepted by the registry's owner, nominee and guardian
    /// check, and accepted by HookrLane as a pool subject unless its code is exactly 23 bytes.
    function test_aStylusProgramKeepsEverySitesAnswer() public {
        bytes memory program = _code(hex"eff00000", 40, keccak256("stylus"));
        vm.etch(probe, program);
        assertTrue(HookrDelegation.isDelegated(probe));
        assertFalse(HookrDelegation.isDesignator(probe));
        _assertEverySiteAsBefore();

        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, probe));
        new HookrCompliance(probe, 1 days);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.DelegatedAccount.selector, probe));
        treasury.proposeOwner(probe);
        bytes32 setQuote = registry.SET_QUOTE();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, probe));
        registry.queue(setQuote, abi.encode(probe, true));
        // The registry's guardian check refuses designators only.
        registry.queue(registry.SET_GUARDIAN(), abi.encode(probe));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(probe);
        assertEq(registry.guardian(), probe);
        assertTrue(_laneAccepts(probe), "a Stylus token is a pool subject");

        vm.etch(probe, _code(hex"eff00000", 23, keccak256("stylus")));
        _assertEverySiteAsBefore();
        assertFalse(_laneAccepts(probe), "23 bytes that start with 0xEF are refused as a subject");
        checks.requireUndelegated(probe);
    }
}
