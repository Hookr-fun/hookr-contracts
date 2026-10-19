// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRevenueToken} from "tokenizer/interfaces/IHookrRevenueToken.sol";
import {IHookrCompoundShares} from "./IHookrCompoundShares.sol";

/// @title Hookr revenue compounder
/// @notice An opt-in vault for one revenue token. Holders deposit revenue tokens and get shares. The deposited tokens
///         stay in the vault, where they keep earning the token's income; the vault claims that income (the pool's
///         quote, native ETH on a market pool) and places it as liquidity in the token's pool, in a band that lies
///         entirely below the token's price (so it holds the quote only and nothing is swapped), and places the revenue
///         tokens the pool pays it in fees, or fills its bids with, in the band entirely above the price, the same way.
///         The fees of every band are compounded too. Drops made to the token's holders (the token's drop box) reach
///         the vault on their own (every deposit, redeem, transfer and poke claims the ones recorded since it last
///         looked) or through `claimDrops`, and release over time like the token's own income. Shareholders redeem for
///         their share of the revenue tokens plus their share of every band, removed pro rata; income in an asset the
///         pool cannot take (a side asset) is claimed with `claimSide`. The reads a front end wants beyond `holdings`
///         (fees pending, previews, the terms at once) are in HookrCompounderLens.
/// @dev No owner, no pause, no sweep, no swap: every term is fixed at construction. The token's creator has one power,
///      `listSide`: to name an asset a drop may bring in that the revenue token does not list. Deposits are
///      proportional, the depositor contributes the vault's own mix of revenue tokens and quote at the moment of the
///      deposit, so no price is ever read to value a share (HookrShareMath). The vault keeps at most `MAX_BANDS` bands:
///      with the price in band `k` (bands are `bandTicks` wide and aligned), the quote band and the token band are
///      `k - 1` and `k + 1`, one on each side, and `k` itself when the price moved into one of them. A `poke` removes any
///      band further away (its contents go back to the right side, with no swap) and places every loose amount; the
///      poker is paid `tipBps` of the quote the poke gathered, at most `tipCap`.
///
///      The vault places next to a price the market has been at, not next to whatever the price is at the moment: it
///      keeps an anchor, the highest and the lowest price it has seen recently, each closing in on the price by
///      `ANCHOR_DRIFT` ticks per `ANCHOR_PERIOD` of looking. Currency0 is placed (above the price) only while the price
///      is not below the recent high by more than `ANCHOR_TOLERANCE` ticks, currency1 (below the price) only while it
///      is not above the recent low by more than that, so a price pushed away from where the market has been can only
///      move a placement further from the market, never closer, and no sequence of touches turns a pushed price into
///      the anchor; a placement the anchor does not allow waits loose for a later poke (`PlacementDeferred`). After a
///      real move the side the move would favour waits until the anchor has closed in, about one band's width per six
///      hours: keepers poke at least hourly.
///
///      The pool may refuse an add (a hook's launch guard, a vault-only block, a tick at its liquidity limit): the
///      deposit or poke goes on with the amount loose, placed by a later poke. A hook that refuses a removal makes
///      `redeem` revert `RemovalLocked`; `redeemUnlocked` leaves such bands behind and pays the rest.
interface IHookrRevenueCompounder is IHookrCompoundShares {
    /// @notice One band the vault holds liquidity in.
    /// @param tickLower The band's lower tick.
    /// @param tickUpper The band's upper tick.
    /// @param liquidity The vault's liquidity in it.
    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice The prices the vault places next to.
    /// @param high The highest tick the vault has seen recently.
    /// @param low The lowest tick the vault has seen recently.
    /// @param lookedAt When the vault last looked at the price.
    struct Anchor {
        int24 high;
        int24 low;
        uint40 lookedAt;
    }

    // ------------------------------------------------------------------ errors
    // `Reentrant`, `InvalidRecipient`, `UnknownSide`, `NothingToClaim` and `TooManySides` come from the shares.

