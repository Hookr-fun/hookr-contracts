// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {Pools} from "./Pools.sol";

/// @notice What it costs to open a market. A new token launched with a dev buy puts the whole supply in one band from
///         the lowest tick to the opening price, and the launcher buys for the creator in the same transaction. An
///         existing token is opened on the steady-state pool with nothing but its base fee. Each Rules contract takes
///         a warm-up launch first, because the first launch with a launch guard on a Rules contract writes storage
///         slots that every later launch reuses, and a launch is measured as the later kind.
contract LaunchTest is Pools {
    uint256 internal constant LAUNCH_SUPPLY = 1e27;
    int24 internal constant OPEN_TICK = 198_060;
    uint128 internal constant DEV_BUY = 0.001 ether;
    uint128 internal constant WALLET_CAP = 2e25;

    address internal creator = makeAddr("creator");
    uint256 internal saltNonce;

    /// @dev Funds the creator, whose approval the launcher needs for the dev buy.
    function setUp() public override {
        super.setUp();
        deal(WETH, creator, 10 ether);
        vm.prank(creator);
        IERC20(WETH).approve(address(LAUNCHER), type(uint256).max);
    }

    /// @notice Each kind of launch, after a warm-up launch on each Rules contract.
    function test_launches() public {
        _newTokenLaunch(RULES, true, 0);
        _newTokenLaunch(RULES, false, 0);
        _newTokenLaunch(RULES_WHOLE_POT, true, 0);
        _newTokenLaunch(RULES_WALLET_CAP, true, WALLET_CAP);
        _nextBlock();
        uint256 antiSnipe = _newTokenLaunch(RULES, true, 0);
        _nextBlock();
        uint256 noGuard = _newTokenLaunch(RULES, false, 0);
        _nextBlock();
        uint256 wholePot = _newTokenLaunch(RULES_WHOLE_POT, true, 0);
        _nextBlock();
        uint256 walletCap = _newTokenLaunch(RULES_WALLET_CAP, true, WALLET_CAP);

        _launch(_newToken(), _member(RULES), "");
        _nextBlock();
        _launch(_newToken(), _member(RULES), "");
        uint256 existing = launchGas;

        _report(
            "launch.new-token-with-anti-snipe",
            "launch",
            "Launch a new token with a dev buy and Anti-Snipe",
            int256(antiSnipe),
            ABSOLUTE,
            "launch"
        );
        _report(
            "launch.existing-token-fee-only",
            "launch",
            "Launch an existing token with nothing on but the base fee",
            int256(existing),
            ABSOLUTE,
            "launch"
        );
        _report(
            "anti-snipe.launch",
            "launch",
            "Anti-Snipe at launch: a new token with a dev buy, over the same launch without a guard",
            _extra(antiSnipe, noGuard),
            SAME_POOL_WITHOUT_PIECE,
            "anti-snipe"
        );
        _report(
            "wallet-cap.launch",
            "launch",
            "Wallet Cap at launch: over the same launch on the whole-pot Rules with the same guard",
            _extra(walletCap, wholePot),
            SAME_POOL_WITHOUT_PIECE,
            "wallet-cap"
        );
    }

    /// @dev Records a launch figure; every launch is a direct call to the launcher.
    function _report(
        string memory id,
        string memory action,
        string memory what,
        int256 gas,
        string memory baseline,
        string memory piece
    ) private {
        _record(
            Figure({
                id: id,
                piece: piece,
                label: what,
                action: action,
                gas: gas,
                baseline: baseline,
                router: DIRECT,
                test: "bench/test/Launch.t.sol:test_launches"
            })
        );
    }

    /// @dev Launches a new token with a dev buy on `rules`, with the launch guard when `guard` is set, and returns the
    ///      launch's gas.
    function _newTokenLaunch(address rules, bool guard, uint128 walletCap) private returns (uint256) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _newTokenMember(rules, guard, walletCap);
        bytes[] memory advisory = new bytes[](1);
        IHookrLauncher.Token memory token = _freshToken();
        vm.prank(creator, creator);
        (bool ok, bytes memory ret) = address(LAUNCHER)
            .call(
                abi.encodeCall(
                    IHookrLauncher.launchWithBuy,
                    (
                        token,
                        ROOT,
                        members,
                        advisory,
                        IHookrLauncher.DevBuy(0, DEV_BUY, 1, 0),
                        vm.getBlockTimestamp() + 600
                    )
                )
            );
        uint256 gas = vm.lastCallGas().gasTotalUsed;
        _requireOk(ok, ret);
        return gas;
    }

    /// @dev The member of a new token's launch: the whole supply in one band from the lowest tick to the opening price,
    ///      with the shared launch guard when `guard` is set.
    function _newTokenMember(address rules, bool guard, uint128 walletCap)
        private
        view
        returns (IHookrLauncher.Member memory m)
    {
        m.quote = Currency.wrap(WETH);
        m.tickSpacing = SPACING;
        m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(OPEN_TICK);
        m.tickLower = TickMath.minUsableTick(SPACING);
        m.tickUpper = OPEN_TICK;
        m.liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(m.tickLower), m.sqrtPriceX96, LAUNCH_SUPPLY
        ) / 1000 * 999;
        m.amount0Max = 0;
        m.amount1Max = uint128(LAUNCH_SUPPLY);
        m.config.rules = rules;
        m.config.baseLpFeePips = BASE_FEE_PIPS;
        m.config.caps = HookrTypes.Caps(600_000, 350_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("hookr-gas-bench");
        m.rules.maxFeePips = BASE_FEE_PIPS;
        m.rules.protocolShareBps = PROTOCOL_SHARE_BPS;
        if (guard) _guard(m, walletCap);
    }

    /// @dev A new token whose address sorts above WETH, so WETH is currency0 and a buy is zeroForOne.
    function _freshToken() private returns (IHookrLauncher.Token memory token) {
        token.name = "Launch Bench";
        token.symbol = "BENCH";
        token.supply = LAUNCH_SUPPLY;
        do {
            token.salt = keccak256(abi.encode("hookr gas bench", ++saltNonce));
        } while (LAUNCHER.predictToken(creator, token) < WETH);
    }
}
