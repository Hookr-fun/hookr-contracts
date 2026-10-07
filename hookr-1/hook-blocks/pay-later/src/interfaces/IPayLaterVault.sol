// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PayLaterTerms} from "../PayLaterTerms.sol";

/// @title Pay Later vault
/// @notice A physically covered call on subject tokens a Hookr founding band earned as LP fees. A buyer pays a
///         premium now for the right to buy reserved tokens at a fixed strike until expiry. There is no loan, no
///         debt, no margin and no liquidation: if the buyer does not exercise, the reservation expires and the
///         buyer has lost only the premium.
interface IPayLaterVault {
    /// @notice Lifecycle of one reservation.
    enum Status {
        None,
        Active,
        Exercised,
        Expired
    }

    /// @notice One covered call.
    /// @param holder The only address that may exercise it. Positions are not transferable.
    /// @param openedBlock Contract-clock block of the open. Exercise needs a later block.
    /// @param status Lifecycle state.
    /// @param expiry Timestamp from which exercise is refused and anyone may expire the position.
    /// @param units Subject units reserved at open.
    /// @param exercised Subject units already bought.
    /// @param strike Quote units due for all `units`; fixed at open.
    /// @param strikePaid Quote units paid so far: ceil(strike * exercised / units).
    /// @param premium Quote units paid at open. Never refunded.
    struct Position {
        address holder;
        uint64 openedBlock;
        Status status;
        uint64 expiry;
        uint128 units;
        uint128 exercised;
        uint256 strike;
        uint256 strikePaid;
        uint256 premium;
    }

    error InvalidConfig();
    error InvalidTerms();
    error Reentrancy();
    error NotBeneficiary(address caller);
    error NotHolder(address caller);
    error NotFamilyOwner();
    error WrongPreviousOwner(address owner);
    error BandLiquidityChanged(uint128 expected, uint128 actual);
    error DeadlineExpired();
    error BadOrderSize(uint256 units);
    error InventoryShortfall(uint256 units, uint256 free);
    error ActiveCapExceeded(uint256 active, uint256 cap);
    error BlockCapExceeded(uint256 opened, uint256 cap);
    error NoRecentObservation();
    error FamilyNotHeld();
    error BandOutOfRange(int24 tick);
    error DepthCapExceeded(uint256 opened, uint256 cap);
    error PoolNotInitialized();
    error StrikeAboveMaximum(uint256 strike, uint256 maximum);
    error PremiumAboveMaximum(uint256 premium, uint256 maximum);
    error PaymentAboveMaximum(uint256 payment, uint256 maximum);
    error WrongPayment(uint256 expected, uint256 sent);
    error InexactTransfer();
    error UnknownPosition(uint256 id);
    error NotActive(uint256 id);
    error TooEarly(uint256 id);
    error PositionExpired(uint256 id);
    error NotExpired(uint256 id);
    error BadExercise(uint256 units);
    error InvalidRecipient(address recipient);
    error AmountZero();
    error AmountExceedsAvailable(uint256 amount, uint256 available);
    error InventoryDeficit();
    error NativeTransferFailed();
    error NearBandTop(uint256 referencePrice, uint256 guardPrice);
    error BandReachTooShort(uint256 reachBps, uint256 minimumBps);

