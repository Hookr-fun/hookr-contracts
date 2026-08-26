// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {IHookrUtilityToken} from "../src/libraries/HookrTokenTransfer.sol";

/*//////////////////////////////////////////////////////////////////////////////
                            V3 API DECLARATIONS
////////////////////////////////////////////////////////////////////////////////

Every V3 surface the staged canary touches is declared here as an interface this file owns rather
than imported from HookrLockRewardsV3/HookrLaunchBoostV3. The sources are now in contracts/src, so
this is no longer about keeping the build green — it is about what the canary is for.

The canary reads a DEPLOYED contract at an address supplied by the environment. Declaring the
expected call shapes here means the canary asserts against the API the release was reviewed
against, not against whatever the local tree currently compiles to. A source change that alters a
signature makes the canary fail at the call, which is the correct outcome; importing the concrete
contract would instead make the canary silently follow the source and prove nothing.

The declarations below match V2 exactly except for the launchpad set, which is V3's only
divergence: HookrLaunchBoostV3 binds an immutable, indexed set of up to MAX_LAUNCHPADS launchpad
generations instead of exactly one.
////////////////////////////////////////////////////////////////////////////////*/

interface IHookrV3CanaryToken is IHookrUtilityToken {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev The V3 lock vault surface the staged canary reads and writes.
interface IHookrLockRewardsV3Canary {
    struct Position {
        address owner;
        uint128 principal;
        uint128 weight;
        uint40 unlockAt;
        uint32 activationEpoch;
        uint32 expiryEpoch;
        uint32 lastClaimEpoch;
        uint8 tier;
        bool withdrawn;
    }

    function contractName() external view returns (string memory);
    function contractVersion() external view returns (string memory);
    function hookrToken() external view returns (address);

    function BOOTSTRAP_EPOCH_LENGTH() external view returns (uint40);
    function EPOCH_LENGTH() external view returns (uint40);
    function MONDAY_EPOCH_OFFSET() external view returns (uint40);
    function FIRST_WEEKLY_EPOCH() external view returns (uint32);

    function bootstrapStartedAt() external view returns (uint40);
    function feeEpochStartsAt() external view returns (uint40);
    function claimEpochStartsAt() external view returns (uint40);
    function weeklyEpochsStartAt() external view returns (uint40);

    function currentEpoch() external view returns (uint32);
    function epochStart(uint32 epoch) external view returns (uint40);
    function epochAt(uint40 timestamp) external view returns (uint32);
    function checkpointEpoch() external view returns (uint32);
    function checkpointCurrent() external view returns (bool);
    function currentEligibleWeight() external view returns (uint256);
    function scheduledWeightAdds(uint32 epoch) external view returns (uint256);
    function rewardIndexAtEpoch(uint32 epoch) external view returns (uint256);

    function tierConfig(uint8 tier) external pure returns (uint40 durationSeconds, uint16 multiplierBps);
    function previewLock(uint256 amount, uint8 tier)
        external
        view
        returns (uint256 weight, uint32 activationEpoch, uint32 expiryEpoch, uint40 unlockAt, uint16 multiplierBps);
    function lock(uint256 amount, uint8 tier, uint32 maxActivationEpoch, uint40 maxUnlockAt, uint256 deadline)
        external
        returns (uint256 positionId);
    function claim(uint256 positionId, address to) external returns (uint256 reward);

    function position(uint256 positionId) external view returns (Position memory);
    function positionCount() external view returns (uint256);
    function positionsOfCount(address owner) external view returns (uint256);
    function positionsOf(address owner, uint256 offset, uint256 limit) external view returns (uint256[] memory);

    function totalLockedPrincipal() external view returns (uint256);
    function rewardReserve() external view returns (uint256);
    function cumulativeBoostFeesNotified() external view returns (uint256);
    function cumulativeRewardsClaimed() external view returns (uint256);
    function solvency()
        external
        view
        returns (uint256 balance, uint256 principalLiability, uint256 rewardLiability, uint256 surplus, bool solvent);

    /// @notice The contract currently allowed to report realized Boost fees.
    function rewardSource() external view returns (address);