    /// @notice Constructor term `code` does not hold: 0 the token has no code or is not sealed, 1 neither pool
    ///         currency is the token, 2 the pool is not initialized, 3 the band width is not a positive multiple of
    ///         the tick spacing at most `MAX_BAND_TICKS`, 4 the tip is above `MAX_TIP_BPS`.
    error InvalidTerms(uint8 code);
    /// @notice The call came after `deadline`.
    error Expired(uint256 deadline);
    /// @notice Only the PoolManager may call back.
    error NotPoolManager();
    /// @notice `msg.value` is not the quote maximum (native quote) or is not zero (ERC-20 quote).
    error NativeMismatch();
    /// @notice The deposit or redeem would move no shares.
    error ZeroShares();
    /// @notice The first deposit must mint more than `MIN_SHARES`.
    error DepositTooSmall();
    /// @notice The deposit would mint `shares`, below the `minShares` asked.
    error InsufficientShares(uint256 shares, uint256 minShares);
    /// @notice The redeem would pay `tokens` and `quote`, below the minimum asked.
    error InsufficientOutput(uint256 tokens, uint256 quote);
    /// @notice The poke claimed nothing, looked at no drop, realized no fee, moved no band, placed nothing and moved
    ///         no anchor.
    error NothingToPoke();
    /// @notice `claimDrops` was called with no drop.
    error NoDrops();
    /// @notice The pool's hook refused the removal from the band `tickLower` to `tickUpper`; `redeemUnlocked` pays
    ///         around it.
    error RemovalLocked(int24 tickLower, int24 tickUpper);
    /// @notice The caller left less than `ADD_GAS_FLOOR` before a liquidity add; call again with more gas.
    error Starved();
    /// @notice An ERC-20 landed other than the amount asked: a fee-on-transfer or rebasing token.
    error InexactTransfer();
    /// @notice The vault would hold more than `MAX_BANDS` bands; cannot happen by construction.
    error TooManyBands();
    /// @notice The revenue token's lock is held, so the vault cannot claim what the token owes it: the call runs inside
    ///         one of the token's own payouts. Make it from outside.
    error TokenLocked();
    /// @notice Only the token's creator may list a side asset.
    error NotCreator(address caller);
    /// @notice The quote and the revenue token cannot be listed as side assets.
    error InvalidSide(address asset);
    /// @notice A drop's asset is neither the quote nor a listed side asset; the creator lists it with `listSide`.
    error NotListed(address asset);

    // ------------------------------------------------------------------ events

    /// @notice `sender` deposited `tokens` revenue tokens and `quote` of the quote for `shares` shares at `to`.
    event Deposit(address indexed sender, address indexed to, uint256 shares, uint256 tokens, uint256 quote);
    /// @notice `sender` redeemed `shares` shares for `tokens` revenue tokens and `quote` of the quote at `to`.
    event Redeem(address indexed sender, address indexed to, uint256 shares, uint256 tokens, uint256 quote);
    /// @notice `amount` of the token's asset `asset` was claimed from the revenue token.
    event IncomeClaimed(uint256 indexed asset, uint256 amount);
    /// @notice `amount` of `asset` was claimed from drop `dropId` of the token's drop box.
    event DropClaimed(uint256 indexed dropId, address indexed asset, uint256 amount);
    /// @notice One poke by `by`: `quote` of the quote gathered (claims and fees), `tokens` revenue tokens of fees,
    ///         `tip` paid to `by`.
    event Poked(address indexed by, uint256 quote, uint256 tokens, uint256 tip);
    /// @notice `liquidity` was added to the band `tickLower` to `tickUpper`.
    event BandAdded(int24 indexed tickLower, int24 indexed tickUpper, uint128 liquidity);
    /// @notice `liquidity`, the whole band, was removed from `tickLower` to `tickUpper`: the price moved on, and its
    ///         contents are placed again next to the price.
    event BandRemoved(int24 indexed tickLower, int24 indexed tickUpper, uint128 liquidity);
    /// @notice The pool refused an add of `liquidity` to `tickLower` to `tickUpper`; the amount stays loose.
    event AddRefused(int24 indexed tickLower, int24 indexed tickUpper, uint128 liquidity);
    /// @notice A `redeemUnlocked` left the band `tickLower` to `tickUpper` in place: the hook refused the removal.
    event BandLeft(int24 indexed tickLower, int24 indexed tickUpper, uint128 liquidity);
    /// @notice The anchor is now `high` and `low`.
    event AnchorMoved(int24 high, int24 low);
    /// @notice With the price at `tick` and the anchor at `high` and `low`, `amount0` of currency0 or `amount1` of
    ///         currency1 was left loose instead of placed; a later poke places it.
    event PlacementDeferred(int24 tick, int24 high, int24 low, uint256 amount0, uint256 amount1);

