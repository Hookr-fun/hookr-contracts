// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrLaunchFee} from "../../src/interfaces/IHookrLaunchFee.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";
import {GasMeasure} from "../utils/GasMeasure.sol";

/// @notice Per-transaction gas of an existing-token SKIP_TAKEN launch with taken ERC-20 members, whose budgets are never
///         pulled, of launchFamily against launch, and of a launch paying the launch fee. Same fixture and method as
///         GasBench (real 4663 PoolManager runtime); run it with
///         `forge test --isolate --match-path test/bench/LaunchEfficiencyBench.t.sol -vv`. The totals are committed
///         in snapshots/LaunchEfficiencyBench.json.
contract LaunchEfficiencyBench is GasBenchFixture, GasMeasure {
    function setUp() public override {
        super.setUp();
        // Take subject/quotes[0] and subject/quotes[1] at spacing 60 before the SKIP_TAKEN launches.
        _launchOne(Currency.wrap(address(quotes[0])), 60, false);
        _launchOne(Currency.wrap(address(quotes[1])), 60, false);
    }

    function _skipFamily(uint256 n) internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](n);
        for (uint256 i; i < n; ++i) {
            members[i] = _member(Currency.wrap(address(quotes[i])), 60, false);
        }
    }

    function _launchSkipTaken(IHookrLauncher.Member[] memory members) internal {
        launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, launcher.SKIP_TAKEN()),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
    }

    /// @dev Member 0 is taken, member 1 launches.
    function test_gas_launch_skipTaken_2member_1skipped() public {
        IHookrLauncher.Member[] memory members = _skipFamily(2);
        members[1].quote = Currency.wrap(address(quotes[2]));
        _launchSkipTaken(members);
        _measure("launch.skipTaken.2member.1skipped");
    }

    /// @dev Members 0 and 1 are taken, members 2 and 3 launch.
    function test_gas_launch_skipTaken_4member_2skipped() public {
        _launchSkipTaken(_skipFamily(4));
        _measure("launch.skipTaken.4member.2skipped");
    }

    /// @dev Reference: the same salt with no member taken (members 2 to 5).
    function test_gas_launch_skipTaken_4member_0skipped() public {
        IHookrLauncher.Member[] memory members = _skipFamily(4);
        members[0].quote = Currency.wrap(address(quotes[4]));
        members[1].quote = Currency.wrap(address(quotes[5]));
        _launchSkipTaken(members);
        _measure("launch.skipTaken.4member.0skipped");
    }

    // ───────────────────────────── launchFamily ─────────────────────────────

    /// @dev launchFamily's input for `members` with today's defaults.
    function _params(IHookrLauncher.Token memory t, IHookrLauncher.Member[] memory members)
        internal
        view
        returns (IHookrLauncher.LaunchParams memory p)
    {
        uint256 n = members.length;
        p.token = t;
        p.root = address(root);
        p.members = members;
        p.knobs = new IHookrLauncher.MemberKnobs[](n);
        p.advisoryConfigs = new bytes[](n);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
    }

    function _oneFull() internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quotes[2])), 60, true);
    }

    /// @dev Reference for the row below: the same one-member launch through launch.
    function test_gas_launch_1member_reference() public {
        launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            _oneFull(),
            vm.getBlockTimestamp()
        );
        _measure("launch.1member.reference");
    }

    /// @dev launch.1member.reference paying a 0.001 launch fee to the treasury's target, an account that already exists.
    function test_gas_launch_1member_fee() public {
        address target = address(0x7A7);
        vm.deal(target, 1);
        HookrTreasury treasury = new HookrTreasury(address(this), target, manager);
        IHookrLaunchFee fees = IHookrLaunchFee(address(launcher));
        fees.proposeLaunchFee(0.001 ether, address(treasury));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        fees.acceptLaunchFee();
        launcher.launch{value: 0.001 ether}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            _oneFull(),
            vm.getBlockTimestamp()
        );
        _measure("launch.1member.fee");
    }

    /// @dev launch.1member.reference through launchFamily at today's defaults.
    function test_gas_launchFamily_1member() public {
        launcher.launchFamily(_params(IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)), _oneFull()));
        _measure("launchFamily.1member");
    }

    /// @dev Eight full members at spacing 10, every member at price 1 checked against a reference pool at price 1, at a
    ///      1 bp tolerance.
    function test_gas_launchFamily_8member_openingCheck() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](8);
        for (uint256 i; i < 8; ++i) {
            members[i] = _member(Currency.wrap(address(quotes[i])), 10, true);
        }
        IHookrLauncher.LaunchParams memory p =
            _params(IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)), members);
        p.opening.toleranceBps = 1;
        p.opening.references = new PoolKey[](7);
        for (uint256 i = 1; i < 8; ++i) {
            (address a, address b) = address(quotes[i]) < address(quotes[0])
                ? (address(quotes[i]), address(quotes[0]))
                : (address(quotes[0]), address(quotes[i]));
            p.opening.references[i - 1] = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(0)));
            manager.initialize(p.opening.references[i - 1], SQRT_ONE);
        }
        launcher.launchFamily(p);
        _measure("launchFamily.8member.openingCheck");
    }

    /// @dev A new token over eight ERC-20 quotes, each member's band on the subject's side of price 1 holding an eighth
    ///      of the 1e27 supply, guarded with a 50% Snipe and a 1e22 per-block cap, and a 1e21 dev buy on every member.
    function test_gas_launchFamily_newToken_8member_8devBuys() public {
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "New", "NEW", 1e27, bytes32(uint256(9)));
        address s = launcher.predictToken(address(this), t);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](8);
        for (uint256 i; i < 8; ++i) {
            members[i] = _member(Currency.wrap(address(quotes[i])), 10, false);
            bool subjectIs0 = s < address(quotes[i]);
            members[i].tickLower = subjectIs0 ? int24(0) : int24(-60_000);
            members[i].tickUpper = subjectIs0 ? int24(60_000) : int24(0);
            uint160 lower = TickMath.getSqrtPriceAtTick(members[i].tickLower);
            uint160 upper = TickMath.getSqrtPriceAtTick(members[i].tickUpper);
            members[i].liquidity =
                (subjectIs0
                            ? LiquidityAmounts.getLiquidityForAmount0(lower, upper, 1e27 / 8)
                            : LiquidityAmounts.getLiquidityForAmount1(lower, upper, 1e27 / 8)) / 1000 * 999;
            members[i].amount0Max = subjectIs0 ? uint128(1e27 / 8) : 0;
            members[i].amount1Max = subjectIs0 ? 0 : uint128(1e27 / 8);
            members[i].rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
            members[i].rules.snipeTaxPips = 500_000;
            members[i].rules.maxBuyQuoteAmount = 1e22;
        }
        IHookrLauncher.LaunchParams memory p = _params(t, members);
        p.buys = new IHookrLauncher.DevBuy[](8);
        for (uint256 i; i < 8; ++i) {
            p.buys[i] = IHookrLauncher.DevBuy(uint8(i), 1e21, 1, 0);
        }
        launcher.launchFamily(p);
        _measure("launchFamily.newToken.8member.8devBuys");
    }

    /// @dev A new token's one-member launchFamily, its band on the subject's side of price 1 against quotes[3].
    function _newTokenParams(bytes32 salt) internal view returns (IHookrLauncher.LaunchParams memory p) {
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "New", "NEW", 1e27, salt);
        address s = launcher.predictToken(address(this), t);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quotes[3])), 60, false);
        bool subjectIs0 = s < address(quotes[3]);
        members[0].tickLower = subjectIs0 ? int24(0) : int24(-60_000);
        members[0].tickUpper = subjectIs0 ? int24(60_000) : int24(0);
        uint160 lower = TickMath.getSqrtPriceAtTick(members[0].tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(members[0].tickUpper);
        members[0].liquidity =
            (subjectIs0
                        ? LiquidityAmounts.getLiquidityForAmount0(lower, upper, 1e27)
                        : LiquidityAmounts.getLiquidityForAmount1(lower, upper, 1e27)) / 1000 * 999;
        members[0].amount0Max = subjectIs0 ? uint128(1e27) : 0;
        members[0].amount1Max = subjectIs0 ? 0 : uint128(1e27);
        p = _params(t, members);
    }

    /// @dev Reference for the row below: the same new token with no tagline or logo URI.
    function test_gas_launchFamily_newToken() public {
        launcher.launchFamily(_newTokenParams(bytes32(uint256(11))));
        _measure("launchFamily.newToken");
    }

    /// @dev The same launch with a 160-byte tagline and a 300-byte logo URI, the longest the token stores.
    function test_gas_launchFamily_newToken_presented() public {
        IHookrLauncher.LaunchParams memory p = _newTokenParams(bytes32(uint256(11)));
        p.tagline = string(new bytes(160));
        p.logoURI = string(new bytes(300));
        bytes memory t = bytes(p.tagline);
        bytes memory l = bytes(p.logoURI);
        for (uint256 i; i < 300; ++i) {
            if (i < 160) t[i] = "t";
            l[i] = "l";
        }
        launcher.launchFamily(p);
        _measure("launchFamily.newToken.presented");
    }
}
