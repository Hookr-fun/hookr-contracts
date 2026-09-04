// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {V4PoolMath} from "../src/libraries/V4PoolMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {BlueprintSeeds} from "./utils/BlueprintSeeds.sol";

/// @notice A stored tranche is not proof that a position was minted.
contract CoreInvariantSecondOpinionTest is Test {
    /// @dev The hook's flywheel recipient. address(0) = flywheel dormant (pre-flywheel semantics).
    address constant FLYWHEEL_RECIPIENT = address(0);

    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    IPoolManager internal manager;
    HookrLaunchpad internal pad;
    HookrHook internal hook;
    address internal creator = address(0xC0FFEE);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pad = new HookrLaunchpad(manager);
        BlueprintSeeds.seed(pad);
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad), FLYWHEEL_RECIPIENT));
        (, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad), FLYWHEEL_RECIPIENT);
        pad.setHook(hook);
        vm.deal(creator, 1 ether);
    }

    function test_configuredButUnseededBandIsSkippedDuringFeeCollection() public {
        uint256 ethIn = 0.001 ether;
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Empty band";
        a.symbol = "EMPTY";
        a.expectedCreator = creator;
        a.creatorBuyWei = ethIn;
        a.custom.baseFeePips = 3000;
        a.lpTranches = new HookrLaunchpad.LpTranche[](1);
        a.lpTranches[0] = HookrLaunchpad.LpTranche({startOffset: 600, endOffset: 6000, bps: 1});

        uint256 creationFee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launchInstant{value: creationFee + ethIn}(a, 10_000);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();
        HookrLaunchpad.Launch memory launched = pad.getLaunch(token);
        (, int24 openTick,,) = manager.getSlot0(id);
        int24 lower = _align(openTick - a.lpTranches[0].endOffset);
        int24 upper = _align(openTick - a.lpTranches[0].startOffset);
        bytes32 positionKey = keccak256(abi.encodePacked(address(pad), lower, upper, bytes32(0)));

        assertEq(openTick, V4PoolMath.getTickAtSqrtPrice(launched.sqrtPriceX96AtGraduation));
        assertEq(manager.getPositionLiquidity(id, positionKey), 0, "audit precondition: band unexpectedly seeded");

        // Pool v4 rejects a zero-delta poke of an empty position. The launchpad must detect that
        // this valid stored plan never minted liquidity and skip it, leaving the base position's
        // collection path live.
        pad.collectPoolFees(token);
    }

    function _align(int24 tick) internal pure returns (int24 aligned) {
        aligned = (tick / 60) * 60;
        if (tick < 0 && aligned != tick) aligned -= 60;
    }
}
