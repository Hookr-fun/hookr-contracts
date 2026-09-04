// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {V4PoolMath} from "./V4PoolMath.sol";
import {HookrToken} from "../HookrToken.sol";
import {HookrHook} from "../HookrHook.sol";
import {HookParams, FeeRecipient} from "./HookrLaunchTypes.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction,
    IContinuousClearingAuctionFactory
} from "../interfaces/IContinuousClearingAuction.sol";

/// @title HookrLaunchpadLibV5
/// @notice The DELEGATECALL-linked library for `HookrLaunchpadV5` — the generation-5 launchpad with
///         two native-ETH lanes: a zero-seed single-sided instant launch and a Continuous Clearing
///         Auction bonded launch. It exists for EIP-170 exactly as v4's `HookrLaunchpadLib` did:
///         the token factory, the pool/band geometry, and the two new lane helpers are linked out
///         so the launchpad carries only call stubs.
///
///         DELIBERATELY SEPARATE FROM v4's `HookrLaunchpadLib`. That library is deployed and its
///         runtime hash is pinned by the retained generation-4 manifest; adding to it would change
///         its bytecode. v5 gets its own linked library. The pool-geometry bodies below are the
///         verbatim pure code motion v4 used (storage reads lifted into parameters); the curve
///         walk is gone, and three lane helpers are new: `zeroSeedPlan`, `migrationPriceWei`,
///         `auctionStepsUniform`.
///
///         Runs by DELEGATECALL in the launchpad's context: `deployToken` CREATEs as the launchpad,
///         and every pool interaction is minted to and settled by the launchpad. Nothing here reads
///         or writes launchpad storage.
library HookrLaunchpadLibV5 {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    /// @dev Uniform CCA issuance schedules must release exactly 1e7 millionths over the window.
    uint256 internal constant AUCTION_MPS_TOTAL = 1e7;

    /// @notice Rejection reasons for `zeroSeedPlan`, in the order the launchpad checks them.
    uint8 internal constant PLAN_OK = 0;
    uint8 internal constant PLAN_BAD_FDV = 1;
    uint8 internal constant PLAN_BAD_PRICE = 2;
    uint8 internal constant PLAN_BAD_BAND = 3;

    /// @dev The launchpad's unlock actions — the complete set for v5. `CB_GRADUATE` seeds the one
    ///      full-range position a bonded launch migrates into; `CB_BAND` mints the instant lane's
    ///      single token-only sell band (and any optional graduation tranche); `CB_COLLECT` pokes
    ///      fees with a zero liquidity delta. None can carry a negative liquidity delta, which is
    ///      what keeps launchpad liquidity locked by construction rather than by policy.
    uint8 internal constant CB_GRADUATE = 1;
    uint8 internal constant CB_COLLECT = 2;
    uint8 internal constant CB_BAND = 3;

    // ------------------------------------------------------------------ pool opening

    /// @notice Configure the hook, create the pool, and seed the one full-range position it holds.
    /// @dev Verbatim from v4's `openPool`. Runs by DELEGATECALL, so `address(this)` is the launchpad:
    ///      the hook's launchpad gate, `beforeInitialize`'s sender check, and the `unlockCallback`
    ///      owner are all still the launchpad.
    function openPool(
        IPoolManager pm,
        HookrHook hookContract,
        PoolKey memory key,
        HookrHook.PoolConfig memory cfg,
        uint160 sqrtPriceX96,
        uint256 ethForPool,
        uint256 tokensForPool
    ) public returns (uint256 ethUsed, uint256 tokensUsed) {
        hookContract.configurePool(key, cfg);
        pm.initialize(key, sqrtPriceX96);
        hookContract.syncBaseFee(key);
        bytes memory result = pm.unlock(abi.encode(CB_GRADUATE, key, sqrtPriceX96, ethForPool, tokensForPool));
        return abi.decode(result, (uint256, uint256));
    }

    /// @notice The whole instant-lane open: configure the hook, initialize the pool at the band's
    ///         upper edge, seed the single token-only sell band with `supply`, and burn the residue.
    /// @dev Bundled to cut launchpad size. Runs by DELEGATECALL, so the pool is initialized by the
    ///      launchpad, the band position is the launchpad's, and the burn is from its own balance.
    /// @return used   tokens the band actually consumed.
    /// @return burned tokens the band could not represent, sent to `0xdEaD`.
    function openInstantBand(
        IPoolManager pm,
        HookrHook hookContract,
        PoolKey memory key,
        HookrHook.PoolConfig memory cfg,
        uint160 sqrtPriceX96,
        int24 bandLower,
        int24 bandUpper,
        uint256 supply
    ) public returns (uint256 used, uint256 burned) {
        hookContract.configurePool(key, cfg);
        pm.initialize(key, sqrtPriceX96);
        hookContract.syncBaseFee(key);
        used = seedBand(pm, key, bandLower, bandUpper, supply);
        burned = supply - used;
        if (burned > 0) {
            HookrToken(Currency.unwrap(key.currency1)).transfer(0x000000000000000000000000000000000000dEaD, burned);
        }
    }

    /// @notice Mint one token-only band over `[lower, upper]` and settle what it consumed.
    /// @dev The inside of the launchpad's `CB_BAND` callback, linked out for EIP-170. A band whose
    ///      liquidity refuses to price mints nothing and reports zero on both sides. `owedEth` is
    ///      RETURNED rather than reverted on so the launchpad raises its own `BadLpPlan`.
    function mintBand(IPoolManager pm, PoolKey memory key, int24 lower, int24 upper, uint256 amount)
        public
        returns (uint256 owedToken, uint256 owedEth)
    {
        uint128 liquidity = bandLiquidity(lower, upper, amount);
        if (liquidity == 0) return (0, 0);

        (BalanceDelta delta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        if (delta.amount0() < 0) return (0, uint256(uint128(-delta.amount0())));
        owedToken = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
        if (owedToken > 0) {
            pm.sync(key.currency1);
            HookrToken(Currency.unwrap(key.currency1)).transfer(address(pm), owedToken);
            pm.settle();
        }
    }

    /// @notice Mint one token-only band, returning the tokens it consumed. Wraps the unlock.
    function seedBand(IPoolManager pm, PoolKey memory key, int24 lower, int24 upper, uint256 amount)
        public
        returns (uint256 used)
    {
        return abi.decode(pm.unlock(abi.encode(CB_BAND, key, lower, upper, amount)), (uint256));
    }

    /// @notice Poke one position's accrued fees out of the pool with a zero liquidity delta.
    function collectRange(IPoolManager pm, PoolKey memory key, uint256 lowerSlot, uint256 upperSlot)
        public
        returns (uint256 ethAmount, uint256 tokenAmount)
    {
        bytes memory out = pm.unlock(abi.encode(CB_COLLECT, key, uint160(0), lowerSlot, upperSlot));
        return abi.decode(out, (uint256, uint256));
    }

    /// @notice The full-range mint-and-settle of the `CB_GRADUATE` unlock, linked out for EIP-170.
    /// @dev Runs by DELEGATECALL inside the launchpad's unlock callback, so the position belongs to
    ///      the launchpad and the settled ETH/tokens are its own.
    function graduateUnlock(
        IPoolManager pm,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint256 ethAmt,
        uint256 tokenAmt
    ) public returns (uint256 oweEth, uint256 oweTokens) {
        uint128 liquidity = liquidityForAmountsInRange(tickLower, tickUpper, sqrtPriceX96, ethAmt, tokenAmt);
        (BalanceDelta callerDelta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        oweEth = callerDelta.amount0() < 0 ? uint256(uint128(-callerDelta.amount0())) : 0;
        oweTokens = callerDelta.amount1() < 0 ? uint256(uint128(-callerDelta.amount1())) : 0;
        if (oweEth > 0) {
            // The quote side: native ETH settles by value; a HOOKR quote settles like any ERC20.
            // DELEGATECALL context, so the transfer spends the launchpad's own swept raise.
            if (Currency.unwrap(key.currency0) == address(0)) {
                pm.settle{value: oweEth}();
            } else {
                pm.sync(key.currency0);
                HookrToken(Currency.unwrap(key.currency0)).transfer(address(pm), oweEth);
                pm.settle();
            }
        }
        if (oweTokens > 0) {
            pm.sync(key.currency1);
            HookrToken(Currency.unwrap(key.currency1)).transfer(address(pm), oweTokens);
            pm.settle();
        }
    }

    /// @notice The zero-delta fee poke of the `CB_COLLECT` unlock, linked out for EIP-170. The token
    ///         side is taken straight to the burn address.
    function collectUnlock(IPoolManager pm, PoolKey memory key, int24 tickLower, int24 tickUpper)
        public
        returns (uint256 ethOwed, uint256 tokensOwed)
    {
        (BalanceDelta callerDelta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );
        ethOwed = callerDelta.amount0() > 0 ? uint256(uint128(callerDelta.amount0())) : 0;
        tokensOwed = callerDelta.amount1() > 0 ? uint256(uint128(callerDelta.amount1())) : 0;
        if (ethOwed > 0) pm.take(key.currency0, address(this), ethOwed);
        if (tokensOwed > 0) pm.take(key.currency1, 0x000000000000000000000000000000000000dEaD, tokensOwed);
    }

    /// @notice The launchpad's entire unlock dispatch, linked out for EIP-170. Codes are the
    ///         launchpad's CB_* constants; a `true` in the first return slot flags a band whose
    ///         mint owed quote (the launchpad raises its own `BadLpPlan`), and an unknown action
    ///         returns `(false, empty)` for the launchpad's own `BadCallback`.
    function unlockDispatch(IPoolManager pm, bytes calldata data, uint8 cbBand, uint8 cbGraduate, uint8 cbCollect)
        public
        returns (bool ok, bytes memory result)
    {
        uint8 action = abi.decode(data[:32], (uint8));
        if (action == cbBand) {
            (, PoolKey memory bKey, int24 bLower, int24 bUpper, uint256 bAmount) =
                abi.decode(data, (uint8, PoolKey, int24, int24, uint256));
            (uint256 oweT, uint256 oweE) = mintBand(pm, bKey, bLower, bUpper, bAmount);
            if (oweE > 0) return (false, abi.encode(uint256(1)));
            return (true, abi.encode(oweT));
        }

        (, PoolKey memory key, uint160 sqrtPriceX96, uint256 ethAmt, uint256 tokenAmt) =
            abi.decode(data, (uint8, PoolKey, uint160, uint256, uint256));
        (int24 tickLower, int24 tickUpper) = usableTickRange(key.tickSpacing);
        if (action == cbCollect && (ethAmt != 0 || tokenAmt != 0)) {
            tickLower = int24(uint24(ethAmt));
            tickUpper = int24(uint24(tokenAmt));
        }
        if (action == cbGraduate) {
            (uint256 oweEth, uint256 oweTokens) =
                graduateUnlock(pm, key, tickLower, tickUpper, sqrtPriceX96, ethAmt, tokenAmt);
            return (true, abi.encode(oweEth, oweTokens));
        }
        if (action == cbCollect) {
            (uint256 ethOwed, uint256 tokensOwed) = collectUnlock(pm, key, tickLower, tickUpper);
            return (true, abi.encode(ethOwed, tokensOwed));
        }
        return (false, bytes(""));
    }

    /// @notice Burn a launch's held tokens down to its reserved amount; return what was held.
    function burnDownToReserve(address token, uint256 reservedTokens) public {
        uint256 held = HookrToken(token).balanceOf(address(this));
        if (held > reservedTokens) {
            HookrToken(token).transfer(0x000000000000000000000000000000000000dEaD, held - reservedTokens);
        }
    }

    /// @notice Create the CCA through the factory, fund it with the auction supply, and arm it.
    /// @dev DELEGATECALL: the factory sees the launchpad as creator, and the transfer spends the
    ///      launchpad's freshly minted supply. The salt folds in the token so launches never collide.
    function createAndArmAuction(
        IContinuousClearingAuctionFactory factory,
        address token,
        uint256 auctionSupply,
        bytes memory configData
    ) public returns (address auction) {
        auction = factory.create(token, auctionSupply, configData, keccak256(abi.encode(token)));
        HookrToken(token).transfer(auction, auctionSupply);
        IContinuousClearingAuction(auction).onTokensReceived();
    }

    /// @notice Sweep a graduated auction's raise and unsold tokens back to the launchpad.
    /// @dev Runs by DELEGATECALL, so `msg.sender` to the auction is the launchpad — which is both
    ///      the auction's `fundsRecipient` and `tokensRecipient`, the only address either sweep
    ///      accepts. The caller measures the ETH balance delta around this to learn the net raise.
    function sweepGraduated(address auction) public {
        IContinuousClearingAuction(auction).sweepCurrency();
        IContinuousClearingAuction(auction).sweepUnsoldTokens();
    }

    /// @notice A failed auction: pull the unsold supply back and burn everything the launchpad holds.
    /// @return burned the total token supply burned to `0xdEaD`.
    function burnFailedAuction(address auction, address token) public returns (uint256 burned) {
        IContinuousClearingAuction(auction).sweepUnsoldTokens();
        burned = HookrToken(token).balanceOf(address(this));
        if (burned > 0) HookrToken(token).transfer(0x000000000000000000000000000000000000dEaD, burned);
    }

    // ------------------------------------------------------------------ token factory

    /// @notice Deploys the launch's ERC-20. CREATEd by the launchpad (DELEGATECALL), so the token
    ///         address, `HookrToken.launchpad`, and initial supply holder are all the launchpad.
    function deployToken(
        string calldata name,
        string calldata symbol,
        string calldata tagline,
        string calldata logoURI,
        address creator,
        uint256 supply
    ) public returns (address) {
        return address(new HookrToken(name, symbol, tagline, logoURI, creator, supply));
    }

    /// @notice Deploys the launch's ERC-20 at a CREATE2 address STRICTLY ABOVE `quoteToken`, so the
    ///         quote is always the pool's currency0 and every currency0-quote assumption holds.
    /// @dev DELEGATECALL context: the CREATE2 deployer is the launchpad. ~90% of addresses beat the
    ///      live HOOKR address, so the mining loop expects ~1.1 iterations; the 256-iteration cap is
    ///      a formality that turns an astronomically unlikely streak into a clean revert.
    function deployTokenAbove(
        string calldata name,
        string calldata symbol,
        string calldata tagline,
        string calldata logoURI,
        address creator,
        uint256 supply,
        address quoteToken
    ) public returns (address token) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(HookrToken).creationCode, abi.encode(name, symbol, tagline, logoURI, creator, supply))
        );
        bytes32 salt;
        for (uint256 i;; ++i) {
            if (i == 256) revert TokenMiningFailed();
            salt = keccak256(abi.encode(address(this), quoteToken, name, symbol, i));
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
            if (predicted > quoteToken && predicted.code.length == 0) break;
        }
        token = address(new HookrToken{salt: salt}(name, symbol, tagline, logoURI, creator, supply));
    }

    error TokenMiningFailed();

    // ------------------------------------------------------------------ lane math (new)

    /// @notice The entire opening plan of a zero-seed instant launch, and every reason to refuse it.
    ///
    /// @dev The creator names an opening fully-diluted valuation; the ENTIRE supply is placed as one
    ///      token-only band whose upper edge is the opening tick, and the pool is initialized there.
    ///      No quote is seeded — the position holds only the token, and buyers deposit all the ETH by
    ///      walking the price down through the band. That is safe precisely because it is a BOUNDED
    ///      range at an interior tick, not the full range: a full-range token-only position can only
    ///      open at a terminal tick, which one dust buy drains (see HookrPairBoundaryAttack).
    ///
    ///      Price is DERIVED from the FDV, never supplied as a tick: `openPriceWei = openFdvWei / 1e9`
    ///      (wei per whole token), which the launchpad clamps to [`minFdvWei`, `maxFdvWei`]. Rounding
    ///      on the wei-per-token figure biases the band a hair one way; the residual token dust below
    ///      the band's own quantization is burned by the launchpad, never stranded.
    ///
    /// @param openFdvWei  Target opening valuation in wei (== the whole-supply value at the open tick).
    /// @param supply      The fixed token supply (whole-token count is `supply / 1e18`).
    /// @param bandTicks   Width of the sell band below the open tick; the max price multiple the band
    ///                    can express before it is exhausted.
    /// @param tickSpacing Pool tick spacing.
    /// @return openPriceWei Wei per whole token at open.
    /// @return sqrtPriceX96 The open price as a v4 sqrt price. Zero when unrepresentable.
    /// @return bandLower    Aligned lower tick of the sell band.
    /// @return bandUpper    Aligned upper tick (== the open tick), where the pool initializes.
    /// @return err          `PLAN_OK`, or which bound the inputs broke.
    function zeroSeedPlan(
        uint256 openFdvWei,
        uint256 supply,
        int24 bandTicks,
        int24 tickSpacing,
        uint256 minFdvWei,
        uint256 maxFdvWei
    ) public pure returns (uint96 openPriceWei, uint160 sqrtPriceX96, int24 bandLower, int24 bandUpper, uint8 err) {
        if (openFdvWei < minFdvWei || openFdvWei > maxFdvWei) return (0, 0, 0, 0, PLAN_BAD_FDV);

        uint256 wholeSupply = supply / 1e18;
        uint256 p = openFdvWei / wholeSupply; // wei per whole token
        if (p == 0 || p > type(uint96).max) return (0, 0, 0, 0, PLAN_BAD_PRICE);
        openPriceWei = uint96(p);

        uint256 root = _sqrt((uint256(1e18) << 192) / p);
        if (root > type(uint160).max) return (openPriceWei, 0, 0, 0, PLAN_BAD_PRICE);
        sqrtPriceX96 = uint160(root);

        // The open tick is the band's upper edge; the pool opens exactly there so the band holds
        // token-only and the first buy activates it. Align the open tick DOWN and the lower tick a
        // full `bandTicks` below it, then bound both inside the usable range.
        int24 openTick = _alignTick(V4PoolMath.getTickAtSqrtPrice(sqrtPriceX96), tickSpacing);
        (int24 minTick, int24 maxTick) = V4PoolMath.usableTickRange(tickSpacing);
        int256 rawLower = int256(openTick) - int256(bandTicks);
        if (openTick > maxTick || openTick <= minTick) return (openPriceWei, sqrtPriceX96, 0, 0, PLAN_BAD_BAND);
        if (rawLower < minTick) return (openPriceWei, sqrtPriceX96, 0, 0, PLAN_BAD_BAND);
        bandUpper = openTick;
        bandLower = _alignTick(int24(rawLower), tickSpacing);
        if (bandUpper <= bandLower) return (openPriceWei, sqrtPriceX96, 0, 0, PLAN_BAD_BAND);
        // Re-derive the sqrt price from the ALIGNED open tick so the pool initializes exactly at the
        // band's upper edge — otherwise a sub-spacing open tick would leave the band active at open.
        sqrtPriceX96 = V4PoolMath.getSqrtPriceAtTick(bandUpper);
    }

    /// @notice The open price and sqrt price a bonded pool migrates at, from the CCA clearing price.
    /// @dev Bundles `migrationPriceWei` + `sqrtPriceX96ForPrice` + the uint160 bound so the launchpad
    ///      does not carry the arithmetic. Returns `sqrtPriceX96 == 0` when the clearing price is
    ///      unrepresentable, which the launchpad turns into its own `OpenPriceOutOfRange`.
    function migrationSqrt(uint256 initialPriceX96) public pure returns (uint256 openPriceWei, uint160 sqrtPriceX96) {
        openPriceWei = V4PoolMath.mulDiv(initialPriceX96, 1e18, V4PoolMath.Q96);
        if (openPriceWei == 0) return (0, 0);
        uint256 root = _sqrt((uint256(1e18) << 192) / openPriceWei);
        if (root == 0 || root > type(uint160).max) return (openPriceWei, 0);
        sqrtPriceX96 = uint160(root);
    }

    /// @notice Wei per whole token implied by a CCA clearing price (Q96 currency-per-token-wei).
    /// @dev The auction reports `initialPriceX96` as ETH-wei per token-wei in Q96. A whole token is
    ///      1e18 token-wei, so `openPriceWei = initialPriceX96 * 1e18 / 2^96`. Feeding this back
    ///      through `sqrtPriceX96ForPrice` keeps ONE price convention across both lanes and the
    ///      pool open, at the cost of sub-wei-per-whole-token precision the pool cannot express anyway.
    function migrationPriceWei(uint256 initialPriceX96) public pure returns (uint256) {
        return V4PoolMath.mulDiv(initialPriceX96, 1e18, V4PoolMath.Q96);
    }

    /// @notice Assemble and ABI-encode the CCA `AuctionParameters` for a bonded launch.
    /// @dev Pure: every input is passed in, so the linked call needs no launchpad storage. The
    ///      floor PRICE is the clearing price at `floorFdvWei` over the TOTAL supply — the auction's
    ///      starting valuation — while `raiseFloorWei` is the independent graduation threshold
    ///      (`requiredCurrencyRaised`), pools.trade-style. The bid tick is 1% of the floor price.
    function encodeAuctionConfig(
        address currency,
        address recipient,
        uint64 startBlock,
        uint64 endBlock,
        uint64 claimBlock,
        uint96 floorFdvWei,
        uint96 raiseFloorWei,
        uint256 totalSupply,
        uint64 durationBlocks
    ) public pure returns (bytes memory configData, uint256 floorPriceQ96) {
        // The CCA initializes the floor as its first TICK and hard-reverts `TickPriceNotAtBoundary`
        // unless `floorPrice % tickSpacing == 0` — so derive the spacing first (1% of the raw
        // floor, clamped to the CCA's MIN_TICK_SPACING of 2) and round the floor DOWN to an exact
        // boundary. The rounding concedes under one tick (<1%) of the requested starting FDV.
        uint256 rawFloorQ96 = (uint256(floorFdvWei) << 96) / totalSupply;
        uint256 tickSpacingQ96 = rawFloorQ96 / 100;
        if (tickSpacingQ96 < 2) tickSpacingQ96 = 2;
        floorPriceQ96 = (rawFloorQ96 / tickSpacingQ96) * tickSpacingQ96;
        AuctionParameters memory p = AuctionParameters({
            currency: currency,
            tokensRecipient: recipient,
            fundsRecipient: recipient,
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: claimBlock,
            tickSpacing: tickSpacingQ96,
            validationHook: address(0),
            floorPrice: floorPriceQ96,
            requiredCurrencyRaised: raiseFloorWei,
            auctionStepsData: auctionStepsUniform(durationBlocks)
        });
        configData = abi.encode(p);
    }

    /// @notice A single uniform CCA issuance step packed as the auction's `auctionStepsData`.
    /// @dev One `bytes8` word: `uint24 mpsPerBlock << 40 | uint40 blockDelta`. The auction enforces
    ///      `sum(mps * delta) == 1e7`, so `durationBlocks` MUST divide 1e7 exactly — the launchpad
    ///      checks this before calling. `mpsPerBlock = 1e7 / durationBlocks`.
    function auctionStepsUniform(uint64 durationBlocks) public pure returns (bytes memory) {
        uint256 mps = AUCTION_MPS_TOTAL / durationBlocks;
        // `bytes8` layout, high bytes first: mps occupies the top 3 bytes, blockDelta the low 5.
        uint64 word = (uint64(uint24(mps)) << 40) | uint64(durationBlocks);
        return abi.encodePacked(bytes8(word));
    }

    /// @notice True iff a uniform single-step schedule can release exactly 1e7 over `durationBlocks`.
    function uniformStepsValid(uint64 durationBlocks) public pure returns (bool) {
        return durationBlocks != 0 && AUCTION_MPS_TOTAL % durationBlocks == 0
            && (AUCTION_MPS_TOTAL / durationBlocks) <= type(uint24).max;
    }

    // ------------------------------------------------------------------ v4 pool math (shared)

    /// @notice `sqrt((1e18 << 192) / pFinal)` — the graduation/open sqrt price, unbounded.
    function sqrtPriceX96ForPrice(uint256 pFinal) public pure returns (uint256) {
        return _sqrt((uint256(1e18) << 192) / pFinal);
    }

    /// @notice Largest full-range position expressible at `tickSpacing`.
    function usableTickRange(int24 tickSpacing) public pure returns (int24 tickLower, int24 tickUpper) {
        return V4PoolMath.usableTickRange(tickSpacing);
    }

    /// @notice Liquidity a token1-only band over `[tickLower, tickUpper]` can fund, or ZERO when
    ///         that band overflows uint128 — the load-bearing refusal that keeps a misconfigured
    ///         band from reverting inside the unlock and bricking the launch.
    function bandLiquidity(int24 tickLower, int24 tickUpper, uint256 amount1) public pure returns (uint128) {
        uint160 lower = V4PoolMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = V4PoolMath.getSqrtPriceAtTick(tickUpper);
        if (upper <= lower) return 0;
        uint256 liquidity = V4PoolMath.mulDiv(amount1, V4PoolMath.Q96, upper - lower);
        if (liquidity > type(uint128).max) return 0;
        return uint128(liquidity);
    }

    /// @notice Liquidity both amounts jointly fund over `[tickLower, tickUpper]` at spot.
    function liquidityForAmountsInRange(
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) public pure returns (uint128) {
        return V4PoolMath.getLiquidityForAmounts(
            sqrtPriceX96,
            V4PoolMath.getSqrtPriceAtTick(tickLower),
            V4PoolMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    // ------------------------------------------------------------------ validation & config

    /// @notice Reverts (returns a nonzero code) if `p` is a stack the hook would reject. Kept in
    ///         lockstep with `HookrHook.configurePool` so anything accepted here configures cleanly.
    /// @return code 0 = ok; nonzero identifies the first failing rule for the launchpad to revert on.
    function validateHookParams(HookParams memory p, uint96 minPotBuyWei) public pure returns (uint8 code) {
        uint24 maxFeePips = p.maxFeePips == 0 ? p.baseFeePips : p.maxFeePips;
        if (p.baseFeePips > 500_000 || maxFeePips > 500_000) return 1;
        if (maxFeePips < p.baseFeePips) return 1;
        if (uint256(p.baseFeePips) + p.snipeTaxPips > 500_000) return 1;
        if (uint256(p.burnBps) + p.lpBps + p.potBps > 1000) return 1;
        if (p.burnTriggerWei != 0) return 1;
        if (p.potBps > 0 && (p.potEveryNBuys < 2 || p.potEveryNBuys > 100_000)) return 1;
        if (p.surgeSens > 10) return 1;
        if (p.guardBlocks > 100_000) return 1;
        if (p.maxBuyBps > BPS) return 1;
        if (p.potBps > 0 && p.potMinBuyWei < minPotBuyWei) return 1;
    }

    /// @notice Validates the creator fee split. Returns 0 when valid, so the launchpad can raise
    ///         its own `BadFeeSplit`.
    function validateDistribution(
        uint16 creatorFeeBps,
        FeeRecipient[] calldata feeRecipients,
        uint16 maxCreatorFeeBps,
        uint256 maxFeeRecipients
    ) public pure returns (uint8 code) {
        if (creatorFeeBps > maxCreatorFeeBps) return 1;
        uint256 n = feeRecipients.length;
        if (n > maxFeeRecipients) return 1;
        if (n > 0) {
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                FeeRecipient calldata r = feeRecipients[i];
                if (r.to == address(0) || r.bps == 0) return 1;
                for (uint256 j; j < i; ++j) {
                    if (feeRecipients[j].to == r.to) return 1;
                }
                sum += r.bps;
            }
            if (sum != BPS) return 1;
        }
    }

    /// @notice Assemble the `PoolConfig` a launch hands the hook. Pure: the launchpad reads the two
    ///         blueprint fields and computes `guardEndBlock`, then hands them in.
    function buildPoolConfig(
        HookParams memory p,
        uint16 royaltyBps,
        address royaltyTo,
        uint256 pFinal,
        uint256 capTokens,
        uint40 guardEndBlock,
        uint24 flywheelFeePips
    ) public pure returns (HookrHook.PoolConfig memory cfg) {
        uint256 maxBuyWei = 0;
        if (p.maxBuyBps != 0) {
            maxBuyWei = (((capTokens * p.maxBuyBps) / BPS) * pFinal) / 1e18;
            if (maxBuyWei > type(uint96).max) maxBuyWei = type(uint96).max;
        }
        cfg = HookrHook.PoolConfig({
            initialized: false,
            guardEndBlock: guardEndBlock,
            baseFeePips: p.baseFeePips,
            maxFeePips: p.maxFeePips == 0 ? p.baseFeePips : p.maxFeePips,
            snipeTaxPips: p.snipeTaxPips,
            surgeSens: p.surgeSens,
            burnBps: p.burnBps,
            lpBps: p.lpBps,
            potBps: p.potBps,
            royaltyBps: royaltyBps,
            potEveryNBuys: p.potEveryNBuys,
            maxBuyWei: uint96(maxBuyWei),
            potMinBuyWei: p.potMinBuyWei,
            burnTriggerWei: p.burnTriggerWei,
            royaltyTo: royaltyTo,
            token: address(0),
            flywheelFeePips: flywheelFeePips
        });
    }

    // ------------------------------------------------------------------ internal

    function _alignTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 aligned = (tick / spacing) * spacing;
        if (tick < 0 && aligned != tick) aligned -= spacing;
        return aligned;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
