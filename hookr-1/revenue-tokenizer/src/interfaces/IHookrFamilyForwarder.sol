// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr family forwarder, part of the HookRevenue Tokenizer
/// @notice The beneficiary of every HookrLauncher family locked for one revenue token in the live HookrFamilyLock. It pulls
///         what the lock lets a beneficiary take (LP fees and arb recapture accruals, never principal) and forwards it
///         to the revenue token, whose next sync recognizes it. At a family's unlock block anyone may release it to the
///         account the tokenizer recorded, after a final pull.
/// @dev One forwarder per revenue token; it may hold several families (the launched family and the token's own market
///      pool). Families are registered only by the tokenizer, only while it creates the token. The forwarder never
///      holds a revenue token: fees paid in the revenue token itself (the market pool's subject side) go to 0xdead, which
///      earns nothing, so every other holder's share grows. It holds no asset between calls except ERC-6909 claims a
///      release leaves it, which `flushClaims` redeems.
interface IHookrFamilyForwarder {
    /// @notice One locked family.
    /// @param id The family.
    /// @param unlockBlock The parent block from which it can be released; type(uint64).max never.
    /// @param returnTo The account the family is released to.
    /// @param released Whether it was released.
    struct Family {
        bytes32 id;
        uint64 unlockBlock;
        address returnTo;
        bool released;
    }

    /// @notice A constructor argument has no code, or a family is registered twice.
    error InvalidConfig();
    /// @notice Only the tokenizer registers families.
    error Unauthorized(address caller);
    /// @notice The lock does not hold `familyId` for this forwarder.
    error NotLockedHere(bytes32 familyId);
    /// @notice `index` is past the last registered family.
    error UnknownFamily(uint256 index);
    /// @notice `familyId` releases at parent block `unlockBlock`, not before.
    error StillLocked(bytes32 familyId, uint256 unlockBlock);
    /// @notice `familyId` was already released.
    error AlreadyReleased(bytes32 familyId);
    /// @notice A family cannot be released to the zero address.
    error InvalidReturnTo(address returnTo);
    /// @notice The call re-entered the forwarder.
    error Reentered();
    /// @notice `asset` is native ETH, one of the token's assets or the revenue token: `pull` forwards those.
    error ListedAsset(address asset);
    /// @notice The forwarder holds nothing of `asset`, or its balance cannot be read.
    error NothingToForward(address asset);
    /// @notice `asset` refused the transfer to the revenue token.
    error ForwardRefused(address asset);

    /// @notice The address revenue-token fees are retired to; its shares earn nothing.
    function DEAD() external view returns (address);
    /// @notice Gas one forward to the revenue token gets: 300,000, for an ERC-20 `transfer` or the native send into the
    ///         token's empty `receive`. A transfer that burns more fails on its own and the asset waits here.
    function FORWARD_GAS() external view returns (uint256);
    /// @notice Gas one `balanceOf` read of an asset gets: 50,000. A read that fails leaves the asset here
    ///         (`ForwardFailed` with amount zero) and never stops the pull.
    function BALANCE_GAS() external view returns (uint256);

    /// @notice `familyId` was registered: locked for this forwarder until `unlockBlock`, returning to `returnTo`.
    event FamilyRegistered(bytes32 indexed familyId, uint64 unlockBlock, address indexed returnTo);
    /// @notice Member `member` of `familyId` was collected: `amount0` and `amount1` of its pool's currencies.
    event Collected(bytes32 indexed familyId, uint8 member, uint256 amount0, uint256 amount1);
    /// @notice `amount` of `currency` was forwarded to the revenue token.
    event Forwarded(Currency indexed currency, uint256 amount);
    /// @notice The revenue token could not take `amount` of `currency` this time (its issuer refuses the token's address,
    ///         or the transfer ran past the forward's gas); it stays in the forwarder for a later pull.
    event ForwardFailed(Currency indexed currency, uint256 amount);
    /// @notice `amount` of the revenue token itself, earned as LP fees, was sent to 0xdead.
    event Retired(uint256 amount);
    /// @notice `amount` of `asset`, which the token does not list, was forwarded to the revenue token.
    event UnlistedForwarded(address indexed asset, uint256 amount);
    /// @notice `familyId` was released to `returnTo` through the lock's `handover`, which `returnTo` accepts.
    event FamilyReturned(bytes32 indexed familyId, address indexed returnTo, address handover);

    /// @notice The revenue token every pull pays.
    function token() external view returns (address);
    /// @notice The HookrFamilyLock holding the families.
    function lock() external view returns (address);
    /// @notice The HookrLauncher the families live on.
    function launcher() external view returns (address);
    /// @notice The tokenizer that may register families.
    function tokenizer() external view returns (address);
    /// @notice Number of families registered.
    function familyCount() external view returns (uint256);
    /// @notice The `i`-th family.
    function familyAt(uint256 i) external view returns (Family memory);

    /// @notice Registers `familyId`, which the lock must already hold for this forwarder. Only the tokenizer.
    /// @param familyId The family.
    /// @param returnTo The account a release hands the family to; not zero, this forwarder, the lock or the launcher.
    function register(bytes32 familyId, address returnTo) external;

    /// @notice Pulls every family: per member the lock's `collect` (LP fees, paid here) and `claimRecapture` (the
    ///         accrual, moved into this forwarder's Rules claims), then the Rules claims of every asset to the revenue token,
    ///         then this forwarder's balances of every asset to the revenue token and of the revenue token itself to 0xdead.
    ///         Anyone may call; the revenue token's sync does.
    /// @return ethForwarded The native ETH forwarded to the revenue token.
    function pull() external returns (uint256 ethForwarded);

    /// @notice From its unlock block, pulls family `i` one last time and releases it to its `returnTo`, who accepts it
    ///         with HookrLauncher.acceptFamily. Anyone may call.
    /// @return handover The HookrFamilyRelease handing the family over.
    function release(uint256 i) external returns (address handover);

    /// @notice Redeems this forwarder's PoolManager ERC-6909 claims in `currency` (left by a release) to the revenue token,
    ///         or to 0xdead for the revenue token itself. Anyone may call. Returns zero, and keeps the claim, when the
    ///         asset refuses the redeem (`ForwardFailed`).
    function flushClaims(Currency currency) external returns (uint256 amount);

    /// @notice Moves the forwarder's whole balance of `asset`, an ERC-20 that is neither one of the token's assets
    ///         nor the revenue token, to the revenue token, where `dropStray` splits it among the holders. Anyone
    ///         may call; the only destination is the token. Native ETH, the listed assets and the revenue token are
    ///         `ListedAsset`; an empty or unreadable balance is `NothingToForward`; a refused transfer is
    ///         `ForwardRefused`.
    /// @return amount What moved.
    function forwardUnlisted(address asset) external returns (uint256 amount);

    /// @notice What a pull would collect now for member `member` of family `i`, in its pool's two currencies, LP fees
    ///         only (the recapture accrual is readable on the member's Rules with `poolAccrued`).
    function pendingFees(uint256 i, uint8 member) external view returns (uint256 amount0, uint256 amount1);
}