    /// @notice The one-shot deployment authority, burned to address(0) by `setRewardSourceOnce`.
    /// @dev Unchanged from V2. There is no admin, no propose/accept and no timelock: the wiring
    ///      transaction that points the sink also destroys the ability to re-point it. That is what
    ///      `_assertRewardSourceAuthorityBurned` below proves, and it is the ONLY consumer here.
    function configurator() external view returns (address);
}

/// @dev The V3 Boost surface the staged canary reads and writes.
interface IHookrLaunchBoostV3Canary {
    /// @dev Unchanged from V2: exactly one position per token, funded only by the launch creator,
    ///      so the position carries `creator` and `boostOf` is keyed by token alone.
    struct BoostPosition {
        address creator;
        uint128 principal;
        uint40 startedAt;
        uint40 unlockAt;
        uint40 startedAtBlock;
        uint8 tier;
    }

    function contractName() external view returns (string memory);
    function contractVersion() external view returns (string memory);
    function hookrToken() external view returns (address);
    function lockRewards() external view returns (address);

    /// @notice The immutable launchpad set, oldest generation first.
    /// @dev V3's only divergence from V2. The slots are immutable and are scanned from 0 upward, so
    ///      the index IS the resolution order. Slots at or above `launchpadCount` are zero and are
    ///      never read by the contract; the canary asserts that zero tail explicitly, because it is
    ///      what rules out an unreviewed extra boostable generation.
    function MAX_LAUNCHPADS() external view returns (uint8);
    function launchpadCount() external view returns (uint8);
    function launchpad0() external view returns (address);
    function launchpad1() external view returns (address);
    function launchpad2() external view returns (address);
    function launchpad3() external view returns (address);

    function BOOST_FEE_BPS() external view returns (uint16);
    function MIN_GROSS_BOOST() external view returns (uint256);

    /// @notice Unchanged from V2: the enumerated active-Boost registry is bounded at 512 slots.
    function MAX_ACTIVE_BOOSTS() external view returns (uint16);

    function boostingOpensAt() external view returns (uint40);
    function boostingOpen() external view returns (bool);

    function boostByIntent(
        bytes32 intentId,
        uint256 grossAmount,
        uint8 tier,
        uint256 maxRewardFee,
        uint256 minPrincipalAdded,
        uint256 deadline
    ) external returns (address token, uint256 principalAdded, uint256 rewardFee);

    function boostOf(address token) external view returns (BoostPosition memory);
    function scoreOf(address token) external view returns (uint256);
    function activePrincipalOf(address token) external view returns (uint256);

    function boostedTokensCount() external view returns (uint256);
    /// @dev Unchanged from V2: one-based index into the active registry, zeroed on removal, with
    ///      swap-removal of the tail. Token address, not array index, is the stable identity.
    function boostedTokenIndexPlusOne(address token) external view returns (uint16);
    function isBoostRegistered(address token) external view returns (bool);

    function totalBoostPrincipal() external view returns (uint256);
    function cumulativeGrossBoosted() external view returns (uint256);
    function cumulativePrincipalAdded() external view returns (uint256);
    function cumulativeFeesForwarded() external view returns (uint256);
    function solvency()
        external
        view
        returns (uint256 balance, uint256 principalLiability, uint256 surplus, bool solvent);
}

/// @dev Shared fail-closed identity, bootstrap-boundary and promoted-core linkage checks for the
///      three separately broadcast V3 canary stages. Mirrors HookrUtilityV2CanaryBase exactly;
///      only the version strings, env-var prefix and in-flight surfaces differ.
abstract contract HookrUtilityV3CanaryBase is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant LOCAL_REHEARSAL_CHAIN_ID = 31337;

    /// @dev The bootstrap epoch length the release was reviewed against. Every other bootstrap
    ///      boundary below is DERIVED from the live `BOOTSTRAP_EPOCH_LENGTH()` rather than
    ///      restating a literal, so this single line is the only place the expected value appears
    ///      and the boundary checks stay internally consistent if it is ever changed.
    uint40 internal constant EXPECTED_BOOTSTRAP_EPOCH_LENGTH = 2 hours;

