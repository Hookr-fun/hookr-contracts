// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {HookrComplianceGuard} from "../../src/compliance/HookrComplianceGuard.sol";
import {IHookrComplianceGuard} from "../../src/interfaces/IHookrComplianceGuard.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";

/// @notice A fail-closed identity gate with the shape of HookrComplianceGuard: it rejects every swap whose
///         authenticated payer (or, unauthenticated, sender) is not on its list, and admits every liquidity add.
contract AllowlistAdvisory is IHookrAdvisory {
    mapping(address => bool) public allowed;
    uint256 public swapChecks;

    function allow(address who) external {
        allowed[who] = true;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("atk.allowlist");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory a) {
        a.reject = !allowed[x.payer];
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory a)
    {}
}

/// @notice ATK-LF-2 regression: a lane member bound to a refusing (identity-gate) advisory. The gate refuses the
///         stranger's and the executor's own outer swaps. Before the fix the executor's legs on the member skipped the
///         advisory entirely, so (1) a permitted trader's swap on the gated member let the unpermitted executor trade
///         its liquidity against an open outside venue, and (2) an unpermitted stranger's buy on an open sibling of the
///         same family reached the gated member's liquidity through the family legs. A leg on a pool whose advisory can
///         refuse swaps now asks it, with the executor as the unauthenticated payer, and a refusal reverts the leg:
///         nothing reaches the gated member unless the creator's gate admits the executor.
contract AdvisoryBypassTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    AllowlistAdvisory internal gate;
    HookrToken internal subject;
    Currency internal s;
    Currency internal qb;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal refA;
    PoolKey internal refB;
    PoolKey internal conn;

    function setUp() public {
        _setUpPartnerShaped();
        gate = new AllowlistAdvisory();
        IHookrRegistry.Admission memory adm = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(gate),
            codeHash: address(gate).codehash,
            schemaHash: gate.configSchemaHash(),
            caps: HookrTypes.Caps(0, 0, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), adm));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), adm);

        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        s = Currency.wrap(address(subject));
        qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[0].config.advisory = address(gate);
        members[0].config.advisoryGasLimit = 100_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        members[1] = _laneMemberAt(qb);
        bytes[] memory data = new bytes[](2);
        data[0] = hex"01";
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        a = launcher.position(family, 0).key;
        b = launcher.position(family, 1).key;
        refA = _hookless(a.currency0, a.currency1);
        refB = _hookless(b.currency0, b.currency1);
        conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        ex.setTrigger(b, 1e22);
        ex.addVenue(b, refB, PAIR_GAP);
        ex.addCycle(b, a, conn, CYCLE_GAP);
        gate.allow(whale);
        _nextBlock();
    }

    /// The gate works on outer swaps: the stranger (attacker) and the executor itself are refused on the gated member.
    function test_gate_refusesTheStrangerAndTheExecutorOnOuterSwaps() public {
        vm.expectRevert();
        _buy(a, ETH, attacker, 1e18);
        // The executor, trading the gated member outside a frame, is refused too (unauthenticated: payer = sender).
        vm.deal(address(this), 1e20);
        vm.expectRevert();
        venue.swap{value: 1e18}(a, true, 1e18, 0);
        _buy(a, ETH, whale, 1e18); // the permitted identity passes
    }

    /// (1) A permitted trader's buy on the gated member: every leg of the unpermitted executor on the member is refused,
    /// so the member ends where the trader's buy alone leaves it. Once the creator's gate admits the executor, the
    /// arb recapture runs.
    function test_regression_executorLegsOnTheGatedMemberAreRefused() public {
        assertFalse(gate.allowed(address(ex)), "the executor is not on the gate's list");
        uint256 snap = vm.snapshotState();
        registry.stopExecutorLane(address(root), address(ex));
        _buy(a, ETH, whale, 5e22);
        (uint160 alone,,,) = manager.getSlot0(a.toId());
        vm.revertToState(snap);
        vm.recordLogs();
        _buy(a, ETH, whale, 5e22);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        (uint160 aAfter,,,) = manager.getSlot0(a.toId());
        console2.log("gated member sqrtPrice after the buy alone / with the lane", alone, aAfter);
        assertEq(o.failed, 0, "each refused chunk unwinds alone");
        assertEq(o.pushedBefore + o.pushedAfter, 0, "nothing recaptured on the gated member");
        assertEq(ex.lastArbs() + ex.lastCycles(), 0, "no chunk legged on the gated member");
        assertEq(aAfter, alone, "the member ends where the trader's buy left it");
        // The creator admits the executor: its legs pass the gate and the next buy is recaptured.
        vm.revertToState(snap);
        gate.allow(address(ex));
        vm.recordLogs();
        _buy(a, ETH, whale, 5e22);
        o = _outcome(vm.getRecordedLogs());
        assertGt(o.pushedAfter, 0, "an admitted executor recaptures the gated member");
    }

    /// (2) The refused stranger buys on the open sibling; the family arb recapture's legs on the gated member are
    /// refused, so the member does not move. The sibling's own venue arb recapture still runs.
    function test_regression_refusedStrangerCannotReachTheGatedMemberThroughTheOpenSibling() public {
        // The PoolManager wraps the root's SwapRejected (0x1f770849) in WrappedError.
        try this.buyAs(a, ETH, attacker, 5e22) {
            revert("the gate let the stranger in");
        } catch (bytes memory err) {
            assertEq(bytes4(err), bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")));
        }

        (uint160 aBefore,,,) = manager.getSlot0(a.toId());
        uint256 aSubjectBefore = subject.balanceOf(address(manager));
        uint256 creditBefore = rules.claimable(qb, attacker);
        vm.recordLogs();
        _buy(b, qb, attacker, 5e22);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        (uint160 aAfter,,,) = manager.getSlot0(a.toId());
        uint256 credit = rules.claimable(qb, attacker) - creditBefore;
        console2.log("gated member sqrtPrice before / after the stranger's sibling buy", aBefore, aAfter);
        console2.log("stranger's trader credit (tokenB wei), from the sibling's own venue arb recapture", credit);
        console2.log(
            "subject held by the PoolManager before / after", aSubjectBefore, subject.balanceOf(address(manager))
        );
        assertEq(o.failed, 0);
        assertEq(ex.lastCycles(), 0, "no cycle through the gated member");
        assertEq(aAfter, aBefore, "the gated member did not move");
        assertGt(o.pushedAfter, 0, "the sibling's venue arb recapture still ran");
    }

    function buyAs(PoolKey memory key, Currency quote, address who, uint256 amount) external {
        require(msg.sender == address(this));
        _buy(key, quote, who, amount);
    }
}

