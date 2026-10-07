// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Hookr swap reward minter
/// @notice One frozen reward programme: a reward asset, a rate, a per-swap cap and a lifetime cap, funded only by
///         quote claims that Hookr Rules credited to the programme's reward accounts.
interface IHookrSwapRewardMinter {
    /// @notice Who a slice is attributed to and who receives the reward.
    /// @dev TRADER: the advisory names the reward account of the swap's authenticated payer; unauthenticated
    ///      swaps (generic routers) pay no slice. FIXED: the advisory names the account of one frozen address for
    ///      every swap. SIDECAR: no advisory binds the programme; it consumes whatever claims another source
    ///      (a Rules royalty or another advisory's take) credits to the fixed address's account.
    enum Mode {
        TRADER,
        FIXED,
        SIDECAR
    }

    /// @notice The creator's frozen programme choices. Validated once in the minter constructor.
    /// @param rules The HookrRules instance that credits the funding claims.
    /// @param quote The quote currency of the funding claims; address zero is native.
    /// @param poolId The pool whose advisory funds the programme. Enforced at advisory bind; informational in SIDECAR.
    /// @param advisory The advisory allowed to bind the programme; zero in SIDECAR.
    /// @param mode Attribution mode, see `Mode`.
    /// @param fixedRecipient The reward recipient in FIXED and SIDECAR; zero in TRADER.
    /// @param rewardToken The asset minted as the reward; must implement `IHookrRewardMintTarget`.
    /// @param creatorRecipient Receives the creator part of every funded slice.
    /// @param buyTakePips The reward slice on buys, pips of the quote leg: zero (buys pay nothing and earn nothing)
    ///        or 1..50,000 (5%). Zero in SIDECAR.
    /// @param sellTakePips The reward slice on sells, pips of the quote output: zero (sells pay nothing and earn
    ///        nothing) or 1..50,000 (5%). Exact-input sells pay it in both modes; exact-output sells pay it in FIXED
    ///        mode only. At least one side is nonzero outside SIDECAR; both zero in SIDECAR.
    /// @param rewardPerQuoteWad Reward units minted per raw quote unit of slice, scaled by 1e18.
    /// @param maxRewardPerSwap Reward-unit ceiling one swap's slice can fund.
    /// @param lifetimeRewardCap Reward-unit ceiling over the programme's life.
    /// @param mintGasLimit Gas stipend of each `mintReward` call.
    /// @param endsAt Timestamp from which swaps stop paying the slice; zero runs until the lifetime cap is spent.
    ///        Settlement is unaffected: slices paid before `endsAt` are still settled and rewarded. Zero in SIDECAR.
    struct Params {
        address rules;
        Currency quote;
        PoolId poolId;
        address advisory;
        Mode mode;
        address fixedRecipient;
        address rewardToken;
        address creatorRecipient;
        uint24 buyTakePips;
        uint24 sellTakePips;
        uint256 rewardPerQuoteWad;
        uint256 maxRewardPerSwap;
        uint256 lifetimeRewardCap;
        uint32 mintGasLimit;
        uint40 endsAt;
    }

    /// @notice Returns the advisory allowed to bind this programme, or zero for a sidecar.
    function advisory() external view returns (address);

    /// @notice Returns the pool this programme is declared for.
    function poolId() external view returns (PoolId);

    /// @notice Returns the HookrRules instance whose claims fund the programme.
    function rules() external view returns (address);

    /// @notice Returns the quote currency of the funding claims.
    function quote() external view returns (Currency);

    /// @notice Returns the attribution mode.
    function mode() external view returns (Mode);

    /// @notice Returns the frozen reward slice on buys in pips; zero when buys are not charged.
    function buyTakePips() external view returns (uint24);

    /// @notice Returns the frozen reward slice on sells in pips; zero when sells are not charged.
    function sellTakePips() external view returns (uint24);

    /// @notice Returns the recipient of the protocol part of every funded slice.
    function protocolRecipient() external view returns (address);

    /// @notice Returns the timestamp from which swaps stop paying the slice, or zero for no end.
    function endsAt() external view returns (uint40);

    /// @notice Returns whether the reward asset currently accepts this minter.
    function rewardReady() external view returns (bool);

    /// @notice Returns the reward account that the next slice of this swap identity is credited to and how much
    ///         quote slice one swap may still pay. Zero room means "charge nothing".
    /// @dev Called by the advisory with a bounded STATICCALL on the swap path.
    function quoteRoom(address payer, bool authenticated) external view returns (address recipient, uint256 room);

    /// @notice Returns the deterministic reward account of `beneficiary` under this minter.
    function accountOf(address beneficiary) external view returns (address);
}
