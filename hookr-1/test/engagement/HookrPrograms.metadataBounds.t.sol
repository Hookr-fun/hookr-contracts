// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";

/// M-11 (onchain part): with zero milestones, NFTMetadata name/symbol/baseURI had no length bound yet were emitted in
/// ProgramCreated, which the service returns verbatim from /v1/programs.
///
/// Before the fix (base b7aeae64, B19Verify.testC3_UnboundedNftMetadataWithZeroMilestones): one createProgram with
/// 2 x 400,000-byte strings cost 21,091,254 gas and emitted an 801,824-byte event; three such programs pushed
/// /v1/programs past the app's 2,000,000-byte cap.
/// Fix: without milestones the metadata must be empty; with milestones the collection constructor bounds it (name
/// <= 100, symbol <= 16, baseURI <= 512). Terms strings were already bounded, so every ProgramCreated event is now a
/// few kilobytes at most. The remaining list-growth DoS (many small programs) needs the offchain pagination and
/// filtering described in the finding; that is outside this contract lane.
contract HookrProgramsMetadataBoundsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms programs;
    PoolKey key;

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 10_000, address(new HookrReferralRegistry()));
    }

    function _long(uint256 n) private pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "a";
        }
        return string(b);
    }

    function _scope(PoolKey memory pool) private view returns (P.Scope memory) {
        HookrTypes.PoolConfig memory c = root.poolConfig(pool.toId());
        return P.Scope(
            address(root),
            PoolId.unwrap(pool.toId()),
            root.policyHash(pool.toId()),
            Currency.unwrap(c.quote),
            1,
            1,
            0,
            0
        );
    }

    function _scopes(uint256 n) private returns (P.Scope[] memory s) {
        int24[7] memory spacings = [int24(10), 12, 15, 20, 24, 25, 30]; // divide the fixture's +-60,000 range
        s = new P.Scope[](n);
        s[0] = _scope(key);
        for (uint256 i = 1; i < n; ++i) {
            // Further markets for the same pair: one family per tick spacing.
            IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
            members[0] = _member(Currency.wrap(address(tokenB)));
            members[0].tickSpacing = spacings[i - 1];
            (bytes32 family,) = launcher.launch(
                IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
                address(root),
                members,
                vm.getBlockTimestamp()
            );
            s[i] = _scope(launcher.position(family, 0).key);
        }
    }

    function _terms() private view returns (P.Terms memory t) {
        t.mode = P.Mode.Immediate;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = 1;
        t.walletPointCap = 1;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("x");
        t.name = "p";
        t.pointDecimals = 18;
    }

    function testUnboundedMetadataWithoutMilestonesIsRejected() public {
        P.Terms memory t = _terms();
        P.Scope[] memory s = _scopes(1);
        string memory big = _long(400_000);
        vm.prank(address(0xBEEF));
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata(big, big, "", false));
        vm.prank(address(0xBEEF));
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "x", false));
    }

    /// The largest creation event the contract now accepts: maximal terms strings, 8 scopes, 16 milestones and
    /// maximal collection metadata (daily mode, since milestones need a reviewed allocation).
    function testLargestProgramCreatedEventIsBounded() public {
        P.Terms memory t = _terms();
        t.mode = P.Mode.DailySwap;
        t.pointNumerator = 0;
        t.pointDenominator = 0;
        t.pointBudget = 1e18;
        t.dailyPointBudget = 1e18;
        t.walletPointCap = 1e18;
        t.attestor = address(0xA1);
        t.reviewer = address(0xA2);
        t.reviewDelay = 6 days;
        t.name = _long(100);
        t.metadataURI = _long(512);
        P.Milestone[] memory ms = new P.Milestone[](16);
        for (uint256 i; i < 16; ++i) {
            ms[i] = P.Milestone(uint128(i + 1), 1);
        }
        P.NFTMetadata memory md = P.NFTMetadata(_long(100), _long(16), _long(512), true);
        P.Scope[] memory s = _scopes(8);
        vm.recordLogs();
        programs.createProgram(t, s, ms, md);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 size = logs[logs.length - 1].data.length;
        emit log_named_uint("largest ProgramCreated data bytes (was up to 801,824 per 400 KB string pair)", size);
        assertLt(size, 8_000);
        // Oversized collection metadata is rejected by the collection constructor.
        md.symbol = _long(17);
        vm.expectRevert();
        programs.createProgram(t, s, ms, md);
    }
}
