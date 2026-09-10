// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {HookrTokenV61} from "./HookrTokenV61.sol";
import {IHookrKernelRouterV2} from "./interfaces/IHookrKernelRouterV2.sol";
import {IHookrKernelInstanceFactoryV1} from "./interfaces/IHookrKernelInstanceFactoryV1.sol";
import {IHookrPartnerRegistryV1} from "./interfaces/IHookrPartnerRegistryV1.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";
import {
    HookrNativeMechanicsCoordinatorLibV1,
    IHookrNativeMechanicsCatalogReadV1
} from "./libraries/HookrNativeMechanicsCoordinatorLibV1.sol";
import {V4PoolMath} from "./libraries/V4PoolMath.sol";

/// @dev Linked code-only helper that keeps token creation and founding-position math outside the
///      coordinator's EIP-170 runtime. Public calls use DELEGATECALL, so CREATE2 and PoolManager
///      actions retain the coordinator as their caller.
library HookrMarketCoordinatorTokenDeployerV3 {
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Deploys a HookrTokenV61 from the coordinator context with CREATE2.
    /// @param name Token name.
    /// @param symbol Token symbol.
    /// @param tagline Token metadata tagline.
    /// @param logoURI Token metadata image URI.
    /// @param creator Creator recorded by the token.
    /// @param totalSupply Fixed token supply minted to the coordinator context.
    /// @param create2Salt Salt used for CREATE2 deployment.
    /// @return subject Deployed token address.
    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata tagline,
        string calldata logoURI,
        address creator,
        uint256 totalSupply,
        bytes32 create2Salt
    ) public returns (address subject) {
        subject = address(new HookrTokenV61{salt: create2Salt}(name, symbol, tagline, logoURI, creator, totalSupply));
    }

    /// @notice Returns the HookrTokenV61 creation-code hash for a set of constructor arguments.
    /// @param name Token name.
    /// @param symbol Token symbol.
    /// @param tagline Token metadata tagline.
    /// @param logoURI Token metadata image URI.
    /// @param creator Creator recorded by the token.
    /// @param totalSupply Fixed token supply minted at deployment.
    /// @return Creation-code hash used to predict the CREATE2 address.
    function initCodeHash(
        string calldata name,
        string calldata symbol,
        string calldata tagline,
        string calldata logoURI,
        address creator,
        uint256 totalSupply
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(HookrTokenV61).creationCode, abi.encode(name, symbol, tagline, logoURI, creator, totalSupply)
            )
        );
    }

    /// @notice Derives the bounded token-only sell band around an exact initialized tick.
    function foundingTickRange(address subject, PoolKey calldata key, uint160 sqrtPriceX96, int24 bandTicks)
        public
        pure
        returns (bool valid, int24 tickLower, int24 tickUpper)
    {
        int24 openTick = V4PoolMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (openTick % key.tickSpacing != 0 || V4PoolMath.getSqrtPriceAtTick(openTick) != sqrtPriceX96) {
            return (false, 0, 0);
        }

        // Keep the V5 width while respecting arbitrary valid v4 tick spacings.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 width = (bandTicks / key.tickSpacing) * key.tickSpacing;
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        if (Currency.unwrap(key.currency0) == subject) {
            int256 rawUpper = int256(openTick) + int256(width);
            if (rawUpper > maxTick) return (false, 0, 0);
            tickLower = openTick;
            // The bound above proves this conversion cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            tickUpper = int24(rawUpper);
        } else if (Currency.unwrap(key.currency1) == subject) {
            int256 rawLower = int256(openTick) - int256(width);
            if (rawLower < minTick) return (false, 0, 0);
            // The bound above proves this conversion cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            tickLower = int24(rawLower);
            tickUpper = openTick;
        } else {
            return (false, 0, 0);
        }
        valid = width > 0 && tickLower < tickUpper;
    }

    /// @notice Mints one bounded position and returns its exact one-sided settlement.
    function seedBand(
        IPoolManager poolManager,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) public returns (bool valid, uint256 used0, uint256 used1) {
        if ((amount0 == 0) == (amount1 == 0)) return (false, 0, 0);
        uint128 liquidity = V4PoolMath.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        if (liquidity == 0) return (false, 0, 0);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        if ((amount0 != 0 && (delta0 >= 0 || delta1 != 0)) || (amount1 != 0 && (delta1 >= 0 || delta0 != 0))) {
            return (false, 0, 0);
        }

        if (delta0 < 0) used0 = uint256(-int256(delta0));
        if (delta1 < 0) used1 = uint256(-int256(delta1));
        valid = used0 <= amount0 && used1 <= amount1;
    }

    /// @notice Collects fees from the coordinator-owned founding band.
    function collectBand(IPoolManager poolManager, PoolKey calldata key, int24 tickLower, int24 tickUpper)
        public
        returns (bool valid, uint256 amount0, uint256 amount1)
    {
        (BalanceDelta collected,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );
        int128 collected0 = collected.amount0();
        int128 collected1 = collected.amount1();
        if (collected0 < 0 || collected1 < 0) return (false, 0, 0);
        amount0 = uint256(uint128(collected0));
        amount1 = uint256(uint128(collected1));
        if (amount0 != 0) poolManager.take(key.currency0, address(this), amount0);
        if (amount1 != 0) poolManager.take(key.currency1, address(this), amount1);
        valid = true;
    }
}