    /// @dev V3 has NO minimum lock principal — that floor was considered and did not ship — so the
    ///      100 ether here is a deliberate canary choice, not a contract requirement: it makes the
    ///      canary lock the same order as the canary Boost, so the stage-three pro-rata claim is a
    ///      meaningful number rather than dust. V2 locked 1 ether, so the deployer needs 200 HOOKR
    ///      on hand for a full run (100 to lock + 100 to Boost), not the 101 V2 needed. Mirrored as
    ///      `lockGross` in scripts/lib/utility-v3-canary-evidence.mjs; change both together.
    uint256 internal constant CANARY_LOCK_GROSS = 100 ether;
    uint256 internal constant CANARY_BOOST_GROSS = 100 ether;
    uint256 internal constant CANARY_FEE = 1 ether;
    uint256 internal constant CANARY_PRINCIPAL = 99 ether;
    uint256 internal constant CANARY_DEADLINE_WINDOW = 10 minutes;
    /// @dev Guard against a stage straddling an epoch boundary and settling in the wrong epoch.
    ///      V2 used 45 minutes, which was a third of its 2-hour bootstrap epoch. V3's bootstrap
    ///      epochs are 15 minutes, so a 45-minute margin can never be satisfied — it exceeds the
    ///      whole epoch. 4 minutes keeps the same protection: Robinhood Chain produces blocks about
    ///      every 0.1s, so this is roughly 2,400 blocks of headroom for a stage that confirms in
    ///      seconds, while still leaving 11 of the 15 minutes usable.
    uint256 internal constant CANARY_MIN_STAGE_REMAINING = 45 minutes;
    uint8 internal constant CANARY_TIER = 0;
    bytes32 internal constant CORE_CANARY_INTENT = keccak256("hookr.v4.canary.instant.all-five.1");

    address internal constant EXPECTED_DEPLOYER = 0x5a52D4B820Ae7F02880d270562950918ACb14aA2;
    address internal constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    bytes32 internal constant REVIEWED_HOOKR_RUNTIME_CODEHASH =
        0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d;

    struct UtilityContracts {
        IHookrV3CanaryToken token;
        IHookrLockRewardsV3Canary rewards;
        IHookrLaunchBoostV3Canary boost;
        HookrLaunchpad launchpad;
    }

