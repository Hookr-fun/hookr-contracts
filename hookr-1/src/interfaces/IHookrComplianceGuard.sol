// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrAdvisory} from "./IHookrAdvisory.sol";
import {IHookrCompliance} from "./IHookrCompliance.sol";

/// @title IHookrComplianceGuard
/// @notice Before-swap and liquidity advisory that admits only permitted identities into a pool. Exits never reach it.
/// @dev Schema: keccak256("ComplianceTerms(bytes32 listId,uint32 requireAll,uint32 blockAny,uint16 flags)")
///      = 0x99e0c588e47623dd1b3cc47a7b05be09b14d3403b34143c1a5a65b3eb14343e5. bind stores the terms under the caller
///      (bound[msg.sender][id]); beforeSwap returns Advice{0,0,0,reject}; afterSwap returns zero advice (that phase is
///      never admitted).
interface IHookrComplianceGuard is IHookrAdvisory {
    /// @notice Pool terms, frozen at bind. data = abi.encode(Terms).
    struct Terms {
        /// @notice The compliance list, or zero for sanctions only.
        bytes32 listId;
        /// @notice The tiers a credential must all hold.
        uint32 requireAll;
        /// @notice The tiers of which a credential must hold none.
        uint32 blockAny;
        /// @notice A bit set: 1 CHECK_BENEFICIARY (on by default) also checks the recipient; 2 KYC_ON_SELL makes
        ///         sellers need a credential; 4 HALT_SELLS_WHEN_SOURCE_DOWN stops sells when the external source fails;
        ///         8 RESTRICTED_SUBJECT marks a subject that enforces transfer restrictions; 16 ACCEPT_CURATED accepts
        ///         curated-router swaps; 32 DIRECT_LP_IF_PERMITTED allows adds from a permitted non-launcher sender.
        uint16 flags;
    }

    /// @notice Stored per (binder, pool). 3 slots: listId | launcher,requireAll,blockAny,flags,bound | curatedRouter
    struct Bound {
        /// @notice The compliance list, or zero for sanctions only.
        bytes32 listId;
        /// @notice The launcher that owns the pool's launch position.
        address launcher;
        /// @notice The tiers a credential must all hold.
        uint32 requireAll;
        /// @notice The tiers of which a credential must hold none.
        uint32 blockAny;
        /// @notice The terms' flag bit set.
        uint16 flags;
        /// @notice Whether the pool is bound.
        bool bound;
        /// @notice The root's curated router, or zero.
        address curatedRouter;
    }
    /// @notice Why the guard refused a swap or liquidity change, or NONE when it admits it.
    enum Reason {
        NONE,
        NOT_BOUND,
        UNAUTHENTICATED,
        CURATED_NOT_ACCEPTED,
        PAYER,
        BENEFICIARY,
        LP_SENDER,
        LP_OWNER,
        /// @dev A launcher's launch buy (HookrLauncher's dev buy), screened as the family owner, was refused.
        LAUNCH_BUY
    }

    /// @notice The constructor argument has no code or is an EIP-7702 delegated account.
    error InvalidCompliance(address compliance);

    /// @notice Returns the compliance registry.
    /// @return The compliance registry.
    function compliance() external view returns (address);
    /// @notice Returns the terms bound by `binder` for a pool.
    /// @param binder The root that bound the pool.
    /// @param id The pool.
    /// @return The terms bound for the pool.
    function terms(address binder, PoolId id) external view returns (Bound memory);
    /// @notice Explains the swap decision `binder` would receive from beforeSwap.
    /// @param binder The root that bound the pool.
    /// @param x The swap's context.
    /// @return allowed True when beforeSwap would admit the swap.
    /// @return reason Why it would refuse, or NONE.
    /// @return decision The compliance decision behind the reason.
    function explainSwap(address binder, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool allowed, Reason reason, IHookrCompliance.Decision decision);
    /// @notice Explains the liquidity decision `binder` would receive from beforeAddLiquidity.
    /// @param binder The root that bound the pool.
    /// @param id The pool.
    /// @param sender The liquidity provider calling the PoolManager.
    /// @return allowed True when beforeAddLiquidity would admit the add.
    /// @return reason Why it would refuse, or NONE.
    /// @return decision The compliance decision behind the reason.
    /// @return actor The identity the guard checked.
    function explainLiquidity(address binder, PoolId id, address sender)
        external
        view
        returns (bool allowed, Reason reason, IHookrCompliance.Decision decision, address actor);
    /// @notice Returns the shared release identity.
    /// @return The release id.
    function releaseId() external view returns (uint256);

    /// @notice A pool's terms were bound.
    /// @param binder The root that bound the pool.
    /// @param id The pool.
    /// @param listId The compliance list, or zero for sanctions only.
    /// @param requireAll The tiers a credential must all hold.
    /// @param blockAny The tiers of which a credential must hold none.
    /// @param flags The terms' flag bit set.
    /// @param launcher The launcher that owns the pool's launch position.
    /// @param curatedRouter The root's curated router, or zero.
    event ComplianceBound(
        address indexed binder,
        PoolId indexed id,
        bytes32 indexed listId,
        uint32 requireAll,
        uint32 blockAny,
        uint16 flags,
        address launcher,
        address curatedRouter
    );
    /// @notice Pool `id` is already bound by `binder`.
    error AlreadyBound(address binder, PoolId id);
    /// @notice The bound terms were refused.
    error InvalidTerms(uint8 field);
    /// @notice The pool's configuration cannot host the guard.
    error InvalidPoolConfig(uint8 field);
}
