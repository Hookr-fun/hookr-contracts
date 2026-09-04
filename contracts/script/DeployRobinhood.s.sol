// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";

/// @notice Deploys Hookr to Robinhood Chain (4663):
///         0. HookrLaunchpadLib — emitted by Forge itself, see the linked-library note below
///         1. HookrLaunchpad
///         2. HookrHook via CREATE2 (mined address carrying the exact permission flags)
///         3. deploys the bounded production swap router
///         4. wires the hook, seeds the five house blueprints
///         5. reads everything back and reverts the simulation on any mismatch.
/// @dev A broadcast is a sequence of transactions. A later failed transaction or readback cannot
///      roll back an earlier mined receipt; release operations must verify every receipt in order.
/// @dev LINKED LIBRARY — the sequence is TEN transactions, not nine. HookrLaunchpad exceeds the
///      EIP-170 deployed-code limit with its arithmetic and its token factory inlined, so both now
///      live in `HookrLaunchpadLib` and are linked by DELEGATECALL. Forge deploys an unlinked
///      library automatically and PREPENDS it to the broadcast: transaction #0 is a CREATE2 of
///      HookrLaunchpadLib through the canonical deployer at 0x4e59..., and every transaction below
///      shifts one index later. That extra transaction also consumes deployer nonce 0, so the
///      launchpad lands at nonce 1 and its address — and therefore the mined hook salt — differs
///      from a pre-library run. `_mine` re-derives both, so nothing here is pinned to the old
///      addresses, but `scripts/promote-release-manifest.mjs` verifies the receipt list by index
///      and must be kept in step.
contract DeployRobinhood is Script {
    /// @dev The hook's flywheel recipient. address(0) = flywheel dormant (pre-flywheel semantics).
    address constant FLYWHEEL_RECIPIENT = address(0);

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    bytes32 constant PM_RUNTIME_CODEHASH = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 constant CREATE2_DEPLOYER_RUNTIME_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    /// @dev EIP-170's deployed-runtime ceiling.
    uint256 constant MAX_RUNTIME_SIZE = 24_576;

    /// @notice keccak256 of HookrLaunchpad's deployed runtime code for the reviewed build.
    /// @dev THE single copy of this value in the repo. `contracts/run-canary.sh` parses it out of
    ///      this file by name rather than keeping its own, because two hand-maintained copies is
    ///      exactly how the previous pair went stale. Deployer- and nonce-invariant, so unrelated
    ///      wallet activity cannot shift it. Re-derive it from a no-broadcast simulation whenever
    ///      contracts/src changes — see the assertion in `run()` for the command.
    bytes32 constant REVIEWED_PAD_RUNTIME_HASH = 0x433411c5613df1dd265dfac168c7f78c4cfcbe87c7ae4ab669d1ff5340d09c71;

    function run() external {
        require(block.chainid == 4663, "wrong chain");
        require(address(PM).codehash == PM_RUNTIME_CODEHASH, "PoolManager runtime codehash wrong");
        require(
            CREATE2_DEPLOYER.codehash == CREATE2_DEPLOYER_RUNTIME_CODEHASH, "CREATE2 deployer runtime codehash wrong"
        );

        address deployer = EXPECTED_DEPLOYER;
        console2.log("deployer", deployer);
        console2.log("balance", deployer.balance);

        // Address-based broadcast keeps dry runs secret-free. A real `--broadcast` must use an
        // explicitly selected Foundry account or hardware wallet for this exact address.
        vm.startBroadcast(deployer);

        // 1. launchpad
        HookrLaunchpad pad = new HookrLaunchpad(PM);

        // 2. mine + deploy the hook
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = _mine(CREATE2_DEPLOYER, creation);
        HookrHook hook = new HookrHook{salt: salt}(PM, address(pad), FLYWHEEL_RECIPIENT);
        require(address(hook) == predicted, "mined address mismatch");

        // 3. production live-pool router (curve-graduated and instant pools share this boundary)
        HookrSwapRouter router = new HookrSwapRouter(PM, hook, address(0));

        // 4. wire + house blueprints
        pad.setHook(hook);
        _seedBlueprints(pad);

        vm.stopBroadcast();

        // 5. simulation readback assertions (no broadcast). Repeat these against the mined
        // addresses after verifying each receipt; they cannot roll back prior broadcasts.
        require(keccak256(bytes(pad.contractName())) == keccak256(bytes("HookrLaunchpad")), "pad identity wrong");
        require(keccak256(bytes(pad.contractVersion())) == keccak256(bytes("1.0.0")), "pad version wrong");
        require(keccak256(bytes(hook.contractName())) == keccak256(bytes("HookrHook")), "hook identity wrong");
        require(keccak256(bytes(hook.contractVersion())) == keccak256(bytes("1.0.0")), "hook version wrong");
        require(keccak256(bytes(router.contractName())) == keccak256(bytes("HookrSwapRouter")), "router identity wrong");
        require(keccak256(bytes(router.contractVersion())) == keccak256(bytes("1.0.0")), "router version wrong");
        require(address(pad.hook()) == address(hook), "hook not wired");
        require(uint160(address(hook)) & 0x3FFF == HOOK_FLAGS, "hook flags wrong");
        require(hook.launchpad() == address(pad), "hook launchpad wrong");
        require(address(hook.poolManager()) == address(PM), "hook PM wrong");
        require(address(router.poolManager()) == address(PM), "router PM wrong");
        require(address(router.hook()) == address(hook), "router hook wrong");
        require(pad.owner() == deployer, "owner wrong");
        require(pad.blueprintsCount() == 6, "blueprints missing"); // sentinel + 5
        require(pad.getBlueprint(2).params.guardBlocks == 100, "sniper slayer params wrong");

        // EIP-170. `forge test` does not enforce the deployed-code limit, so a contract that grows
        // past 24,576 bytes passes the entire suite and only reverts when the real CREATE runs.
        // That is exactly how an oversized launchpad reached a funded release wallet once already.
        // Assert it against the actually-deployed runtime, so a regression stops the simulation.
        require(address(pad).code.length <= MAX_RUNTIME_SIZE, "launchpad exceeds EIP-170");
        require(address(hook).code.length <= MAX_RUNTIME_SIZE, "hook exceeds EIP-170");
        require(address(router).code.length <= MAX_RUNTIME_SIZE, "router exceeds EIP-170");
        console2.log("HookrLaunchpad runtime size", address(pad).code.length);

        bytes32 padRuntimeCodehash = address(pad).codehash;
        bytes32 hookRuntimeCodehash = address(hook).codehash;
        bytes32 routerRuntimeCodehash = address(router).codehash;
        require(
            padRuntimeCodehash != bytes32(0) && hookRuntimeCodehash != bytes32(0)
                && routerRuntimeCodehash != bytes32(0),
            "runtime codehash missing"
        );

        // Print the candidate hash before enforcing the reviewed anchor. A contract change is
        // expected to stop here, but the no-broadcast simulation must still provide the exact
        // candidate hash reviewers need to reproduce and assess; deriving it is not approval.
        console2.log("HookrLaunchpad candidate runtime codehash");
        console2.logBytes32(padRuntimeCodehash);

        // The reviewed-build anchor, asserted rather than merely logged. run-canary.sh reads this
        // very constant out of this file, so there is exactly one copy of it in the repo; it used
        // to be duplicated there and in RELEASE.md, and both silently went two revisions stale.
        //
        // Asserting here moves the check to where it is cheap. The canary checks the same value,
        // but the canary runs AFTER the ten-transaction deploy has spent real ETH — a mismatch
        // discovered there is discovered too late. In simulation this costs nothing.
        //
        // A contract change is therefore meant to fail this until someone re-derives the hash and
        // reviews it. That friction is the point. Re-derive with a no-broadcast simulation (the
        // launchpad's `poolManager` immutable means the build artifact alone cannot produce it):
        //   forge script script/DeployRobinhood.s.sol \
        //     --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <deployer>
        require(padRuntimeCodehash == REVIEWED_PAD_RUNTIME_HASH, "launchpad is not the reviewed build");

        console2.log("HookrLaunchpad", address(pad));
        console2.log("HookrHook     ", address(hook));
        console2.log("HookrSwapRouter", address(router));
        console2.log("HookrLaunchpad runtime codehash");
        console2.logBytes32(padRuntimeCodehash);
        console2.log("HookrHook runtime codehash");
        console2.logBytes32(hookRuntimeCodehash);
        console2.log("HookrSwapRouter runtime codehash");
        console2.logBytes32(routerRuntimeCodehash);
    }

    function _mine(address deployer, bytes memory creation) internal view returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(creation);
        for (uint256 i = 0; i < 2_000_000; i++) {
            salt = bytes32(i);
            hookAddress =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            // EIP-684 rejects CREATE2 when either code or nonce already exists. Skipping occupied
            // targets prevents a collision from turning a reviewed sequence into a partial deploy.
            if (
                uint160(hookAddress) & 0x3FFF == HOOK_FLAGS && hookAddress.code.length == 0
                    && vm.getNonce(hookAddress) == 0
            ) {
                return (hookAddress, salt);
            }
        }
        revert("no salt");
    }

    function _seedBlueprints(HookrLaunchpad pad) internal {
        // 1: NTH-BUY POT — every 500th qualifying buy takes the whole deterministic pot
        pad.saveBlueprint(
            "Nth-buy Pot",
            HookrLaunchpad.HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000,
                maxFeePips: 0,
                surgeSens: 0,
                burnBps: 0,
                burnTriggerWei: 0,
                lpBps: 0,
                potBps: 50, // 0.5% of buys to the pot
                potEveryNBuys: 500, // every 500th qualifying buy
                potMinBuyWei: 0.01 ether
            }),
            500 // 5% of hook cuts to the author
        );
        // 2: SNIPER SLAYER — guard window + wallet cap + snipe tax
        pad.saveBlueprint(
            "Sniper Slayer",
            HookrLaunchpad.HookParams({
                guardBlocks: 100,
                maxBuyBps: 50, // 0.5% supply per swap
                snipeTaxPips: 400_000, // +40% during the guard
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
            0 // guard/tax behavior creates no native hook cut, so no royalty can accrue
        );
        // 3: AUTO BURN — token output is burned inline; no ETH cut exists to pay a royalty
        pad.saveBlueprint(
            "Auto Burn",
            HookrLaunchpad.HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000,
                maxFeePips: 0,
                surgeSens: 0,
                burnBps: 100, // 1% of buys
                burnTriggerWei: 0,
                lpBps: 0,
                potBps: 0,
                potEveryNBuys: 0,
                potMinBuyWei: 0
            }),
            0
        );
        // 4: SURGE FEES — fee scales with trade size vs pool depth
        pad.saveBlueprint(
            "Surge Fees",
            HookrLaunchpad.HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000, // 0.3% calm
                maxFeePips: 30_000, // 3% ceiling
                surgeSens: 5,
                burnBps: 0,
                burnTriggerWei: 0,
                lpBps: 0,
                potBps: 0,
                potEveryNBuys: 0,
                potMinBuyWei: 0
            }),
            0 // surge changes the LP fee only; it creates no native hook cut
        );
        // 5: LP LOYALTY — fee share donated to in-range LPs
        pad.saveBlueprint(
            "LP Loyalty",
            HookrLaunchpad.HookParams({
                guardBlocks: 0,
                maxBuyBps: 0,
                snipeTaxPips: 0,
                baseFeePips: 3000,
                maxFeePips: 0,
                surgeSens: 0,
                burnBps: 0,
                burnTriggerWei: 0,
                lpBps: 25, // 0.25% of buys donated to LPs
                potBps: 0,
                potEveryNBuys: 0,
                potMinBuyWei: 0
            }),
            400
        );
    }
}