/// @notice Derives the SDK-facing commitments bound by partner market vouchers.
/// @dev Keeping the nested dynamic ABI encoders in a linked library preserves coordinator runtime
///      headroom under EIP-170.
library HookrMarketCoordinatorPartnerHashLibV2 {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant POOL_KEY_DOMAIN = keccak256("HOOKR_PARTNER_POOL_KEY_V1");
    bytes32 internal constant HOOK_STACK_DOMAIN = keccak256("HOOKR_PARTNER_HOOK_STACK_V1");
    bytes32 internal constant FUNDING_DOMAIN = keccak256("HOOKR_PARTNER_MARKET_FUNDING_V1");
    bytes32 internal constant MARKET_CONTEXT_DOMAIN = keccak256("HOOKR_PARTNER_MARKET_CONTEXT_V1");
    bytes32 internal constant NEW_TOKEN_INTENT_DOMAIN = keccak256("HOOKR_PARTNER_NEW_TOKEN_MARKET_INTENT_V1");
    bytes32 internal constant EXISTING_TOKEN_INTENT_DOMAIN = keccak256("HOOKR_PARTNER_EXISTING_TOKEN_MARKET_INTENT_V1");
    bytes32 internal constant DIRECTIONAL_TAX_MODULE_KEY = keccak256("DIRECTIONAL_QUOTE_TAX");
    bytes32 internal constant DIRECTIONAL_TAX_CONFIG_SCHEMA_HASH = keccak256(
        "HookrDirectionalTaxBlockV1.Config(uint16 buyTaxBps,address buyStrategy,bytes32 buyStrategyCodeHash,uint16 sellTaxBps,address sellStrategy,bytes32 sellStrategyCodeHash)"
    );
    bytes4 private constant ROOT_KERNEL_ID_SELECTOR = bytes4(keccak256("rootKernelId()"));

    struct DirectionalTaxConfig {
        uint16 buyTaxBps;
        address buyStrategy;
        bytes32 buyStrategyCodeHash;
        uint16 sellTaxBps;
        address sellStrategy;
        bytes32 sellStrategyCodeHash;
    }

    error PartnerRevenueStackMismatch();

    /// @notice Derives the complete voucher context for a new-token market.
    /// @param args New-token creation, funding, and stack parameters.
    /// @param intentId Optional creator intent identifier.
    /// @param expectedToken Optional caller-supplied token-address assertion.
    /// @param subject Counterfactual or deployed subject token address.
    /// @param caller Account calling the coordinator.
    /// @param key Complete Uniswap v4 PoolKey.
    /// @return context Context committed by the market voucher.
    function newTokenContext(
        HookrMarketCoordinatorV3.NewTokenArgs calldata args,
        bytes32 intentId,
        address expectedToken,
        address subject,
        address caller,
        PoolKey calldata key
    ) public pure returns (IHookrPartnerRegistryV1.MarketContext memory context) {
        bytes32 poolKeyHash = _poolKeyHash(key);
        bytes32 hookStackHash = _hookStackHash(args.market);
        bytes32 fundingHash = _newFundingHash(args, caller, subject);
        context.marketKind = 1;
        context.caller = caller;
        context.creator = args.expectedCreator;
        context.subject = subject;
        context.quote = args.market.quote;
        context.kernel = address(key.hooks);
        context.poolId = PoolId.unwrap(key.toId());
        context.poolKeyHash = poolKeyHash;
        context.hookStackHash = hookStackHash;
        context.fundingHash = fundingHash;
        context.marketIntentHash = _newIntentHash(args, intentId, expectedToken, subject, caller, context);
    }

    /// @notice Derives the complete voucher context for an existing-token market.
    /// @param args Existing subject and stack parameters.
    /// @param caller Account calling the coordinator.
    /// @param creator Creator attributed to the market.
    /// @param key Complete Uniswap v4 PoolKey.
    /// @return context Context committed by the market voucher.
    function existingTokenContext(
        HookrMarketCoordinatorV3.ExistingTokenArgs calldata args,
        address caller,
        address creator,
        PoolKey calldata key
    ) public pure returns (IHookrPartnerRegistryV1.MarketContext memory context) {
        bytes32 poolKeyHash = _poolKeyHash(key);
        bytes32 hookStackHash = _hookStackHash(args.market);
        bytes32 fundingHash = _existingFundingHash(args, caller, creator);
        context.marketKind = 2;
        context.caller = caller;
        context.creator = creator;
        context.subject = args.subject;
        context.quote = args.market.quote;
        context.kernel = address(key.hooks);
        context.poolId = PoolId.unwrap(key.toId());
        context.poolKeyHash = poolKeyHash;
        context.hookStackHash = hookStackHash;
        context.fundingHash = fundingHash;
        context.marketIntentHash = _existingIntentHash(args, context);
    }

    /// @notice Returns the context commitment for a new-token market.
    /// @param args New-token creation, funding, and stack parameters.
    /// @param intentId Optional creator intent identifier.
    /// @param expectedToken Optional caller-supplied token-address assertion.
    /// @param subject Counterfactual or deployed subject token address.
    /// @param caller Account calling the coordinator.
    /// @param key Complete Uniswap v4 PoolKey.
    /// @return Commitment consumed by the partner registry.
    function newTokenContextCommitment(
        HookrMarketCoordinatorV3.NewTokenArgs calldata args,
        bytes32 intentId,
        address expectedToken,
        address subject,
        address caller,
        PoolKey calldata key
    ) public pure returns (bytes32) {
        return _contextCommitment(newTokenContext(args, intentId, expectedToken, subject, caller, key));
    }

    /// @notice Returns the context commitment for an existing-token market.
    /// @param args Existing subject and stack parameters.
    /// @param caller Account calling the coordinator.
    /// @param creator Creator attributed to the market.
    /// @param key Complete Uniswap v4 PoolKey.
    /// @return Commitment consumed by the partner registry.
    function existingTokenContextCommitment(
        HookrMarketCoordinatorV3.ExistingTokenArgs calldata args,
        address caller,
        address creator,
        PoolKey calldata key
    ) public pure returns (bytes32) {
        return _contextCommitment(existingTokenContext(args, caller, creator, key));
    }

    /// @notice Proves that every enabled partner-revenue leg matches the frozen directional-tax
    ///         configuration that will execute for the pool.
    /// @dev A zero partner-revenue leg may use a generic strategy in the corresponding direction of
    ///      the same signed directional module. The complete configuration remains committed by
    ///      `hookStackHash`. Stack admission permits only one module for a module key, so the first
    ///      matching key is final.
    /// @param stackRegistry Registry exposing the exact modules frozen for the pool.
    /// @param revenueVault Voucher-activated vault containing immutable partner-revenue terms.
    /// @param poolId Pool whose frozen stack is checked.
    /// @param expectedStackHash Stack commitment returned by the registry for this PoolId.
    /// @param moduleCount Number of frozen modules recorded for the pool.
    function validatePartnerRevenueStack(
        IHookrFrozenModuleReaderV3 stackRegistry,
        address revenueVault,
        PoolId poolId,
        bytes32 expectedStackHash,
        uint8 moduleCount
    ) public view {
        IHookrPartnerRevenueStackTermsV3 vault = IHookrPartnerRevenueStackTermsV3(revenueVault);
        // V2 full vaults expose a nonzero rootKernelId and sign the registry's concrete stack hash.
        // V1 clone vaults predate that field and retain their original input-hash commitment.
        (bool profileAware, bytes memory encodedRootKernelId) =
            revenueVault.staticcall(abi.encodeWithSelector(ROOT_KERNEL_ID_SELECTOR));
        if (profileAware) {
            if (
                encodedRootKernelId.length != 32 || abi.decode(encodedRootKernelId, (bytes32)) == bytes32(0)
                    || vault.hookStackHash() != expectedStackHash
            ) revert PartnerRevenueStackMismatch();
        }
        uint16 expectedBuyTaxBps = vault.buyTaxBps();
        uint16 expectedSellTaxBps = vault.sellTaxBps();
        if (expectedBuyTaxBps == 0 && expectedSellTaxBps == 0) return;

        for (uint256 i; i < moduleCount; ++i) {
            (HookrModuleTypesV1.ModuleSnapshot memory module_, bytes memory config) = stackRegistry.moduleAt(poolId, i);
            if (module_.moduleKey != DIRECTIONAL_TAX_MODULE_KEY) continue;
            if (module_.configSchemaHash != DIRECTIONAL_TAX_CONFIG_SCHEMA_HASH || config.length != 192) {
                revert PartnerRevenueStackMismatch();
            }

            DirectionalTaxConfig memory decoded = abi.decode(config, (DirectionalTaxConfig));
            if (
                (expectedBuyTaxBps != 0
                        && (decoded.buyTaxBps != expectedBuyTaxBps
                            || decoded.buyStrategy != vault.buyStrategy()
                            || decoded.buyStrategyCodeHash != vault.buyStrategyCodeHash()))
                    || (expectedSellTaxBps != 0
                        && (decoded.sellTaxBps != expectedSellTaxBps
                            || decoded.sellStrategy != vault.sellStrategy()
                            || decoded.sellStrategyCodeHash != vault.sellStrategyCodeHash()))
            ) revert PartnerRevenueStackMismatch();
            return;
        }

        revert PartnerRevenueStackMismatch();
    }

    function _newFundingHash(HookrMarketCoordinatorV3.NewTokenArgs calldata args, address caller, address subject)
        private
        pure
        returns (bytes32)
    {
        bytes32 seedFundingHash = keccak256(
            abi.encode(
                caller,
                args.expectedCreator,
                subject,
                args.market.quote,
                args.market.subjectAmount,
                args.market.quoteAmount
            )
        );
        bytes32 initialBuyFundingHash = keccak256(
            abi.encode(
                args.initialBuy.quoteAmountIn,
                args.initialBuy.subjectAmountOutMinimum,
                args.initialBuy.deadline,
                keccak256(args.initialBuy.moduleData)
            )
        );
        return keccak256(abi.encode(FUNDING_DOMAIN, uint8(1), seedFundingHash, initialBuyFundingHash));
    }

    function _newIntentHash(
        HookrMarketCoordinatorV3.NewTokenArgs calldata args,
        bytes32 intentId,
        address expectedToken,
        address subject,
        address caller,
        IHookrPartnerRegistryV1.MarketContext memory context
    ) private pure returns (bytes32) {
        bytes32 tokenDetailsHash = keccak256(
            abi.encode(
                keccak256(bytes(args.name)),
                keccak256(bytes(args.symbol)),
                keccak256(bytes(args.tagline)),
                keccak256(bytes(args.logoURI)),
                args.expectedCreator,
                args.totalSupply,
                args.deploymentSalt
            )
        );
        return keccak256(
            abi.encode(
                NEW_TOKEN_INTENT_DOMAIN,
                tokenDetailsHash,
                _marketCoreHash(args.market),
                keccak256(abi.encode(intentId, expectedToken, subject, caller)),
                context.poolKeyHash,
                context.hookStackHash,
                context.fundingHash
            )
        );
    }

    function _existingFundingHash(
        HookrMarketCoordinatorV3.ExistingTokenArgs calldata args,
        address caller,
        address creator
    ) private pure returns (bytes32) {
        bytes32 identitiesHash = keccak256(abi.encode(caller, creator, args.subject, args.market.quote));
        bytes32 amountsHash = keccak256(abi.encode(args.market.subjectAmount, args.market.quoteAmount));
        return keccak256(abi.encode(FUNDING_DOMAIN, uint8(2), identitiesHash, amountsHash));
    }

    function _existingIntentHash(
        HookrMarketCoordinatorV3.ExistingTokenArgs calldata args,
        IHookrPartnerRegistryV1.MarketContext memory context
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EXISTING_TOKEN_INTENT_DOMAIN,
                _marketCoreHash(args.market),
                keccak256(abi.encode(context.caller, context.creator, args.subject)),
                context.poolKeyHash,
                context.hookStackHash,
                context.fundingHash
            )
        );
    }

    function _marketCoreHash(HookrMarketCoordinatorV3.MarketParams calldata market) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                market.quote,
                market.subjectAmount,
                market.quoteAmount,
                market.lpFeeRecipient,
                market.tickSpacing,
                market.sqrtPriceX96,
                market.kernelId
            )
        );
    }

    function _poolKeyHash(PoolKey calldata key) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                POOL_KEY_DOMAIN,
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                key.fee,
                key.tickSpacing,
                address(key.hooks)
            )
        );
    }

    function _hookStackHash(HookrMarketCoordinatorV3.MarketParams calldata market) private pure returns (bytes32) {
        return keccak256(abi.encode(HOOK_STACK_DOMAIN, market.kernelId, market.modules, market.limits));
    }

    function _contextCommitment(IHookrPartnerRegistryV1.MarketContext memory context) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MARKET_CONTEXT_DOMAIN,
                context.marketKind,
                context.caller,
                context.creator,
                context.subject,
                context.quote,
                context.kernel,
                context.poolId,
                context.poolKeyHash,
                context.hookStackHash,
                context.marketIntentHash,
                context.fundingHash
            )
        );
    }
}

