// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HookrLaunchpadLib} from "./libraries/HookrLaunchpadLib.sol";

/// @title HookrBlueprints
/// @notice The reusable hook configurations ("blueprints") any author can publish, split out of
///         HookrLaunchpad for its EIP-170 budget exactly like the shared math library. Launching
///         against a blueprint routes a share of that pool's hook fees to the author (royalty);
///         the launchpad resolves the params through `resolveForLaunch` at launch time.
/// @dev Append-only by construction: there is no edit, no delete, and no owner override over a
///      saved blueprint's behavior. The only owner-shaped power is the finite house-seeding gate:
///      ids are reserved so the launchpad CREATE and five reviewed house saves cannot be front-run
///      in the mempool between deployment transactions. Once six entries exist, authoring is
///      permissionless forever.
contract HookrBlueprints {
    uint256 internal constant FIRST_PUBLIC_BLUEPRINT_ID = 6;
    uint96 internal constant MAX_ROYALTY_BPS = 1000;

    struct Blueprint {
        address author;
        uint16 royaltyBps; // share of LP/pot cuts routed to the author
        uint32 uses;
        uint40 savedAtBlock;
        string name;
        HookrLaunchpadLib.HookParams params;
    }

    Blueprint[] internal blueprints;
    address public immutable authority;

    event BlueprintSaved(uint32 indexed id, address indexed author, string name, uint16 royaltyBps);

    error BadLaunchArgs();
    error BadHookParams();
    error HouseBlueprintsPending();
    error RoyaltyTooHigh();

    constructor(address authority_) {
        // Sentinel id 0 is the "custom stack" entry; nothing stores it, it simply does not exist,
        // which is what makes `blueprintId == 0` mean "use the caller's custom params".
        blueprints.push();
        authority = authority_;
    }

    /// @notice Stable deployment identity for post-deploy readbacks and agent health checks.
    function contractName() external pure returns (string memory) {
        return "HookrBlueprints";
    }

    /// @notice Candidate generation. Runtime code hash remains the release authority.
    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function saveBlueprint(string calldata name, HookrLaunchpadLib.HookParams calldata params, uint16 royaltyBps)
        external
        returns (uint32 id)
    {
        if (blueprints.length < FIRST_PUBLIC_BLUEPRINT_ID && msg.sender != authority) {
            revert HouseBlueprintsPending();
        }
        if (bytes(name).length == 0 || bytes(name).length > 48) revert BadLaunchArgs();
        if (royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        HookrLaunchpadLib.validateHookParams(params);
        // Auto Burn, anti-snipe, and surge fees do not create a native hook cut. Reject a
        // royalty that could never accrue instead of letting a blueprint advertise phantom
        // economics. LP, pot, and buyback cuts are the revenue-bearing Hookr blocks.
        if (royaltyBps > 0 && uint256(params.lpBps) + params.potBps == 0) {
            revert BadHookParams();
        }
        id = uint32(blueprints.length);
        blueprints.push(
            Blueprint({
                author: msg.sender,
                royaltyBps: royaltyBps,
                uses: 0,
                savedAtBlock: uint40(block.number),
                name: name,
                params: params
            })
        );
        emit BlueprintSaved(id, msg.sender, name, royaltyBps);
    }

    function blueprintsCount() external view returns (uint256) {
        return blueprints.length;
    }

    function getBlueprint(uint32 id) external view returns (Blueprint memory) {
        return blueprints[id];
    }

    /// @notice Resolve a blueprint for an in-flight launch: the params to configure the pool
    ///         with, plus the author's royalty routing. Bumps the lifetime use counter.
    /// @dev Reverts on an unknown id so a mistyped `blueprintId` fails the launch instead of
    ///      silently launching with empty params. Callers keep their own `BadLaunchArgs` shape.
    function resolveForLaunch(uint32 id)
        external
        returns (address author, uint16 royaltyBps, HookrLaunchpadLib.HookParams memory params)
    {
        Blueprint storage bp = blueprints[id];
        if (bp.author == address(0)) revert BadLaunchArgs();
        bp.uses += 1;
        return (bp.author, bp.royaltyBps, bp.params);
    }

    /// @notice The royalty routing a launch using `id` must configure into its pool.
    function feeSplitOf(uint32 id) external view returns (uint16 royaltyBps, address royaltyTo) {
        Blueprint storage bp = blueprints[id];
        return (bp.royaltyBps, bp.author);
    }
}