/// @notice ATK-LF-2 regression with the release's own HookrComplianceGuard (KYC list, requireAll tier 1) on the ETH
///         member: the unattested stranger is refused on the member and buys on the open sibling instead. Before the
///         fix the arb recapture's legs took the subject out of the KYC-gated member (an unauthenticated buy the guard
///         would refuse, never asked); now the guard is asked about every leg and refuses the unattested executor.
contract ComplianceGuardBypassTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    bytes32 internal constant LIST = keccak256("hookr.list.kyc");
    HookrCompliance internal compliance;
    HookrComplianceGuard internal guard;
    HookrToken internal subject;
    Currency internal qb;
    PoolKey internal a;
    PoolKey internal b;

    function setUp() public {
        _setUpPartnerShaped();
        compliance = new HookrCompliance(address(this), 1 days);
        compliance.queue(compliance.CREATE_LIST(), abi.encode(LIST));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        compliance.createList(LIST);
        address attesterAddr = vm.addr(0xA11CE);
        compliance.queue(compliance.GRANT_ATTESTER(), abi.encode(LIST, attesterAddr));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        compliance.grantAttester(LIST, attesterAddr);
        vm.startPrank(attesterAddr);
        compliance.attest(LIST, whale, 1, uint32(vm.getBlockTimestamp() + 30 days));
        compliance.attest(LIST, address(this), 1, uint32(vm.getBlockTimestamp() + 30 days));
        vm.stopPrank();
        guard = new HookrComplianceGuard(address(compliance));
        IHookrRegistry.Admission memory adm = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(guard),
            codeHash: address(guard).codehash,
            schemaHash: guard.configSchemaHash(),
            caps: HookrTypes.Caps(0, 0, 0),
            gasLimit: 200_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), adm));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), adm);

        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[0].config.advisory = address(guard);
        members[0].config.advisoryGasLimit = 200_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        members[1] = _laneMemberAt(qb);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(IHookrComplianceGuard.Terms({listId: LIST, requireAll: 1, blockAny: 0, flags: 0}));
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        a = launcher.position(family, 0).key;
        b = launcher.position(family, 1).key;
        PoolKey memory conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        ex.setTrigger(b, 1e22);
        ex.addCycle(b, a, conn, CYCLE_GAP);
        _nextBlock();
    }

    function buyAs(PoolKey memory key, Currency quote, address who, uint256 amount) external {
        require(msg.sender == address(this));
        _buy(key, quote, who, amount);
    }

    function test_regression_unattestedStrangerCannotReachTheKycMemberThroughTheSibling() public {
        (bool allowed,,) = guard.explainSwap(address(root), _ctx(attacker));
        assertFalse(allowed, "the guard refuses the stranger");
        (allowed,,) = guard.explainSwap(address(root), _unauthCtx(address(ex)));
        assertFalse(allowed, "the guard would refuse the executor's unauthenticated buy leg");
        try this.buyAs(a, ETH, attacker, 5e22) {
            revert("the guard let the stranger in");
        } catch {}
        _buy(a, ETH, whale, 1e18); // the attested wallet trades
        _nextBlock();

        (uint160 aBefore,,,) = manager.getSlot0(a.toId());
        uint256 c0 = rules.claimable(qb, attacker);
        vm.recordLogs();
        _buy(b, qb, attacker, 5e22);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        (uint160 aAfter,,,) = manager.getSlot0(a.toId());
        uint256 credit = rules.claimable(qb, attacker) - c0;
        console2.log("KYC member sqrtPrice before / after the stranger's sibling buy", aBefore, aAfter);
        console2.log("stranger's trader credit (tokenB wei), executor cycles", credit, ex.lastCycles());
        assertEq(o.failed, 0);
        assertEq(ex.lastCycles(), 0, "every cycle through the KYC member was refused");
        assertEq(aAfter, aBefore, "the KYC member did not move");
        assertEq(o.pushedAfter, 0);
        assertEq(credit, 0);
    }

    function _ctx(address who) internal view returns (HookrTypes.SwapContext memory x) {
        x.id = a.toId();
        x.sender = address(router);
        x.payer = who;
        x.beneficiary = who;
        x.subject = root.poolConfig(a.toId()).subject;
        x.quote = ETH;
        x.authenticated = true;
        x.isBuy = true;
        x.exactInput = true;
        x.zeroForOne = true;
        x.amountSpecified = -1e18;
        x.baseLpFeePips = POOL_FEE;
    }

    function _unauthCtx(address who) internal view returns (HookrTypes.SwapContext memory x) {
        x = _ctx(who);
        x.sender = who;
        x.authenticated = false;
    }
}
