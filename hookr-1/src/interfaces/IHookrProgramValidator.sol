// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrProgramTypes} from "../types/HookrProgramTypes.sol";

/// @title IHookrProgramValidator
/// @notice Interface for HookrProgramValidator, the stateless creation checks of HookrPrograms.
interface IHookrProgramValidator {
    /// @notice The program's terms, milestones or metadata are invalid.
    error InvalidProgram();
    /// @notice A scope is not a market the router's registry knows, or its rates are invalid.
    error InvalidScope();

    /// @notice Immediate receipts carry the raw quote fill, which a payer can recover with an exact-output buy and a
    ///         self-owned in-range position. Unreviewed Immediate activity may therefore back creator points only:
    ///         no cash, no global Bux and no milestone NFTs.
    error ImmediateValueUnreviewed(uint256 cashBudget, bool globalBux, uint256 milestones);

    /// @notice Validate immutable terms, registered market scopes, rates, ordered milestone limits and bounded
    ///         collection metadata.
    /// @param t The program's terms.
    /// @param sources The program's market scopes.
    /// @param milestones The program's milestones.
    /// @param metadata The milestone collection's metadata.
    /// @param manager The PoolManager the scopes' roots must report.
    /// @param router The Programs contract's pinned router; its registry decides which roots are real.
    /// @param lp Whether the program counts earned LP fees, which the scopes' pools must support.
    function validate(
        HookrProgramTypes.Terms calldata t,
        HookrProgramTypes.Scope[] calldata sources,
        HookrProgramTypes.Milestone[] calldata milestones,
        HookrProgramTypes.NFTMetadata calldata metadata,
        address manager,
        address router,
        bool lp
    ) external view;
}