    function _loadUtilityContracts() internal view returns (UtilityContracts memory u) {
        bool rehearsal = block.chainid == LOCAL_REHEARSAL_CHAIN_ID && vm.envOr("HOOKR_UTILITY_V3_REHEARSAL", false);
        require(block.chainid == ROBINHOOD_CHAIN_ID || rehearsal, "wrong chain or rehearsal mode");

        u.token = IHookrV3CanaryToken(HOOKR_TOKEN);
        u.rewards = IHookrLockRewardsV3Canary(vm.envAddress("HOOKR_UTILITY_V3_LOCK_REWARDS_ADDRESS"));
        u.boost = IHookrLaunchBoostV3Canary(vm.envAddress("HOOKR_UTILITY_V3_LAUNCH_BOOST_ADDRESS"));
        u.launchpad = HookrLaunchpad(payable(vm.envAddress("HOOKR_UTILITY_V3_LAUNCHPAD_ADDRESS")));

        bytes32 expectedRewardsHash = vm.envBytes32("HOOKR_UTILITY_V3_LOCK_REWARDS_RUNTIME_CODEHASH");
        bytes32 expectedBoostHash = vm.envBytes32("HOOKR_UTILITY_V3_LAUNCH_BOOST_RUNTIME_CODEHASH");
        bytes32 expectedLaunchpadHash = vm.envBytes32("HOOKR_UTILITY_V3_LAUNCHPAD_RUNTIME_CODEHASH");
        require(
            expectedRewardsHash != bytes32(0) && expectedBoostHash != bytes32(0) && expectedLaunchpadHash != bytes32(0),
            "runtime hash missing"
        );
        require(address(u.rewards).codehash == expectedRewardsHash, "LockRewards runtime wrong");
        require(address(u.boost).codehash == expectedBoostHash, "LaunchBoost runtime wrong");
        require(address(u.launchpad).codehash == expectedLaunchpadHash, "launchpad runtime wrong");

        if (rehearsal) {
            bytes32 rehearsalTokenHash = vm.envBytes32("HOOKR_UTILITY_V3_TOKEN_RUNTIME_CODEHASH");
            require(
                rehearsalTokenHash != bytes32(0) && HOOKR_TOKEN.codehash == rehearsalTokenHash, "token runtime wrong"
            );
        } else {
            require(HOOKR_TOKEN.codehash == REVIEWED_HOOKR_RUNTIME_CODEHASH, "HOOKR runtime wrong");
            require(
                keccak256(bytes(u.launchpad.contractName())) == keccak256(bytes("HookrLaunchpad")),
                "launchpad identity wrong"
            );
            require(
                keccak256(bytes(u.launchpad.contractVersion())) == keccak256(bytes("1.0.0")), "launchpad version wrong"
            );
        }

        require(
            keccak256(bytes(u.rewards.contractName())) == keccak256(bytes("HookrLockRewards")),
            "LockRewards identity wrong"
        );
        require(keccak256(bytes(u.rewards.contractVersion())) == keccak256(bytes("3")), "LockRewards version wrong");
        require(
            keccak256(bytes(u.boost.contractName())) == keccak256(bytes("HookrLaunchBoost")),
            "LaunchBoost identity wrong"
        );
        require(keccak256(bytes(u.boost.contractVersion())) == keccak256(bytes("3")), "LaunchBoost version wrong");
        require(u.rewards.hookrToken() == HOOKR_TOKEN, "LockRewards token wrong");
        require(u.boost.hookrToken() == HOOKR_TOKEN, "LaunchBoost token wrong");
        require(u.boost.lockRewards() == address(u.rewards), "LaunchBoost rewards wrong");
        _assertLaunchpadSet(u.boost, address(u.launchpad));
        require(u.boost.MIN_GROSS_BOOST() == CANARY_BOOST_GROSS, "LaunchBoost minimum wrong");
        require(u.boost.MAX_ACTIVE_BOOSTS() == 512, "LaunchBoost capacity wrong");
        require(u.rewards.rewardSource() == address(u.boost), "reward source wrong");
        _assertRewardSourceAuthorityBurned(u.rewards);
        require(u.rewards.BOOTSTRAP_EPOCH_LENGTH() == EXPECTED_BOOTSTRAP_EPOCH_LENGTH, "bootstrap epoch length wrong");
        require(u.rewards.FIRST_WEEKLY_EPOCH() == 3, "first weekly epoch wrong");
        _assertBootstrapBoundaries(u.rewards);
        require(u.boost.boostingOpensAt() == u.rewards.feeEpochStartsAt(), "boost opening boundary wrong");
        require(
            u.boost.boostingOpen() == (block.timestamp >= u.rewards.feeEpochStartsAt()), "boost opening state wrong"
        );
    }

    /// @dev The single consumer of the reward-source authority surface.
    ///
    ///      The one-shot configurator is burned to address(0) by the wiring transaction, so "no one
    ///      can ever repoint the fee sink" is provable from this one read. That is what makes
    ///      `policy.upgradeable === false` in the release manifest a proven property rather than an
    ///      asserted one.
    function _assertRewardSourceAuthorityBurned(IHookrLockRewardsV3Canary rewards) internal view {
        require(rewards.configurator() == address(0), "configurator not burned");
    }

    /// @dev Read one immutable launchpad slot. Slots are fixed at construction and scanned from 0
    ///      upward, so the index is the resolution order.
    function _launchpadSlot(IHookrLaunchBoostV3Canary boost, uint256 slot) internal view returns (address) {
        if (slot == 0) return boost.launchpad0();
        if (slot == 1) return boost.launchpad1();
        if (slot == 2) return boost.launchpad2();
        return boost.launchpad3();
    }

