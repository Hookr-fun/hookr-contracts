// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ErgTypes} from "./ErgTypes.sol";

/// @title Entry Ratio Guarantee hook
/// @notice Standalone custody hook (permission bits 9, 8 and 0, word 0x0301). LPs deposit through the paired
///         vault; at exit they can take back their entry amounts, paid from a per-pool reserve that only
///         forfeited fees and exchanged surplus fund.
/// @dev The hook never sees swaps: it has no swap bit, so a failure
///      here cannot stop a swap on any pool.
interface IEntryRatioGuarantee {
    /// @notice Emitted when a creator registers a pool and its terms are frozen.
    /// @param id The pool id
    /// @param creator The account that registered the pool and chose its terms
    /// @param priceReference The entry price reference
    /// @param terms The frozen terms, including the derived entry band
    event PoolRegistered(
        PoolId indexed id, address indexed creator, address indexed priceReference, ErgTypes.PoolTerms terms
    );

    /// @notice Emitted when the registrar allows or disallows a price reference for a currency pair.
    /// @param currency0 The pair's lower-sorted currency
    /// @param currency1 The pair's higher-sorted currency
    /// @param priceReference The reference
    /// @param allowed True when pools on the pair may name the reference and deposits may be priced against it
    event PriceReferenceSet(
        Currency indexed currency0, Currency indexed currency1, address indexed priceReference, bool allowed
    );

    /// @notice Emitted when the registrar permanently stops new deposits into a pool. Exits are unaffected.
    /// @param id The pool id
    event PoolClosed(PoolId indexed id);