/// @notice Validates and executes an optional native-quote initial creator buy.
/// @dev Public library calls use DELEGATECALL, so the coordinator remains the event emitter and
///      native settlement source while this logic stays outside its EIP-170 runtime.
library HookrMarketCoordinatorInitialBuyLibV3 {
    uint256 internal constant MAX_MODULE_DATA_LENGTH = 3_904;
    uint256 private constant QUERY_GAS = 50_000;
    bytes4 private constant ROUTER_COORDINATOR_SELECTOR = bytes4(keccak256("coordinator()"));
    bytes4 private constant ROUTER_COORDINATOR_CODE_HASH_SELECTOR = bytes4(keccak256("coordinatorCodeHash()"));
    bytes4 private constant POOL_MANAGER_SELECTOR = bytes4(keccak256("poolManager()"));
    bytes4 private constant STACK_REGISTRY_SELECTOR = bytes4(keccak256("stackRegistry()"));
    bytes4 private constant INTEGRATION_VERSION_SELECTOR = bytes4(keccak256("integrationVersion()"));

    event CreatorBuyExecuted(
        PoolId indexed poolId,
        address indexed subject,
        address indexed creator,
        bytes32 intentId,
        bytes32 stackHash,
        address router,
        uint256 requestedQuoteIn,
        uint256 actualQuoteIn,
        uint256 subjectOut,
        uint256 subjectOutMinimum,
        bytes32 moduleDataHash,
        uint256 creatorAllocation,
        uint256 subjectSeedResidue,
        uint256 quoteSeedResidue
    );

    error InvalidInitialBuy();
    error InitialBuyInputMismatch(uint256 expected, uint256 actual);

    /// @notice Validates optional initial-buy parameters and immutable router wiring.
    /// @dev A zero quote amount requires all companion buy fields to be empty.
    /// @param poolManager PoolManager expected from the router.
    /// @param stackRegistry Stack registry expected from the router.
    /// @param router Router selected by the immutable stack.
    /// @param quote Quote token, which must be native currency for a nonzero buy.
    /// @param quoteAmountIn Exact native quote input, or zero to disable the buy.
    /// @param subjectAmountOutMinimum Minimum subject output for a nonzero buy.
    /// @param deadline Last block timestamp at which a nonzero buy may execute.
    /// @param moduleData Encoded data forwarded to the market's hook stack.
    function validate(
        address poolManager,
        address stackRegistry,
        address router,
        address quote,
        uint128 quoteAmountIn,
        uint128 subjectAmountOutMinimum,
        uint256 deadline,
        bytes calldata moduleData
    ) public view {
        if (quoteAmountIn == 0) {
            if (subjectAmountOutMinimum != 0 || deadline != 0 || moduleData.length != 0) {
                revert InvalidInitialBuy();
            }
            return;
        }
        // Inclusion-time expiry is the user-authorized execution bound.
        // forge-lint: disable-next-line(block-timestamp)
        bool expired = block.timestamp > deadline;
        if (
            quote != address(0) || quoteAmountIn > uint128(type(int128).max) || subjectAmountOutMinimum == 0 || expired
                || moduleData.length > MAX_MODULE_DATA_LENGTH || router == address(0) || router.code.length == 0
        ) revert InvalidInitialBuy();
        if (
            _readAddress(router, ROUTER_COORDINATOR_SELECTOR) != address(this)
                || _readAddress(router, POOL_MANAGER_SELECTOR) != poolManager
                || _readAddress(router, STACK_REGISTRY_SELECTOR) != stackRegistry
        ) revert InvalidInitialBuy();
        (bool ok, uint256 result) = _staticcallWord(router, abi.encodeWithSelector(INTEGRATION_VERSION_SELECTOR));
        if (!ok || result != 2) revert InvalidInitialBuy();
        (ok, result) = _staticcallWord(router, abi.encodeWithSelector(ROUTER_COORDINATOR_CODE_HASH_SELECTOR));
        if (!ok || bytes32(result) != address(this).codehash) revert InvalidInitialBuy();
    }

    /// @notice Executes an initial creator buy and emits its settlement values from the coordinator.
    /// @param params Pool, creator, input, slippage, and deadline parameters.
    /// @param moduleData Encoded data forwarded to the market's hook stack.
    /// @param poolId Pool receiving the buy.
    /// @param intentId Optional creator intent identifier.
    /// @param stackHash Commitment to the immutable hook stack.
    /// @param creatorAllocation Compatibility field; always zero for fixed-supply band launches.
    /// @param subjectSeedResidue Compatibility field; always zero after quantization dust is burned.
    /// @param quoteSeedResidue Compatibility field; always zero because quote is not seeded.
    /// @param router Router selected by the immutable stack.
    /// @return actualQuoteIn Native quote amount consumed by the buy.
    /// @return subjectOut Subject amount delivered to the creator.
    function executeAndEmit(
        IHookrKernelRouterV2.InitialBuyParams memory params,
        bytes calldata moduleData,
        PoolId poolId,
        bytes32 intentId,
        bytes32 stackHash,
        uint256 creatorAllocation,
        uint256 subjectSeedResidue,
        uint256 quoteSeedResidue,
        address router
    ) public returns (uint256 actualQuoteIn, uint256 subjectOut) {
        (actualQuoteIn, subjectOut) = IHookrKernelRouterV2(router).exactInputInitialBuy{value: params.quoteAmountIn}(
            params, moduleData
        );
        if (actualQuoteIn != params.quoteAmountIn) {
            revert InitialBuyInputMismatch(params.quoteAmountIn, actualQuoteIn);
        }
        emit CreatorBuyExecuted(
            poolId,
            Currency.unwrap(params.key.currency1),
            params.creator,
            intentId,
            stackHash,
            router,
            params.quoteAmountIn,
            actualQuoteIn,
            subjectOut,
            params.subjectAmountOutMinimum,
            keccak256(moduleData),
            creatorAllocation,
            subjectSeedResidue,
            quoteSeedResidue
        );
    }

    function _readAddress(address target, bytes4 selector) private view returns (address value) {
        (bool ok, uint256 result) = _staticcallWord(target, abi.encodeWithSelector(selector));
        if (!ok || result > type(uint160).max) revert InvalidInitialBuy();
        // The preceding bound proves this conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        value = address(uint160(result));
    }

    function _staticcallWord(address target, bytes memory input) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(QUERY_GAS, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }
}

/// @dev Narrow coordinator-facing view of the append-only stack registry. The registry owns the
///      kernel and module ABI; this interface deliberately exposes only the market-creation
///      lifecycle. `createStack` freezes the exact stack before initialization. The selected
///      kernel then calls `markInitialized` from its `beforeInitialize` hook.
interface IHookrStackRegistryV1CoordinatorV3 {
    /// @notice Active root-hook implementation admitted for a kernel identifier.
    struct KernelSnapshot {
        /// @notice Registered kernel identifier.
        bytes32 kernelId;
        /// @notice Kernel family supported by the implementation.
        bytes32 kernelFamilyId;
        /// @notice Registered implementation version.
        uint32 version;
        /// @notice Active root-hook implementation.
        address implementation;
        /// @notice Runtime code hash expected from the implementation.
        bytes32 implementationCodeHash;
        /// @notice Uniswap v4 hook flags encoded by the implementation address.
        uint160 hookFlags;
    }

    /// @notice Returns the PoolManager bound to the registry.
    /// @return PoolManager used by registered kernels.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the active implementation for a kernel identifier.
    /// @param kernelId Registered kernel identifier.
    /// @return snapshot Active kernel metadata.
    function activeKernel(bytes32 kernelId) external view returns (KernelSnapshot memory snapshot);

    /// @notice Returns the factory provenance for a kernel instance, or zero for a direct kernel.
    function kernelInstanceFactoryFor(bytes32 kernelId) external view returns (address factory);

    /// @notice Records an immutable stack before pool initialization.
    /// @param key Complete Uniswap v4 PoolKey.
    /// @param subject Subject token paired by the pool.
    /// @param quote Quote token, or address(0) for native currency.
    /// @param kernelId Registered kernel identifier.
    /// @param selections Ordered module selections for the stack.
    /// @param limits Immutable stack limits and integration bindings.
    /// @return poolId PoolId derived from key.
    /// @return stackHash Commitment to the recorded stack.
    function createStack(
        PoolKey calldata key,
        address subject,
        address quote,
        bytes32 kernelId,
        HookrModuleTypesV1.ModuleSelection[] calldata selections,
        HookrModuleTypesV1.StackLimits calldata limits
    ) external returns (PoolId poolId, bytes32 stackHash);

    /// @notice Returns the immutable stack recorded for a pool.
    /// @param poolId Pool to query.
    /// @return stack_ Recorded stack, or a zero-valued struct when absent.
    function stack(PoolId poolId) external view returns (HookrModuleTypesV1.StackCore memory stack_);

    function module(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot);
}

/// @dev Frozen module read used by the linked partner-revenue parity check.
interface IHookrFrozenModuleReaderV3 {
    function moduleAt(PoolId poolId, uint256 index)
        external
        view
        returns (HookrModuleTypesV1.ModuleSnapshot memory module_, bytes memory config);
}