    /// @dev Prove the deployed launchpad set is exactly the reviewed one.
    ///
    ///      The canary runs against a live deployment whose address comes from the environment, and
    ///      it must also work in a loopback rehearsal where every address is freshly minted, so the
    ///      set is checked structurally rather than against pinned mainnet addresses:
    ///
    ///        * the populated slots are non-zero and pairwise distinct,
    ///        * the slots at and above `launchpadCount` are zero — this is the check that rules out
    ///          an extra, unreviewed boostable generation hiding in the tail,
    ///        * the NEWEST populated slot is the promoted core launchpad this canary transacts
    ///          against, which pins the position and therefore the resolution order, not just
    ///          membership.
    ///
    ///      The exact mainnet set and its ordering are pinned separately, in the deploy script's
    ///      constructor arguments and in the two JS verifiers.
    function _assertLaunchpadSet(IHookrLaunchBoostV3Canary boost, address expectedNewest) internal view {
        uint8 maxLaunchpads = boost.MAX_LAUNCHPADS();
        require(maxLaunchpads == 4, "LaunchBoost MAX_LAUNCHPADS wrong");
        uint8 count = boost.launchpadCount();
        require(count != 0 && count <= maxLaunchpads, "LaunchBoost launchpad count wrong");

        for (uint256 i; i < maxLaunchpads; ++i) {
            address slot = _launchpadSlot(boost, i);
            if (i >= count) {
                require(slot == address(0), "LaunchBoost launchpad tail not empty");
                continue;
            }
            require(slot != address(0), "LaunchBoost launchpad slot empty");
            require(slot.code.length != 0, "LaunchBoost launchpad slot has no code");
            for (uint256 j; j < i; ++j) {
                require(_launchpadSlot(boost, j) != slot, "LaunchBoost launchpad set has a duplicate");
            }
        }
        require(_launchpadSlot(boost, count - 1) == expectedNewest, "LaunchBoost newest launchpad wrong");
    }

    function _assertBootstrapBoundaries(IHookrLockRewardsV3Canary rewards) internal view {
        uint40 bootstrapLength = rewards.BOOTSTRAP_EPOCH_LENGTH();
        uint40 startedAt = rewards.bootstrapStartedAt();
        uint40 feeStart = rewards.feeEpochStartsAt();
        uint40 claimStart = rewards.claimEpochStartsAt();
        uint40 weeklyStart = rewards.weeklyEpochsStartAt();
        require(feeStart == startedAt + bootstrapLength, "fee boundary wrong");
        require(claimStart == feeStart + bootstrapLength, "claim boundary wrong");
        uint256 weeklyNumber = (uint256(claimStart) - 4 days) / 7 days + 1;
        require(weeklyStart == 4 days + weeklyNumber * 7 days, "weekly boundary wrong");
        require(rewards.epochStart(0) == startedAt, "epoch zero boundary wrong");
        require(rewards.epochStart(1) == feeStart, "epoch one boundary wrong");
        require(rewards.epochStart(2) == claimStart, "epoch two boundary wrong");
        require(rewards.epochStart(3) == weeklyStart, "epoch three boundary wrong");
    }

    function _requireStageRemaining(uint40 boundary) internal view {
        require(uint256(boundary) >= block.timestamp + CANARY_MIN_STAGE_REMAINING, "less than the stage margin remains");
    }

    function _canaryPosition(IHookrLockRewardsV3Canary rewards)
        internal
        view
        returns (uint256 positionId, IHookrLockRewardsV3Canary.Position memory p)
    {
        require(rewards.positionsOfCount(EXPECTED_DEPLOYER) == 1, "canary owner position missing");
        uint256[] memory ids = rewards.positionsOf(EXPECTED_DEPLOYER, 0, 2);
        require(ids.length == 1 && ids[0] != 0, "canary position id wrong");
        positionId = ids[0];
        p = rewards.position(positionId);
        require(p.owner == EXPECTED_DEPLOYER, "canary position owner wrong");
        require(p.principal == CANARY_LOCK_GROSS && p.weight == CANARY_LOCK_GROSS, "canary lock amount wrong");
        require(p.activationEpoch == 1, "canary activation epoch wrong");
        require(p.tier == CANARY_TIER && !p.withdrawn, "canary lock state wrong");
    }

    function _canonicalLaunchToken(HookrLaunchpad launchpad) internal view returns (address token) {
        token = launchpad.launchedByIntent(EXPECTED_DEPLOYER, CORE_CANARY_INTENT);
        require(token != address(0), "core canary token missing");
        HookrLaunchpad.Launch memory launch = launchpad.getLaunch(token);
        require(launch.token == token, "core canary launch mismatch");
        require(launch.creator == EXPECTED_DEPLOYER, "core canary creator wrong");
        require(launch.graduated && launch.graduatedAtBlock == launch.launchBlock, "core canary not instant");
    }
}
