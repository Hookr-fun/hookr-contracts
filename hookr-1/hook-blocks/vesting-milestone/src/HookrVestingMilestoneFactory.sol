// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrVestingMilestoneEscrow} from "./HookrVestingMilestoneEscrow.sol";
import {IHookrVestingMilestoneEscrow} from "./interfaces/IHookrVestingMilestoneEscrow.sol";
import {IHookrVestingLauncher} from "./interfaces/IHookrVestingLauncher.sol";

/// @title HookrVestingMilestoneFactory
/// @notice The one vesting-milestone contract that needs a permanent address. Deployed once through the CREATE3 factory at
///         a release id's `vesting-milestone-factory` role; every individual escrow (one per launch that wants a
///         vesting allocation) is then a CREATE2 deploy from here, keyed by the caller's own `salt` so the same
///         launch can be escrowed more than once on purpose (e.g. a second beneficiary tranche) but never by
///         accident with an identical tuple and salt.
/// @dev Permissionless: anyone can call `createEscrow`, exactly like anyone can already deploy
///      HookrVestingMilestoneEscrow directly by hand. The factory exists only so the release plan has one CREATE3
///      address to authorise and canary, and so every escrow this release produces is discoverable from one place
///      (`escrows`, `isEscrow`, `escrowsOf`) without indexing constructor calldata. It holds no funds, no owner
///      role and no registry admission. A CREATE2 collision (the same tuple and salt reused) reverts the deploy
///      through Solidity's own new-with-salt revert, so no duplicate ever silently overwrites another.
///
///      Pool binding: `createEscrow` deploys only an escrow whose milestones read a pool that `launcher` launched
///      on `launcher.poolManager()`, and whose PoolKey holds `subject` as one of its two currencies. So `isEscrow`
///      also means "gated on one of the subject's own Hookr pools". An escrow deployed by hand behaves the same
///      but is not bound, and is not listed.
///
///      Milestones: `createEscrow` refuses a nonzero liquidity bar, a nonzero volume bar and a nonzero time-in-range
///      bar until a hook-fed observation exists, so every listed escrow is pure cliff-then-linear vesting. A sampled
///      milestone sees the pool only at the instant of a sample, and the creator, as launcher family owner, controls
///      what a sample sees. A liquidity run is restarted by any one below-bar sample, so an LP holding more than
///      (pool liquidity - bar) in range can withdraw, sample and re-add in one block once a day. Time in range is
///      broken by any one out-of-band sample, so the family owner can withdraw, push the price past the band (for one
///      unit when its position was the pool's only liquidity), sample, push it back and re-add after each keeper
///      sample. Either keeps the milestone unmet for good, and with no lapse the allocation strands. Fee growth is a
///      wash-tradable proxy that never measures demand. The escrow refuses a raise that switches any milestone on, so
///      no listed escrow ever carries one. A hand-deployed escrow still can, and is not listed.
contract HookrVestingMilestoneFactory {
    using PoolIdLibrary for PoolKey;

    /// @notice The HookrLauncher whose pools an escrow listed here may be gated on.
    IHookrVestingLauncher public immutable launcher;
    /// @notice Every escrow this factory has deployed, in deployment order.
    address[] public escrows;

    /// @notice True for any address this factory deployed.
    mapping(address => bool) public isEscrow;

    /// @notice Every escrow this factory deployed for a given beneficiary.
    mapping(address => address[]) public escrowsOf;

    event EscrowCreated(
        address indexed escrow, address indexed owner, address indexed beneficiary, address subject, PoolId poolId
    );

    error InvalidLauncher();
    error WrongPoolManager(address given, address expected);
    error NotLauncherPool(PoolId poolId);
    error SubjectNotInPool(address subject, PoolId poolId);
    error LiquidityMilestoneRefused(uint128 liquidityThreshold);
    error VolumeMilestoneRefused(uint256 volumeThreshold);
    error TimeInRangeMilestoneRefused(uint32 timeInRangeSeconds);

    constructor(IHookrVestingLauncher launcher_) {
        if (address(launcher_) == address(0)) revert InvalidLauncher();
        launcher = launcher_;
    }

    /// @notice The PoolKey of `poolId` if `createEscrow` would accept it for `subject` on `poolManager`, otherwise
    ///         the revert `createEscrow` would raise: WrongPoolManager unless `poolManager` is the launcher's,
    ///         NotLauncherPool unless the launcher launched `poolId`, SubjectNotInPool unless `subject` is one of
    ///         that pool's currencies.
    function poolKeyFor(address subject, IPoolManager poolManager, PoolId poolId)
        public
        view
        returns (PoolKey memory key)
    {
        address expected = address(launcher.poolManager());
        if (address(poolManager) != expected) revert WrongPoolManager(address(poolManager), expected);
        bytes32 family = launcher.poolFamily(poolId);
        if (family == bytes32(0)) revert NotLauncherPool(poolId);
        uint8 count = launcher.memberCount(family);
        bool found;
        for (uint8 m; m < count; ++m) {
            key = launcher.position(family, m).key;
            if (PoolId.unwrap(key.toId()) == PoolId.unwrap(poolId)) {
                found = true;
                break;
            }
        }
        if (!found) revert NotLauncherPool(poolId);
        if (
            subject == address(0)
                || (Currency.unwrap(key.currency0) != subject && Currency.unwrap(key.currency1) != subject)
        ) {
            revert SubjectNotInPool(subject, poolId);
        }
    }

    /// @notice Deploys a new HookrVestingMilestoneEscrow with the given parameters at a CREATE2 address keyed by
    ///         `salt`. Reverts inside the escrow's own constructor if any config field is out of its MIN/MAX bound
    ///         (see HookrVestingMilestoneEscrow), and reverts on a `salt` collision with a prior deploy from this
    ///         factory, and reverts through `poolKeyFor` unless `poolId` is one of `subject`'s launcher pools, and
    ///         reverts LiquidityMilestoneRefused, VolumeMilestoneRefused or TimeInRangeMilestoneRefused unless all
    ///         three milestone bars are 0.
    function createEscrow(
        address owner,
        address beneficiary,
        address subject,
        IPoolManager poolManager,
        PoolId poolId,
        IHookrVestingMilestoneEscrow.Config calldata config,
        bytes32 salt
    ) external returns (address escrow) {
        poolKeyFor(subject, poolManager, poolId);
        if (config.liquidityThreshold != 0) revert LiquidityMilestoneRefused(config.liquidityThreshold);
        if (config.volumeThreshold != 0) revert VolumeMilestoneRefused(config.volumeThreshold);
        if (config.timeInRangeSeconds != 0) revert TimeInRangeMilestoneRefused(config.timeInRangeSeconds);
        escrow = address(
            new HookrVestingMilestoneEscrow{salt: salt}(owner, beneficiary, subject, poolManager, poolId, config)
        );

        escrows.push(escrow);
        isEscrow[escrow] = true;
        escrowsOf[beneficiary].push(escrow);
        emit EscrowCreated(escrow, owner, beneficiary, subject, poolId);
    }

    /// @notice Predicted CREATE2 address for `createEscrow` with these exact arguments, before calling it.
    function predictEscrow(
        address owner,
        address beneficiary,
        address subject,
        IPoolManager poolManager,
        PoolId poolId,
        IHookrVestingMilestoneEscrow.Config calldata config,
        bytes32 salt
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrVestingMilestoneEscrow).creationCode,
                abi.encode(owner, beneficiary, subject, poolManager, poolId, config)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Number of escrows this factory has deployed.
    function escrowCount() external view returns (uint256) {
        return escrows.length;
    }
}