    /// @notice Emitted when the vault enrolls a new position.
    /// @param positionId The position id, also the PoolManager salt
    /// @param owner The LP
    /// @param id The pool id
    /// @param term LOCK or OPTION
    /// @param liquidity Liquidity held by the vault for the position
    /// @param entry0 currency0 paid
    /// @param entry1 currency1 paid
    /// @param unlockAt End of the lock (LOCK) or of the minimum hold (OPTION)
    /// @param expiry Last second the entry ratio can be asked for (OPTION, and LOCK with a coverage horizon), or
    ///        zero (LOCK whose coverage never lapses)
    /// @param spotSqrtPriceX96 The pool's sqrt price at entry
    /// @param referenceSqrtPriceX96 The reference sqrt price at entry
    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        PoolId indexed id,
        ErgTypes.Term term,
        uint128 liquidity,
        uint128 entry0,
        uint128 entry1,
        uint40 unlockAt,
        uint40 expiry,
        uint160 spotSqrtPriceX96,
        uint160 referenceSqrtPriceX96
    );

    /// @notice Emitted when a position exits.
    /// @param positionId The position id
    /// @param owner The LP
    /// @param id The pool id
    /// @param exercised True when the entry-ratio leg was requested
    /// @param result Amounts the LP received, forfeited, was paid and gave up
    event PositionClosed(
        uint256 indexed positionId, address indexed owner, PoolId indexed id, bool exercised, ErgTypes.ExitResult result
    );

    /// @notice Emitted whenever a pool's reserve changes.
    /// @param id The pool id
    /// @param reserve0 The new currency0 reserve
    /// @param reserve1 The new currency1 reserve
    event ReserveUpdated(PoolId indexed id, uint256 reserve0, uint256 reserve1);

    /// @notice Emitted when an exit credits the protocol its share of the forfeited fees.
    /// @param id The pool id
    /// @param amount0 currency0 credited to the protocol recipient's claim
    /// @param amount1 currency1 credited to the protocol recipient's claim
    event ProtocolCredited(PoolId indexed id, uint256 amount0, uint256 amount1);

    /// @notice Emitted when the protocol recipient's claim is paid, as tokens or as PoolManager ERC-6909 claims.
    /// @param currency The currency paid
    /// @param beneficiary The protocol recipient whose claim was paid
    /// @param to The account that received the payment
    /// @param amount The amount paid
    event Claimed(Currency indexed currency, address indexed beneficiary, address indexed to, uint256 amount);

    /// @notice Thrown when a callback does not come from the PoolManager.
    error NotPoolManager();
    /// @notice Thrown when a vault-only entry is called by another address.
    error NotVault();
    /// @notice Thrown when a registrar-only entry is called by another address, or at deployment when the
    ///         registrar holds no code or is an EIP-7702 delegated account.
    error NotRegistrar();
    /// @notice Thrown when a pool names a reference the registrar has not allowed for its pair, or a deposit is
    ///         priced against a reference the registrar has since disallowed.
    /// @param priceReference The reference
    error ReferenceNotAllowed(address priceReference);
    /// @notice Thrown when a reference is allowlisted for currencies that are not sorted as a v4 pool key sorts them.
    error InvalidReferencePair();
    /// @notice Thrown when a callback outside bits 9, 8 and 0 is invoked.
    error HookNotImplemented();
    /// @notice Thrown when the key does not name this hook.
    error WrongHook();
    /// @notice Thrown when a pool is registered twice.
    /// @param id The pool id
    error AlreadyRegistered(PoolId id);
    /// @notice Thrown when a pool is not registered.
    /// @param id The pool id
    error NotRegistered(PoolId id);
    /// @notice Thrown when a pool no longer takes deposits.
    /// @param id The pool id
    error PoolIsClosed(PoolId id);
    /// @notice Thrown when a pool's key has a dynamic fee or a fee below the floor.
    /// @param fee The key's fee
    error UnsupportedFee(uint24 fee);
    /// @notice Thrown when the pool is not initialized in the PoolManager.
    /// @param id The pool id
    error PoolNotInitialized(PoolId id);
    /// @notice Thrown when terms fall outside the hook's immutable bounds.
    /// @param field Index of the offending field, in `PoolTerms` order (0 reference .. 6 draw cap, 7 entry band,
    ///        8 LOCK coverage horizon, 9 protocol share)
    error InvalidTerms(uint8 field);
    /// @notice Thrown when a position id is reused or a deposit is malformed.
    /// @param positionId The position id
    error InvalidPosition(uint256 positionId);
    /// @notice Thrown when the reference refuses or returns zero.
    error ReferenceUnavailable();
    /// @notice Thrown when the entry price is outside the reference band.
    /// @param spotSqrtPriceX96 The pool's sqrt price
    /// @param referenceSqrtPriceX96 The reference sqrt price
    /// @param maxDeviationPips The pool's band
    error EntryPriceOutOfBand(uint160 spotSqrtPriceX96, uint160 referenceSqrtPriceX96, uint24 maxDeviationPips);
    /// @notice Thrown when an exit asks for the entry ratio while the pool price is outside the reference band. The
    ///         leg converts at the position's own exit-time rate, so the price must be the market's, not one pushed in
    ///         the exit's own transaction.
    /// @param spotSqrtPriceX96 The pool's sqrt price
    /// @param referenceSqrtPriceX96 The reference sqrt price
    /// @param maxDeviationPips The pool's band
    error ExercisePriceOutOfBand(uint160 spotSqrtPriceX96, uint160 referenceSqrtPriceX96, uint24 maxDeviationPips);
    /// @notice Thrown when a vault removal does not match an open position exactly.
    /// @param positionId The position id
    error RemovalMismatch(uint256 positionId);
    /// @notice Thrown when the principal is still locked or the option hold has not elapsed.
    /// @param positionId The position id
    /// @param unlockAt The first second an exit is allowed
    error Locked(uint256 positionId, uint40 unlockAt);
    /// @notice Thrown when an option is exercised after its window closed.
    /// @param positionId The position id
    /// @param expiry The last second the right could be exercised
    error ExerciseWindowClosed(uint256 positionId, uint40 expiry);
    /// @notice Thrown when the hook address does not carry exactly bits 9, 8 and 0.
    error HookAddressMismatch();
    /// @notice Thrown by the constructor for a zero or PoolManager protocol recipient, or a protocol share floor
    ///         outside `[MIN_PROTOCOL_SHARE_BPS, MAX_PROTOCOL_SHARE_BPS]`.
    error InvalidProtocolConfig();
    /// @notice Thrown when a claim is paid to zero, the PoolManager or this hook.
    error InvalidRecipient();
    /// @notice Thrown when the caller has nothing to claim in the currency.
    error NothingToClaim();

    /// @notice The PoolManager the hook serves.
    /// @return The Uniswap v4 PoolManager
    function poolManager() external view returns (IPoolManager);

    /// @notice The permission bits the hook's address carries; the low 14 bits of its address equal this.
    /// @return The v4 hook permission flags, 0x0301
    function HOOK_FLAGS() external view returns (uint160);

    /// @notice The account every pool's protocol share is credited to (the Hookr treasury).
    /// @return The protocol recipient
    function protocolRecipient() external view returns (address);

    /// @notice The lowest protocol share any of the hook's pools may set, in basis points.
    /// @return The release floor
    function minProtocolShareBps() external view returns (uint16);

    /// @notice The only account whose removals the hook settles; it owns every enrolled PoolManager position.
    /// @return The vault created by this hook's constructor
    function vault() external view returns (address);

    /// @notice The only account that may allowlist price references and close pools. It has no power over funds
    ///         or exits and does not choose any pool's terms. It is a contract, checked at deployment.
    /// @return The immutable registrar
    function registrar() external view returns (address);

    /// @notice The account's unpaid claim in `currency`. Only the protocol recipient ever holds one.
    /// @param currency The currency
    /// @param account The account
    /// @return The claim, backed by this hook's PoolManager ERC-6909 balance
    function claimable(Currency currency, address account) external view returns (uint256);

    /// @notice All unpaid protocol claims in `currency`. The hook's ERC-6909 balance equals the pools' reserves
    ///         plus this.
    /// @param currency The currency
    /// @return The outstanding protocol claim
    function totalLiability(Currency currency) external view returns (uint256);

    /// @notice Pays the caller's whole claim in `currency` to `to` as tokens, through a PoolManager unlock.
    /// @param currency The currency
    /// @param to The recipient: not zero, the PoolManager or this hook
    /// @return amount The amount paid
    function claimTo(Currency currency, address to) external returns (uint256 amount);

    /// @notice Pays the caller's whole claim in `currency` to `to` as PoolManager ERC-6909 claims. Moves no token.
    /// @dev The exit for a currency whose transfers stop delivering exact amounts; the recipient redeems the
    ///      ERC-6909 balance through any PoolManager unlock.
    /// @param currency The currency
    /// @param to The recipient: not zero, the PoolManager or this hook
    /// @return amount The amount paid
    function claimAsClaims(Currency currency, address to) external returns (uint256 amount);

    /// @notice Allows or disallows a price reference for one currency pair. Registrar only.
    /// @dev A pool can only be registered with a reference allowed for its pair, and every deposit re-checks the
    ///      allowance, so disallowing a reference stops deposits into every pool that names it. No exit re-checks
    ///      the allowance: an exit that asks for the entry ratio still reads a disallowed reference and settles while
    ///      it answers, and an exit that does not ask never reads the reference.
    /// @param currency0 The pair's lower-sorted currency
    /// @param currency1 The pair's higher-sorted currency
    /// @param priceReference The reference; when allowing, it must be a contract that is not an EIP-7702
    ///        delegated account
    /// @param allowed True to allow, false to disallow
    function setPriceReference(Currency currency0, Currency currency1, address priceReference, bool allowed) external;

    /// @notice Registers an initialized pool with the caller's terms and freezes them. The caller is the pool's
    ///         creator. Anyone may register a pool that is not yet registered.
    /// @dev The reference must be a contract that declares its tolerance (`errorSqrtPips`), be allowed for the
    ///      pool's pair and answer now. The entry band is set to `entryBandPips(fee, tolerance)`: half the pool fee,
    ///      rounded down, less the tolerance. The terms must then pass `validateTerms`, which refuses a zero band.
    /// @param key The pool key; `key.hooks` must be this hook
    /// @param terms The creator's terms
    function registerPool(PoolKey calldata key, ErgTypes.CreatorTerms calldata terms) external;

    /// @notice Permanently stops new deposits into a pool. Registrar only. Exits and the reserve are unaffected.
    /// @param id The pool id
    function closePool(PoolId id) external;

    /// @notice Records a position the vault has just added. Vault only; called inside the vault's unlock.
    /// @param positionId The id the vault used as the PoolManager salt
    /// @param owner The LP
    /// @param key The pool key
    /// @param tickLower Lower tick
    /// @param tickUpper Upper tick
    /// @param liquidity Liquidity added
    /// @param entry0 currency0 the LP paid
    /// @param entry1 currency1 the LP paid
    /// @param term LOCK or OPTION
    function enroll(
        uint256 positionId,
        address owner,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 entry0,
        uint128 entry1,
        ErgTypes.Term term
    ) external;

    /// @notice Returns whether the registrar allows a reference for a currency pair.
    /// @param currency0 The pair's lower-sorted currency
    /// @param currency1 The pair's higher-sorted currency
    /// @param priceReference The reference
    /// @return True when allowed
    function isPriceReferenceAllowed(Currency currency0, Currency currency1, address priceReference)
        external
        view
        returns (bool);

    /// @notice Returns the account that registered a pool and chose its terms.
    /// @param id The pool id
    /// @return The creator, or zero for an unregistered pool
    function poolCreator(PoolId id) external view returns (address);

    /// @notice Returns whether a pool is registered.
    /// @param id The pool id
    /// @return True once registered
    function isRegistered(PoolId id) external view returns (bool);

    /// @notice Returns whether a registered pool stopped taking deposits.
    /// @param id The pool id
    /// @return True once closed
    function isClosed(PoolId id) external view returns (bool);

    /// @notice Returns a registered pool's key.
    /// @param id The pool id
    /// @return The pool key recorded at registration
    function poolKey(PoolId id) external view returns (PoolKey memory);

    /// @notice Returns a registered pool's frozen terms.
    /// @param id The pool id
    /// @return The terms frozen at registration
    function poolTerms(PoolId id) external view returns (ErgTypes.PoolTerms memory);

    /// @notice Returns a pool's reserve in both currencies.
    /// @param id The pool id
    /// @return reserve0 The currency0 reserve
    /// @return reserve1 The currency1 reserve
    function reserves(PoolId id) external view returns (uint256 reserve0, uint256 reserve1);

    /// @notice Returns a position.
    /// @param positionId The position id
    /// @return The stored position
    function position(uint256 positionId) external view returns (ErgTypes.Position memory);

    /// @notice Previews an exit at the current PoolManager state, exactly as `afterRemoveLiquidity` would settle it.
    /// @dev Reverts for a closed or unknown position, and, when `exercise` is true, with `ReferenceUnavailable` while
    ///      the pool's price reference refuses, as the exercise itself would. Does not check the lock, the window or
    ///      the exercise price band (`entryPriceCheck` reports the spot and reference an exercise is checked against).
    /// @param positionId The position
    /// @param exercise Whether the entry-ratio leg is requested
    /// @return The exit outcome at the current state
    function previewExit(uint256 positionId, bool exercise) external view returns (ErgTypes.ExitResult memory);

    /// @notice Returns the pool's spot and reference sqrt prices and whether a deposit would pass the band now.
    /// @dev Reverts `NotRegistered` for an unknown pool and `ReferenceUnavailable` while the reference refuses.
    /// @param id The pool id
    /// @return spot The pool's sqrt price
    /// @return reference_ The reference sqrt price
    /// @return ok True when the pool is open, its reference is still allowed and a deposit would pass the band
    function entryPriceCheck(PoolId id) external view returns (uint160 spot, uint160 reference_, bool ok);
}
