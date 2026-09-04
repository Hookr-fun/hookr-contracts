// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrFlywheelBurner} from "../src/HookrFlywheelBurner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookParams, FeeRecipient} from "../src/libraries/HookrLaunchTypes.sol";

interface ICanaryAuction {
    function endBlock() external view returns (uint64);
}

/// @notice Generation-5 production canary, in TWO phases because a real auction has a real window.
///
///         Phase A is nine transactions: six in FOUR raw Forge artifacts (1 + 2 + 1 + 2), one
///         separately preserved owner-bid transaction, and two raw timing transactions. ETH-lane
///         tokens use pad-nonce-sensitive CREATE and the CCA includes the mined contract-clock
///         start; the HOOKR token is deterministic CREATE2, but policy still requires every launch
///         to finalize and authenticate from `launchedByIntent` / `getLaunch` before its address may
///         enter later calldata. The recovery entrypoint never replays or fabricates the already
///         mined owner bid; the wrapper authenticates its raw transaction/receipt pair first.
///         Phase B is intentionally NOT a Forge batch. Its five permissionless transitions may be
///         executed by keepers or a helper, so the wrapper reconciles six canonical outcomes that
///         may share one receipt and signs only missing work; only the bounded final flywheel
///         buyback is owner-only.
///
///         The operator keeps production timing for phase A/1, waits for that launch to finalize,
///         sets `setAuctionTiming(20000,0,1)` only immediately before phase A/2-3, and restores
///         `setAuctionTiming(125000,0,1)` immediately after its auction-launch receipt. The CCA
///         retains its baked end block while the public launchpad remains at production timing
///         throughout the finality wait and all later canary stages.
///
///         Peak outlay: ~0.012 ETH (0.0105 bid + 0.001 instant buy + 3x 0.0002 creation fee)
///         plus 25,000 HOOKR before phase B returns ~0.0065 ETH of proceeds; the clearing-price
///         value of the reserved tokens (~0.004 ETH) locks as liquidity and is intentionally
///         non-recoverable. Fund the canary signer to ~0.02 ETH plus gas. The small numbers are safe BECAUSE the contract
///         floors are deliberately loose rails (0.01 ether); production floors are UI policy,
///         pools.trade-parity, and nothing here depends on them.
contract CanaryRobinhoodV5 is Script {
    address constant ARBSYS = address(0x64);
    bytes32 constant ROBINHOOD_ARBSYS_MARKER_CODEHASH = keccak256(hex"fe");
    bytes32 constant ARBSYS_SIMULATION_SHIM_CODEHASH = keccak256(hex"4360005260206000f3");
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    bytes32 constant PM_RUNTIME_CODEHASH = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    address constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 constant HOOKR_RUNTIME_CODEHASH = 0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d;
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    bytes32 constant INTENT_INSTANT = keccak256("hookr.v5.canary.instant.1");
    bytes32 constant INTENT_AUCTION = keccak256("hookr.v5.canary.auction.1");
    bytes32 constant INTENT_HOOKR = keccak256("hookr.v5.canary.hookr.1");
    uint96 constant CANARY_FLOOR_FDV = 0.02 ether; // starting valuation (floor price = FDV / supply)
    uint96 constant CANARY_RAISE_FLOOR = 0.01 ether; // graduation threshold, at the contract minimum
    uint16 constant CANARY_RESERVE_BPS = 2000; // exercises the proceeds path; most of the raise returns
    uint128 constant CANARY_BID_WEI = 0.0105 ether; // clears the raise floor with headroom
    uint256 constant CANARY_BUY_WEI = 0.001 ether;
    uint256 constant CANARY_CREATION_FEE_WEI = 0.0002 ether;
    // Robinhood's finalized head currently trails latest by ~10k rollup blocks. The auction must
    // remain open long enough to finalize its creation before a direct-value bid is signed.
    uint64 constant CANARY_AUCTION_DURATION_BLOCKS = 20_000;
    // Each launched identity must finalize before it may enter later router calldata. Keep the
    // canary guard open across the observed ~10k-block finality lag plus operator headroom so both
    // buys actually exercise the guarded/snipe-tax path rather than merely succeeding post-guard.
    uint32 constant CANARY_GUARD_BLOCKS = 20_000;
    uint64 constant CANARY_CLAIM_DELAY_BLOCKS = 0;
    uint64 constant CANARY_MIGRATION_DELAY_BLOCKS = 1;
    /// @dev The HOOKR-quoted instant canary. The sender must HOLD at least this much HOOKR before
    ///      phase A (runbook prep: buy ~50k HOOKR, a few thousandths of an ETH, on the site) —
    ///      zero-seed launches need no HOOKR, but proving the pair trades does.
    uint256 constant CANARY_HOOKR_BUY = 25_000e18;
    /// @dev Conservative floor under the ~320k tokens a 0.001 ETH buy nets at the fixed 2.5 ETH
    ///      open after the 20% snipe tax and 1% burn. Nonzero and real, with rehearsal headroom.
    uint128 constant BUY_MIN_TOKENS_OUT = 200_000e18;

    /// @dev Robinhood exposes ArbSys as the 0xfe marker at address(0x64). Robinhood's RPC executes
    ///      that marker as a chain precompile, while Foundry's local script EVM treats 0xfe as an
    ///      invalid opcode. Replace only the authenticated marker in local script state with an
    ///      equivalent `arbBlockNumber()` shim. `vm.etch` runs before `startBroadcast`, so it never
    ///      enters the broadcast transaction list or mutates production state.
    function _installArbSysSimulationShim() internal {
        require(block.chainid == 4663, "wrong chain");
        bytes32 currentCodehash = ARBSYS.codehash;
        // A disposable Anvil rehearsal may already carry the exact same shim so its mined fork
        // transactions can emulate Robinhood. The release wrapper enables that exception only
        // for its authenticated loopback/unlocked mode; production must start from the marker.
        if (currentCodehash == ARBSYS_SIMULATION_SHIM_CODEHASH) {
            require(
                vm.envOr("HOOKR_CANARY_ALLOW_PREINSTALLED_ARBSYS_SHIM", false), "preinstalled ArbSys shim forbidden"
            );
        } else {
            require(currentCodehash == ROBINHOOD_ARBSYS_MARKER_CODEHASH, "ArbSys marker wrong");
            vm.etch(ARBSYS, hex"4360005260206000f3");
        }
        require(ARBSYS.codehash == ARBSYS_SIMULATION_SHIM_CODEHASH, "ArbSys shim wrong");
        (bool ok, bytes memory result) = ARBSYS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        require(ok && result.length == 32 && abi.decode(result, (uint256)) == block.number, "ArbSys shim read wrong");
    }

    function _release()
        internal
        view
        returns (HookrLaunchpadV5 pad, HookrHook hook, HookrSwapRouter router, HookrFlywheelBurner burner)
    {
        require(block.chainid == 4663, "wrong chain");
        require(address(PM).codehash == PM_RUNTIME_CODEHASH, "PoolManager runtime codehash wrong");
        require(HOOKR_TOKEN.codehash == HOOKR_RUNTIME_CODEHASH, "HOOKR runtime wrong");
        pad = HookrLaunchpadV5(payable(vm.envAddress("HOOKR_LAUNCHPAD_V5_ADDRESS")));
        hook = HookrHook(payable(vm.envAddress("HOOKR_HOOK_V5_ADDRESS")));
        router = HookrSwapRouter(vm.envAddress("HOOKR_SWAP_ROUTER_V5_ADDRESS"));
        burner = HookrFlywheelBurner(payable(vm.envAddress("HOOKR_FLYWHEEL_BURNER_ADDRESS")));
        // Runtime bytecode is the release authority; identity strings are spoofable. Fail before
        // loading a key unless every address matches the reviewed deployment's runtime hashes.
        require(address(pad).codehash == vm.envBytes32("HOOKR_LAUNCHPAD_V5_RUNTIME_CODEHASH"), "pad runtime wrong");
        require(address(hook).codehash == vm.envBytes32("HOOKR_HOOK_V5_RUNTIME_CODEHASH"), "hook runtime wrong");
        require(
            address(router).codehash == vm.envBytes32("HOOKR_SWAP_ROUTER_V5_RUNTIME_CODEHASH"), "router runtime wrong"
        );
        require(
            address(burner).codehash == vm.envBytes32("HOOKR_FLYWHEEL_BURNER_RUNTIME_CODEHASH"), "burner runtime wrong"
        );
        require(hook.REQUIRED_FLAGS() == HOOK_FLAGS, "hook flags wrong");
        require(address(pad.hook()) == address(hook), "hook not wired");
        require(address(router.hook()) == address(hook), "router hook wrong");
        require(address(router.poolManager()) == address(PM), "router PoolManager wrong");
        require(router.quoteToken() == HOOKR_TOKEN, "router HOOKR wrong");
        require(address(hook.flywheelRecipient()) == address(burner), "hook burner wrong");
        require(burner.hook() == address(hook), "burner hook wrong");
        require(address(burner.poolManager()) == address(PM), "burner PoolManager wrong");
        require(pad.hookrToken() == HOOKR_TOKEN && burner.hookrToken() == HOOKR_TOKEN, "HOOKR wiring wrong");
        require(burner.poolFee() == 2500 && burner.poolTickSpacing() == 25, "burner pool key wrong");
        require(keccak256(bytes(burner.contractVersion())) == keccak256(bytes("1.0.1")), "burner version wrong");
    }

    function _allFive() internal pure returns (HookParams memory p) {
        // The same five-block stack every prior canary proved: guard + cap + snipe tax, surge,
        // burn, LP donation, and the deterministic pot with the canary buy as its qualifying floor.
        // BONDED LANE ONLY: the instant lane structurally refuses the LP-donation block (a
        // zero-seed pool has no in-range LP at open to receive it) — use `_instantFour` there.
        p = HookParams({
            guardBlocks: CANARY_GUARD_BLOCKS,
            maxBuyBps: 1000, // 10% of supply-at-open-price per block
            snipeTaxPips: 200_000, // +20% during the guard
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 100, // 1%
            burnTriggerWei: 0,
            lpBps: 25, // 0.25%
            potBps: 50, // 0.5%
            potEveryNBuys: 2,
            potMinBuyWei: 0.001 ether
        });
    }

    function _instantFour() internal pure returns (HookParams memory p) {
        p = _allFive();
        p.lpBps = 0; // structurally unavailable on the zero-seed instant lane
    }

    /// @dev The HOOKR-pair stack: guard + surge only — the native-cut blocks are refused there.
    function _guardTwo() internal pure returns (HookParams memory p) {
        p = _allFive();
        p.lpBps = 0;
        p.potBps = 0;
        p.potEveryNBuys = 0;
        p.potMinBuyWei = 0;
        p.burnBps = 0;
    }

    function _args(string memory name, string memory symbol, address creator, HookParams memory stack)
        internal
        pure
        returns (HookrLaunchpadV5.LaunchArgs memory a)
    {
        a.name = name;
        a.symbol = symbol;
        a.tagline = "generation-5 canary";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.blueprintId = 0;
        a.custom = stack;
        a.creatorFeeBps = 0;
        a.feeRecipients = new FeeRecipient[](0);
    }

    function _phaseAContext(HookrLaunchpadV5 pad, HookrFlywheelBurner burner)
        internal
        returns (address me, uint256 fee)
    {
        me = vm.envAddress("HOOKR_CANARY_SENDER");
        require(me == pad.owner() && me == burner.owner(), "canary sender is not the release owner");
        fee = pad.creationFeeWei();
        require(fee == CANARY_CREATION_FEE_WEI, "creation fee is not the reviewed canary value");
    }

    function _requireTiming(HookrLaunchpadV5 pad, uint64 duration) internal view {
        require(
            pad.auctionDurationBlocks() == duration && pad.claimDelayBlocks() == CANARY_CLAIM_DELAY_BLOCKS
                && pad.migrationDelayBlocks() == CANARY_MIGRATION_DELAY_BLOCKS,
            "auction timing is not the required operator state"
        );
    }

    function _authenticatedLaunch(
        HookrLaunchpadV5 pad,
        address me,
        bytes32 intent,
        string memory envName,
        HookrLaunchpadV5.LaunchMode mode,
        HookrLaunchpadV5.LaunchStatus status,
        HookrLaunchpadV5.Quote quote
    ) internal returns (address token, HookrLaunchpadV5.Launch memory launch) {
        token = vm.envAddress(envName);
        require(token.code.length > 0 && pad.launchedByIntent(me, intent) == token, "token is not the mined intent");
        launch = pad.getLaunch(token);
        require(launch.token == token && launch.creator == me, "launch identity is wrong");
        require(
            uint8(launch.mode) == uint8(mode) && uint8(launch.status) == uint8(status)
                && uint8(launch.quote) == uint8(quote),
            "launch mode, status, or quote is wrong"
        );
    }

    /// @notice PHASE A/1: launch the ETH instant canary and stop. The token address must mine before
    ///         it may enter router calldata; a local CREATE prediction is never release authority.
    function openInstant() external {
        _installArbSysSimulationShim();
        (HookrLaunchpadV5 pad,,, HookrFlywheelBurner burner) = _release();
        (address me, uint256 fee) = _phaseAContext(pad, burner);
        _requireTiming(pad, 125_000);
        require(me.balance >= 0.02 ether, "canary sender holds too little ETH");
        require(IERC20(pad.hookrToken()).balanceOf(me) >= CANARY_HOOKR_BUY, "canary sender holds too little HOOKR");
        require(pad.launchedByIntent(me, INTENT_INSTANT) == address(0), "instant canary intent already used");
        require(pad.launchedByIntent(me, INTENT_AUCTION) == address(0), "auction canary intent already used");
        require(pad.launchedByIntent(me, INTENT_HOOKR) == address(0), "HOOKR canary intent already used");

        vm.startBroadcast(me);
        pad.launchInstant{value: fee}(
            _args("Canary Instant V5", "CANV5I", me, _instantFour()), HookrLaunchpadV5.Quote.Eth, INTENT_INSTANT
        );
        vm.stopBroadcast();
    }

    /// @notice PHASE A/2-3: buy the canonically mined ETH instant token, then launch the auction.
    ///         Nothing in this artifact consumes the auction's still-dynamic token or CCA address.
    function buyInstantLaunchAuction() external {
        _installArbSysSimulationShim();
        (HookrLaunchpadV5 pad, HookrHook hook, HookrSwapRouter router, HookrFlywheelBurner burner) = _release();
        (address me, uint256 fee) = _phaseAContext(pad, burner);
        _requireTiming(pad, CANARY_AUCTION_DURATION_BLOCKS);
        require(me.balance >= CANARY_BUY_WEI + fee, "canary sender holds too little ETH");
        (address instantToken,) = _authenticatedLaunch(
            pad,
            me,
            INTENT_INSTANT,
            "CANARY_INSTANT_TOKEN",
            HookrLaunchpadV5.LaunchMode.Instant,
            HookrLaunchpadV5.LaunchStatus.Live,
            HookrLaunchpadV5.Quote.Eth
        );
        require(pad.launchedByIntent(me, INTENT_AUCTION) == address(0), "auction canary intent already used");
        require(pad.launchedByIntent(me, INTENT_HOOKR) == address(0), "HOOKR canary intent already used");

        vm.startBroadcast(me);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(instantToken),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        router.exactInput{value: CANARY_BUY_WEI}(
            HookrSwapRouter.ExactInputParams({
                key: key,
                zeroForOne: true,
                amountIn: uint128(CANARY_BUY_WEI),
                amountOutMinimum: BUY_MIN_TOKENS_OUT,
                sqrtPriceLimitX96: hook.MIN_SQRT_PRICE_LIMIT(),
                recipient: me,
                deadline: block.timestamp + 10 minutes
            })
        );

        pad.launchAuction{value: fee}(
            _args("Canary Auction V5", "CANV5A", me, _allFive()),
            HookrLaunchpadV5.Quote.Eth,
            CANARY_FLOOR_FDV,
            CANARY_RAISE_FLOOR,
            CANARY_RESERVE_BPS,
            INTENT_AUCTION
        );
        vm.stopBroadcast();
    }

    /// @notice PHASE A/6: after the wrapper authenticates and finalizes the already-mined raw owner
    ///         bid at nonce 712, launch only the HOOKR pair. This recovery artifact can never bid.
    function launchHookrPair() external {
        _installArbSysSimulationShim();
        (HookrLaunchpadV5 pad,,, HookrFlywheelBurner burner) = _release();
        (address me, uint256 fee) = _phaseAContext(pad, burner);
        _requireTiming(pad, 125_000);
        require(me.balance >= fee, "canary sender holds too little ETH");
        require(IERC20(pad.hookrToken()).balanceOf(me) >= CANARY_HOOKR_BUY, "canary sender holds too little HOOKR");
        require(pad.launchedByIntent(me, INTENT_INSTANT) != address(0), "instant canary intent is missing");
        address auctionToken = vm.envAddress("CANARY_AUCTION_TOKEN");
        require(
            auctionToken.code.length > 0 && pad.launchedByIntent(me, INTENT_AUCTION) == auctionToken,
            "auction token is not the mined intent"
        );
        HookrLaunchpadV5.Launch memory launch = pad.getLaunch(auctionToken);
        require(launch.token == auctionToken && launch.creator == me, "auction launch identity is wrong");
        require(
            uint8(launch.mode) == uint8(HookrLaunchpadV5.LaunchMode.Bonded)
                && uint8(launch.quote) == uint8(HookrLaunchpadV5.Quote.Eth)
                && (uint8(launch.status) == uint8(HookrLaunchpadV5.LaunchStatus.Auctioning)
                    || uint8(launch.status) == uint8(HookrLaunchpadV5.LaunchStatus.Live)),
            "auction launch mode, status, or quote is wrong"
        );
        require(pad.launchedByIntent(me, INTENT_HOOKR) == address(0), "HOOKR canary intent already used");
        address auction = vm.envAddress("CANARY_AUCTION");
        require(launch.auction == auction && auction.code.length > 0, "auction is not the mined launch target");
        require(ICanaryAuction(auction).endBlock() == launch.auctionEndBlock, "auction end block is not launch state");

        vm.startBroadcast(me);
        pad.launchInstant{value: fee}(
            _args("Canary Hookr Pair V5", "CANV5H", me, _guardTwo()), HookrLaunchpadV5.Quote.Hookr, INTENT_HOOKR
        );
        vm.stopBroadcast();

        console2.log("auction token ", auctionToken);
        console2.log("auction       ", auction);
        console2.log("auction ends at block", ICanaryAuction(auction).endBlock());
    }

    /// @notice PHASE A/7-8: approve the fixed HOOKR quote and buy the canonically mined HOOKR-pair
    ///         token. Keeping approve beside use minimizes any residual allowance if interrupted.
    function buyHookrPair() external {
        _installArbSysSimulationShim();
        (HookrLaunchpadV5 pad, HookrHook hook, HookrSwapRouter router, HookrFlywheelBurner burner) = _release();
        (address me,) = _phaseAContext(pad, burner);
        _requireTiming(pad, 125_000);
        require(IERC20(pad.hookrToken()).balanceOf(me) >= CANARY_HOOKR_BUY, "canary sender holds too little HOOKR");
        require(pad.launchedByIntent(me, INTENT_INSTANT) != address(0), "instant canary intent is missing");
        require(pad.launchedByIntent(me, INTENT_AUCTION) != address(0), "auction canary intent is missing");
        (address hookrPairToken,) = _authenticatedLaunch(
            pad,
            me,
            INTENT_HOOKR,
            "CANARY_HOOKR_PAIR_TOKEN",
            HookrLaunchpadV5.LaunchMode.Instant,
            HookrLaunchpadV5.LaunchStatus.Live,
            HookrLaunchpadV5.Quote.Hookr
        );
        address hookrQuote = pad.hookrToken();

        vm.startBroadcast(me);
        IERC20(hookrQuote).approve(address(router), CANARY_HOOKR_BUY);
        router.exactInput(
            HookrSwapRouter.ExactInputParams({
                key: PoolKey({
                    currency0: Currency.wrap(hookrQuote),
                    currency1: Currency.wrap(hookrPairToken),
                    fee: 0x800000,
                    tickSpacing: 60,
                    hooks: IHooks(address(hook))
                }),
                zeroForOne: true,
                amountIn: uint128(CANARY_HOOKR_BUY),
                amountOutMinimum: 1_000_000e18, // conservative floor under the ~9.9M tokens 25k HOOKR nets at the 2.5M open
                sqrtPriceLimitX96: hook.MIN_SQRT_PRICE_LIMIT(),
                recipient: me,
                deadline: block.timestamp + 10 minutes
            })
        );
        vm.stopBroadcast();
    }
}
