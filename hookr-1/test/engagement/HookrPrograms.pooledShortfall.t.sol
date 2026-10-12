// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";

contract ClawbackToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("M", "M") {
        _mint(msg.sender, 1e30);
    }

    function adminBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// L-19 (Programs side): all programs in one reward token shared reservedCash and one balance, and any
/// shortfall reverted every payout, refund and new funding in that token until a third party donated the gap.
///
/// Before the fix (base b7aeae64, B15Verify.testC4_ShortfallFreezesUnrelatedCreator): with reservedCash 200e18, an
/// issuer burn of 1 wei made creator B's zero-activity releaseUnusedCash, creator A's trader claimCash and a new
/// createProgram all revert BudgetExceeded; only a 1-wei donation restored them (B then received 100e18).
/// Fix: each program's cash is its own ledger, and an unattributable token shortfall is shared pro rata. The party
/// owed may exit at held/owed at any time, which leaves the ratio unchanged for everyone else; a third party cannot
/// impose that haircut, and new funding stays blocked while the pool is short. Exits no longer depend on a donor.
/// Residual (no contract fix exists): an issuer that blacklists the Programs address blocks every transfer of that
/// token; the qualified-asset policy must exclude such assets.
contract HookrProgramsPooledShortfallTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms programs;
    PoolKey key;
    ClawbackToken m;
    address attestor = address(0xA11);
    address reviewer = address(0xB22);
    address creator2 = address(0xC22);
    bytes32 constant COV = keccak256("cov");

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        m = new ClawbackToken();
        m.transfer(creator2, 1e24);
        m.approve(address(programs), type(uint256).max);
        vm.prank(creator2);
        m.approve(address(programs), type(uint256).max);
    }

    function _terms() internal view returns (P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.dailyPointBudget = 1000e18;
        t.pointBudget = 1000e18;
        t.walletPointCap = t.pointBudget;
        t.rewardToken = address(m);
        t.dailyCashBudget = 100e18;
        t.cashBudget = 100e18;
        t.walletCashCap = t.cashBudget;
        t.attestor = attestor;
        t.reviewer = reviewer;
        t.reviewDelay = 6 days;
        t.sourcePolicyHash = keccak256("dailySwap");
        t.name = "Daily";
        t.pointDecimals = 18;
    }

    function _scopes() internal view returns (P.Scope[] memory s) {
        s = new P.Scope[](1);
        s[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(root.poolConfig(key.toId()).quote),
            1,
            1,
            0,
            0
        );
    }

    function _leaf(uint256 id, address who, uint128 w) internal view returns (bytes32) {
        uint64 end = programs.dayEnd(id, 0);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(programs),
                        id,
                        programs.program(id).termsHash,
                        uint256(0),
                        uint64(end - 1 days),
                        end,
                        COV,
                        who,
                        w
                    )
                )
            )
        );
    }

    function _setUpTwoCreators() internal returns (uint256 a, uint256 b) {
        P.Terms memory t = _terms();
        P.Scope[] memory s = _scopes();
        P.NFTMetadata memory md;
        a = programs.createProgram(t, s, new P.Milestone[](0), md);
        vm.prank(creator2);
        b = programs.createProgram(t, s, new P.Milestone[](0), md);
        vm.warp(programs.dayEnd(a, 0));
        bytes32 leafA = _leaf(a, trader, 5);
        vm.startPrank(attestor);
        programs.proposeDay(a, 0, leafA, 5, COV, keccak256("ev"));
        programs.proposeDay(b, 0, bytes32(0), 0, COV, keccak256("zero"));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 6 days);
        programs.finalizeDay(a, 0);
        programs.finalizeDay(b, 0);
        programs.claimDay(a, 0, trader, 5, new bytes32[](0));
    }

    /// The PoC's 1-wei issuer burn no longer freezes the unrelated creator or the trader.
    function testShortfallNoLongerFreezesUnrelatedParties() public {
        (uint256 a, uint256 b) = _setUpTwoCreators();
        assertEq(programs.reservedCash(address(m)), 200e18);
        m.adminBurn(address(programs), 1);
        // Third-party triggers cannot realize someone else's haircut.
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.CashShortfall.selector, address(m), 200e18, 200e18 - 1));
        programs.releaseUnusedCash(b, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.CashShortfall.selector, address(m), 200e18, 200e18 - 1));
        programs.claimCash(a, trader, trader, 0);
        // New money cannot enter a short pool.
        P.Terms memory t3 = _terms();
        P.Scope[] memory s3 = _scopes();
        P.Milestone[] memory none = new P.Milestone[](0);
        P.NFTMetadata memory md;
        vm.expectRevert(IHookrPrograms.BudgetExceeded.selector);
        programs.createProgram(t3, s3, none, md);
        // The parties owed exit on their own, without any donor.
        vm.prank(creator2);
        uint256 nominal = programs.releaseUnusedCash(b, 0);
        assertEq(nominal, 100e18);
        assertEq(m.balanceOf(creator2), 1e24 - 100e18 + 100e18 - 1, "B bears its pro-rata share of the 1-wei loss");
        vm.prank(trader);
        programs.claimCash(a, trader, trader, 0);
        assertEq(m.balanceOf(trader), 100e18, "the pool was whole again after B's rounded exit");
        assertEq(programs.reservedCash(address(m)), 0);
        assertEq(m.balanceOf(address(programs)), 0);
    }

    /// A larger clawback is shared at one ratio, whatever the exit order.
    function testClawbackIsSharedAtOneRatio() public {
        (uint256 a, uint256 b) = _setUpTwoCreators();
        m.adminBurn(address(programs), 50e18); // 150e18 held against 200e18 owed
        vm.prank(trader);
        programs.claimCash(a, trader, trader, 40e18);
        assertEq(m.balanceOf(trader), 30e18);
        vm.prank(creator2);
        programs.releaseUnusedCash(b, 0);
        assertEq(m.balanceOf(creator2), 1e24 - 100e18 + 75e18);
        vm.prank(trader);
        programs.claimCash(a, trader, trader, 0);
        assertEq(m.balanceOf(trader), 75e18);
        assertEq(m.balanceOf(address(programs)), 0);
        assertEq(programs.reservedCash(address(m)), 0);
    }

    /// Residual: a blacklist of the Programs address itself still blocks that token (documented, no rescue power).
    function testContractBlacklistRemainsAnAssetQualificationRisk() public {
        (, uint256 b) = _setUpTwoCreators();
        m.setBlocked(address(programs), true);
        vm.prank(creator2);
        vm.expectRevert();
        programs.releaseUnusedCash(b, 0);
    }
}