    // ------------------------------------------------------------------ constants

    /// @notice Shares of the first deposit sent to `DEAD` for good: 1,000. A first depositor cannot inflate the share
    ///         price against later ones.
    function MIN_SHARES() external view returns (uint256);
    /// @notice Most bands the vault holds at once: 3 (the band holding the price and one on each side).
    function MAX_BANDS() external view returns (uint256);
    /// @notice Widest band: 100,000 ticks.
    function MAX_BAND_TICKS() external view returns (int24);
    /// @notice Largest tip: 100 basis points (1%) of the quote a poke gathers.
    function MAX_TIP_BPS() external view returns (uint16);
    /// @notice Gas each claim from the revenue token is called with: 400,000. A claim that fails is skipped; the
    ///         income stays claimable.
    function CLAIM_GAS() external view returns (uint256);
    /// @notice Gas the caller must have left before each liquidity add: 500,000. With less, the call reverts
    ///         `Starved` instead of mistaking a starved add for a refused one.
    function ADD_GAS_FLOOR() external view returns (uint256);
    /// @notice How far the recent high and low close in on the price per `ANCHOR_PERIOD` of looking: 100 ticks.
    function ANCHOR_DRIFT() external view returns (uint256);
    /// @notice The period `ANCHOR_DRIFT` is per, and the most one look counts: one hour.
    function ANCHOR_PERIOD() external view returns (uint256);
    /// @notice How far beyond the recent high or low the price may be, in ticks, for a placement: a quarter of the
    ///         band width.
    function ANCHOR_TOLERANCE() external view returns (int24);
    /// @notice Most drops a deposit, redeem, transfer or poke looks at: 16.
    function DROP_SCAN() external view returns (uint256);

    // ------------------------------------------------------------------ fixed terms

    /// @notice The revenue token.
    function token() external view returns (IHookrRevenueToken);
    /// @notice The PoolManager.
    function poolManager() external view returns (IPoolManager);
    /// @notice The pool.
    function poolId() external view returns (PoolId);
    /// @notice The pool's key.
    function poolKey() external view returns (PoolKey memory);
    /// @notice The pool's other currency, which the vault's bids are placed in.
    function quote() external view returns (Currency);
    /// @notice Whether the token is the pool's currency0.
    function tokenIsCurrency0() external view returns (bool);
    /// @notice The width of a band in ticks, a multiple of the pool's tick spacing.
    function bandTicks() external view returns (int24);
    /// @notice The poker's tip, in basis points of the quote a poke gathers.
    function tipBps() external view returns (uint16);
    /// @notice The most a poke tips, in quote units.
    function tipCap() external view returns (uint128);

    // ------------------------------------------------------------------ state

    /// @notice The revenue tokens deposited and not redeemed: they stay in the vault and earn the token's income.
    ///         Revenue tokens the vault holds above this came from the pool and are placed as asks.
    function reserve() external view returns (uint256);
    /// @notice The bands the vault holds liquidity in, at most `MAX_BANDS`.
    function bands() external view returns (Band[] memory);
    /// @notice The anchor: the recent high and low the vault has seen.
    function anchor() external view returns (Anchor memory);
    /// @notice The token's creator, who alone may list a side asset.
    function creator() external view returns (address);
    /// @notice The first drop of the token's box the vault has not looked at.
    function nextDrop() external view returns (uint256);
    /// @notice What the vault holds at the pool's current price: loose amounts plus every band's amounts, fees not
    ///         yet realized left out.
    function holdings() external view returns (uint256 tokens, uint256 quote);

