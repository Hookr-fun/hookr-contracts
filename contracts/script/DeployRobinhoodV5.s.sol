// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrFlywheelBurner} from "../src/HookrFlywheelBurner.sol";
import {HookParams} from "../src/libraries/HookrLaunchTypes.sol";
import {IContinuousClearingAuctionFactory} from "../src/interfaces/IContinuousClearingAuction.sol";

/// @notice Deploys Hookr generation 5 to Robinhood Chain (4663): the zero-seed instant lane and the
///         CCA-bonded lane replace the stepped bonding curve. Sequence, after Forge PREPENDS the
///         linked library when it is not already deployed:
///         0. HookrLaunchpadLibV5 — CREATE2 by the canonical deployer, added by Forge (reused on a
///            retry or patch release when the exact reviewed library is already live)
///         1. HookrFlywheelBurner
///         2. HookrLaunchpadV5
///         3. HookrHook via CREATE2 (mined address carrying the exact permission flags; byte-equal
///            to every prior generation's hook source, re-mined for this launchpad address)
///         4. the bounded production swap router
///         5. wire the hook and burner, seed the five house blueprints
///         6. read everything back and revert the simulation on any mismatch.
///
/// @dev The CCA factory is Uniswap Labs' DEPLOYED, byte-verified, permissionless instance. Hookr
///      deploys none of it; it is a constructor dependency, its runtime codehash asserted here so a
///      wrong or moved factory stops the simulation. The auction window and delays are constructor
///      immutables (chain-cadence dependent), and `AUCTION_DURATION_BLOCKS` must divide 1e7 so the
///      uniform issuance schedule has an integer per-block rate.
contract DeployRobinhoodV5 is Script {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IContinuousClearingAuctionFactory constant CCA_FACTORY =
        IContinuousClearingAuctionFactory(0x000000001F26a0044BaA66024e7b6599c61963F8);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    bytes32 constant PM_RUNTIME_CODEHASH = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 constant CREATE2_DEPLOYER_RUNTIME_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    bytes32 constant CCA_FACTORY_RUNTIME_CODEHASH = 0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa;
    bytes32 constant HOOKR_RUNTIME_CODEHASH = 0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d;
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint256 constant MAX_RUNTIME_SIZE = 24_576;

    /// @dev The INITIAL auction cadence. Owner-settable after deploy via `setAuctionTiming`, so the
    ///      go-live canary can use a short window (e.g. 2500 blocks ~4 min) and then flip to this
    ///      production value — one contract, no redeploy. 125,000 blocks ≈ 3.47 h at ~10 blocks/s;
    ///      chosen as a clean divisor of 1e7 (mps/block = 80) so one uniform issuance step releases
    ///      the whole supply. The UI shows the real wall-clock end from the end block.
    uint64 constant AUCTION_DURATION_BLOCKS = 125_000;
    uint64 constant CLAIM_DELAY_BLOCKS = 0;
    uint64 constant MIGRATION_DELAY_BLOCKS = 1;
    /// @dev The fixed instant opening valuation, platform-wide (pools.trade-style). ~2.5 ETH matches
    ///      pools.trade's fixed opening tick. Immutable per deployment; redeploy to retune.
    uint96 constant INSTANT_OPEN_FDV_WEI = 2.5 ether;

    /// @dev The HOOKR flywheel. The burner buys through the canonical hookless ETH/HOOKR pool
    ///      (fee 2500, tick spacing 25) and burns everything it buys; the hook accrues 0.3% of the
    ///      ETH side of every ETH-paired generation-5 swap to it. HOOKR-quoted launches open at a
    ///      fixed 2,500,000 HOOKR FDV and pay no protocol fee anywhere.
    address constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    uint96 constant HOOKR_INSTANT_OPEN_FDV = 2_500_000e18;
    uint24 constant HOOKR_POOL_FEE = 2500;
    int24 constant HOOKR_POOL_TICK_SPACING = 25;

    /// @notice Reviewed 5.0.1 runtime anchors. The only difference is the constructor-probed
    ///         `useArbSysClock` immutable: Forge's RPC simulator cannot execute Robinhood's ArbSys
    ///         precompile and encodes false, while the live chain and an ArbSys-faithful fork encode
    ///         true. The production preflight normalizes that immutable and independently proves
    ///         the live runtime; this script accepts only these two exact raw forms.
    /// @dev 5.0.1 adds a mandatory final CCA checkpoint before reading lazy graduation state.
    ///      Runtime size 23,838. Pinning is not approval: independently reproduce both forms and
    ///      assess the source diff before any `--broadcast`.
    bytes32 constant REVIEWED_PAD_SIMULATION_RUNTIME_HASH =
        0x48da8743006f10945600ca27c4334cabc78210d48c071495520cc61650e14513;
    bytes32 constant REVIEWED_PAD_LIVE_RUNTIME_HASH =
        0x26dd92acae56386f99dbc98ed2f53aa62ccff493bab27b6f1a26d84e23ed3a5d;
    /// @dev Raw simulation hashes for the exact production action packet whose first CREATE uses
    ///      deployer nonce 686 (the confirmed account nonce before this packet is 686). Hook and
    ///      router runtimes carry deployment-address immutables, so any deployer nonce drift makes
    ///      these fail before Forge broadcasts. Re-simulate and review; never silently repin.
    bytes32 constant REVIEWED_HOOK_RUNTIME_HASH = 0x1d8e5b8f744d277779ddbeaed93e18afda4bfdfae74b4c8c5147601b8ee9f4ea;
    bytes32 constant REVIEWED_ROUTER_RUNTIME_HASH = 0xdfba091b062d784c6f06439d3a158d1ece3ca990f808b2aa474774893da27d61;
    bytes32 constant REVIEWED_BURNER_RUNTIME_HASH = 0xa75474371e64ed31e66ce6d1be687f00b87607ca7ca9818e15030d8b311cf84d;

    function run() external {
        require(block.chainid == 4663, "wrong chain");
        require(address(PM).codehash == PM_RUNTIME_CODEHASH, "PoolManager runtime codehash wrong");
        require(
            CREATE2_DEPLOYER.codehash == CREATE2_DEPLOYER_RUNTIME_CODEHASH, "CREATE2 deployer runtime codehash wrong"
        );
        require(address(CCA_FACTORY).codehash == CCA_FACTORY_RUNTIME_CODEHASH, "CCA factory runtime codehash wrong");
        console2.log("CCA factory runtime codehash");
        console2.logBytes32(address(CCA_FACTORY).codehash);

        address deployer = EXPECTED_DEPLOYER;
        console2.log("deployer", deployer);
        console2.log("balance", deployer.balance);

        require(HOOKR_TOKEN.codehash == HOOKR_RUNTIME_CODEHASH, "HOOKR runtime codehash wrong");

        vm.startBroadcast(deployer);

        // The burner first: the hook takes it as a constructor immutable.
        HookrFlywheelBurner burner = new HookrFlywheelBurner(PM, HOOKR_TOKEN, HOOKR_POOL_FEE, HOOKR_POOL_TICK_SPACING);

        HookrLaunchpadV5 pad = new HookrLaunchpadV5(
            PM,
            CCA_FACTORY,
            AUCTION_DURATION_BLOCKS,
            CLAIM_DELAY_BLOCKS,
            MIGRATION_DELAY_BLOCKS,
            INSTANT_OPEN_FDV_WEI,
            HOOKR_TOKEN,
            HOOKR_INSTANT_OPEN_FDV
        );

        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad), address(burner)));
        (address predicted, bytes32 salt) = _mine(CREATE2_DEPLOYER, creation);
        HookrHook hook = new HookrHook{salt: salt}(PM, address(pad), address(burner));
        require(address(hook) == predicted, "mined address mismatch");

        HookrSwapRouter router = new HookrSwapRouter(PM, hook, HOOKR_TOKEN);

        pad.setHook(hook);
        burner.setHook(address(hook));
        _seedBlueprints(pad);

        vm.stopBroadcast();

        // ---- readback assertions (no broadcast) ----
        require(keccak256(bytes(pad.contractName())) == keccak256(bytes("HookrLaunchpadV5")), "pad identity wrong");
        require(keccak256(bytes(pad.contractVersion())) == keccak256(bytes("5.0.1")), "pad version wrong");
        require(keccak256(bytes(hook.contractName())) == keccak256(bytes("HookrHook")), "hook identity wrong");
        require(address(pad.hook()) == address(hook), "hook not wired");
        require(uint160(address(hook)) & 0x3FFF == HOOK_FLAGS, "hook flags wrong");
        require(hook.launchpad() == address(pad), "hook launchpad wrong");
        require(address(hook.poolManager()) == address(PM), "hook PM wrong");
        require(address(pad.auctionFactory()) == address(CCA_FACTORY), "auction factory wrong");
        require(pad.auctionDurationBlocks() == AUCTION_DURATION_BLOCKS, "auction duration wrong");
        require(address(router.poolManager()) == address(PM), "router PM wrong");
        require(address(router.hook()) == address(hook), "router hook wrong");
        require(router.quoteToken() == HOOKR_TOKEN, "router quote token wrong");
        require(hook.flywheelRecipient() == address(burner), "hook flywheel recipient wrong");
        require(burner.hook() == address(hook), "burner hook not wired");
        require(burner.hookrToken() == HOOKR_TOKEN, "burner HOOKR wrong");
        require(burner.owner() == deployer, "burner owner wrong");
        require(keccak256(bytes(burner.contractVersion())) == keccak256(bytes("1.0.1")), "burner version wrong");
        require(pad.hookrToken() == HOOKR_TOKEN, "pad HOOKR wrong");
        require(pad.hookrInstantOpenFdv() == HOOKR_INSTANT_OPEN_FDV, "pad HOOKR instant FDV wrong");
        require(pad.owner() == deployer, "owner wrong");
        require(pad.blueprintsCount() == 6, "blueprints missing"); // sentinel + 5
        require(pad.getBlueprint(2).params.guardBlocks == 100, "sniper slayer params wrong");

        require(address(pad).code.length <= MAX_RUNTIME_SIZE, "launchpad exceeds EIP-170");
        require(address(hook).code.length <= MAX_RUNTIME_SIZE, "hook exceeds EIP-170");
        require(address(router).code.length <= MAX_RUNTIME_SIZE, "router exceeds EIP-170");
        require(address(burner).code.length <= MAX_RUNTIME_SIZE, "burner exceeds EIP-170");
        console2.log("HookrLaunchpadV5 runtime size", address(pad).code.length);

        bytes32 padRuntimeCodehash = address(pad).codehash;
        require(padRuntimeCodehash != bytes32(0), "runtime codehash missing");
        console2.log("HookrLaunchpadV5 candidate runtime codehash");
        console2.logBytes32(padRuntimeCodehash);

        // The reviewed-build anchor. Placeholder bytes32(0) fails this until a reviewer derives the
        // candidate above from a no-broadcast simulation and pins it. A contract or constant change
        // is meant to stop here.
        //   forge script script/DeployRobinhoodV5.s.sol \
        //     --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <deployer>
        require(
            padRuntimeCodehash == REVIEWED_PAD_SIMULATION_RUNTIME_HASH
                || padRuntimeCodehash == REVIEWED_PAD_LIVE_RUNTIME_HASH,
            "launchpad is not the reviewed build"
        );
        require(address(hook).codehash == REVIEWED_HOOK_RUNTIME_HASH, "hook is not the reviewed build/nonce");
        require(address(router).codehash == REVIEWED_ROUTER_RUNTIME_HASH, "router is not the reviewed build/nonce");
        require(address(burner).codehash == REVIEWED_BURNER_RUNTIME_HASH, "burner is not the reviewed build");

        console2.log("HookrLaunchpadV5   ", address(pad));
        console2.log("HookrHook          ", address(hook));
        console2.log("HookrSwapRouter    ", address(router));
        console2.log("HookrFlywheelBurner", address(burner));
        // The canary script gates on all four runtime hashes before it will load a key.
        console2.log("HookrHook runtime codehash");
        console2.logBytes32(address(hook).codehash);
        console2.log("HookrSwapRouter runtime codehash");
        console2.logBytes32(address(router).codehash);
        console2.log("HookrFlywheelBurner runtime codehash");
        console2.logBytes32(address(burner).codehash);
    }

    function _mine(address deployer, bytes memory creation) internal view returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(creation);
        uint160 flags = HOOK_FLAGS;
        // ALLOCATION-FREE search. The 14-bit flag match needs ~16k expected iterations but an
        // unlucky init-code hash can need hundreds of thousands, and a fresh `abi.encodePacked`
        // per iteration expands memory until forge's simulator dies with MemoryOOG (observed live:
        // a nonce shift moved the predicted constructor args and the new hash needed a deep salt).
        // One fixed 85-byte buffer, hashed in place, makes the search depth memory-invariant. The
        // buffer layout is the CREATE2 preimage: 0xff ++ deployer ++ salt ++ initCodeHash.
        uint256 candidate;
        for (uint256 i = 0; i < 4_000_000; i++) {
            assembly ("memory-safe") {
                let buf := mload(0x40) // scratch past the free pointer, never advanced
                mstore8(buf, 0xff)
                mstore(add(buf, 0x01), shl(96, deployer))
                mstore(add(buf, 0x15), i)
                mstore(add(buf, 0x35), initCodeHash)
                candidate := and(keccak256(buf, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if (uint160(candidate) & 0x3FFF != flags) continue;
            hookAddress = address(uint160(candidate));
            if (hookAddress.code.length == 0 && vm.getNonce(hookAddress) == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert("no salt");
    }

    /// @dev The five reviewed house blueprints — identical stacks to every prior generation.
    function _seedBlueprints(HookrLaunchpadV5 pad) internal {
        pad.saveBlueprint(
            "Nth-buy Pot",
            HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000,
                maxFeePips: 0,
                surgeSens: 0,
                burnBps: 0,
                burnTriggerWei: 0,
                lpBps: 0,
                potBps: 50,
                potEveryNBuys: 500,
                potMinBuyWei: 0.01 ether
            }),
            500
        );
        pad.saveBlueprint(
            "Sniper Slayer",
            HookParams({
                guardBlocks: 100,
                maxBuyBps: 50,
                snipeTaxPips: 400_000,
                baseFeePips: 3000,
                maxFeePips: 0,
                surgeSens: 0,
                burnBps: 0,
                burnTriggerWei: 0,
                lpBps: 0,
                potBps: 0,
                potEveryNBuys: 0,
                potMinBuyWei: 0
            }),
            0
        );
        pad.saveBlueprint(
            "Auto Burn",
            HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000,
                maxFeePips: 0,
                surgeSens: 0,
                burnBps: 100,
                burnTriggerWei: 0,
                lpBps: 0,
                potBps: 0,
                potEveryNBuys: 0,
                potMinBuyWei: 0
            }),
            0
        );
        pad.saveBlueprint(
            "Surge Fees",
            HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000,
                maxFeePips: 30_000,
                surgeSens: 5,
                burnBps: 0,
                burnTriggerWei: 0,
                lpBps: 0,
                potBps: 0,
                potEveryNBuys: 0,
                potMinBuyWei: 0
            }),
            0
        );
        pad.saveBlueprint(
            "LP Loyalty",
            HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000,
                maxFeePips: 0,
                surgeSens: 0,
                burnBps: 0,
                burnTriggerWei: 0,
                lpBps: 25,
                potBps: 0,
                potEveryNBuys: 0,
                potMinBuyWei: 0
            }),
            400
        );
    }
}
