// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IHookrEngagementReceiptSink} from "../../src/interfaces/IHookrEngagementReceiptSink.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramValidator} from "../../src/engagement/HookrProgramValidator.sol";
import {IHookrProgramValidator} from "../../src/interfaces/IHookrProgramValidator.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

contract RejectProgramNFT {}

/// @dev Reward token whose issuer can burn from any holder, standing in for a clawback or negative rebase.
contract ProgramsBurnableToken is ERC20 {
    constructor() ERC20("Burnable", "BRN") {
        _mint(msg.sender, 1e30);
    }

    function issuerBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Answers like a root for one real pool but is not registered.
contract ProgramsMimicRoot {
    address public immutable poolManager;
    bytes32 private immutable hash;
    address private immutable quote;

    constructor(address manager, bytes32 policy, address quoteAsset) {
        poolManager = manager;
        hash = policy;
        quote = quoteAsset;
    }

    function knownPool(PoolId) external pure returns (bool) {
        return true;
    }

    function policyHash(PoolId) external view returns (bytes32) {
        return hash;
    }

    function poolConfig(PoolId) external view returns (HookrTypes.PoolConfig memory c) {
        c.quote = Currency.wrap(quote);
    }
}

contract SpoofReferralRegistry {
    function eligible(bytes32, address, address, uint64) external pure returns (bool) {
        return true;
    }
}

contract ReenterProgramNFT is IERC721Receiver {
    HookrPrograms private immutable programs;
    uint256 private immutable id;
    address private immutable user;
    bool public blocked;

    constructor(HookrPrograms p, uint256 id_, address user_) {
        programs = p;
        id = id_;
        user = user_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        try programs.claimCash(id, user, user, 0) {
            blocked = false;
        } catch {
            blocked = true;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract HookrProgramsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using stdStorage for StdStorage;
    HookrPrograms private programs;
    HookrReferralRegistry private programReferrals;
    PoolKey private key;
    bytes32 private constant COVERAGE = keccak256("complete pinned daily coverage");

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programReferrals = new HookrReferralRegistry();
        programs = new HookrPrograms(manager, address(router), address(this), 10_000, address(programReferrals));
        tokenB.approve(address(programs), type(uint256).max);
    }

    function testCreatorPointsDoNotMintGlobalBuxAndWalletCapBinds() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        t.walletPointCap = 300;
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        _trade(id, key, trader, 1e18);
        assertEq(programs.points(id, trader), 300);
        assertEq(programs.buxBalance(trader), 0);
        assertEq(programs.claimableCash(id, trader), 0);
        _trade(id, key, trader, 1e18);
        assertEq(programs.points(id, trader), 300);
        assertEq(programs.reservedCash(address(tokenB)), 0);
    }

    /// Immediate receipts carry a payer-recoverable raw fill (L-04), so they may back creator points only.
    function testImmediateProgramsCannotHoldCashBuxOrMilestones() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        t.rewardToken = address(tokenB);
        t.cashBudget = 100;
        t.walletCashCap = 100;
        t.cashNumerator = 1;
        t.cashDenominator = 1;
        P.Scope[] memory sources = _scopes(key);
        vm.expectRevert(abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 100, false, 0));
        _create(t, sources, false);
        t = _terms(P.Mode.Immediate, true);
        vm.expectRevert(abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 0, true, 0));
        _create(t, sources, false);
        t = _terms(P.Mode.Immediate, false);
        vm.expectRevert(abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 0, false, 1));
        _create(t, sources, true);
        assertEq(programs.programCount(), 0);
    }

    function testProgramsFitsDeploymentLimitsAndPinsStatelessValidator() public view {
        assertLe(address(programs).code.length, 24_576);
        assertEq(address(programs.validator()).codehash, keccak256(type(HookrProgramValidator).runtimeCode));
        assertLe(
            type(HookrPrograms).creationCode.length
                + abi.encode(manager, address(router), address(this), uint256(10_000), address(programReferrals))
                .length,
            49_152
        );
    }

    function testCreationValidatorRejectsInvalidTermsScopesAndMilestonesAtomically() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        t.pointNumerator = 0;
        P.Scope[] memory sources = _scopes(key);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        _create(t, sources, false);
        t = _terms(P.Mode.Immediate, false);
        sources[0].configHash = bytes32(0);
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        _create(t, sources, false);
        t = _terms(P.Mode.DailySwap, false);
        P.Milestone[] memory ms = new P.Milestone[](1);
        ms[0] = P.Milestone(t.walletPointCap + 1, 1);
        sources = _scopes(key);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, sources, ms, P.NFTMetadata("MS", "MS", "", false));
        // No milestones means no collection, so its metadata must be empty (M-11).
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, sources, new P.Milestone[](0), P.NFTMetadata("MS", "", "", false));
        // Review windows below the six-day floor, two days above the forced-inclusion delay, are rejected (L-23).
        t.reviewDelay = 6 days - 1;
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        _create(t, sources, false);
        assertEq(programs.programCount(), 0);
        assertEq(programs.reservedCash(address(tokenB)), 0);
    }

    /// The program limits are defined once (HookrProgramTypes): the getters report the bounds the validator enforces,
    /// and one scope or one milestone past them is refused with InvalidProgram.
    function testProgramLimitsAreTheValidatorsBounds() public {
        assertEq(programs.DAY(), 1 days);
        assertEq(programs.MAX_DAYS(), 366);
        assertEq(programs.MAX_SCOPES(), 8);
        assertEq(programs.MAX_MILESTONES(), 16);
        assertEq(programs.MAX_RATE(), 1e18);
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        P.Scope[] memory one = _scopes(key);
        P.Scope[] memory tooMany = new P.Scope[](programs.MAX_SCOPES() + 1);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = one[0];
        }
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, tooMany, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        P.Milestone[] memory ms = new P.Milestone[](programs.MAX_MILESTONES() + 1);
        for (uint256 i; i < ms.length; ++i) {
            ms[i] = P.Milestone(uint128(i + 1), 1);
        }
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, one, ms, P.NFTMetadata("MS", "MS", "", false));
        assertEq(programs.programCount(), 0);
    }

    function testPointsOnlyProgramNeedsNoRewardAssetOrFunding() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        t.rewardToken = address(0);
        t.cashBudget = 0;
        t.walletCashCap = 0;
        t.cashNumerator = 0;
        t.cashDenominator = 0;
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        _trade(id, key, trader, 1e18);
        assertGt(programs.points(id, trader), 0);
        assertEq(programs.claimableCash(id, trader), 0);
    }

    function testDuplicateSelectedProgramRevertsEntireTrade() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        IHookrRouter.Swap memory params = _swap(key, true, true, 1e18);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        uint256 beforeA = tokenA.balanceOf(trader);
        uint256 beforeB = tokenB.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(IHookrPrograms.Duplicate.selector);
        router.swap(params, address(programs), ids);
        assertEq(programs.points(id, trader), 0);
        assertEq(tokenA.balanceOf(trader), beforeA);
        assertEq(tokenB.balanceOf(trader), beforeB);
    }

    function testForgedReceiptCallerAndWrongScopeAreRejected() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        IHookrEngagementReceiptSink.EngagementReceipt memory r = IHookrEngagementReceiptSink.EngagementReceipt(
            block.chainid,
            address(root),
            PoolId.unwrap(key.toId()),
            bytes32(0),
            address(tokenB),
            trader,
            1e18,
            keccak256("forged"),
            uint64(vm.getBlockTimestamp()),
            0
        );
        uint256[] memory ids = _ids(id);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.recordExecution(r, ids);
        vm.prank(address(router));
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        programs.recordExecution(r, ids);
    }

    function testBuxRequiresApprovalAndFiniteReservedAllowance() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, true);
        t.pointBudget = 6000;
        t.dailyPointBudget = 6000;
        t.walletPointCap = 6000;
        uint256 id = _create(t, _scopes(key), false);
        uint256 another = _create(t, _scopes(key), false);
        programs.proposeBuxProgram(id);
        programs.proposeBuxProgram(another);
        vm.warp(vm.getBlockTimestamp() + programs.BUX_APPROVAL_DELAY());
        programs.approveBuxProgram(id);
        vm.expectRevert(IHookrPrograms.BudgetExceeded.selector);
        programs.approveBuxProgram(another);
        vm.warp(t.start);
        IHookrRouter.Swap memory params = _swap(key, true, true, 1e18);
        uint256[] memory ids = _ids(another);
        vm.prank(trader);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        router.swap(params, address(programs), ids);
        _trade(id, key, trader, 1e18);
        vm.warp(t.end);
        bytes32 leaf = _leaf(id, 0, trader, 1, COVERAGE);
        programs.proposeDay(id, 0, leaf, 1, COVERAGE, keccak256("evidence"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(id, 0);
        programs.claimDay(id, 0, trader, 1, new bytes32[](0));
        assertGt(programs.buxBalance(trader), 0);
        assertEq(programs.buxBalance(trader), programs.points(id, trader));
        assertLe(programs.buxIssued(), programs.buxReserved());
        assertLe(programs.buxReserved(), programs.buxSupplyCap());
    }

    /// N-01: an unapproved Bux program has exactly one exit, and it pays once.
    function testUnapprovedBuxRefundCannotBeClaimedTwice() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, true);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        uint256 before_ = tokenB.balanceOf(address(this));
        programs.refundUnapprovedBux(id);
        assertEq(tokenB.balanceOf(address(this)), before_ + t.cashBudget);
        assertEq(programs.program(id).cashRefunded, t.cashBudget);
        vm.warp(uint256(t.end) + programs.PROPOSAL_WINDOW());
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.lapseDay(id, 0);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.releaseUnusedCash(id, 0);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.refundUnapprovedBux(id);
        assertEq(programs.reservedCash(address(tokenB)), 0);
    }

    function testOneProgramSharesWalletCapAcrossExplicitPools() public {
        (, PoolKey memory nativeKey,,) = _launch(false, true);
        P.Scope[] memory sources = new P.Scope[](2);
        sources[0] = _scopes(key)[0];
        sources[1] = _scopes(nativeKey)[0];
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        t.walletPointCap = 300;
        uint256 id = _create(t, sources, false);
        vm.warp(t.start);
        _trade(id, key, trader, 1e18);
        _trade(id, nativeKey, trader, 1e18);
        assertEq(programs.points(id, trader), 300);
    }

    function testPointAndCashBudgetsBoundTwoWallets() public {
        address second = address(0x7777);
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        t.pointBudget = 500;
        t.dailyPointBudget = 500;
        t.walletPointCap = 300;
        t.cashBudget = 100;
        t.dailyCashBudget = 100;
        t.walletCashCap = 60;
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.end);
        bytes32 a = _leaf(id, 0, trader, 3, COVERAGE);
        bytes32 b = _leaf(id, 0, second, 1, COVERAGE);
        programs.proposeDay(id, 0, _pair(a, b), 4, COVERAGE, keccak256("evidence"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(id, 0);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        programs.claimDay(id, 0, trader, 3, proof);
        proof[0] = a;
        programs.claimDay(id, 0, second, 1, proof);
        assertEq(programs.points(id, trader), 300);
        assertEq(programs.claimableCash(id, trader), 60);
        assertEq(programs.points(id, second), 125);
        assertEq(programs.claimableCash(id, second), 25);
        assertLe(programs.points(id, trader) + programs.points(id, second), 500);
        assertLe(programs.claimableCash(id, trader) + programs.claimableCash(id, second), 100);
        uint256 before_ = tokenB.balanceOf(address(this));
        assertEq(programs.releaseUnusedCash(id, 0), 15);
        assertEq(tokenB.balanceOf(address(this)), before_ + 15);
        assertEq(programs.reservedCash(address(tokenB)), 85);
    }

    function testTinyTradesPreserveFractionalCarry() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        _trade(id, key, trader, 1e15);
        assertEq(programs.points(id, trader), 0);
        _trade(id, key, trader, 1e15);
        assertEq(programs.points(id, trader), 1);
    }

    /// The Immediate credit is points-only; it keeps the program's point budget across wallets as well as each
    /// wallet's cap.
    function testImmediatePointBudgetBoundsTwoWallets() public {
        address second = address(0x7777);
        tokenA.transfer(second, 1e21);
        tokenB.transfer(second, 1e21);
        vm.startPrank(second);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        t.pointBudget = 400;
        t.walletPointCap = 300;
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        _trade(id, key, trader, 1e18);
        assertEq(programs.points(id, trader), 300, "wallet cap");
        _trade(id, key, second, 1e18);
        assertEq(programs.points(id, second), 100, "program budget");
        _trade(id, key, second, 1e18);
        assertEq(programs.points(id, second), 100, "budget spent");
        assertEq(programs.program(id).pointsIssued, 400);
    }

    /// Both fractional carries survive the points-only credit: scope weight carries below one unit, point carries
    /// below one point, and the sum of awards equals the floor of the summed exact values.
    function testImmediateCreditKeepsScopeAndPointCarries() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        t.pointNumerator = 2;
        t.pointDenominator = 3;
        P.Scope[] memory sources = _scopes(key);
        sources[0].denominator = 1e15 + 1;
        uint256 id = _create(t, sources, false);
        vm.warp(t.start);
        vm.recordLogs();
        uint256 volume;
        for (uint256 i; i < 5; ++i) {
            _trade(id, key, trader, 7e14);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 accepted = keccak256("ExecutionAccepted(bytes32,address,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(programs) || logs[i].topics[0] != accepted) continue;
            IHookrEngagementReceiptSink.EngagementReceipt memory r =
                abi.decode(abi.decode(logs[i].data, (bytes)), (IHookrEngagementReceiptSink.EngagementReceipt));
            volume += r.quoteVolume;
        }
        assertGt(volume, 0);
        // Exact carries make the summed weight floor(volume / d) and the summed points floor(2 * weight / 3).
        assertEq(programs.points(id, trader), volume / (1e15 + 1) * 2 / 3, "floor of the exact total");
    }

    /// Receipt replay protection holds on the points-only path: the same executionId credits a program once.
    function testImmediateReceiptReplayIsRefused() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        PoolId pool = key.toId();
        IHookrEngagementReceiptSink.EngagementReceipt memory r = IHookrEngagementReceiptSink.EngagementReceipt(
            block.chainid,
            address(root),
            PoolId.unwrap(pool),
            root.policyHash(pool),
            Currency.unwrap(root.poolConfig(pool).quote),
            trader,
            1e18,
            keccak256("once"),
            uint64(vm.getBlockTimestamp()),
            0
        );
        vm.prank(address(router));
        programs.recordExecution(r, _ids(id));
        uint256 credited = programs.points(id, trader);
        assertGt(credited, 0);
        vm.prank(address(router));
        vm.expectRevert(IHookrPrograms.Duplicate.selector);
        programs.recordExecution(r, _ids(id));
        assertEq(programs.points(id, trader), credited);
    }

    /// An Immediate credit never reads or writes the wallet's cash ledger or global Bux: those slots stay untouched.
    function testImmediateCreditLeavesCashLedgerAndBuxUntouched() public {
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        bytes32[3] memory untouched = [
            bytes32(
                stdstore.target(address(programs)).sig(programs.cashAllocated.selector).with_key(id).with_key(trader)
                    .find()
            ),
            bytes32(
                stdstore.target(address(programs)).sig(programs.claimableCash.selector).with_key(id).with_key(trader)
                    .find()
            ),
            bytes32(stdstore.target(address(programs)).sig(programs.buxBalance.selector).with_key(trader).find())
        ];
        vm.record();
        _trade(id, key, trader, 1e18);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(programs));
        assertGt(programs.points(id, trader), 0);
        for (uint256 j; j < untouched.length; ++j) {
            for (uint256 i; i < reads.length; ++i) {
                assertTrue(reads[i] != untouched[j], "cash or Bux slot read");
            }
            for (uint256 i; i < writes.length; ++i) {
                assertTrue(writes[i] != untouched[j], "cash or Bux slot written");
            }
        }
    }

    /// An id never created is refused with InvalidProgram on every path that names one, a recorded receipt included.
    function testUnknownProgramIsRefused() public {
        uint256 unknown = 7;
        PoolId pool = key.toId();
        IHookrEngagementReceiptSink.EngagementReceipt memory r = IHookrEngagementReceiptSink.EngagementReceipt(
            block.chainid,
            address(root),
            PoolId.unwrap(pool),
            root.policyHash(pool),
            Currency.unwrap(root.poolConfig(pool).quote),
            trader,
            1e18,
            keccak256("unknown"),
            uint64(vm.getBlockTimestamp()),
            0
        );
        vm.prank(address(router));
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.recordExecution(r, _ids(unknown));
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.program(unknown);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.dayEnd(unknown, 0);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.referralProgramKey(unknown);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.setRefundRecipient(unknown, address(this));
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.claimCash(unknown, trader, trader, 0);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.finalizeDay(unknown, 0);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.refundUnapprovedBux(unknown);
    }

    /// Only a Bux program can be disabled: an unapproved one and a refunded (cancelled) one refuse a receipt, while a
    /// program without Bux records it.
    function testOnlyBuxProgramsCanBeDisabled() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, true);
        uint256 bux = _create(t, _scopes(key), false);
        uint256 plain = _create(_terms(P.Mode.DailySwap, false), _scopes(key), false);
        vm.warp(t.start);
        IHookrRouter.Swap memory params = _swap(key, true, true, 1e18);
        vm.prank(trader);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        router.swap(params, address(programs), _ids(bux));
        programs.refundUnapprovedBux(bux);
        assertTrue(programs.program(bux).cancelled);
        vm.prank(trader);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        router.swap(params, address(programs), _ids(bux));
        _trade(plain, key, trader, 1e18);
        assertFalse(programs.program(plain).cancelled);
    }

    /// A recorded receipt for a program without Bux reads neither the program's creator word (existence is read from
    /// its first terms word) nor its flag word (only a Bux program can be disabled).
    function testRecordedReceiptSkipsTheCreatorAndFlagWords() public {
        uint256 id = _create(_terms(P.Mode.DailySwap, false), _scopes(key), false);
        // _programs is slot 6; within a Program, Terms fill words 0 to 14, creator is word 15 and the word holding
        // openDays and the four flags is word 23.
        uint256 base = uint256(keccak256(abi.encode(id, uint256(6))));
        bytes32 creatorWord = bytes32(base + 15);
        bytes32 flagWord = bytes32(base + 23);
        assertEq(vm.load(address(programs), creatorWord), bytes32(uint256(uint160(address(this)))), "creator word");
        assertEq(vm.load(address(programs), flagWord), bytes32(uint256(1)), "flag word: one open day, no flags");
        vm.warp(programs.program(id).terms.start);
        vm.record();
        _trade(id, key, trader, 1e18);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(programs));
        assertGt(reads.length, 0);
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(reads[i] != creatorWord && reads[i] != flagWord, "creator or flag word read");
        }
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(writes[i] != creatorWord && writes[i] != flagWord, "creator or flag word written");
        }
    }

    function testDailySwapAcceptsOptInButDefersPointsUntilClaim() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.start);
        _trade(id, key, trader, 1e18);
        assertEq(programs.points(id, trader), 0);
        vm.warp(t.end);
        bytes32 leaf = _leaf(id, 0, trader, 100, COVERAGE);
        programs.proposeDay(id, 0, leaf, 100, COVERAGE, keccak256("evidence"));
        vm.expectRevert(IHookrPrograms.InvalidProof.selector);
        programs.claimDay(id, 0, trader, 100, new bytes32[](0));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(id, 0);
        programs.claimDay(id, 0, trader, 100, new bytes32[](0));
        assertEq(programs.points(id, trader), t.dailyPointBudget);
        assertEq(programs.claimableCash(id, trader), t.dailyCashBudget);
    }

    function testDailyPointBudgetIsProRataAndDustReturnsOnlyAfterAllWeight() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, true);
        t.pointBudget = 10;
        t.dailyPointBudget = 10;
        t.walletPointCap = 10;
        t.cashBudget = 10;
        t.dailyCashBudget = 10;
        t.walletCashCap = 10;
        uint256 id = _create(t, _scopes(key), false);
        _approveBux(id);
        vm.warp(t.end);
        address second = address(0x9999);
        bytes32 a = _leaf(id, 0, trader, 1, COVERAGE);
        bytes32 b = _leaf(id, 0, second, 2, COVERAGE);
        programs.proposeDay(id, 0, _pair(a, b), 3, COVERAGE, keccak256("evidence"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(id, 0);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        programs.claimDay(id, 0, trader, 1, proof);
        assertEq(programs.points(id, trader), 3);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.releaseUnusedCash(id, 0);
        proof[0] = a;
        programs.claimDay(id, 0, second, 2, proof);
        assertEq(programs.points(id, second), 6);
        uint256 before_ = tokenB.balanceOf(address(this));
        programs.releaseUnusedCash(id, 0);
        assertEq(tokenB.balanceOf(address(this)), before_ + 1);
        // Closing the day returned its unissued allowance at once (L-03); no separate release call exists.
        assertEq(programs.buxReserved(), 9);
        assertEq(programs.buxIssued(), 9);
        assertTrue(programs.program(id).buxReleased);
    }

    function testDailyCoverageDomainAndReviewVeto() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.end);
        bytes32 leaf = _leaf(id, 0, trader, 1, COVERAGE);
        programs.proposeDay(id, 0, leaf, 1, COVERAGE, keccak256("evidence"));
        vm.prank(royalty);
        programs.challengeDay(id, 0, keccak256("bad source"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        // The veto is sticky (L-18): a re-proposal stays challenged until the reviewer approves its exact version.
        programs.proposeDay(id, 0, leaf, 1, keccak256("different coverage"), keccak256("new evidence"));
        assertTrue(programs.epoch(id, 0).challenged);
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.StaleVersion.selector, id, 0, 2));
        programs.approveDay(id, 0, 1);
        vm.prank(royalty);
        programs.approveDay(id, 0, 2);
        assertTrue(programs.epoch(id, 0).finalized);
        vm.expectRevert(IHookrPrograms.InvalidProof.selector);
        programs.claimDay(id, 0, trader, 1, new bytes32[](0));
    }

    function testZeroVolumeDayRefundsCashAndReleasesBuxReservation() public {
        P.Terms memory t = _terms(P.Mode.DailyLPFees, true);
        P.Scope[] memory sources = _scopes(key);
        sources[0].subjectNumerator = 1;
        sources[0].subjectDenominator = 1e15;
        uint256 id = _create(t, sources, false);
        _approveBux(id);
        vm.warp(t.end);
        programs.proposeDay(id, 0, bytes32(0), 0, COVERAGE, keccak256("zero fees evidence"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(id, 0);
        assertEq(programs.buxReserved(), 0);
        programs.releaseUnusedCash(id, 0);
        assertEq(programs.reservedCash(address(tokenB)), 0);
        assertEq(programs.buxReserved(), 0);
    }

    function testLpFeeModeRequiresBothCurrencyRatesAndCannotClaimSwapReceipts() public {
        P.Terms memory t = _terms(P.Mode.DailyLPFees, false);
        P.Scope[] memory sources = _scopes(key);
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        _create(t, sources, false);
        sources[0].subjectNumerator = 1;
        sources[0].subjectDenominator = 1e15;
        uint256 id = _create(t, sources, false);
        vm.warp(t.start);
        IHookrRouter.Swap memory params = _swap(key, true, true, 1e18);
        uint256[] memory ids = _ids(id);
        vm.prank(trader);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        router.swap(params, address(programs), ids);
    }

    function testNftReservationSurvivesRejectedReceiverAndIsNotAutomatic() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), true);
        _settleSingle(id, t, trader);
        uint256 tokenId = programs.reservedNFT(id, trader, 0);
        assertGt(tokenId, 0);
        assertEq(programs.deliveredNFT(id, trader), 0);
        RejectProgramNFT receiver = new RejectProgramNFT();
        vm.prank(trader);
        assertFalse(programs.claimNFT(id, trader, 0, address(receiver)));
        assertEq(programs.deliveredNFT(id, trader), 0);
        vm.prank(trader);
        assertTrue(programs.claimNFT(id, trader, 0, trader));
        assertEq(programs.program(id).collection.ownerOf(tokenId), trader);
    }

    function testNftReceiverCannotReenterCashDelivery() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), true);
        _settleSingle(id, t, trader);
        uint256 cash = programs.claimableCash(id, trader);
        ReenterProgramNFT receiver = new ReenterProgramNFT(programs, id, trader);
        vm.prank(trader);
        assertTrue(programs.claimNFT(id, trader, 0, address(receiver)));
        assertTrue(receiver.blocked());
        assertEq(programs.claimableCash(id, trader), cash);
    }

    function testInexactFundingRollsBackProgramCreation() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        P.Scope[] memory sources = _scopes(key);
        vm.mockCall(address(tokenB), abi.encodeCall(IERC20.balanceOf, (address(programs))), abi.encode(uint256(0)));
        vm.expectRevert(IHookrPrograms.InexactTransfer.selector);
        _create(t, sources, false);
        assertEq(programs.programCount(), 0);
        assertEq(programs.reservedCash(address(tokenB)), 0);
    }

    function testCashDeliveryFailurePreservesClaimAndBacking() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), false);
        _settleSingle(id, t, trader);
        uint256 claim = programs.claimableCash(id, trader);
        uint256 reserved = programs.reservedCash(address(tokenB));
        vm.mockCall(address(tokenB), abi.encodeCall(IERC20.transfer, (trader, claim)), abi.encode(false));
        vm.expectRevert();
        programs.claimCash(id, trader, trader, 0);
        assertEq(programs.claimableCash(id, trader), claim);
        assertEq(programs.reservedCash(address(tokenB)), reserved);
    }

    function testFuzzDailyAllocationNeverExceedsPrefundedCaps(uint128 first, uint128 second) public {
        first = uint128(bound(first, 1, 1e20));
        second = uint128(bound(second, 1, 1e20));
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.end);
        address other = address(0x4444);
        bytes32 a = _leaf(id, 0, trader, first, COVERAGE);
        bytes32 b = _leaf(id, 0, other, second, COVERAGE);
        programs.proposeDay(id, 0, _pair(a, b), uint256(first) + second, COVERAGE, keccak256("evidence"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(id, 0);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        programs.claimDay(id, 0, trader, first, proof);
        proof[0] = a;
        programs.claimDay(id, 0, other, second, proof);
        assertLe(programs.points(id, trader) + programs.points(id, other), t.pointBudget);
        assertLe(programs.claimableCash(id, trader) + programs.claimableCash(id, other), t.cashBudget);
        assertEq(tokenB.balanceOf(address(programs)), programs.reservedCash(address(tokenB)));
    }

    function testCreatorCannotBypassAuthorizationWithSpoofReferralRegistry() public {
        uint256 baseId = _create(_terms(P.Mode.Immediate, false), _scopes(key), false);
        SpoofReferralRegistry fake = new SpoofReferralRegistry();
        P.Terms memory t = _referralTerms(baseId, address(fake), false);
        P.Scope[] memory sources = _scopes(key);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        _create(t, sources, false);
        assertEq(address(programs.referrals()), address(programReferrals));
    }

    function testReferralPointsUseSeparateApprovedBudgetWithoutReducingInvitee() public {
        HookrReferralRegistry registry_ = programReferrals;
        // Immediate base programs credit creator points only; the reviewed referral bonus carries the Bux.
        P.Terms memory base = _terms(P.Mode.Immediate, false);
        uint256 baseId = _create(base, _scopes(key), false);
        P.Terms memory bonus = _referralTerms(baseId, address(registry_), true);
        uint256 bonusId = _create(bonus, _scopes(key), false);
        _approveBux(bonusId);
        bytes32 programKey = programs.referralProgramKey(bonusId);
        address referrer = address(0x123456);
        vm.prank(trader);
        registry_.register(programKey, referrer, bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        uint64 first = uint64(vm.getBlockNumber());
        vm.warp(base.start);
        _trade(baseId, key, trader, 1e18);
        uint256 inviteePoints = programs.points(baseId, trader);
        assertGt(inviteePoints, 0);
        vm.warp(bonus.end);
        bytes32 leaf = _referralLeaf(bonusId, trader, referrer, first, 100, COVERAGE);
        programs.proposeDay(bonusId, 0, leaf, 100, COVERAGE, keccak256("eligible base activity"));
        vm.warp(vm.getBlockTimestamp() + bonus.reviewDelay);
        programs.finalizeDay(bonusId, 0);
        vm.expectRevert(IHookrPrograms.InvalidProof.selector);
        programs.claimDay(bonusId, 0, referrer, 100, new bytes32[](0));
        programs.claimReferralDay(bonusId, 0, trader, referrer, first, 100, new bytes32[](0));
        assertEq(programs.points(baseId, trader), inviteePoints);
        assertEq(programs.buxBalance(trader), 0);
        assertEq(programs.points(bonusId, referrer), bonus.pointBudget);
        assertEq(programs.buxBalance(referrer), bonus.pointBudget);
        vm.expectRevert(IHookrPrograms.Duplicate.selector);
        programs.claimReferralDay(bonusId, 0, trader, referrer, first, 100, new bytes32[](0));
    }

    function testReferralPointsRejectBackdatedBindingAndNestedBonus() public {
        HookrReferralRegistry registry_ = programReferrals;
        uint256 baseId = _create(_terms(P.Mode.DailySwap, false), _scopes(key), false);
        P.Terms memory bonus = _referralTerms(baseId, address(registry_), false);
        uint256 id = _create(bonus, _scopes(key), false);
        P.Terms memory nested = bonus;
        nested.baseProgramId = id;
        P.Scope[] memory nestedScopes = _scopes(key);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        _create(nested, nestedScopes, false);
        address referrer = address(0x123456);
        uint64 first = uint64(vm.getBlockNumber());
        bytes32 key_ = programs.referralProgramKey(id);
        vm.prank(trader);
        registry_.register(key_, referrer, bytes32(0));
        vm.warp(bonus.end);
        bytes32 leaf = _referralLeaf(id, trader, referrer, first, 100, COVERAGE);
        programs.proposeDay(id, 0, leaf, 100, COVERAGE, keccak256("bad historical enrollment"));
        vm.warp(vm.getBlockTimestamp() + bonus.reviewDelay);
        programs.finalizeDay(id, 0);
        vm.expectRevert(IHookrPrograms.InvalidProof.selector);
        programs.claimReferralDay(id, 0, trader, referrer, first, 100, new bytes32[](0));
    }

    function testReferralPointsSupportExplicitLpFeeUnits() public {
        HookrReferralRegistry registry_ = programReferrals;
        P.Scope[] memory sources = _scopes(key);
        sources[0].subjectNumerator = 1;
        sources[0].subjectDenominator = 1e15;
        uint256 baseId = _create(_terms(P.Mode.DailyLPFees, false), sources, false);
        P.Terms memory bonus = _referralTerms(baseId, address(registry_), false);
        uint256 id = _create(bonus, sources, false);
        assertEq(uint256(programs.program(id).terms.mode), uint256(P.Mode.DailyReferral));
        sources[0].numerator = 2;
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        _create(bonus, sources, false);
    }

    // ---------------------------------------------------------------- review, window and lapse (L-03, L-18, L-23)

    function testApproveDayFinalizesExactVersionAndRejectsOthers() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.end);
        bytes32 leaf = _leaf(id, 0, trader, 1, COVERAGE);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.StaleVersion.selector, id, 0, 0));
        programs.approveDay(id, 0, 0);
        programs.proposeDay(id, 0, leaf, 1, COVERAGE, keccak256("evidence"));
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.approveDay(id, 0, 1); // attestor is not the reviewer
        vm.prank(royalty);
        programs.approveDay(id, 0, 1); // fast path: no need to wait out the delay
        assertTrue(programs.epoch(id, 0).finalized);
        assertFalse(programs.epoch(id, 0).challenged);
        programs.claimDay(id, 0, trader, 1, new bytes32[](0));
        assertEq(programs.claimableCash(id, trader), t.dailyCashBudget);
        vm.prank(royalty);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.approveDay(id, 0, 1);
    }

    function testApprovedZeroDayClosesAndReleases() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, true);
        uint256 id = _create(t, _scopes(key), false);
        _approveBux(id);
        vm.warp(t.end);
        programs.proposeDay(id, 0, bytes32(0), 0, COVERAGE, keccak256("zero"));
        vm.prank(royalty);
        programs.approveDay(id, 0, 1);
        assertTrue(programs.epoch(id, 0).closed);
        assertEq(programs.buxReserved(), 0);
        assertEq(programs.releaseUnusedCash(id, 0), t.dailyCashBudget);
    }

    function testChallengeLandsAfterDelayUntilSomeoneFinalizes() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        uint256 id = _create(t, _scopes(key), false);
        vm.warp(t.end);
        programs.proposeDay(id, 0, _leaf(id, 0, trader, 1, COVERAGE), 1, COVERAGE, keccak256("evidence"));
        vm.warp(programs.epoch(id, 0).finalizeAfter + 1 hours);
        vm.prank(royalty);
        programs.challengeDay(id, 0, keccak256("late but first"));
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
    }

    function testProposalWindowClosesAndOnlyUnproposedOrVetoedDaysLapse() public {
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        t.end = t.start + 3 days;
        t.pointBudget = 3000;
        t.walletPointCap = 3000;
        t.cashBudget = 30_000;
        t.walletCashCap = 30_000;
        uint256 id = _create(t, _scopes(key), false);
        uint256 window = programs.PROPOSAL_WINDOW();
        uint256 end0 = programs.dayEnd(id, 0);
        vm.warp(end0 + window - 1);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 0);
        // day 1: an unchallenged proposal made at the last moment finalizes and never lapses
        programs.proposeDay(id, 1, _leaf(id, 1, trader, 1, COVERAGE), 1, COVERAGE, keccak256("evidence"));
        // day 2: vetoed
        programs.proposeDay(id, 2, _leaf(id, 2, trader, 1, COVERAGE), 1, COVERAGE, keccak256("evidence"));
        vm.prank(royalty);
        programs.challengeDay(id, 2, keccak256("veto"));
        vm.warp(end0 + window);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.ProposalWindowClosed.selector, id, 0, end0 + window));
        programs.proposeDay(id, 0, bytes32(0), 0, COVERAGE, keccak256("late"));
        uint256 before_ = tokenB.balanceOf(address(this));
        programs.lapseDay(id, 0);
        assertTrue(programs.epoch(id, 0).closed);
        assertEq(programs.releaseUnusedCash(id, 0), t.dailyCashBudget);
        assertEq(tokenB.balanceOf(address(this)), before_ + t.dailyCashBudget);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 0);
        vm.warp(programs.dayEnd(id, 2) + window);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 1);
        // The last-moment proposals mature after their own review delay, which here outlasts the window.
        vm.warp(programs.epoch(id, 1).finalizeAfter);
        programs.finalizeDay(id, 1);
        programs.claimDay(id, 1, trader, 1, new bytes32[](0));
        programs.lapseDay(id, 2);
        assertEq(programs.epoch(id, 2).totalWeight, 0);
        assertEq(programs.epoch(id, 2).merkleRoot, bytes32(0));
        vm.expectRevert(IHookrPrograms.InvalidProof.selector);
        programs.claimDay(id, 2, trader, 1, new bytes32[](0));
        assertEq(programs.program(id).openDays, 0);
    }

    function testRenounceOwnershipIsDisabled() public {
        vm.expectRevert(IHookrPrograms.RenounceDisabled.selector);
        programs.renounceOwnership();
        assertEq(programs.owner(), address(this));
    }

    function testUnregisteredRootScopeIsRejected() public {
        ProgramsMimicRoot fake = new ProgramsMimicRoot(
            address(manager), root.policyHash(key.toId()), Currency.unwrap(root.poolConfig(key.toId()).quote)
        );
        P.Scope[] memory sources = _scopes(key);
        sources[0].root = address(fake);
        P.Terms memory t = _terms(P.Mode.Immediate, false);
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        _create(t, sources, false);
    }

    // ---------------------------------------------------------------- cash ledgers and shortfalls (N-01, L-19)

    function testIssuerShortfallIsSharedProRataOnlyByThePartyOwed() public {
        ProgramsBurnableToken m = new ProgramsBurnableToken();
        m.approve(address(programs), type(uint256).max);
        P.Terms memory t = _terms(P.Mode.DailySwap, false);
        t.rewardToken = address(m);
        t.cashBudget = 1000;
        t.dailyCashBudget = 1000;
        t.walletCashCap = 1000;
        uint256 a = _create(t, _scopes(key), false);
        uint256 b = _create(t, _scopes(key), false);
        vm.warp(t.end);
        programs.proposeDay(a, 0, _leaf(a, 0, trader, 1, COVERAGE), 1, COVERAGE, keccak256("evidence"));
        programs.proposeDay(b, 0, bytes32(0), 0, COVERAGE, keccak256("zero"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(a, 0);
        programs.finalizeDay(b, 0);
        programs.claimDay(a, 0, trader, 1, new bytes32[](0));
        m.issuerBurn(address(programs), 200); // held 1800 against 2000 owed: ratio 0.9
        // A third party cannot impose the haircut on the trader or on the creator.
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.CashShortfall.selector, address(m), 2000, 1800));
        programs.claimCash(a, trader, trader, 0);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.CashShortfall.selector, address(m), 2000, 1800));
        programs.releaseUnusedCash(b, 0);
        // New money cannot enter a pool that is short.
        P.Terms memory later = _terms(P.Mode.DailySwap, false);
        later.rewardToken = address(m);
        later.cashBudget = 1000;
        later.dailyCashBudget = 1000;
        later.walletCashCap = 1000;
        P.Scope[] memory sources = _scopes(key);
        vm.expectRevert(IHookrPrograms.BudgetExceeded.selector);
        _create(later, sources, false);
        // Each party owed may exit at the same ratio; nobody is frozen.
        vm.prank(trader);
        programs.claimCash(a, trader, trader, 0);
        assertEq(m.balanceOf(trader), 900);
        uint256 before_ = m.balanceOf(address(this));
        programs.releaseUnusedCash(b, 0);
        assertEq(m.balanceOf(address(this)), before_ + 900);
        assertEq(programs.reservedCash(address(m)), 0);
        assertEq(m.balanceOf(address(programs)), 0);
    }

    function _referralTerms(uint256 baseId, address registry_, bool bux) private view returns (P.Terms memory t) {
        t = _terms(P.Mode.DailyReferral, bux);
        t.referralRegistry = registry_;
        t.baseProgramId = baseId;
        t.rewardToken = address(0);
        t.cashBudget = 0;
        t.walletCashCap = 0;
        t.dailyCashBudget = 0;
    }

    function _referralLeaf(uint256 id, address payer, address referrer, uint64 first, uint128 weight, bytes32 coverage)
        private
        view
        returns (bytes32)
    {
        IHookrPrograms.Program memory p = programs.program(id);
        uint64 end = programs.dayEnd(id, 0);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(programs),
                        id,
                        p.termsHash,
                        uint256(0),
                        uint64(end - 1 days),
                        end,
                        coverage,
                        payer,
                        referrer,
                        first,
                        weight
                    )
                )
            )
        );
    }

    function _terms(P.Mode mode, bool bux) private view returns (P.Terms memory t) {
        t.mode = mode;
        t.globalBux = bux;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = 1000;
        t.walletPointCap = 1000;
        t.rewardToken = address(tokenB);
        t.cashBudget = 10_000;
        t.walletCashCap = 10_000;
        t.sourcePolicyHash = keccak256("explicit normalized scope units");
        t.name = "Program";
        t.metadataURI = "ipfs://terms";
        t.pointDecimals = 18;
        if (mode == P.Mode.Immediate) {
            // Immediate programs back creator points only (L-04).
            t.pointNumerator = 1;
            t.pointDenominator = 1;
            t.rewardToken = address(0);
            t.cashBudget = 0;
            t.walletCashCap = 0;
        } else {
            t.dailyPointBudget = t.pointBudget;
            t.dailyCashBudget = t.cashBudget;
            t.attestor = address(this);
            t.reviewer = royalty;
            t.reviewDelay = 6 days;
        }
    }

    function _scopes(PoolKey memory pool) private view returns (P.Scope[] memory sources) {
        sources = new P.Scope[](1);
        HookrTypes.PoolConfig memory c = root.poolConfig(pool.toId());
        sources[0] = P.Scope(
            address(root),
            PoolId.unwrap(pool.toId()),
            root.policyHash(pool.toId()),
            Currency.unwrap(c.quote),
            1,
            1e15,
            0,
            0
        );
    }

    /// @dev Proposes a Bux program's approval and executes it once BUX_APPROVAL_DELAY has passed.
    function _approveBux(uint256 id) private {
        programs.proposeBuxProgram(id);
        vm.warp(vm.getBlockTimestamp() + programs.BUX_APPROVAL_DELAY());
        programs.approveBuxProgram(id);
    }

    function _create(P.Terms memory t, P.Scope[] memory sources, bool nft) private returns (uint256) {
        P.Milestone[] memory ms = new P.Milestone[](nft ? 1 : 0);
        if (nft) ms[0] = P.Milestone(10, 100);
        P.NFTMetadata memory metadata;
        if (nft) metadata = P.NFTMetadata("Milestone", "MS", "ipfs://nft/", true);
        return programs.createProgram(t, sources, ms, metadata);
    }

    /// @dev Attest, finalize and claim a single-beneficiary day 0 of a one-day daily program.
    function _settleSingle(uint256 id, P.Terms memory t, address user) private {
        vm.warp(t.end);
        bytes32 leaf = _leaf(id, 0, user, 100, COVERAGE);
        programs.proposeDay(id, 0, leaf, 100, COVERAGE, keccak256("evidence"));
        vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
        programs.finalizeDay(id, 0);
        programs.claimDay(id, 0, user, 100, new bytes32[](0));
    }

    function _trade(uint256 id, PoolKey memory pool, address payer, uint128 amount) private {
        IHookrRouter.Swap memory params = _swap(pool, true, true, amount);
        params.recipient = payer;
        uint256 value = Currency.unwrap(params.zeroForOne ? pool.currency0 : pool.currency1) == address(0) ? amount : 0;
        vm.prank(payer);
        router.swap{value: value}(params, address(programs), _ids(id));
    }

    function _ids(uint256 id) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _leaf(uint256 id, uint256 day, address user, uint128 weight, bytes32 coverage)
        private
        view
        returns (bytes32)
    {
        IHookrPrograms.Program memory p = programs.program(id);
        uint64 end = programs.dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(programs),
                        id,
                        p.termsHash,
                        day,
                        uint64(end - 1 days),
                        end,
                        coverage,
                        user,
                        weight
                    )
                )
            )
        );
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