    // ------------------------------------------------------------------ actions

    /// @notice Deposits for shares at `to`. The vault claims its income and realizes its fees first, then takes the
    ///         vault's own mix: with `supply` shares out and `T` revenue tokens and `Q` quote held, the shares are the
    ///         most `tokensMax` and `quoteMax` afford, `min(tokensMax x supply / T, quoteMax x supply / Q)`, and the
    ///         vault pulls `shares x T / supply` revenue tokens and `shares x Q / supply` quote, rounded up. The first
    ///         deposit takes `tokensMax` revenue tokens for as many shares, less `MIN_SHARES`. A native quote comes as
    ///         `msg.value`, which must equal `quoteMax`; the excess is refunded. The pulled quote is placed in the
    ///         quote band at once when the anchor allows it. Refused past `deadline`, below `minShares`, and when it
    ///         would mint nothing.
    function deposit(uint256 tokensMax, uint256 quoteMax, address to, uint256 minShares, uint256 deadline)
        external
        payable
        returns (uint256 shares, uint256 tokens, uint256 quote);
    /// @notice Burns `shares` of the caller and pays `to` their share of everything: the vault claims its income and
    ///         removes `shares / supply` of every band (fees come with it), then pays that principal plus the same
    ///         share of what is loose. Refused past `deadline`, below the minimum outputs, and when the pool's hook
    ///         refuses a removal (`RemovalLocked`). Side assets the caller is owed stay claimable with `claimSide`.
    function redeem(uint256 shares, address to, uint256 minTokens, uint256 minQuote, uint256 deadline)
        external
        returns (uint256 tokens, uint256 quote);
    /// @notice `redeem`, except that a band whose removal the pool's hook refuses is left in place (`BandLeft`) and
    ///         the caller is paid its share of everything else. The caller's share of the bands left stays with the
    ///         remaining shareholders: use it with minimum outputs that make that acceptable, when waiting for the
    ///         lock to end is worse.
    function redeemUnlocked(uint256 shares, address to, uint256 minTokens, uint256 minQuote, uint256 deadline)
        external
        returns (uint256 tokens, uint256 quote);
    /// @notice Claims the token's income, realizes every band's fees, removes the bands the price moved away from and
    ///         places every loose amount the anchor allows: the quote below the price, the revenue tokens above the
    ///         `reserve` above it. Anyone may call; the caller is paid `tipBps` of the quote gathered, at most
    ///         `tipCap`. Reverts `NothingToPoke` when there was nothing to do.
    function poke() external returns (uint256 tip);
    /// @notice Claims the vault's share of each listed drop from the token's drop box (`IHookrDropBox.claim`), then
    ///         does everything `poke` does. What a drop brings in is held back and released linearly over `dropStream`
    ///         seconds, as the revenue token releases its own income: a drop of the quote joins the vault's holdings
    ///         as it releases, a drop of a side asset is split over the shares as it releases, so only whoever holds
    ///         shares while it releases earns it. No tip is paid on it. Anyone may call; the box reverts on an unknown
    ///         or claimed drop and on one the vault has no share in. Reverts `NoDrops` with no drop and `NotListed`
    ///         for an asset that is neither the quote nor a side asset. Every other call that prices or moves
    ///         shares claims the drops recorded since the last look on its own (up to `DROP_SCAN`).
    function claimDrops(uint256[] calldata dropIds) external returns (uint256 tip);
    /// @notice Lists `asset` as a side asset, so drops of it can be claimed; the token's creator only. Reverts
    ///         `InvalidSide` for the quote and the revenue token, `TooManySides` past `MAX_SIDES`.
    function listSide(address asset) external returns (uint256 side);
}