/// @dev Immutable revenue terms exposed by a voucher-activated per-pool vault.
interface IHookrPartnerRevenueStackTermsV3 {
    function hookStackHash() external view returns (bytes32);
    function buyTaxBps() external view returns (uint16);
    function sellTaxBps() external view returns (uint16);
    function buyStrategy() external view returns (address);
    function sellStrategy() external view returns (address);
    function buyStrategyCodeHash() external view returns (bytes32);
    function sellStrategyCodeHash() external view returns (bytes32);
}

/// @dev Linked helper for the optional one-market reservation carried by kernel instances.
library HookrMarketCoordinatorKernelReservationLibV1 {
    function consume(IHookrStackRegistryV1CoordinatorV3 stackRegistry, bytes32 kernelId, address kernel, address caller)
        public
    {
        address instanceFactory = stackRegistry.kernelInstanceFactoryFor(kernelId);
        if (instanceFactory != address(0)) {
            IHookrKernelInstanceFactoryV1(instanceFactory).consumeReservation(kernel, caller);
        }
    }
}

/// @title Hookr Market Coordinator V3
/// @notice Opens a modular pool for a newly deployed token or a fresh pool for an existing token.
/// @dev Every market receives a sorted Uniswap v4 PoolKey and one immutable registered stack.
///      New-token markets preserve the generation-5 instant-launch geometry: a fixed one-billion
///      token supply is placed in one bounded, token-only sell band with no quote seed or creator
///      allocation. The coordinator owns that position and exposes no liquidity-removal function.
///      An optional native-quote creator buy runs only after the band is seeded. Existing-token
///      markets initialize with zero liquidity; LPs add and remove their own positions through v4
///      periphery.
contract HookrMarketCoordinatorV3 is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Uniswap v4 dynamic-fee flag required by every coordinated pool.
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    /// @notice Maximum module-data length accepted by an initial creator buy.
    uint256 public constant MAX_MODULE_DATA_LENGTH = 3_904;
    /// @notice Fixed supply minted by every new-token market.
    uint256 public constant SUPPLY = 1_000_000_000e18;
    /// @notice Width of the generation-5 sell band before alignment to the pool tick spacing.
    int24 public constant BAND_TICKS = 207_000;
    /// @notice Domain used to derive new-token CREATE2 salts.
    bytes32 public constant TOKEN_SALT_DOMAIN = keccak256("HOOKR_MARKET_COORDINATOR_TOKEN_CREATE2_V3");

    uint8 private constant CB_SEED_BAND = 1;
    uint8 private constant CB_COLLECT_BAND = 2;
    uint256 private constant TOKEN_QUERY_GAS = 50_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Source of a market coordinated by this contract.
    enum MarketOrigin {
        /// @notice Zero value for an absent market record.
        UNSET,
        /// @notice Market whose subject token was deployed by this coordinator.
        NEW_TOKEN,
        /// @notice Fresh market for a subject token that was already deployed.
        EXISTING_TOKEN
    }

    /// @notice Pool, seed, founding-fee, and immutable-stack parameters for a market.
    struct MarketParams {
        /// @notice Quote token, or address(0) for native currency.
        address quote;
        /// @notice Subject amount placed in the new-token founding band.
        /// @dev Must equal `SUPPLY` for a new-token market and zero for an existing-token market.
        uint128 subjectAmount;
        /// @notice Quote amount placed in a founding position.
        /// @dev Must be zero for every market. An initial creator buy is funded separately.
        uint128 quoteAmount;
        /// @notice Recipient of fees earned by the new-token founding position.
        /// @dev Must be address(0) for an existing-token market, which has no founding position.
        address lpFeeRecipient;
        /// @notice Tick spacing encoded in the PoolKey.
        int24 tickSpacing;
        /// @notice Initial square-root pool price encoded as Q64.96.
        /// @dev A new-token market binds this value in its voucher and must place it exactly on a
        ///      usable tick. This preserves per-market modular pricing while making the value the
        ///      boundary of the token-only founding band.
        uint160 sqrtPriceX96;
        /// @notice Registered root-hook identifier selected for the pool.
        bytes32 kernelId;
        /// @notice Ordered module selections frozen before pool initialization.
        HookrModuleTypesV1.ModuleSelection[] modules;
        /// @notice Immutable limits and integration bindings frozen with the stack.
        HookrModuleTypesV1.StackLimits limits;
    }

    /// @notice Optional native-quote exact-input buy executed immediately after founding liquidity.
    /// @dev A zero `quoteAmountIn` requires every companion field to be empty.
    struct InitialBuyParams {
        /// @notice Exact native quote amount supplied to the buy, or zero to disable it.
        uint128 quoteAmountIn;
        /// @notice Minimum subject amount the creator must receive.
        uint128 subjectAmountOutMinimum;
        /// @notice Last block timestamp at which the buy may execute.
        uint256 deadline;
        /// @notice Encoded data forwarded to the market's immutable hook stack.
        bytes moduleData;
    }

    /// @notice Complete arguments for a new-token market.
    struct NewTokenArgs {
        /// @notice Token name.
        string name;
        /// @notice Token symbol.
        string symbol;
        /// @notice Token metadata tagline.
        string tagline;
        /// @notice Token metadata image URI.
        string logoURI;
        /// @notice Creator recorded by the token and receiving optional initial-buy output.
        address expectedCreator;
        /// @notice Token supply minted at deployment; must equal `SUPPLY`.
        uint256 totalSupply;
        /// @notice Caller-supplied entropy included in the CREATE2 salt.
        bytes32 deploymentSalt;
        /// @notice Pool, seed, founding-fee, and immutable-stack parameters.
        MarketParams market;
        /// @notice Optional native-quote initial creator buy.
        InitialBuyParams initialBuy;
    }

    /// @notice Complete arguments for a fresh pool using an existing subject token.
    struct ExistingTokenArgs {
        /// @notice Already deployed subject token.
        address subject;
        /// @notice Pool and immutable-stack parameters, with all founding-position fields zero.
        MarketParams market;
    }

    /// @notice Coordinator record for an initialized market.
    struct Market {
        /// @notice True after the coordinator records the initialized market.
        /// @dev This flag does not indicate release activation or production availability.
        bool live;
        /// @notice Whether the subject was newly deployed or already existed.
        MarketOrigin origin;
        /// @notice Subject token paired by the pool.
        address subject;
        /// @notice Quote token, or address(0) for native currency.
        address quote;
        /// @notice Creator permanently attributed to the market.
        address creator;
        /// @notice Root hook implementation bound to the PoolKey.
        address kernel;
        /// @notice Deterministic vault accounting for directional-tax proceeds.
        address revenueVault;
        /// @notice Recipient of fees earned by the founding position, or zero when absent.
        address lpFeeRecipient;
        /// @notice Registered root-hook identifier.
        bytes32 kernelId;
        /// @notice Commitment to the immutable hook stack.
        bytes32 stackHash;
        /// @notice Uniswap v4 PoolId for the market.
        PoolId poolId;
        /// @notice Initial square-root pool price encoded as Q64.96.
        uint160 sqrtPriceX96;
        /// @notice Tick spacing encoded in the PoolKey.
        int24 tickSpacing;
        /// @notice Maximum subject amount offered to the founding position.
        uint256 subjectSupplied;
        /// @notice Maximum quote amount offered to the founding position.
        uint256 quoteSupplied;
        /// @notice Subject amount consumed by the founding position.
        uint256 subjectUsed;
        /// @notice Quote amount consumed by the founding position.
        uint256 quoteUsed;
        /// @notice Cumulative currency0 fees collected from the founding position.
        uint256 cumulativeFee0;
        /// @notice Cumulative currency1 fees collected from the founding position.
        uint256 cumulativeFee1;
        /// @notice Block number at which the market record was created.
        uint256 openedAtBlock;
        /// @notice Optional creator intent identifier used by the launch.
        bytes32 launchIntentId;
        /// @notice Router that executed the initial creator buy, or zero when no buy occurred.
        address initialBuyRouter;
        /// @notice Creator token allocation; always zero for fixed-supply band launches.
        uint256 creatorAllocation;
        /// @notice Native quote amount consumed by the initial creator buy.
        uint256 initialBuyQuoteIn;
        /// @notice Subject amount delivered by the initial creator buy.
        uint256 initialBuySubjectOut;
        /// @notice Minimum subject output required by the initial creator buy.
        uint256 initialBuySubjectOutMinimum;
        /// @notice Hash of module data supplied to the initial creator buy.
        bytes32 initialBuyModuleDataHash;
    }

    struct FundingBaselines {
        uint256 subject;
        uint256 quote;
    }

    struct OpenResult {
        PoolId poolId;
        uint256 subjectRefund;
        uint256 quoteRefund;
    }

    struct SeedResult {
        uint256 subjectUsed;
        uint256 quoteUsed;
        uint256 subjectRefund;
        uint256 quoteRefund;
    }

    /// @notice Uniswap v4 PoolManager used for initialization and founding-position accounting.
    IPoolManager public immutable poolManager;
    /// @notice Registry used to record immutable hook stacks.
    IHookrStackRegistryV1CoordinatorV3 public immutable stackRegistry;
    /// @notice Registry used to authorize and attribute market creation.
    IHookrPartnerRegistryV1 public immutable partnerRegistry;

    /// @notice Account authorized to configure market-opening availability.
    address public owner;
    /// @notice Account eligible to accept the pending ownership transfer.
    address public pendingOwner;
    /// @notice True while only the owner may open markets.
    bool public marketOpeningPaused = true;
    uint256 private reentrancyState = 1;
    uint8 private activeCallbackAction;
    PoolId private activeCallbackPoolId;

    /// @notice Returns the subject deployed for a creator and optional intent identifier.
    mapping(address creator => mapping(bytes32 intentId => address subject)) public launchedByIntent;
    /// @notice Returns the subject deployed from a derived CREATE2 salt.
    mapping(bytes32 create2Salt => address subject) public tokenByCreate2Salt;
    mapping(PoolId poolId => Market market) private _markets;
    PoolId[] private marketIds;

    event OwnerProposed(address indexed pendingOwner);
    event OwnerSet(address indexed owner);
    event MarketOpeningPauseSet(bool paused);
    /// @notice Emitted after a market is initialized and recorded.
    /// @param poolId Uniswap v4 PoolId for the market.
    /// @param subject Subject token paired by the pool.
    /// @param creator Creator permanently attributed to the market.
    /// @param quote Quote token, or address(0) for native currency.
    /// @param origin Whether the subject was newly deployed or already existed.
    /// @param kernel Root hook implementation bound to the PoolKey.
    /// @param revenueVault Vault accounting for directional-tax proceeds.
    /// @param lpFeeRecipient Founding-position fee recipient, or zero when no founding position exists.
    /// @param kernelId Registered root-hook identifier.
    /// @param stackHash Commitment to the immutable hook stack.
    /// @param sqrtPriceX96 Initial square-root pool price encoded as Q64.96.
    /// @param tickSpacing Tick spacing encoded in the PoolKey.
    /// @param subjectUsed Subject amount consumed by the founding position.
    /// @param quoteUsed Quote amount consumed by the founding position.
    event MarketCreated(
        PoolId indexed poolId,
        address indexed subject,
        address indexed creator,
        address quote,
        MarketOrigin origin,
        address kernel,
        address revenueVault,
        address lpFeeRecipient,
        bytes32 kernelId,
        bytes32 stackHash,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint256 subjectUsed,
        uint256 quoteUsed
    );
    /// @notice Emitted after an optional initial creator buy settles.
    /// @param poolId Pool that executed the buy.
    /// @param subject Subject token delivered by the buy.
    /// @param creator Creator receiving the subject output.
    /// @param intentId Optional creator intent identifier.
    /// @param stackHash Commitment to the immutable hook stack.
    /// @param router Router selected by the immutable stack.
    /// @param requestedQuoteIn Exact native quote amount requested.
    /// @param actualQuoteIn Native quote amount consumed.
    /// @param subjectOut Subject amount delivered to the creator.
    /// @param subjectOutMinimum Minimum subject output required by the creator.
    /// @param moduleDataHash Hash of module data forwarded to the hook stack.
    /// @param creatorAllocation Creator token allocation; always zero.
    /// @param subjectSeedResidue Subject seed residue; always zero after quantization dust is burned.
    /// @param quoteSeedResidue Quote seed residue; always zero because quote is not seeded.
    event CreatorBuyExecuted(
        PoolId indexed poolId,
        address indexed subject,
        address indexed creator,
        bytes32 intentId,
        bytes32 stackHash,
        address router,
        uint256 requestedQuoteIn,
        uint256 actualQuoteIn,
        uint256 subjectOut,
        uint256 subjectOutMinimum,
        bytes32 moduleDataHash,
        uint256 creatorAllocation,
        uint256 subjectSeedResidue,
        uint256 quoteSeedResidue
    );
    /// @notice Emitted after fees are collected from a new-token founding position.
    /// @param poolId Pool containing the founding position.
    /// @param recipient Account receiving both collected currencies.
    /// @param amount0 Currency0 amount collected.
    /// @param amount1 Currency1 amount collected.
    event LpFeesCollected(PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1);
    event GuardLpFeesWithheld(
        PoolId indexed poolId,
        address indexed module,
        address indexed treasury,
        uint256 amount,
        uint256 cumulativeWithheld,
        uint256 cumulativeEarned
    );

    error NotOwner();
    error NotPendingOwner();
    error MarketOpeningPaused(address caller);
    error MarketOpeningPauseUnchanged();
    error ZeroAddress();
    error InvalidWiring();
    error InvalidMarketArgs();
    error InvalidToken();
    error UnexpectedToken(address expected, address actual);
    error IntentAlreadyUsed(address creator, bytes32 intentId, address subject);
    error TokenSaltAlreadyUsed(bytes32 create2Salt, address subject);
    error InvalidPartnerVoucher();
    error InvalidPayment(uint256 expected, uint256 received);
    error InvalidInitialBuy();
    error InitialBuyInputMismatch(uint256 expected, uint256 actual);
    error InvalidStack();
    error DuplicateMarket(PoolId poolId);
    error NoFoundingPosition(PoolId poolId);
    error ZeroLiquidity();
    error ExcessiveSettlement();
    error TransferFailed();
    error TaxedTransfer();
    error NativeTransferFailed();
    error NotPoolManager();
    error BadCallback();
    error ReentrantCall();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (reentrancyState != 1) revert ReentrantCall();
        reentrancyState = 2;
        _;
        reentrancyState = 1;
    }

    modifier onlyWhenMarketOpeningAllowed() {
        if (marketOpeningPaused && msg.sender != owner) revert MarketOpeningPaused(msg.sender);
        _;
    }

    /// @notice Initializes coordinator governance and immutable registry wiring.
    /// @param owner_ Initial owner.
    /// @param poolManager_ Uniswap v4 PoolManager used by every market.
    /// @param stackRegistry_ Registry used to create immutable hook stacks.
    /// @param partnerRegistry_ Registry used to authorize and attribute market creation.
    constructor(
        address owner_,
        IPoolManager poolManager_,
        IHookrStackRegistryV1CoordinatorV3 stackRegistry_,
        IHookrPartnerRegistryV1 partnerRegistry_
    ) {
        if (
            owner_ == address(0) || address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
                || address(partnerRegistry_) == address(0) || address(partnerRegistry_).code.length == 0
        ) revert ZeroAddress();
        if (address(stackRegistry_.poolManager()) != address(poolManager_)) revert InvalidWiring();
        if (partnerRegistry_.coordinator() != address(0)) revert InvalidWiring();
        owner = owner_;
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
        partnerRegistry = partnerRegistry_;
        emit OwnerSet(owner_);
    }

    /// @notice Accepts native currency only from the PoolManager during settlement.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NativeTransferFailed();
    }

    /// @notice Returns the release identity used by deployment and integration tooling.
    function contractName() external pure virtual returns (string memory) {
        return "HookrMarketCoordinatorV3";
    }

    /// @notice Returns the coordinator interface version.
    function contractVersion() external pure virtual returns (string memory) {
        return "3.0.0";
    }

    // ---------------------------------------------------------------- ownership

    /// @notice Proposes a new owner.
    /// @param nextOwner Account that may accept ownership.
    function proposeOwner(address nextOwner) external onlyOwner {
        if (nextOwner == address(0) || nextOwner == owner) revert ZeroAddress();
        pendingOwner = nextOwner;
        emit OwnerProposed(nextOwner);
    }

    /// @notice Accepts ownership as the pending owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    /// @notice Sets whether non-owner callers may open markets.
    /// @dev The owner may open markets while paused. Any operational review or authorization is
    ///      enforced offchain.
    /// @param paused_ True to restrict market opening to the owner.
    function setMarketOpeningPaused(bool paused_) external onlyOwner {
        if (paused_ == marketOpeningPaused) revert MarketOpeningPauseUnchanged();
        marketOpeningPaused = paused_;
        emit MarketOpeningPauseSet(paused_);
    }

    // ---------------------------------------------------------------- market opening

    /// @notice Deploys a HookrTokenV61, opens its modular pool, and optionally executes a native-quote
    ///         initial creator buy.
    /// @dev The complete fixed supply is placed in one coordinator-held token-only band before the
    ///      optional buy. No quote is seeded and no token allocation is transferred to the creator.
    ///      Any sub-unit band-quantization residue is burned. The coordinator exposes no
    ///      liquidity-removal path.
    /// @param args Token, seed, stack, fee-recipient, and optional initial-buy parameters.
    /// @param partnerLaunchData `abi.encode(intentId, expectedToken, partnerAuthorization)`.
    /// @return subject Deployed HookrTokenV61 address.
    /// @return poolId Initialized Uniswap v4 PoolId.
    function openNewTokenMarket(NewTokenArgs calldata args, bytes calldata partnerLaunchData)
        external
        payable
        onlyWhenMarketOpeningAllowed
        nonReentrant
        returns (address subject, PoolId poolId)
    {
        (bytes32 intentId, address expectedToken, bytes memory partnerAuthorization) =
            abi.decode(partnerLaunchData, (bytes32, address, bytes));
        address creator = args.expectedCreator;
        if (creator == address(0)) revert ZeroAddress();
        if (
            args.totalSupply != SUPPLY || args.market.subjectAmount != SUPPLY || args.market.quoteAmount != 0
                || args.market.lpFeeRecipient == address(0) || args.market.lpFeeRecipient == address(this)
        ) {
            revert InvalidMarketArgs();
        }
        _validateInitialBuy(args.market, args.initialBuy);
        if (intentId != bytes32(0)) {
            address prior = launchedByIntent[creator][intentId];
            if (prior != address(0)) revert IntentAlreadyUsed(creator, intentId, prior);
        }
        bytes32 create2Salt = _newTokenSalt(args, intentId);
        address priorAtSalt = tokenByCreate2Salt[create2Salt];
        if (priorAtSalt != address(0)) revert TokenSaltAlreadyUsed(create2Salt, priorAtSalt);
        _validatePayment(args.market, args.initialBuy.quoteAmountIn);

        subject = HookrMarketCoordinatorTokenDeployerV3.deploy(
            args.name, args.symbol, args.tagline, args.logoURI, creator, args.totalSupply, create2Salt
        );
        if (expectedToken != address(0) && subject != expectedToken) revert UnexpectedToken(expectedToken, subject);
        _validateMarketArgs(subject, args.market, true);
        address revenueVault = _consumeNewTokenVoucher(args, intentId, expectedToken, subject, partnerAuthorization);
        if (revenueVault == args.market.lpFeeRecipient) revert InvalidPartnerVoucher();

        if (_balanceOf(subject, address(this)) != args.totalSupply) revert TaxedTransfer();

        uint256 quoteBaseline = _fundQuote(args.market);
        FundingBaselines memory baselines =
            FundingBaselines({subject: 0, quote: quoteBaseline + args.initialBuy.quoteAmountIn});
        OpenResult memory opened =
            _openMarket(MarketOrigin.NEW_TOKEN, subject, creator, revenueVault, args.market, baselines);
        poolId = opened.poolId;

        Market storage market = _markets[poolId];
        market.launchIntentId = intentId;
        if (args.initialBuy.quoteAmountIn != 0) {
            PoolKey memory key = _poolKey(subject, args.market.quote, market.kernel, args.market.tickSpacing);
            IHookrKernelRouterV2.InitialBuyParams memory buyParams = IHookrKernelRouterV2.InitialBuyParams({
                key: key,
                creator: creator,
                quoteAmountIn: args.initialBuy.quoteAmountIn,
                subjectAmountOutMinimum: args.initialBuy.subjectAmountOutMinimum,
                deadline: args.initialBuy.deadline
            });
            (uint256 actualQuoteIn, uint256 subjectOut) = HookrMarketCoordinatorInitialBuyLibV3.executeAndEmit(
                buyParams,
                args.initialBuy.moduleData,
                poolId,
                intentId,
                market.stackHash,
                0,
                opened.subjectRefund,
                opened.quoteRefund,
                args.market.limits.trustedRouter
            );
            bytes32 moduleDataHash = keccak256(args.initialBuy.moduleData);
            market.initialBuyRouter = args.market.limits.trustedRouter;
            market.initialBuyQuoteIn = actualQuoteIn;
            market.initialBuySubjectOut = subjectOut;
            market.initialBuySubjectOutMinimum = args.initialBuy.subjectAmountOutMinimum;
            market.initialBuyModuleDataHash = moduleDataHash;
        }

        if (opened.subjectRefund != 0 || opened.quoteRefund != 0) revert ExcessiveSettlement();
        _assertHeld(subject, 0, 0);
        _assertHeld(args.market.quote, quoteBaseline, 0);
        tokenByCreate2Salt[create2Salt] = subject;
        if (intentId != bytes32(0)) launchedByIntent[creator][intentId] = subject;
    }

    /// @notice Initializes a fresh modular pool for an already deployed subject token without adding
    ///         liquidity.
    /// @dev `subjectAmount`, `quoteAmount`, and `lpFeeRecipient` must be zero. This path has no initial
    ///      creator buy. Liquidity is added and removed separately through v4 periphery.
    /// @param args Existing subject and immutable pool-stack parameters.
    /// @param partnerLaunchData `abi.encode(creator, partnerAuthorization)`.
    /// @return poolId Initialized zero-liquidity Uniswap v4 PoolId.
    function openExistingTokenMarket(ExistingTokenArgs calldata args, bytes calldata partnerLaunchData)
        external
        payable
        onlyWhenMarketOpeningAllowed
        nonReentrant
        returns (PoolId poolId)
    {
        (address creator, bytes memory partnerAuthorization) = abi.decode(partnerLaunchData, (address, bytes));
        if (creator == address(0)) revert ZeroAddress();
        _validateExistingToken(args.subject);
        // Existing-token market creation is initialization only. Liquidity remains a separate
        // caller-owned periphery action subject to the frozen stack's add-liquidity policy; this
        // coordinator never escrows or locks a caller-supplied existing-token position.
        if (args.market.subjectAmount != 0 || args.market.quoteAmount != 0 || args.market.lpFeeRecipient != address(0)) revert InvalidMarketArgs();
        _validateMarketArgs(args.subject, args.market, true);
        _validatePayment(args.market, 0);
        address revenueVault = _consumeExistingTokenVoucher(args, creator, partnerAuthorization);

        OpenResult memory opened = _openMarket(
            MarketOrigin.EXISTING_TOKEN,
            args.subject,
            creator,
            revenueVault,
            args.market,
            FundingBaselines({subject: 0, quote: 0})
        );
        poolId = opened.poolId;
    }

    function _consumeNewTokenVoucher(
        NewTokenArgs calldata args,
        bytes32 intentId,
        address expectedToken,
        address subject,
        bytes memory partnerAuthorization
    ) internal returns (address revenueVault) {
        PoolKey memory key = _partnerPoolKey(subject, args.market);
        bytes32 contextCommitment = HookrMarketCoordinatorPartnerHashLibV2.newTokenContextCommitment(
            args, intentId, expectedToken, subject, msg.sender, key
        );
        revenueVault = partnerRegistry.consumeMarketVoucher(partnerAuthorization, contextCommitment);
        if (revenueVault == address(0) || revenueVault.code.length == 0) revert InvalidPartnerVoucher();
    }

    function _consumeExistingTokenVoucher(
        ExistingTokenArgs calldata args,
        address creator,
        bytes memory partnerAuthorization
    ) internal returns (address revenueVault) {
        PoolKey memory key = _partnerPoolKey(args.subject, args.market);
        bytes32 contextCommitment =
            HookrMarketCoordinatorPartnerHashLibV2.existingTokenContextCommitment(args, msg.sender, creator, key);
        revenueVault = partnerRegistry.consumeMarketVoucher(partnerAuthorization, contextCommitment);
        if (revenueVault == address(0) || revenueVault.code.length == 0) revert InvalidPartnerVoucher();
    }

    /// @notice Collects gross fees accrued to the coordinator-held founding position and routes them.
    /// @dev Anyone may call this function. It does not collect directional-tax revenue or fees owned
    ///      by external LP positions. Guard earnings may be withheld to the Hookr treasury; the
    ///      GuardLpFeesWithheld and net LpFeesCollected events expose that split. Existing-token
    ///      markets have no founding position and revert.
    /// @param poolId New-token pool containing the founding position.
    /// @return amount0 Gross currency0 amount collected before guard routing.
    /// @return amount1 Gross currency1 amount collected before guard routing.
    function collectLpFees(PoolId poolId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Market storage market = _markets[poolId];
        if (!market.live) revert InvalidMarketArgs();
        if (market.origin != MarketOrigin.NEW_TOKEN || market.lpFeeRecipient == address(0) || market.subjectUsed == 0) {
            revert NoFoundingPosition(poolId);
        }

        PoolKey memory key = _poolKey(market.subject, market.quote, market.kernel, market.tickSpacing);
        (int24 tickLower, int24 tickUpper) = _foundingTickRange(market.subject, key, market.sqrtPriceX96);
        uint256 baseline0 = _balanceOf(Currency.unwrap(key.currency0), address(this));
        uint256 baseline1 = _balanceOf(Currency.unwrap(key.currency1), address(this));
        activeCallbackAction = CB_COLLECT_BAND;
        activeCallbackPoolId = poolId;
        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(CB_COLLECT_BAND, key, tickLower, tickUpper)), (uint256, uint256));
        _clearActiveCallback();

        _assertHeld(Currency.unwrap(key.currency0), baseline0, amount0);
        _assertHeld(Currency.unwrap(key.currency1), baseline1, amount1);
        HookrNativeMechanicsCoordinatorLibV1.routeFoundingPositionFees(
            HookrNativeMechanicsCoordinatorLibV1.FeeRouteInput({
                poolId: PoolId.unwrap(poolId),
                quote: market.quote,
                currency0: Currency.unwrap(key.currency0),
                currency1: Currency.unwrap(key.currency1),
                lpFeeRecipient: market.lpFeeRecipient,
                partnerRegistry: address(partnerRegistry),
                amount0: amount0,
                amount1: amount1
            })
        );
        _assertHeld(Currency.unwrap(key.currency0), baseline0, 0);
        _assertHeld(Currency.unwrap(key.currency1), baseline1, 0);

        market.cumulativeFee0 += amount0;
        market.cumulativeFee1 += amount1;
    }

    /// @dev Shared immutable-stack and initialization pipeline. NEW_TOKEN continues into one
    ///      coordinator-held position with no removal path; EXISTING_TOKEN remains at zero liquidity.
    function _openMarket(
        MarketOrigin origin,
        address subject,
        address creator,
        address revenueVault,
        MarketParams calldata params,
        FundingBaselines memory baselines
    ) internal returns (OpenResult memory opened) {
        IHookrStackRegistryV1CoordinatorV3.KernelSnapshot memory kernel = stackRegistry.activeKernel(params.kernelId);
        if (
            kernel.kernelId != params.kernelId || kernel.implementation == address(0)
                || kernel.implementation.code.length == 0
        ) revert InvalidStack();

        PoolKey memory key = _poolKey(subject, params.quote, kernel.implementation, params.tickSpacing);
        PoolId poolId = key.toId();
        if (_markets[poolId].live) revert DuplicateMarket(poolId);
        HookrNativeMechanicsCoordinatorLibV1.validateAndRecordMarket(
            IHookrNativeMechanicsCatalogReadV1(address(stackRegistry)),
            uint8(origin),
            params.limits.baseLpFeePips,
            params.modules,
            PoolId.unwrap(poolId)
        );

        HookrMarketCoordinatorKernelReservationLibV1.consume(
            stackRegistry, params.kernelId, kernel.implementation, msg.sender
        );

        (PoolId registeredPoolId, bytes32 stackHash) =
            stackRegistry.createStack(key, subject, params.quote, params.kernelId, params.modules, params.limits);
        if (PoolId.unwrap(registeredPoolId) != PoolId.unwrap(poolId) || stackHash == bytes32(0)) {
            revert InvalidStack();
        }

        // `createStack` is the freeze boundary. Initialization may start only after the complete
        // stack exists, and the kernel must not have marked it initialized before its hook runs.
        HookrModuleTypesV1.StackCore memory frozen = stackRegistry.stack(poolId);
        if (!_matchesStack(frozen, subject, params.quote, kernel.implementation, params.kernelId, stackHash)) {
            revert InvalidStack();
        }
        if (frozen.initialized) revert InvalidStack();
        HookrMarketCoordinatorPartnerHashLibV2.validatePartnerRevenueStack(
            IHookrFrozenModuleReaderV3(address(stackRegistry)), revenueVault, poolId, stackHash, frozen.moduleCount
        );

        poolManager.initialize(key, params.sqrtPriceX96);
        HookrModuleTypesV1.StackCore memory initialized = stackRegistry.stack(poolId);
        if (
            !_matchesStack(initialized, subject, params.quote, kernel.implementation, params.kernelId, stackHash)
                || !initialized.initialized
        ) revert InvalidStack();

        SeedResult memory seed;
        if (origin == MarketOrigin.NEW_TOKEN) {
            if (
                params.subjectAmount != SUPPLY || params.quoteAmount != 0 || params.lpFeeRecipient == address(0)
                    || params.lpFeeRecipient == address(this)
            ) revert InvalidMarketArgs();
            seed = _seedLockedPosition(subject, key, poolId, params, baselines);
        } else if (
            origin != MarketOrigin.EXISTING_TOKEN || params.subjectAmount != 0 || params.quoteAmount != 0
                || params.lpFeeRecipient != address(0) || baselines.subject != 0 || baselines.quote != 0
        ) {
            revert InvalidMarketArgs();
        }

        Market storage market = _markets[poolId];
        market.live = true;
        market.origin = origin;
        market.subject = subject;
        market.quote = params.quote;
        market.creator = creator;
        market.kernel = kernel.implementation;
        market.revenueVault = revenueVault;
        market.lpFeeRecipient = params.lpFeeRecipient;
        market.kernelId = params.kernelId;
        market.stackHash = stackHash;
        market.poolId = poolId;
        market.sqrtPriceX96 = params.sqrtPriceX96;
        market.tickSpacing = params.tickSpacing;
        market.subjectSupplied = params.subjectAmount;
        market.quoteSupplied = params.quoteAmount;
        market.subjectUsed = seed.subjectUsed;
        market.quoteUsed = seed.quoteUsed;
        market.openedAtBlock = block.number;
        marketIds.push(poolId);
        emit MarketCreated(
            poolId,
            subject,
            creator,
            params.quote,
            origin,
            kernel.implementation,
            revenueVault,
            params.lpFeeRecipient,
            params.kernelId,
            stackHash,
            params.sqrtPriceX96,
            params.tickSpacing,
            seed.subjectUsed,
            seed.quoteUsed
        );
        opened = OpenResult({poolId: poolId, subjectRefund: seed.subjectRefund, quoteRefund: seed.quoteRefund});
    }

    function _seedLockedPosition(
        address subject,
        PoolKey memory key,
        PoolId poolId,
        MarketParams calldata params,
        FundingBaselines memory baselines
    ) internal returns (SeedResult memory result) {
        _assertHeld(subject, baselines.subject, params.subjectAmount);
        _assertHeld(params.quote, baselines.quote, 0);

        (int24 tickLower, int24 tickUpper) = _foundingTickRange(subject, key, params.sqrtPriceX96);
        uint256 amount0 = Currency.unwrap(key.currency0) == subject ? params.subjectAmount : 0;
        uint256 amount1 = Currency.unwrap(key.currency1) == subject ? params.subjectAmount : 0;
        activeCallbackAction = CB_SEED_BAND;
        activeCallbackPoolId = poolId;
        (uint256 used0, uint256 used1) = abi.decode(
            poolManager.unlock(
                abi.encode(CB_SEED_BAND, key, params.sqrtPriceX96, tickLower, tickUpper, amount0, amount1)
            ),
            (uint256, uint256)
        );
        _clearActiveCallback();

        result.subjectUsed = amount0 == 0 ? used1 : used0;
        result.quoteUsed = amount0 == 0 ? used0 : used1;
        if (result.subjectUsed == 0 || result.subjectUsed > params.subjectAmount || result.quoteUsed != 0) {
            revert ExcessiveSettlement();
        }

        uint256 residue = uint256(params.subjectAmount) - result.subjectUsed;
        if (residue != 0) _transferExact(subject, DEAD, residue);
        _assertHeld(subject, baselines.subject, 0);
        _assertHeld(params.quote, baselines.quote, 0);
    }

    // ---------------------------------------------------------------- PoolManager callback

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint8 action = abi.decode(data[:32], (uint8));
        PoolKey memory key;
        if (action == CB_SEED_BAND) {
            (, key,,,,,) = abi.decode(data, (uint8, PoolKey, uint160, int24, int24, uint256, uint256));
        } else if (action == CB_COLLECT_BAND) {
            (, key,,) = abi.decode(data, (uint8, PoolKey, int24, int24));
        } else {
            revert BadCallback();
        }
        if (
            action != activeCallbackAction || PoolId.unwrap(activeCallbackPoolId) == bytes32(0)
                || PoolId.unwrap(key.toId()) != PoolId.unwrap(activeCallbackPoolId)
        ) revert BadCallback();

        int24 tickLower;
        int24 tickUpper;
        if (action == CB_COLLECT_BAND) {
            (,, tickLower, tickUpper) = abi.decode(data, (uint8, PoolKey, int24, int24));
            (bool collectionValid, uint256 amount0Collected, uint256 amount1Collected) =
                HookrMarketCoordinatorTokenDeployerV3.collectBand(poolManager, key, tickLower, tickUpper);
            if (!collectionValid) revert ExcessiveSettlement();
            return abi.encode(amount0Collected, amount1Collected);
        }

        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        (,, sqrtPriceX96, tickLower, tickUpper, amount0, amount1) =
            abi.decode(data, (uint8, PoolKey, uint160, int24, int24, uint256, uint256));
        (bool seedValid, uint256 used0, uint256 used1) = HookrMarketCoordinatorTokenDeployerV3.seedBand(
            poolManager, key, sqrtPriceX96, tickLower, tickUpper, amount0, amount1
        );
        if (!seedValid) revert ZeroLiquidity();

        if (used0 != 0) _settle(key.currency0, used0);
        if (used1 != 0) _settle(key.currency1, used1);
        return abi.encode(used0, used1);
    }

    function _foundingTickRange(address subject, PoolKey memory key, uint160 sqrtPriceX96)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        bool valid;
        (valid, tickLower, tickUpper) =
            HookrMarketCoordinatorTokenDeployerV3.foundingTickRange(subject, key, sqrtPriceX96, BAND_TICKS);
        if (!valid) revert InvalidMarketArgs();
    }

    function _clearActiveCallback() internal {
        activeCallbackAction = 0;
        activeCallbackPoolId = PoolId.wrap(bytes32(0));
    }

    // ---------------------------------------------------------------- reads and validation

    /// @notice Returns the number of markets recorded by the coordinator.
    /// @return Number of initialized market records.
    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice Returns the coordinator record for a pool.
    /// @param poolId Pool to query.
    /// @return market Recorded market, or a zero-valued struct when absent.
    function getMarket(PoolId poolId) external view returns (Market memory market) {
        market = _markets[poolId];
    }

    /// @notice Returns cumulative quote-denominated guarded-LP earnings, treasury withholding, and remainder.
    function guardLpFeeAccounting(PoolId poolId)
        external
        view
        returns (
            address module,
            address treasury,
            uint256 cumulativeEarned,
            uint256 cumulativeWithheld,
            uint256 pending
        )
    {
        return HookrNativeMechanicsCoordinatorLibV1.guardAccounting(PoolId.unwrap(poolId), address(partnerRegistry));
    }

    /// @notice Deterministic HookrTokenV61 address available before pool-bound dependencies exist.
    /// @param args New-token constructor and salt inputs.
    /// @param intentId Optional creator intent identifier included in the salt.
    /// @return predicted Counterfactual token address.
    function previewNewTokenAddress(NewTokenArgs calldata args, bytes32 intentId)
        external
        view
        returns (address predicted)
    {
        predicted = _previewNewTokenAddress(args, intentId);
    }

    /// @notice Returns the CREATE2 salt derived for a new-token launch.
    /// @param args New-token constructor and salt inputs.
    /// @param intentId Optional creator intent identifier included in the salt.
    /// @return Derived CREATE2 salt.
    function computeNewTokenSalt(NewTokenArgs calldata args, bytes32 intentId) external view returns (bytes32) {
        return _newTokenSalt(args, intentId);
    }

    /// @notice Returns the PoolKey implied by a subject and market configuration.
    /// @dev This view accepts a counterfactual subject address. Mutating market paths additionally
    ///      require deployed subject code.
    /// @param subject Subject token or counterfactual new-token address.
    /// @param params Quote, price, tick-spacing, and kernel selection.
    /// @return key Sorted Uniswap v4 PoolKey.
    function poolKeyFor(address subject, MarketParams calldata params) external view returns (PoolKey memory key) {
        _validateMarketArgs(subject, params, false);
        IHookrStackRegistryV1CoordinatorV3.KernelSnapshot memory kernel = stackRegistry.activeKernel(params.kernelId);
        key = _poolKey(subject, params.quote, kernel.implementation, params.tickSpacing);
    }

    function _newTokenSalt(NewTokenArgs calldata args, bytes32 intentId) internal view returns (bytes32 create2Salt) {
        if (
            args.expectedCreator == address(0) || args.totalSupply == 0
                || (intentId == bytes32(0) && args.deploymentSalt == bytes32(0))
        ) revert InvalidMarketArgs();
        create2Salt = keccak256(
            abi.encode(
                TOKEN_SALT_DOMAIN,
                block.chainid,
                address(this),
                args.expectedCreator,
                intentId,
                args.deploymentSalt,
                keccak256(bytes(args.name)),
                keccak256(bytes(args.symbol)),
                keccak256(bytes(args.tagline)),
                keccak256(bytes(args.logoURI)),
                args.totalSupply
            )
        );
    }

    function _previewNewTokenAddress(NewTokenArgs calldata args, bytes32 intentId)
        internal
        view
        returns (address predicted)
    {
        bytes32 create2Salt = _newTokenSalt(args, intentId);
        bytes32 initCodeHash = HookrMarketCoordinatorTokenDeployerV3.initCodeHash(
            args.name, args.symbol, args.tagline, args.logoURI, args.expectedCreator, args.totalSupply
        );
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), create2Salt, initCodeHash))))
        );
    }

    function _partnerPoolKey(address subject, MarketParams calldata params) internal view returns (PoolKey memory key) {
        IHookrStackRegistryV1CoordinatorV3.KernelSnapshot memory kernel = stackRegistry.activeKernel(params.kernelId);
        if (kernel.kernelId != params.kernelId || kernel.implementation == address(0)) revert InvalidStack();
        key = _poolKey(subject, params.quote, kernel.implementation, params.tickSpacing);
    }

    function _validateExistingToken(address subject) internal view {
        if (subject == address(0) || subject.code.length == 0) revert InvalidToken();
    }

    function _validateMarketArgs(address subject, MarketParams calldata params, bool requireSubjectCode) internal view {
        if (
            subject == address(0) || (requireSubjectCode && subject.code.length == 0) || params.quote == subject
                || (params.quote != address(0) && params.quote.code.length == 0) || params.tickSpacing <= 0
                || params.tickSpacing > type(int16).max || params.sqrtPriceX96 == 0 || params.kernelId == bytes32(0)
        ) revert InvalidMarketArgs();
        int24 lower = TickMath.minUsableTick(params.tickSpacing);
        int24 upper = TickMath.maxUsableTick(params.tickSpacing);
        if (
            params.sqrtPriceX96 <= TickMath.getSqrtPriceAtTick(lower)
                || params.sqrtPriceX96 >= TickMath.getSqrtPriceAtTick(upper)
        ) revert InvalidMarketArgs();
        IHookrStackRegistryV1CoordinatorV3.KernelSnapshot memory kernel = stackRegistry.activeKernel(params.kernelId);
        if (
            kernel.kernelId != params.kernelId || kernel.implementation == address(0)
                || kernel.implementation.code.length == 0
        ) revert InvalidStack();
    }

    function _validateInitialBuy(MarketParams calldata market, InitialBuyParams calldata initialBuy) internal view {
        HookrMarketCoordinatorInitialBuyLibV3.validate(
            address(poolManager),
            address(stackRegistry),
            market.limits.trustedRouter,
            market.quote,
            initialBuy.quoteAmountIn,
            initialBuy.subjectAmountOutMinimum,
            initialBuy.deadline,
            initialBuy.moduleData
        );
    }

    function _validatePayment(MarketParams calldata params, uint256 initialBuyQuoteAmount) internal view {
        uint256 expected = params.quote == address(0) ? uint256(params.quoteAmount) + initialBuyQuoteAmount : 0;
        if (msg.value != expected) revert InvalidPayment(expected, msg.value);
    }

    function _matchesStack(
        HookrModuleTypesV1.StackCore memory stack_,
        address subject,
        address quote,
        address kernel,
        bytes32 kernelId,
        bytes32 stackHash
    ) internal pure returns (bool) {
        return stack_.configured && stack_.kernel == kernel && stack_.kernelId == kernelId && stack_.subject == subject
            && stack_.quote == quote && stack_.stackHash == stackHash;
    }

    function _poolKey(address subject, address quote, address kernel, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address currency0, address currency1) = subject < quote ? (subject, quote) : (quote, subject);
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(kernel)
        });
    }

    // ---------------------------------------------------------------- exact custody and settlement

    function _fundQuote(MarketParams calldata params) internal returns (uint256 baseline) {
        if (params.quote == address(0)) return address(this).balance - msg.value;
        if (params.quoteAmount == 0) return _balanceOf(params.quote, address(this));
        return _pullExact(params.quote, msg.sender, params.quoteAmount);
    }

    function _pullExact(address token, address from, uint256 amount) internal returns (uint256 baseline) {
        baseline = _balanceOf(token, address(this));
        uint256 fromBefore = _balanceOf(token, from);
        if (!_callExactBool(token, abi.encodeWithSelector(bytes4(0x23b872dd), from, address(this), amount))) {
            revert TransferFailed();
        }
        uint256 afterBalance = _balanceOf(token, address(this));
        uint256 fromAfter = _balanceOf(token, from);
        if (
            afterBalance < baseline || afterBalance - baseline != amount || fromAfter > fromBefore
                || fromBefore - fromAfter != amount
        ) {
            revert TaxedTransfer();
        }
    }

    function _transferExact(address token, address to, uint256 amount) internal {
        uint256 selfBefore = _balanceOf(token, address(this));
        uint256 toBefore = _balanceOf(token, to);
        if (!_callExactBool(token, abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount))) {
            revert TransferFailed();
        }
        uint256 selfAfter = _balanceOf(token, address(this));
        uint256 toAfter = _balanceOf(token, to);
        if (
            selfAfter > selfBefore || selfBefore - selfAfter != amount || toAfter < toBefore
                || toAfter - toBefore != amount
        ) {
            revert TaxedTransfer();
        }
    }

    function _balanceOf(address token, address account) internal view returns (uint256 balance) {
        if (token == address(0)) return account.balance;
        (bool ok, uint256 result) =
            _staticcallWord(token, TOKEN_QUERY_GAS, abi.encodeWithSelector(bytes4(0x70a08231), account));
        if (!ok) revert TransferFailed();
        balance = result;
    }

    function _staticcallWord(address target, uint256 gasLimit, bytes memory input)
        internal
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }

    function _callExactBool(address target, bytes memory input) internal returns (bool valid) {
        bool ok;
        uint256 returnSize;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(gas(), target, 0, add(input, 0x20), mload(input), 0, 0x20)
            returnSize := returndatasize()
            word := mload(0)
        }
        return ok && returnSize == 32 && word == 1;
    }

    function _assertHeld(address token, uint256 baseline, uint256 amount) internal view {
        if (_balanceOf(token, address(this)) != baseline + amount) revert TaxedTransfer();
    }

    function _settle(Currency currency, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        uint256 paid;
        if (token == address(0)) {
            paid = poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            _transferExact(token, address(poolManager), amount);
            paid = poolManager.settle();
        }
        if (paid != amount) revert TaxedTransfer();
    }

    function _refund(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            _transferExact(token, to, amount);
        }
    }
}
