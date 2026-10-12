// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ComplianceTestBase} from "./ComplianceTestBase.sol";
import {HookrComplianceGuard} from "../../src/compliance/HookrComplianceGuard.sol";
import {IHookrComplianceGuard} from "../../src/interfaces/IHookrComplianceGuard.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {MockSanctionsList} from "../fixtures/MockSanctionsList.sol";
import {MockRootView} from "../mocks/MockRootView.sol";
import {MockLauncherView} from "../mocks/MockLauncherView.sol";

/// @notice Audit findings F-022 and F-065.
contract HookrComplianceGuardTest is ComplianceTestBase {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant FAMILY = keccak256("family");
    uint16 internal constant DEFAULT_FLAGS = 1; // CHECK_BENEFICIARY; sells continue while the source is down

    HookrComplianceGuard internal guard;
    MockRootView internal root;
    MockLauncherView internal launcher;
    address internal router = makeAddr("router");
    address internal curated = makeAddr("curated");
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");
    PoolKey internal key;
    PoolId internal id;

    function setUp() public override {
        super.setUp();
        guard = new HookrComplianceGuard(address(compliance));
        root = new MockRootView(curated);
        launcher = new MockLauncherView();
        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(root))
        });
        id = key.toId();
        launcher.setFamily(id, FAMILY, creator);
        _attest(creator, 1);
        _attest(buyer, 1);
    }

    // ------------------------------------------------------------ helpers

    function _pc() internal view returns (HookrTypes.PoolConfig memory pc) {
        pc.subject = key.currency1;
        pc.quote = key.currency0;
        pc.advisory = address(guard);
        pc.liquidityOwner = address(launcher);
        pc.advisoryGasLimit = 200_000;
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP;
    }

    function _terms(bytes32 listId, uint16 flags) internal pure returns (bytes memory) {
        return abi.encode(IHookrComplianceGuard.Terms({listId: listId, requireAll: 1, blockAny: 0, flags: flags}));
    }

    function _bind(bytes32 listId, uint16 flags) internal {
        vm.prank(address(root));
        guard.bind(key, _pc(), _terms(listId, flags));
    }

    function _ctx(address sender, address payer, address beneficiary, bool authenticated, bool isBuy)
        internal
        view
        returns (HookrTypes.SwapContext memory x)
    {
        x.id = id;
        x.sender = sender;
        x.payer = payer;
        x.beneficiary = beneficiary;
        x.subject = key.currency1;
        x.quote = key.currency0;
        x.authenticated = authenticated;
        x.isBuy = isBuy;
        x.exactInput = true;
        x.amountSpecified = -1e18;
    }

    /// @dev Calls beforeSwap as the root, asserts explainSwap agrees, and returns (allowed, reason, decision).
    function _swap(HookrTypes.SwapContext memory x)
        internal
        returns (bool allowed, IHookrComplianceGuard.Reason reason, IHookrCompliance.Decision decision)
    {
        vm.prank(address(root));
        HookrTypes.Advice memory advice = guard.beforeSwap(x);
        (allowed, reason, decision) = guard.explainSwap(address(root), x);
        assertEq(advice.reject, !allowed, "beforeSwap and explainSwap disagree");
        assertEq(advice.lpFeeSurchargePips, 0);
        assertEq(advice.quoteTakePips, 0);
        assertEq(advice.recipient, address(0));
    }

    function _add(address sender) internal returns (bool allowed, IHookrComplianceGuard.Reason reason, address actor) {
        vm.prank(address(root));
        bool live = guard.beforeAddLiquidity(id, sender);
        (allowed, reason,, actor) = guard.explainLiquidity(address(root), id, sender);
        assertEq(live, allowed, "beforeAddLiquidity and explainLiquidity disagree");
    }

    function _expect(
        HookrTypes.SwapContext memory x,
        bool wantAllowed,
        IHookrComplianceGuard.Reason wantReason,
        IHookrCompliance.Decision wantDecision
    ) internal {
        (bool allowed, IHookrComplianceGuard.Reason reason, IHookrCompliance.Decision decision) = _swap(x);
        assertEq(allowed, wantAllowed, "allowed");
        assertEq(uint8(reason), uint8(wantReason), "reason");
        assertEq(uint8(decision), uint8(wantDecision), "decision");
    }

    // ------------------------------------------------------------ identity

    function test_identity() public view {
        assertEq(guard.releaseId(), 1);
        assertEq(guard.compliance(), address(compliance));
        assertEq(
            guard.configSchemaHash(),
            keccak256("ComplianceTerms(bytes32 listId,uint32 requireAll,uint32 blockAny,uint16 flags)")
        );
        assertEq(guard.bind.selector, bytes4(0x7733c476));
        HookrTypes.Advice memory a = guard.afterSwap(_ctx(router, buyer, buyer, true, true), 1, -1);
        assertEq(a.reject, false);
    }

    function test_constructorRequiresCode() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrComplianceGuard.InvalidCompliance.selector, stranger));
        new HookrComplianceGuard(stranger);
    }

    // ------------------------------------------------------------ bind (§9.3)

    function test_bindStoresTerms() public {
        bytes memory data = _terms(LIST, DEFAULT_FLAGS);
        vm.expectEmit(true, true, true, true, address(guard));
        emit IHookrComplianceGuard.ComplianceBound(
            address(root), id, LIST, 1, 0, DEFAULT_FLAGS, address(launcher), curated
        );
        vm.prank(address(root));
        bytes32 h = guard.bind(key, _pc(), data);
        assertEq(h, keccak256(data));
        IHookrComplianceGuard.Bound memory b = guard.terms(address(root), id);
        assertTrue(b.bound);
        assertEq(b.listId, LIST);
        assertEq(b.launcher, address(launcher));
        assertEq(b.curatedRouter, curated);
        assertEq(b.flags, DEFAULT_FLAGS);
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrComplianceGuard.AlreadyBound.selector, address(root), id));
        guard.bind(key, _pc(), data);
    }

    function test_bindTermsErrors() public {
        _bindReverts(_pc(), _terms(LIST, 64), abi.encodeWithSelector(IHookrComplianceGuard.InvalidTerms.selector, 1));
        bytes memory overlap =
            abi.encode(IHookrComplianceGuard.Terms({listId: LIST, requireAll: 3, blockAny: 2, flags: DEFAULT_FLAGS}));
        _bindReverts(_pc(), overlap, abi.encodeWithSelector(IHookrComplianceGuard.InvalidTerms.selector, 2));
        _bindReverts(
            _pc(),
            _terms(keccak256("nope"), DEFAULT_FLAGS),
            abi.encodeWithSelector(IHookrComplianceGuard.InvalidTerms.selector, 3)
        );
        _bindReverts(_pc(), _terms(LIST, 16), abi.encodeWithSelector(IHookrComplianceGuard.InvalidTerms.selector, 4));
        _bindReverts(
            _pc(),
            bytes.concat(_terms(LIST, 1), hex"00"),
            abi.encodeWithSelector(IHookrComplianceGuard.InvalidTerms.selector, 5)
        );
        bytes memory dirty = _terms(LIST, 1);
        dirty[64 - 5] = 0x01; // requireAll word with a bit above uint32
        _bindReverts(_pc(), dirty, abi.encodeWithSelector(IHookrComplianceGuard.InvalidTerms.selector, 5));
    }

    function test_bindPoolConfigErrors() public {
        bytes memory data = _terms(LIST, DEFAULT_FLAGS);
        HookrTypes.PoolConfig memory pc = _pc();
        pc.advisoryFailOpen = true;
        _bindReverts(pc, data, abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 1));
        pc = _pc();
        pc.advisoryPhases = HookrTypes.AFTER_SWAP;
        _bindReverts(pc, data, abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 2));
        pc = _pc();
        pc.advisoryGasLimit = 149_999;
        _bindReverts(pc, data, abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 3));
        pc = _pc();
        pc.caps.maxSubjectTakeBps = 100; // Auto Burn possible: refused for a restricted (ERC-3643) subject
        _bindReverts(
            pc,
            _terms(LIST, DEFAULT_FLAGS | 8),
            abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 4)
        );
        pc = _pc();
        pc.liquidityOwner = address(0);
        _bindReverts(pc, data, abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 5));
        pc = _pc();
        pc.liquidityOwner = stranger; // no code: launcher views fail
        _bindReverts(pc, data, abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 6));
        launcher.setFamily(id, FAMILY, address(0));
        _bindReverts(_pc(), data, abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 6));
        launcher.setFamily(id, FAMILY, creator);
        PoolKey memory k = key;
        k.hooks = IHooks(stranger); // not a root
        launcher.setFamily(k.toId(), FAMILY, creator);
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrComplianceGuard.InvalidPoolConfig.selector, 7));
        guard.bind(k, _pc(), data);
    }

    function test_bindRestrictedSubjectWithoutBurn() public {
        _bind(LIST, DEFAULT_FLAGS | 8 | 16); // RESTRICTED_SUBJECT + ACCEPT_CURATED on a KYC list
        assertTrue(guard.terms(address(root), id).bound);
    }

    function _bindReverts(HookrTypes.PoolConfig memory pc, bytes memory data, bytes memory err) internal {
        vm.prank(address(root));
        vm.expectRevert(err);
        guard.bind(key, pc, data);
    }

    // ------------------------------------------------------------ caller-keyed storage (§9.2)

    function test_thirdPartyBindIsIgnoredByRoot() public {
        vm.prank(stranger);
        guard.bind(key, _pc(), _terms(bytes32(0), DEFAULT_FLAGS));
        assertTrue(guard.terms(stranger, id).bound);
        assertFalse(guard.terms(address(root), id).bound);
        _expect(
            _ctx(router, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.NOT_BOUND,
            IHookrCompliance.Decision.ALLOW
        );
        (bool ok, IHookrComplianceGuard.Reason reason,) = _add(address(launcher));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IHookrComplianceGuard.Reason.NOT_BOUND));
        _bind(LIST, DEFAULT_FLAGS);
        _expect(
            _ctx(router, buyer, buyer, true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
    }

    // ------------------------------------------------------------ swap paths (§9.4, §9.6)

    function test_unauthenticatedAlwaysRejected() public {
        _bind(LIST, DEFAULT_FLAGS);
        _expect(
            _ctx(stranger, buyer, buyer, false, true),
            false,
            IHookrComplianceGuard.Reason.UNAUTHENTICATED,
            IHookrCompliance.Decision.ALLOW
        );
        _expect(
            _ctx(stranger, buyer, buyer, false, false),
            false,
            IHookrComplianceGuard.Reason.UNAUTHENTICATED,
            IHookrCompliance.Decision.ALLOW
        );
    }

    function test_curatedPath() public {
        _bind(LIST, DEFAULT_FLAGS);
        _expect(
            _ctx(curated, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.CURATED_NOT_ACCEPTED,
            IHookrCompliance.Decision.ALLOW
        );
    }

    function test_curatedAcceptedSanctionsOnlySkipsBeneficiary() public {
        _bind(bytes32(0), DEFAULT_FLAGS | 16);
        address anyone = makeAddr("anyone");
        _expect(
            _ctx(curated, anyone, stranger, true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        _sanction(anyone, true);
        _expect(
            _ctx(curated, anyone, anyone, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.SANCTIONED
        );
    }

    function test_buyPaths() public {
        _bind(LIST, DEFAULT_FLAGS);
        // router, forwarder (payer = signer), 4337 account and quoter all arrive authenticated with a payer
        _expect(
            _ctx(router, buyer, buyer, true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        _expect(
            _ctx(router, stranger, stranger, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.NO_CREDENTIAL
        );
        _expect(
            _ctx(router, buyer, stranger, true, true),
            false,
            IHookrComplianceGuard.Reason.BENEFICIARY,
            IHookrCompliance.Decision.NO_CREDENTIAL
        );
        _expect(
            _ctx(router, buyer, creator, true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
    }

    function test_buyWithoutBeneficiaryCheck() public {
        _bind(LIST, 0);
        _expect(
            _ctx(router, buyer, stranger, true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
    }

    function test_sellPaths() public {
        _bind(LIST, DEFAULT_FLAGS);
        // an unverified seller can exit
        _expect(
            _ctx(router, stranger, stranger, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        // a sanctioned seller cannot
        _sanction(stranger, true);
        _expect(
            _ctx(router, stranger, stranger, true, false),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.SANCTIONED
        );
        // a sanctioned quote recipient cannot receive
        _expect(
            _ctx(router, buyer, stranger, true, false),
            false,
            IHookrComplianceGuard.Reason.BENEFICIARY,
            IHookrCompliance.Decision.SANCTIONED
        );
        // a suspended list does not stop sells
        vm.prank(guardian);
        compliance.suspendList(LIST);
        _expect(
            _ctx(router, buyer, buyer, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        _expect(
            _ctx(router, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.LIST_SUSPENDED
        );
    }

    function test_kycOnSell() public {
        _bind(LIST, DEFAULT_FLAGS | 2);
        address unverified = makeAddr("unverified");
        _expect(
            _ctx(router, unverified, unverified, true, false),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.NO_CREDENTIAL
        );
        _expect(
            _ctx(router, buyer, unverified, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
    }

    function test_sourceDown() public {
        _setSource(address(source));
        source.setMode(MockSanctionsList.Mode.REVERT);
        _bind(LIST, DEFAULT_FLAGS);
        _expect(
            _ctx(router, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.SOURCE_FAILED
        );
        _expect(
            _ctx(router, buyer, buyer, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
    }

    function test_sourceDownWithHaltFlag() public {
        _setSource(address(source));
        source.setMode(MockSanctionsList.Mode.TWO);
        _bind(LIST, 1 | 4);
        _expect(
            _ctx(router, buyer, buyer, true, false),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.SOURCE_FAILED
        );
    }

    function test_decisionIsPerIdentity() public {
        _bind(LIST, DEFAULT_FLAGS);
        _sanction(stranger, true);
        _expect(
            _ctx(router, buyer, buyer, true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
    }

    // ------------------------------------------------------------ liquidity (§9.5)

    function test_launcherAddResolvesFamilyOwner() public {
        _bind(LIST, DEFAULT_FLAGS);
        (bool ok, IHookrComplianceGuard.Reason reason, address actor) = _add(address(launcher));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(IHookrComplianceGuard.Reason.NONE));
        assertEq(actor, creator);
        launcher.transferFamily(FAMILY, stranger);
        (ok, reason, actor) = _add(address(launcher));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IHookrComplianceGuard.Reason.LP_OWNER));
        assertEq(actor, stranger);
        launcher.transferFamily(FAMILY, buyer);
        (ok,, actor) = _add(address(launcher));
        assertTrue(ok);
        assertEq(actor, buyer);
        launcher.transferFamily(FAMILY, address(0));
        (ok, reason,) = _add(address(launcher));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IHookrComplianceGuard.Reason.LP_OWNER));
    }

    function test_positionManagerAddRejected() public {
        _bind(LIST, DEFAULT_FLAGS);
        (bool ok, IHookrComplianceGuard.Reason reason, address actor) = _add(buyer);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IHookrComplianceGuard.Reason.LP_SENDER));
        assertEq(actor, buyer);
    }

    function test_directLpIfPermitted() public {
        _bind(LIST, DEFAULT_FLAGS | 32);
        (bool ok,,) = _add(buyer);
        assertTrue(ok);
        (ok,,) = _add(stranger);
        assertFalse(ok);
    }

    function test_sanctionsOnlyAddBlockedWhenSourceFails() public {
        _bind(bytes32(0), DEFAULT_FLAGS);
        address someone = makeAddr("someone");
        launcher.transferFamily(FAMILY, someone);
        (bool ok,,) = _add(address(launcher));
        assertTrue(ok);
        _setSource(address(source));
        source.setMode(MockSanctionsList.Mode.WIDE);
        (ok,,) = _add(address(launcher));
        assertFalse(ok);
    }

    // ------------------------------------------------------------ exits cannot be frozen (F-022, F-065)

    /// F-022 (PoC C3): a guardian suspension froze every KYC_ON_SELL sell until a timelocked resume. Sells now fall
    /// back to the sanctions rule; buys and LP adds stay stopped.
    function test_suspensionDoesNotFreezeKycOnSellExits() public {
        _bind(LIST, DEFAULT_FLAGS | 2);
        vm.prank(guardian);
        compliance.suspendList(LIST);
        _expect(
            _ctx(router, buyer, buyer, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        _expect(
            _ctx(router, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.LIST_SUSPENDED
        );
        (bool allowed,,) = _add(address(launcher));
        assertFalse(allowed);
        // A sanctioned seller is still refused.
        _sanction(buyer, true);
        _expect(
            _ctx(router, buyer, buyer, true, false),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.SANCTIONED
        );
    }

    /// F-022: after revokeAttester, or once a credential expires, a KYC_ON_SELL seller can still exit; a wallet that
    /// never held a credential cannot. A re-grant restores the old credentials for buys.
    function test_revokedIssuerOrExpiryDoesNotFreezeKycOnSellExits() public {
        _bind(LIST, DEFAULT_FLAGS | 2);
        vm.prank(guardian);
        compliance.revokeAttester(LIST, attester);
        _expect(
            _ctx(router, buyer, buyer, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        _expect(
            _ctx(router, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.ISSUER_REVOKED
        );
        address unverified = makeAddr("unverified");
        _expect(
            _ctx(router, unverified, unverified, true, false),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.NO_CREDENTIAL
        );
        _grantAttester(LIST, attester);
        _expect(
            _ctx(router, buyer, buyer, true, true),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _expect(
            _ctx(router, buyer, buyer, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        _expect(
            _ctx(router, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.EXPIRED
        );
    }

    /// F-065: a source outage stops sells only on pools bound with HALT_SELLS_WHEN_SOURCE_DOWN, including KYC_ON_SELL
    /// pools, where the credential is still required.
    function test_sourceOutageHaltsSellsOnlyByExplicitPolicy() public {
        _setSource(address(source));
        source.setMode(MockSanctionsList.Mode.REVERT);
        assertEq(guard.HALT_SELLS_WHEN_SOURCE_DOWN(), 4);
        _bind(LIST, DEFAULT_FLAGS | 2);
        _expect(
            _ctx(router, buyer, buyer, true, false),
            true,
            IHookrComplianceGuard.Reason.NONE,
            IHookrCompliance.Decision.ALLOW
        );
        address unverified = makeAddr("unverified");
        _expect(
            _ctx(router, unverified, unverified, true, false),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.NO_CREDENTIAL
        );
        _expect(
            _ctx(router, buyer, buyer, true, true),
            false,
            IHookrComplianceGuard.Reason.PAYER,
            IHookrCompliance.Decision.SOURCE_FAILED
        );
    }
}
