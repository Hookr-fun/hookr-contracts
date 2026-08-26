// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrHookRegistry} from "../src/HookrHookRegistry.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {IHookrLaunchHook} from "../src/interfaces/IHookrLaunchHook.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Small second hook family used to prove the generic launch boundary. It owns one
///         opaque setting: the pool's dynamic LP fee. It uses only beforeInitialize, which proves
///         that configuration happened before PoolManager initialization.
contract AlternateLaunchHook is IHooks, IHookrLaunchHook {
    using PoolIdLibrary for PoolKey;

    uint160 public constant override REQUIRED_FLAGS = uint160(1 << 13);
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;

    IPoolManager public immutable override poolManager;
    address public immutable override launchpad;

    mapping(PoolId id => uint24 feePips) public feeOf;

    error NotLaunchpad();
    error NotPoolManager();
    error BadConfig();
    error UnusedCallback();

    constructor(IPoolManager poolManager_, address launchpad_) {
        poolManager = poolManager_;
        launchpad = launchpad_;
    }

    function configurePool(PoolKey calldata key, bytes calldata config) external override {
        if (msg.sender != launchpad) revert NotLaunchpad();
        if (key.fee != DYNAMIC_FEE_FLAG || key.tickSpacing != 60 || feeOf[key.toId()] != 0) revert BadConfig();
        uint24 feePips = abi.decode(config, (uint24));
        if (feePips == 0 || feePips > 1_000_000) revert BadConfig();
        feeOf[key.toId()] = feePips;
    }

    function validateHookConfig(bytes calldata config) external pure override {
        uint24 feePips = abi.decode(config, (uint24));
        if (feePips == 0 || feePips > 1_000_000) revert BadConfig();
    }

    function syncBaseFee(PoolKey calldata key) external override {
        if (msg.sender != launchpad) revert NotLaunchpad();
        uint24 feePips = feeOf[key.toId()];
        if (feePips == 0) revert BadConfig();
        poolManager.updateDynamicLPFee(key, feePips);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (sender != launchpad || feeOf[key.toId()] == 0) revert BadConfig();
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert UnusedCallback();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnusedCallback();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnusedCallback();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnusedCallback();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnusedCallback();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert UnusedCallback();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert UnusedCallback();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert UnusedCallback();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert UnusedCallback();
    }
}

    contract GenericHookSelectionTest is Test {
        using PoolIdLibrary for PoolKey;
        using StateLibrary for IPoolManager;

        uint160 internal constant DEFAULT_HOOK_FLAGS =
            uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
        uint160 internal constant ALTERNATE_HOOK_FLAGS = uint160(1 << 13);
        uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;

        IPoolManager internal manager;
        HookrLaunchpad internal pad;
        HookrHook internal defaultHook;
        AlternateLaunchHook internal alternateHook;
        HookrSwapRouter internal alternateRouter;
        HookrHookRegistry internal registry;
        uint32 internal alternateHookId;

        address internal creator = address(0xC0FFEE);
        address internal trader = address(0xB0B);

        function setUp() public {
            manager = IPoolManager(address(new PoolManager(address(this))));
            pad = new HookrLaunchpad(manager, new HookrBlueprints(address(this)));
            registry = pad.hookRegistry();

            bytes memory defaultCreation =
                abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad)));
            (address predictedDefault, bytes32 defaultSalt) =
                HookMiner.find(address(this), DEFAULT_HOOK_FLAGS, defaultCreation);
            defaultHook = new HookrHook{salt: defaultSalt}(manager, address(pad));
            assertEq(address(defaultHook), predictedDefault);
            pad.setHook(defaultHook);

            bytes memory alternateCreation =
                abi.encodePacked(type(AlternateLaunchHook).creationCode, abi.encode(manager, address(pad)));
            (address predictedAlternate, bytes32 alternateSalt) =
                HookMiner.find(address(this), ALTERNATE_HOOK_FLAGS, alternateCreation);
            alternateHook = new AlternateLaunchHook{salt: alternateSalt}(manager, address(pad));
            assertEq(address(alternateHook), predictedAlternate);
            alternateRouter = new HookrSwapRouter(manager, IHooks(address(alternateHook)));
            alternateHookId = registry.registerHook(IHookrLaunchHook(address(alternateHook)), address(alternateRouter));

            vm.deal(creator, 10 ether);
            vm.deal(trader, 1 ether);
        }

        function test_stagedHookLaunchesTokenThroughAlternateHookAndProductionRouter() public {
            bytes32 intentId = keccak256("alternate-instant-launch");
            bytes memory config = abi.encode(uint24(5_000));

            vm.prank(creator);
            registry.stageHook(alternateHookId, config, intentId);

            HookrLaunchpad.LaunchArgs memory args = _instantArgs(false);
            uint256 payment = pad.creationFeeWei() + args.creatorBuyWei;
            vm.prank(creator);
            address token = pad.launchInstant{value: payment}(args, 5_000, intentId);

            PoolKey memory key = _key(token, IHooks(address(alternateHook)));
            PoolId id = key.toId();
            (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
            assertGt(sqrtPriceX96, 0, "real PoolManager pool was not initialized");
            assertEq(alternateHook.feeOf(id), 5_000, "opaque config did not reach selected hook");
            assertEq(registry.hookIdOf(token), alternateHookId);
            assertEq(registry.hookConfigHashOf(token), keccak256(config));

            HookrSwapRouter.ExactInputParams memory swap = HookrSwapRouter.ExactInputParams({
                key: key,
                zeroForOne: true,
                amountIn: 0.01 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: MIN_SQRT_PRICE_LIMIT,
                recipient: trader,
                deadline: block.timestamp + 1
            });
            vm.prank(trader);
            uint256 amountOut = alternateRouter.exactInput{value: 0.01 ether}(swap);
            assertGt(amountOut, 0);
            assertEq(HookrToken(token).balanceOf(trader), amountOut);
        }

        function test_existingLaunchCallStillUsesDefaultHookWithoutStagedSelection() public {
            HookrLaunchpad.LaunchArgs memory args = _instantArgs(true);
            uint256 payment = pad.creationFeeWei() + args.creatorBuyWei;
            vm.prank(creator);
            address token = pad.launchInstant{value: payment}(args, 5_000, bytes32(0));

            PoolKey memory key = _key(token, IHooks(address(defaultHook)));
            (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
            assertGt(sqrtPriceX96, 0);
            assertEq(registry.hookIdOf(token), 0);
        }

        function test_stagedHookSurvivesCurvePhaseAndOpensAlternatePoolAtGraduation() public {
            bytes32 intentId = keccak256("alternate-curve-launch");
            bytes memory config = abi.encode(uint24(7_000));
            vm.prank(creator);
            registry.stageHook(alternateHookId, config, intentId);

            HookrLaunchpad.LaunchArgs memory args;
            args.name = "Selectable Curve";
            args.symbol = "SCURVE";
            args.expectedCreator = creator;
            args.targetRaiseWei = pad.MIN_TARGET();
            args.creatorBuyWei = 0.02 ether;

            uint256 payment = pad.creationFeeWei() + args.creatorBuyWei;
            vm.prank(creator);
            address token = pad.launch{value: payment}(args, intentId);

            PoolKey memory key = _key(token, IHooks(address(alternateHook)));
            PoolId id = key.toId();
            HookrLaunchpad.Launch memory launched = pad.getLaunch(token);
            (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
            assertTrue(launched.graduated, "curve did not graduate");
            assertEq(PoolId.unwrap(launched.poolId), PoolId.unwrap(id), "launch recorded the wrong hook pool");
            assertGt(sqrtPriceX96, 0, "alternate pool was not initialized");
            assertEq(alternateHook.feeOf(id), 7_000, "staged config did not survive the curve phase");
        }

        function test_stagedSelectionRefusesWrongIntentAndSurvivesRevert() public {
            bytes32 intentId = keccak256("expected-intent");
            bytes memory config = abi.encode(uint24(5_000));
            vm.prank(creator);
            registry.stageHook(alternateHookId, config, intentId);

            HookrLaunchpad.LaunchArgs memory args = _instantArgs(false);
            uint256 payment = pad.creationFeeWei() + args.creatorBuyWei;
            vm.prank(creator);
            vm.expectRevert(HookrHookRegistry.InvalidSelection.selector);
            pad.launchInstant{value: payment}(args, 5_000, keccak256("wrong-intent"));

            (uint32 stagedId, bytes32 stagedIntent, bytes32 configHash) = registry.stagedHook(creator);
            assertEq(stagedId, alternateHookId);
            assertEq(stagedIntent, intentId);
            assertEq(configHash, keccak256(config));
        }

        function test_registeredHookRefusesBuiltInHookParams() public {
            bytes32 intentId = keccak256("ambiguous-config");
            vm.prank(creator);
            registry.stageHook(alternateHookId, abi.encode(uint24(5_000)), intentId);

            HookrLaunchpad.LaunchArgs memory args = _instantArgs(true);
            uint256 payment = pad.creationFeeWei() + args.creatorBuyWei;
            vm.prank(creator);
            vm.expectRevert(HookrLaunchpadLib.BadHookSelection.selector);
            pad.launchInstant{value: payment}(args, 5_000, intentId);
        }

        function test_invalidOpaqueConfigCannotCreateCurveThatBricksAtGraduation() public {
            bytes32 intentId = keccak256("invalid-curve-config");
            vm.prank(creator);
            registry.stageHook(alternateHookId, abi.encode(uint24(0)), intentId);

            HookrLaunchpad.LaunchArgs memory args;
            args.name = "Invalid Curve";
            args.symbol = "BAD";
            args.expectedCreator = creator;
            args.targetRaiseWei = pad.MIN_TARGET();
            uint256 payment = pad.creationFeeWei();

            vm.prank(creator);
            vm.expectRevert(AlternateLaunchHook.BadConfig.selector);
            pad.launch{value: payment}(args, intentId);

            (uint32 stagedId, bytes32 stagedIntent,) = registry.stagedHook(creator);
            assertEq(stagedId, alternateHookId);
            assertEq(stagedIntent, intentId);
            assertEq(pad.tokensCount(), 0);
        }

        function _instantArgs(bool withDefaultConfig) internal view returns (HookrLaunchpad.LaunchArgs memory args) {
            args.name = "Selectable Token";
            args.symbol = "SELECT";
            args.expectedCreator = creator;
            args.creatorBuyWei = 1 ether;
            if (withDefaultConfig) {
                args.custom.baseFeePips = 3_000;
                args.custom.maxFeePips = 3_000;
            }
        }

        function _key(address token, IHooks selectedHook) internal pure returns (PoolKey memory) {
            return PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: selectedHook
            });
        }
    }
