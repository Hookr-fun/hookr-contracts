// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrPrograms} from "../engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../interfaces/IHookrPrograms.sol";
import {HookrProgramTypes as P} from "../types/HookrProgramTypes.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRouter} from "../interfaces/IHookrRouter.sol";

/// @title HookrProgramsAdmin
/// @notice HookrPrograms' cold paths: the owner's Hookr Bux approval (a proposal, a fixed wait, then the approval that
///         reserves the program's complete point budget, or a veto by the owner or the Hookr registry's guardian that
///         voids the proposal) and milestone NFT delivery.
/// @dev Deployed as an external (linked) library so HookrPrograms stays under the EIP-170 runtime limit: the release
///      deploys it through CREATE3 and links it into HookrPrograms' bytecode before HookrPrograms is deployed.
///      HookrPrograms reaches it by DELEGATECALL after its own checks (the owner for the Bux paths; the recipient
///      rule, reentrancy and the program's existence for a delivery), so every function reads and writes the storage
///      it is passed, `address(this)` is HookrPrograms and every event is logged by HookrPrograms. The events and
///      errors are HookrPrograms' own, declared again here to be emitted and raised.
library HookrProgramsAdmin {
    /// @dev HookrPrograms.BUX_APPROVAL_DELAY.
    uint256 internal constant BUX_APPROVAL_DELAY = 30 minutes;
    /// @dev HookrPrograms.BUX_APPROVAL_GRACE.
    uint256 internal constant BUX_APPROVAL_GRACE = 14 days;

    event BuxProgramProposed(uint256 indexed id, uint256 readyAt, uint256 expiresAt);
    event BuxProgramVetoed(uint256 indexed id, address indexed by);
    event BuxProgramApproved(uint256 indexed id, uint256 reserved);
    event NFTDelivered(uint256 indexed id, address indexed beneficiary, uint256 indexed milestone, address to);

    error InvalidProgram();
    error BudgetExceeded();
    error BuxApprovalNotReady(uint256 id, uint256 readyAt);
    error BuxApprovalExpired(uint256 id, uint256 expiredAt);
    error BuxApprovalPending(uint256 id, uint256 readyAt);
    error NothingToClaim();
    /// @dev Ownable's error, raised for a veto by neither the owner nor the guardian.
    error OwnableUnauthorizedAccount(address account);

    /// @notice Records a proposal to approve program `id`, executable from BUX_APPROVAL_DELAY after now until
    ///         BUX_APPROVAL_GRACE after that. Refuses a program without Bux, an approved one, one already started and
    ///         one whose earlier proposal is still pending or approvable.
    /// @param p The program.
    /// @param readyAt HookrPrograms.buxApprovalReadyAt.
    /// @param id The program id.
    function proposeBux(IHookrPrograms.Program storage p, mapping(uint256 => uint256) storage readyAt, uint256 id)
        external
    {
        if (!p.terms.globalBux || p.buxApproved || block.timestamp >= p.terms.start) revert InvalidProgram();
        uint256 ready = readyAt[id];
        if (ready != 0 && block.timestamp <= ready + BUX_APPROVAL_GRACE) revert BuxApprovalPending(id, ready);
        ready = block.timestamp + BUX_APPROVAL_DELAY;
        readyAt[id] = ready;
        emit BuxProgramProposed(id, ready, ready + BUX_APPROVAL_GRACE);
    }

    /// @notice Voids program `id`'s pending proposal, for HookrPrograms' owner or the guardian of its trusted router's
    ///         registry.
    /// @dev Reads both from HookrPrograms (`address(this)` under the DELEGATECALL) through its own getters, so the
    ///      veto costs HookrPrograms no code. The owner is checked first, so a guardian read that reverts never stops
    ///      the owner's veto; a read that reverts, or a guardian of zero, means no guardian. Any other caller is
    ///      refused with Ownable's error.
    /// @param readyAt HookrPrograms.buxApprovalReadyAt.
    /// @param id The program id.
    function vetoBux(mapping(uint256 => uint256) storage readyAt, uint256 id) external {
        HookrPrograms programs = HookrPrograms(address(this));
        if (msg.sender != programs.owner() && msg.sender != _guardian(programs.trustedRouter())) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        if (readyAt[id] == 0) revert BuxApprovalNotReady(id, 0);
        delete readyAt[id];
        emit BuxProgramVetoed(id, msg.sender);
    }

    /// @dev The guardian of `router`'s registry, read now; zero when either read reverts.
    function _guardian(address router) private view returns (address guardian) {
        try IHookrRouter(router).registry() returns (IHookrRegistry registry) {
            try registry.guardian() returns (address account) {
                guardian = account;
            } catch {}
        } catch {}
    }

    /// @notice Executes program `id`'s ready proposal: marks the program approved, consumes the proposal and returns
    ///         the point budget the caller adds to its Bux reservation. Refuses a program without Bux, an approved
    ///         one, one already started, a proposal not ready or expired, and a budget above `room`.
    /// @param p The program.
    /// @param readyAt HookrPrograms.buxApprovalReadyAt.
    /// @param id The program id.
    /// @param room The unreserved Bux supply: HookrPrograms' buxSupplyCap - buxReserved.
    /// @return budget The program's point budget, now reserved.
    function approveBux(
        IHookrPrograms.Program storage p,
        mapping(uint256 => uint256) storage readyAt,
        uint256 id,
        uint256 room
    ) external returns (uint256 budget) {
        if (!p.terms.globalBux || p.buxApproved || block.timestamp >= p.terms.start) {
            revert InvalidProgram();
        }
        uint256 ready = readyAt[id];
        if (ready == 0 || block.timestamp < ready) revert BuxApprovalNotReady(id, ready);
        if (block.timestamp > ready + BUX_APPROVAL_GRACE) revert BuxApprovalExpired(id, ready + BUX_APPROVAL_GRACE);
        budget = p.terms.pointBudget;
        if (budget > room) revert BudgetExceeded();
        delete readyAt[id];
        p.buxApproved = true;
        emit BuxProgramApproved(id, budget);
    }

    /// @notice Delivers `beneficiary`'s reserved NFT for `milestone` of program `id` to `to` through the collection's
    ///         `mintReserved`, with at most 300,000 gas. A mint that reverts unmarks the delivery and returns false,
    ///         so it stays retryable.
    /// @param p The program.
    /// @param milestones HookrPrograms' milestones by program.
    /// @param reserved HookrPrograms.reservedNFT.
    /// @param delivered HookrPrograms.deliveredNFT.
    /// @param id The program id.
    /// @param beneficiary The wallet that earned the milestone.
    /// @param milestone The milestone index.
    /// @param to The NFT's recipient.
    /// @return Whether the NFT was minted.
    function deliverMilestone(
        IHookrPrograms.Program storage p,
        mapping(uint256 => P.Milestone[]) storage milestones,
        mapping(
            uint256 => mapping(address => mapping(uint256 => uint256))
        ) storage reserved,
        mapping(uint256 => mapping(address => uint256)) storage delivered,
        uint256 id,
        address beneficiary,
        uint256 milestone,
        address to
    ) external returns (bool) {
        if (milestone >= milestones[id].length) revert NothingToClaim();
        uint256 tokenId = reserved[id][beneficiary][milestone];
        uint256 bit = uint256(1) << milestone;
        if (tokenId == 0 || delivered[id][beneficiary] & bit != 0) revert NothingToClaim();
        delivered[id][beneficiary] |= bit;
        try p.collection.mintReserved{gas: 300_000}(to, tokenId) {
            emit NFTDelivered(id, beneficiary, milestone, to);
            return true;
        } catch {
            delivered[id][beneficiary] &= ~bit;
            return false;
        }
    }
}