    /// @notice The vault took ownership of its family from the beneficiary.
    event FamilyAccepted(bytes32 indexed familyId, address indexed previousOwner);
    /// @notice The beneficiary started handing the family back to itself.
    event FamilyReleased(bytes32 indexed familyId, address indexed to, uint16 claims);
    /// @notice LP fees of one member were collected. `toInventory` of `subjectIn` became credit inventory.
    event Harvested(
        uint8 indexed member, uint256 subjectIn, uint256 toInventory, Currency indexed other, uint256 otherIn
    );
    /// @notice Untracked balance (claims redeemed, donations, fees delivered on release) was credited.
    event Credited(Currency indexed currency, uint256 amount, uint256 toInventory);
    /// @notice A price observation for `blockNumber` was raised to `value` (normalized sqrt price, Q96).
    event Observed(uint256 indexed blockNumber, uint256 value);
    /// @notice A covered call was opened.
    event PositionOpened(
        uint256 indexed id,
        address indexed holder,
        uint128 units,
        uint256 strike,
        uint256 premium,
        uint64 expiry,
        uint256 referenceSqrtPriceX96
    );
    /// @notice Part or all of a position was bought.
    event Exercised(
        uint256 indexed id, address indexed holder, address indexed recipient, uint128 units, uint256 payment
    );
    /// @notice A position lapsed; `releasedUnits` returned to free inventory.
    event Expired(uint256 indexed id, uint128 releasedUnits);
    /// @notice The beneficiary withdrew earned currency.
    event EarningsWithdrawn(Currency indexed currency, address indexed to, uint256 amount);
    /// @notice The beneficiary withdrew free (unreserved) inventory.
    event InventoryWithdrawn(address indexed to, uint256 amount);
    /// @notice The beneficiary moved a PoolManager ERC-6909 claim the vault held.
    event ClaimsTransferred(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice Member `member`'s recapture accrual, already moved into the vault's claims in its Rules, was collected:
    ///         credited now (`asClaims` false) or received as a PoolManager ERC-6909 claim for `redeemClaims`.
    event RecaptureCollected(uint8 indexed member, Currency indexed currency, uint256 amount, bool asClaims);
    /// @notice The protocol share of premiums was paid to the protocol recipient.
    event ProtocolPaid(address indexed recipient, uint256 amount);

    /// @notice Immutable terms of this vault.
    function terms() external view returns (PayLaterTerms.Terms memory);

    /// @notice Completes the beneficiary's `transferFamily` to this vault. Beneficiary only.
    /// @dev Requires the current family owner to be the beneficiary, so fees earned before the hand-over are
    ///      paid to the beneficiary by the Launcher, not to the vault. Refuses (`BandLiquidityChanged`) a reference
    ///      band whose liquidity is below the `bandLiquidity` the depth cap was priced on; a band that grew is fine.
    ///      Refuses (`BandReachTooShort`) while `custodyReachBps` is under `PayLaterTerms.MIN_BAND_REACH_BPS`
    ///      (10x), on the first hand-over and on every re-hand after a release. A refused hand-over stays pending in
    ///      the Launcher; only the beneficiary can complete it, and `HookrLauncher.transferFamily(familyId,
    ///      address(0), 0)` cancels it.
    function acceptFamily() external;

    /// @notice Starts handing the family back to the beneficiary, who completes it with
    ///         `HookrLauncher.acceptFamily`. Beneficiary only. Never depends on this vault receiving funds:
    ///         fees accrued until acceptance are delivered to the vault as ERC-6909 claims.
    function releaseFamily() external;

    /// @notice Collects one member's LP fees into the vault. Anyone may call while the vault owns the family.
    /// @dev The subject side becomes inventory up to `maxInventory` (the rest is owed to the beneficiary); the
    ///      other side is owed to the beneficiary.
    function harvest(uint8 member) external returns (uint256 subjectIn, uint256 otherIn);

    /// @notice `harvest`, delivering currency0 (bit 0) and/or currency1 (bit 1) of the member's pool as PoolManager
    ///         ERC-6909 claims instead of tokens. Anyone may call while the vault owns the family.
    /// @dev For an asset that is paused or refuses the vault: `harvest` would revert as a whole, so the subject side
    ///      could not become inventory; here the other side stays a claim until `redeemClaims` credits it (or the
    ///      beneficiary moves it with `transferClaims`). `subjectIn` and `otherIn` count tokens received now only.
    function harvestWithClaims(uint8 member, uint8 claims) external returns (uint256 subjectIn, uint256 otherIn);

    /// @notice Turns every PoolManager ERC-6909 claim the vault holds in `currency` into tokens and credits them.
    function redeemClaims(Currency currency) external returns (uint256 amount);

    /// @notice Claims the vault's `currency` claims in member `member`'s Rules and credits them like a fee: the subject
    ///         becomes inventory up to `maxInventory`, anything else is owed to the beneficiary. Anyone may call, also
    ///         after a release. `asClaims` takes them as PoolManager ERC-6909 claims instead (for a paused or
    ///         restricted currency), which `redeemClaims` credits later.
    /// @dev A member launched with the recapture lane accrues the LP share of a push in a currency other than its pool's
    ///      two (or one that finds no liquidity in range) to its liquidity owner in its Rules; the Launcher moves that
    ///      accrual into the family owner's claims with every `harvest`, so while the vault owns the family the claims
    ///      are the vault's and nothing but this call can reach them. The LP share of a push in one of the pool's two
    ///      currencies is donated to the pool's in-range liquidity instead, and the band's part arrives through
    ///      `harvest`.
    function collectRecapture(uint8 member, Currency currency, bool asClaims) external returns (uint256 amount);

    /// @notice Pays the protocol share of premiums (`protocolOwed`) to the protocol recipient. Anyone may call.
    function payProtocol() external returns (uint256 amount);

    /// @notice Credits any balance of `currency` the vault holds but has not accounted. Anyone may call.
    function sync(Currency currency) external returns (uint256 amount);

    /// @notice Records the reference pool's current price for this block. Anyone may call.
    function poke() external;

    /// @notice Reserves `units` subject at a fixed strike until `block.timestamp + tenor`, paying the premium now.
    /// @dev Native quote: send exactly the premium as value. ERC20 quote: approve the premium; send no value.
    ///      Refused unless the vault owns the family, the spot price is inside the founding band and, with a top
    ///      guard, the reference price is below `guardPrice` (`NearBandTop`). `protocolShareBps` of the premium is
    ///      owed to the protocol, the rest to the beneficiary.
    /// @return id The position id.
    /// @return strike Quote units due to buy all `units`.
    /// @return premium Quote units paid now.
    function open(uint128 units, uint256 maxStrike, uint256 maxPremium, uint256 deadline)
        external
        payable
        returns (uint256 id, uint256 strike, uint256 premium);

    /// @notice Buys `units` more of the caller's reserved subject for the pro-rata strike, delivered to `recipient`.
    /// @return payment Quote units paid in this call.
    function exercise(uint256 id, uint128 units, uint256 maxPayment, address recipient)
        external
        payable
        returns (uint256 payment);

    /// @notice Lapses an unexercised remainder after expiry and frees its inventory. Anyone may call.
    function expire(uint256 id) external;

    /// @notice Pays earned currency (premiums, strikes, quote-side fees, excess subject) to `to`. Beneficiary only.
    function withdrawEarnings(Currency currency, address to, uint256 amount) external;

    /// @notice Pays free (unreserved) inventory to `to`. Beneficiary only. Reserved units are never withdrawable.
    function withdrawInventory(address to, uint128 amount) external;

    /// @notice Moves an ERC-6909 claim the vault holds, for a currency `redeemClaims` cannot redeem. Beneficiary only.
    function transferClaims(Currency currency, address to, uint256 amount) external;

    /// @notice Returns one position.
    function position(uint256 id) external view returns (Position memory);

    /// @notice Strike and premium an open of `units` would pay now. Reverts as `open` would on a missing price.
    function quoteOpen(uint128 units)
        external
        view
        returns (uint256 strike, uint256 premium, uint256 referenceSqrtPriceX96);

    /// @notice The price the next open would use: the highest of the spot price and every observation in the window.
    function referencePrice() external view returns (uint256 sqrtPriceX96);

    /// @notice The reach `acceptFamily` checks: the band-top price over the higher of the spot price and every price
    ///         recorded in the last `priceWindowBlocks` blocks, in basis points, rounded down (`PayLaterTerms.bandReachBps`).
    function custodyReachBps() external view returns (uint256);

    /// @notice The spot price of the subject in the quote, as a Q96 square root.
    function spotPrice() external view returns (uint256 sqrtPriceX96);

    /// @notice Whether balances cover every accounted liability in the subject and the reference quote.
    function accountingInvariant() external view returns (bool);
}
