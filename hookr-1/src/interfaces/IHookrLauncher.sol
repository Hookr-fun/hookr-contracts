// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrLauncherView} from "./IHookrLauncherView.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @title IHookrLauncher
/// @notice Interface for HookrLauncher: atomic, funded Market Families.
interface IHookrLauncher is IHookrLauncherView {
    /// @notice The family's subject. `salt` is the CREATE2 salt of a new token; for an existing token it is zero
    ///         for an atomic family or SKIP_TAKEN to launch only the members whose PoolKey is still free.
    struct Token {
        /// @notice An existing token to launch the family for, or zero to deploy a new one.
        address existing;
        /// @notice The new token's name; empty for an existing token.
        string name;
        /// @notice The new token's symbol; empty for an existing token.
        string symbol;
        /// @notice The new token's whole supply, minted to the Launcher for the family; zero for an existing token.
        uint256 supply;
        /// @notice A new token's CREATE2 salt; for an existing token, zero or SKIP_TAKEN.
        bytes32 salt;
    }

    /// @notice One member of a family. `recapture` turns the recapture lane on for the member's pool (its
    ///         RecaptureConfig becomes the third part of the Rules data): the pool freezes the root's open lane at
    ///         initialization and the launch reverts while the root has no open lane. A zeroed `recapture` launches the
    ///         member without the lane; the SDK and launch wizard pre-fill the Rules' `recaptureDefaults()` (on) while
    ///         the root's lane is open, and the creator opts out by clearing `on`.
    struct Member {
        /// @notice The member's quote currency, address zero for native ETH.
        Currency quote;
        /// @notice The pool's tick spacing.
        int24 tickSpacing;
        /// @notice The opening price as a sqrt price in Q64.96.
        uint160 sqrtPriceX96;
        /// @notice The lower tick of the member's launch position.
        int24 tickLower;
        /// @notice The upper tick of the member's launch position.
        int24 tickUpper;
        /// @notice The liquidity the launch position adds.
        uint128 liquidity;
        /// @notice The most currency0 the launch pulls to fund the position.
        uint128 amount0Max;
        /// @notice The most currency1 the launch pulls to fund the position.
        uint128 amount1Max;
        /// @notice The pool's identity, trusted modules and execution limits.
        HookrTypes.PoolConfig config;
        /// @notice The pool's native rules configuration.
        HookrTypes.RulesConfig rules;
        /// @notice The pool's recapture configuration; zeroed launches the member without the lane.
        HookrTypes.RecaptureConfig recapture;
    }

    /// @notice A member's managed launch position.
    struct Position {
        /// @notice The member's pool.
        PoolKey key;
        /// @notice The lower tick of the position.
        int24 tickLower;
        /// @notice The upper tick of the position.
        int24 tickUpper;
        /// @notice The liquidity the position holds.
        uint128 liquidity;
    }

    /// @notice The optional first buy of a new-token launch (the dev buy), on member `member`'s pool, guarded or not.
    /// @dev `quoteIn` is the exact quote spent and `minSubjectOut` the least subject the caller receives, net of
    ///      Auto Burn. `lockBlocks` (at most MAX_DEV_BUY_LOCK_BLOCKS) keeps the family's principal locked for at least
    ///      that many parent blocks past the launch block, on top of the guards; zero leaves the guards alone.
    struct DevBuy {
        /// @notice The index of the member whose pool takes the buy.
        uint8 member;
        /// @notice The exact quote the buy spends.
        uint128 quoteIn;
        /// @notice The least subject the caller must receive, net of Auto Burn.
        uint128 minSubjectOut;
        /// @notice The parent blocks past the launch block the family's principal stays locked, or zero.
        uint32 lockBlocks;
    }

    /// @notice A launchFamily member's knobs, beside its Member.
    /// @dev `subjectWeightBps`: the share of a new token's supply the member is funded with, in basis points. Zero on
    ///      every member, or nonzero on every member of a new-token family with a sum of at most 10,000; each member's
    ///      subject budget (amount0Max when the subject sorts first, else amount1Max) must then be exactly
    ///      floor(supply × subjectWeightBps / 10,000). `dynamicFeeLiquidityDivisor`: a dynamic fee member's launch
    ///      liquidity divided by this is its pool's minimum dynamic fee liquidity (at least 1, at most 2^96 - 1);
    ///      zero is DYNAMIC_FEE_LIQUIDITY_DIVISOR, and a member without dynamic fees takes only zero. Bounds:
    ///      HookrLaunchChecks.familyBounds (2 to 10,000). `lockEndBlock`: zero, or a parent block from the family's
    ///      last guardEndBlock to the launch block + 100,000; the family's principal stays locked until the latest of
    ///      every member's lockEndBlock, its guards and its dev buys' locks (principalLockedUntil). `windowSeconds`,
    ///      `resetSeconds`, `carryBps`, `moveTicks` and `snipeCurve`: the member's Rules knobs
    ///      (HookrTypes.RulesKnobs), passed to its Rules as given and checked there at bind, except that a dynamic fee
    ///      member whose four tempo knobs are all zero takes the default tempo; zero tempo knobs on a member without
    ///      dynamic fees, and a zero snipeCurve for the linear default.
    struct MemberKnobs {
        /// @notice The share of a new token's supply the member is funded with, in basis points.
        uint16 subjectWeightBps;
        /// @notice The divisor of the member's launch liquidity that gives its minimum dynamic fee liquidity; zero for
        ///         the default.
        uint16 dynamicFeeLiquidityDivisor;
        /// @notice A parent block until which the family's principal stays locked, or zero.
        uint64 lockEndBlock;
        /// @notice The dynamic fee tempo's window, in seconds.
        uint16 windowSeconds;
        /// @notice The dynamic fee tempo's reset, in seconds.
        uint16 resetSeconds;
        /// @notice The share of its distance to the anchor the dynamic fee reference keeps per step, in basis points.
        uint16 carryBps;
        /// @notice The ticks an anchor move must carry the anchor to count.
        uint24 moveTicks;
        /// @notice The shape of a decaying Snipe, zero for linear.
        uint8 snipeCurve;
    }

    /// @notice A check that the members open at one price: member i's opening price, converted into member 0's quote
    ///         through `references[i - 1]`, must lie within `toleranceBps` (1 to 1,000) of member 0's opening price.
    /// @dev An empty check (no references, a zero tolerance) checks nothing. Otherwise every member after the first
    ///      names a reference pool on the PoolManager whose two currencies are its quote and member 0's quote, in
    ///      either order, initialized; its price is read when the family launches. The check binds the creator's own
    ///      launch, against the creator's own mistake: a reference pool moved earlier in the same transaction or block
    ///      moves the check with it, so pick deep references. It is not an oracle and keeps no state.
    struct OpeningCheck {
        /// @notice The widest relative gap between a member's converted opening price and member 0's, in basis points.
        uint16 toleranceBps;
        /// @notice The reference pool converting each member after the first into member 0's quote.
        PoolKey[] references;
    }

    /// @notice launchFamily's input: a launch's Token, root, Members and advisory configs, with each member's knobs,
    ///         up to one dev buy per member, a retained-supply cap and an opening check.
    /// @dev `maxRetainedBps` (0 to 10,000) caps, on a new token, the supply the creator holds when the launch returns
    ///      (the unplaced supply refunded plus every dev buy's subject) at floor(supply × maxRetainedBps / 10,000);
    ///      10,000 is no cap, and an existing-token family takes only 10,000. With any dev buy the dev buy bound
    ///      (MAX_DEV_BUY_BPS) applies too: a launch over it reverts DevBuyAboveCap, and one within it but over the
    ///      retained cap RetainedAboveCap. `tagline` (at most 160 bytes) and `logoURI` (at most 300 bytes) are a new
    ///      token's on-chain presentation, set on it for good in the launch (HookrToken.setPresentation); an
    ///      existing-token family takes only empty ones (InvalidFunding).
    struct LaunchParams {
        /// @notice The family's subject.
        Token token;
        /// @notice The root every member pool opens on.
        address root;
        /// @notice The family's members, one to eight.
        Member[] members;
        /// @notice Each member's knobs, one per member.
        MemberKnobs[] knobs;
        /// @notice Each member's advisory bind data, empty for a member without an advisory.
        bytes[] advisoryConfigs;
        /// @notice The dev buys, at most one per member.
        DevBuy[] buys;
        /// @notice The most of a new token's supply the creator may hold when the launch returns, in basis points.
        uint16 maxRetainedBps;
        /// @notice The opening price check across the members.
        OpeningCheck opening;
        /// @notice The timestamp after which the launch reverts.
        uint256 deadline;
        /// @notice A new token's tagline, at most 160 bytes.
        string tagline;
        /// @notice A new token's logo URI, at most 300 bytes.
        string logoURI;
    }

    /// @notice The family, position or recipient is invalid: its deadline passed, its members, root or quote currencies
    ///         are out of bounds, or the caller may not open the root.
    error InvalidFamily();
    /// @notice The call's native value, the token inputs or a balance do not match what the launch or liquidity change
    ///         needs.
    error InvalidFunding();
    /// @notice Member `member`'s pool `id` is already initialized.
    error PoolExists(uint8 member, PoolId id);
    /// @notice The caller is not the family's owner.
    error NotOwner();
    /// @notice `caller` is not the pending owner of family `familyId`.
    error NotPendingOwner(bytes32 familyId, address caller);
    /// @notice Member `member`'s principal of family `familyId` stays locked until block `untilBlock`.
    error PrincipalLocked(bytes32 familyId, uint8 member, uint256 untilBlock);
    /// @notice Member `member`'s guard ends at block `guardEndBlock`, beyond the 100,000 parent blocks a launch allows.
    error GuardTooLong(uint8 member, uint256 guardEndBlock);
    /// @notice `recipient` cannot receive the payout.
    error InvalidRecipient(address recipient);
    /// @notice `claims` selects a currency the family's members or the pool do not have.
    error InvalidClaims(uint256 claims);
    /// @notice `amount` is zero or otherwise invalid.
    error InvalidAmount(uint256 amount);
    /// @notice The PoolManager's callback did not complete the unlock this contract started.
    error InvalidCallback();
    /// @notice The call re-entered the Launcher.
    error Reentered();
    /// @notice A liquidity change broke the caller's bounds: an add pulled more than `max0` or `max1`, or a withdrawal
    ///         paid less principal than `min0` or `min1`.
    error Slippage();

    /// @notice A launchWithBuy input or dev-buy member outside the dev buy's bounds, or a pool whose price moved
    ///         before the dev buy.
    error InvalidDevBuy();

    /// @notice The creator would hold `held` subject when the launch returns, more than `cap`.
    error DevBuyAboveCap(uint256 held, uint256 cap);

    /// @notice The dev buy delivered `subjectOut`, less than `minSubjectOut`.
    error DevBuySlippage(uint256 subjectOut, uint256 minSubjectOut);

    /// @notice The dev buy spent `paid` of `quoteIn`: the band cannot absorb it at a pool without a quote take.
    error DevBuyPartialFill(uint256 paid, uint256 quoteIn);

    /// @notice `caller` may not change the launch fee: the registry's owner proposes and applies it, and the owner or
    ///         the guardian clears it.
    error NotFeeGovernor(address caller);

    /// @notice A launch fee above 0.01 of the native currency, or above zero with a treasury that has no code.
    error InvalidLaunchFee(uint256 fee, address treasury);

    /// @notice No proposed launch fee the caller can apply now: none pending, proposed by another owner, before its
    ///         `readyAt` or more than 14 days after it.
    error LaunchFeeNotReady(uint256 readyAt);

    /// @notice The treasury's target refused the launch fee.
    error LaunchFeeUndelivered(address target, uint256 fee);

    /// @notice A launchFamily retained cap above 10,000, or below it on an existing token.
    error InvalidRetainedCap(uint256 maxRetainedBps);

    /// @notice The creator would hold `held` subject when the launch returns, more than the family's retained cap.
    error RetainedAboveCap(uint256 held, uint256 cap);

    /// @notice Supply weights on some members only, summing above 10,000, or on an existing token.
    error InvalidWeights();

    /// @notice Member `member`'s subject budget is `budget`, not the `expected` share of supply its weight gives.
    error WeightMismatch(uint8 member, uint256 budget, uint256 expected);

    /// @notice Member `member`'s dynamicFeeLiquidityDivisor is out of bounds, or set on a member without dynamic fees.
    error InvalidDivisor(uint8 member, uint256 divisor);

    /// @notice Member `member`'s lockEndBlock is before the family's last guard end or past launch + 100,000.
    error InvalidLockEnd(uint8 member, uint256 lockEndBlock);

    /// @notice An opening check with references and a tolerance of zero or above 1,000.
    error OpeningToleranceOutOfRange(uint16 toleranceBps);

    /// @notice Member `member`'s reference pool does not hold exactly its quote and member 0's quote.
    error OpeningReferenceMismatch(uint8 member);

    /// @notice Member `member`'s reference pool is not initialized.
    error OpeningReferenceUninitialized(uint8 member);

    /// @notice Member `member`'s opening price, converted into member 0's quote, is outside [low, high]. All three are
    ///         prices of the subject in member 0's quote in Q64.96 (a sqrt price squared over 2^96), the converted one
    ///         rounded down and saturating at 2^256 - 1, `low` rounded up and `high` down. The check itself compares the
    ///         squared sqrt prices exactly (HookrLaunchChecks).
    error OpeningOutsideTolerance(uint8 member, uint256 converted, uint256 low, uint256 high);

    /// @notice A family launched.
    /// @param familyId The family.
    /// @param owner The family's first owner, the launch's caller.
    /// @param subject The family's subject token.
    /// @param root The root the members opened on.
    event FamilyLaunched(bytes32 indexed familyId, address indexed owner, address indexed subject, address root);

    /// @notice A family member's pool opened with its launch position.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param poolId The member's pool.
    /// @param quote The member's quote currency.
    /// @param liquidity The liquidity the launch position added.
    event MemberLaunched(
        bytes32 indexed familyId, uint8 member, PoolId indexed poolId, address quote, uint128 liquidity
    );

    /// @notice A launch's dev buy: `buyer`, the family owner, spent `quoteIn` on member `member` and received
    ///         `subjectOut`, net of Auto Burn. The pool opened at `sqrtPriceX96` and the buy left it at
    ///         `sqrtPriceAfterX96`; compare the opening price with the siblings' in one unit before reading the buy as
    ///         a price signal. The quote the buy left in the family's band is principal and can leave with it from
    ///         block `lockedUntil`; the buy's LP fee parts are the position's fees, collectable at once. Emitted once
    ///         per dev buy, right after the buy's Swap, HookFee and FeesAllocated logs and before that member's
    ///         MemberLaunched; the pool's PoolOpened comes before all of them. The unplaced supply refunded to the
    ///         owner is the launch's later subject Transfer from this contract, and with every dev buy's `subjectOut`
    ///         it is at most MAX_DEV_BUY_BPS of supply.
    /// @param familyId The family.
    /// @param poolId The member's pool.
    /// @param buyer The family owner who made the buy.
    /// @param member The member's index.
    /// @param quoteIn The quote spent.
    /// @param subjectOut The subject received, net of Auto Burn.
    /// @param sqrtPriceX96 The pool's opening price.
    /// @param sqrtPriceAfterX96 The pool's price after the buy.
    /// @param lockedUntil The block from which the quote the buy left in the band can leave with the principal.
    event DevBuyExecuted(
        bytes32 indexed familyId,
        PoolId indexed poolId,
        address indexed buyer,
        uint8 member,
        uint256 quoteIn,
        uint256 subjectOut,
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAfterX96,
        uint256 lockedUntil
    );

    /// @notice The registry's owner proposed a launch fee of `fee` wei paid to `treasury`'s target, from `readyAt`.
    /// @param fee The proposed fee in wei.
    /// @param treasury The treasury whose target is paid.
    /// @param readyAt The timestamp from which the fee can be applied.
    event LaunchFeeProposed(uint256 fee, address treasury, uint256 readyAt);

    /// @notice Every launch pays `fee` wei to `treasury`'s target from now on (zero: no fee).
    /// @param fee The fee in wei, zero for none.
    /// @param treasury The treasury whose target is paid.
    event LaunchFeeSet(uint256 fee, address treasury);

    /// @notice The launch of `familyId` paid `fee` wei to `target`, the treasury's target.
    /// @param familyId The family.
    /// @param target The treasury's target that received the fee.
    /// @param fee The fee paid in wei.
    event LaunchFeePaid(bytes32 indexed familyId, address indexed target, uint256 fee);

    /// @notice launchFamily funded each member with its weight's share of the new token's supply: `weightsBps[i]`
    ///         for member i, zero past the last member.
    /// @param familyId The family.
    /// @param weightsBps Each member's share of the supply in basis points, zero past the last member.
    event FamilyWeights(bytes32 indexed familyId, uint16[8] weightsBps);

    /// @notice A launchFamily launch of a new token returned with the creator holding `retained` subject from it
    ///         (unplaced supply plus dev buys), at most `cap`.
    /// @param familyId The family.
    /// @param retained The subject the creator holds from the launch.
    /// @param cap The retained cap in subject units.
    event FamilyRetained(bytes32 indexed familyId, uint256 retained, uint256 cap);

    /// @notice launchFamily's opening check passed at `toleranceBps`; `referencesHash` is keccak256(abi.encode(the
    ///         reference PoolKeys)).
    /// @param familyId The family.
    /// @param toleranceBps The tolerance the check passed at, in basis points.
    /// @param referencesHash The hash of the reference pool keys.
    event FamilyOpeningChecked(bytes32 indexed familyId, uint16 toleranceBps, bytes32 referencesHash);

    /// @notice A SKIP_TAKEN member whose PoolKey was already initialized. Its position stays empty. Its ERC-20
    ///         budgets are never pulled; a native quote budget sent with msg.value is refunded whole.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param poolId The already initialized pool.
    event MemberSkipped(bytes32 indexed familyId, uint8 member, PoolId indexed poolId);
    /// @notice A member's position lost liquidity.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param liquidity The liquidity removed.
    /// @param amount0 The currency0 paid.
    /// @param amount1 The currency1 paid.
    event LiquidityRemoved(bytes32 indexed familyId, uint8 member, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice A member's position gained liquidity.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param liquidity The liquidity added.
    /// @param amount0 The currency0 pulled.
    /// @param amount1 The currency1 pulled.
    event LiquidityAdded(bytes32 indexed familyId, uint8 member, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Emitted only when a position change realizes non-zero fees. `owner` is the family owner at that
    ///         moment; `recipient` is where the fees went (the payer, when an addition nets them).
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param poolId The member's pool.
    /// @param owner The family owner at that moment.
    /// @param recipient Where the fees went.
    /// @param amount0 The currency0 fees.
    /// @param amount1 The currency1 fees.
    event LPFeesCollected(
        bytes32 indexed familyId,
        uint8 member,
        PoolId indexed poolId,
        address indexed owner,
        address recipient,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice A transfer is pending until `pendingOwner` accepts. A zero `pendingOwner` cancels it. `claims` is
    ///         the owner's chosen fee form for its own accrued fees (see PendingTransfer).
    /// @param familyId The family.
    /// @param owner The current owner.
    /// @param pendingOwner The account that may accept, or zero when the transfer was cancelled.
    /// @param claims The owner's fee form for its own accrued fees.
    event FamilyTransferStarted(
        bytes32 indexed familyId, address indexed owner, address indexed pendingOwner, uint16 claims
    );
    /// @notice A pending transfer completed.
    /// @param familyId The family.
    /// @param owner The new owner.
    event FamilyTransferred(bytes32 indexed familyId, address indexed owner);
    /// @notice An owner redeemed PoolManager ERC-6909 claims through the Launcher.
    /// @param owner The holder of the burned claims.
    /// @param currency The currency redeemed.
    /// @param to The recipient.
    /// @param amount The amount redeemed.
    event ClaimsRedeemed(address indexed owner, Currency indexed currency, address indexed to, uint256 amount);
    /// @notice An idle balance was sent out of the Launcher.
    /// @param currency The currency swept.
    /// @param to The recipient.
    /// @param amount The amount swept.
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice Returns the PoolManager every family pool lives on.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the registry that admits roots, quotes and modules.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice Address that may accept a pending family transfer (or zero) and the current owner's fee form.
    /// @param familyId The family.
    /// @return pendingOwner The account that may accept the transfer, or zero.
    /// @return claims The current owner's fee form for its own accrued fees.
    function pendingFamilyOwner(bytes32 familyId) external view returns (address pendingOwner, uint16 claims);

    /// @notice Returns how many members a family has.
    /// @param familyId The family.
    /// @return The member count, zero for an unknown family.
    function memberCount(bytes32 familyId) external view returns (uint8);

    /// @notice Returns a member's managed position. Unknown members return zero fields.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @return p The member's position.
    function position(bytes32 familyId, uint8 member) external view returns (Position memory p);

    /// @notice block.number before which no member's principal can be withdrawn; zero if never locked.
    /// @dev The latest of the family's members' Anti-Snipe guardEndBlock (at most 100,000 parent blocks after
    ///      launch), DevBuy.lockBlocks past the launch block for each dev buy, and under launchFamily each member's
    ///      MemberKnobs.lockEndBlock (at most 100,000 parent blocks after launch).
    ///      While any member's Rules admit only this Launcher as LP, the owner can neither remove that pool's
    ///      liquidity nor pull a sibling's subject out to sell into it. Fee collection stays available.
    ///      This lock stops LP principal withdrawal only; it does not stop a creator from selling subject it holds
    ///      elsewhere (retained new-token supply, dev-bought subject, existing-token holdings, or subject bought
    ///      from a sibling pool, paid into its own locked position at a price it chose) into a guarded pool. The quote
    ///      a dev buy leaves in the family's band can leave with the principal from this block; its LP fee parts are
    ///      fees, collectable at once. Show creator-held subject and every member's guard with this value, never the
    ///      lock alone. The lock also keeps the owner from pulling liquidity if a quote asset fails during the guard.
    /// @param familyId The family.
    /// @return The block before which no member's principal can be withdrawn, or zero.
    function principalLockedUntil(bytes32 familyId) external view returns (uint256);

    /// @notice The PoolKey a member would use and whether it is still free. Keys ignore roles and creators, so
    ///         the first initialization of a (subject, quote, spacing, root) key blocks every later family that
    ///         names it; pick another tick spacing when `available` is false. A key can be taken between this
    ///         read and the launch; an existing-token launch with salt SKIP_TAKEN then launches the free members.
    /// @param subject The family's subject token.
    /// @param quote The member's quote currency.
    /// @param tickSpacing The member's tick spacing.
    /// @param rootAddress The root the member would open on.
    /// @return key The pool key the member would use.
    /// @return available True while the key is not yet initialized.
    function memberKey(address subject, Currency quote, int24 tickSpacing, address rootAddress)
        external
        view
        returns (PoolKey memory key, bool available);

    /// @notice Stable token identity. Other creators cannot consume this salt.
    /// @param creator The account that launches.
    /// @param token The token inputs, whose salt is scoped to the creator.
    /// @return The address the new token deploys to.
    function predictToken(address creator, Token calldata token) external view returns (address);

    /// @notice Atomically deploys or selects a token, funds every family member and refunds unused inputs.
    /// @dev Reverts PoolExists(member, id) when a member's key is already initialized, unless an existing-token
    ///      launch passes salt SKIP_TAKEN: that member is then skipped (MemberSkipped) and only a family with no
    ///      free member reverts. Only launched members' ERC-20 budgets (subject and quote) are pulled; msg.value is
    ///      still the native member's budget, skipped or not, plus the launch fee, and a skipped member's budget is
    ///      refunded whole. A dynamic fee member's minimum dynamic fee liquidity is its launch liquidity divided by
    ///      DYNAMIC_FEE_LIQUIDITY_DIVISOR, at least 1 and at most 2^96 - 1, and it binds the default dynamic fee tempo
    ///      and Snipe curve (HookrTypes.RulesKnobs); launchFamily's MemberKnobs set them per member.
    /// @param token The family's subject.
    /// @param rootAddress The root every member opens on.
    /// @param members The family's members.
    /// @param deadline The timestamp after which the call reverts.
    /// @return familyId The family.
    /// @return subject The family's subject token.
    function launch(Token calldata token, address rootAddress, Member[] calldata members, uint256 deadline)
        external
        payable
        returns (bytes32 familyId, address subject);

    /// @notice launch, where member i may bind its admitted advisory with the exact bytes advisoryConfigs[i].
    /// @dev A member without an advisory must pass empty bytes. The Root checks admission, phases, gas and the hash.
    /// @param token The family's subject.
    /// @param rootAddress The root every member opens on.
    /// @param members The family's members.
    /// @param advisoryConfigs Each member's advisory bind data, empty for a member without an advisory.
    /// @param deadline The timestamp after which the call reverts.
    /// @return familyId The family.
    /// @return subject The family's subject token.
    function launchAdvised(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        uint256 deadline
    ) external payable returns (bytes32 familyId, address subject);

    /// @notice launchAdvised for a new token, with its first buy (the dev buy) on member `buy.member`, made in the
    ///         same PoolManager unlock as that member's liquidity add and delivered to the caller.
    /// @dev The dev buy is an exact-input buy of `buy.quoteIn`, sent by this Launcher unauthenticated and priced from
    ///      the launch price. It pays every Rules leg its member charges a buy (base fee, the launch Snipe on a guarded
    ///      member, dynamic fee, LP Rewards, royalty, Auto Burn and the protocol share) and must fill in full. Its LP
    ///      parts accrue to the family's own position as fees, which the owner can collect at once. A guarded dev-buy
    ///      member must be guarded past this block, with a Snipe (snipeTaxPips above zero) and a maxBuyQuoteAmount of at
    ///      least `quoteIn`; there the buy counts against the cap and then closes the launch parent block to every other
    ///      buy on the member (see HookrRules.settleSwap). An unguarded member (guardEndBlock zero) takes a dev buy too:
    ///      it pays the member's Rules legs with no Snipe and no cap, and closes nothing. Either way the member's
    ///      protocolShareBps is any share HookrRules admits, and the protocol takes that share of the Snipe, dynamic
    ///      fee, LP Rewards and Auto Burn the buy pays; the launch-buy marker (launchBuyPool) is set for the swap; and
    ///      when the launch returns, the caller holds at most MAX_DEV_BUY_BPS of supply, dev-bought and unplaced
    ///      subject together (DevBuyAboveCap).
    ///      A plain launch followed by a buy in the same transaction is an ordinary buy: it pays the member's guard
    ///      like any buyer, but no MAX_DEV_BUY_BPS bounds it and it emits no DevBuyExecuted. The family's principal
    ///      (the liquidity, with the quote the buy left in the band) stays locked until the later of its guards and
    ///      `buy.lockBlocks` past this block. `msg.value` or the ERC-20 pull covers the member's liquidity budget plus
    ///      `quoteIn`, and `msg.value` the launch fee too; nothing of the buy is refunded. Call it with `minSubjectOut`
    ///      1 to read `subjectOut`. A band too small to fill the buy reverts DevBuyPartialFill when the member charges no
    ///      quote take, and from the root as UnauthenticatedRefund when it does.
    /// @param token The new token.
    /// @param rootAddress The root every member opens on.
    /// @param members The family's members.
    /// @param advisoryConfigs Each member's advisory bind data, empty for a member without an advisory.
    /// @param buy The dev buy.
    /// @param deadline The timestamp after which the call reverts.
    /// @return familyId The family.
    /// @return subject The family's subject token.
    /// @return subjectOut The subject the dev buy delivered to the caller, net of Auto Burn.
    function launchWithBuy(
        Token calldata token,
        address rootAddress,
        Member[] calldata members,
        bytes[] calldata advisoryConfigs,
        DevBuy calldata buy,
        uint256 deadline
    ) external payable returns (bytes32 familyId, address subject, uint256 subjectOut);

    /// @notice A Multi-pool launch: launchWithBuy for one to eight members, with each member's knobs, up to one dev
    ///         buy per member, a retained-supply cap and an opening price check across members (see LaunchParams).
    /// @dev Everything launch, launchAdvised and launchWithBuy do and check applies to each member, and each dev buy is
    ///      launchWithBuy's, run right after its member's add in that member's unlock. Then, beyond them: the knobs
    ///      (MemberKnobs), the retained cap and the opening check (OpeningCheck), checked by the linked library
    ///      HookrLaunchChecks before any pool opens. Every dev buy's subject counts toward one bound: the creator holds
    ///      at most MAX_DEV_BUY_BPS of supply when the launch returns, dev-bought and unplaced subject together
    ///      (DevBuyAboveCap), and at most the retained cap (RetainedAboveCap). Logs FamilyWeights when the members are
    ///      weighted, FamilyOpeningChecked when an opening check ran and, for a new token, FamilyRetained. `msg.value`
    ///      or the ERC-20 pulls cover each member's budget plus its dev buy's quoteIn, and `msg.value` the launch fee
    ///      too. A new token takes the LaunchParams' tagline and logo URI for good.
    /// @param p The launch: token, root, members and their knobs, advisory configs, dev buys, retained cap, opening
    ///        check, deadline and a new token's presentation.
    /// @return familyId The family.
    /// @return subject The family's subject.
    /// @return subjectOut The subject every dev buy delivered to the caller, net of Auto Burn.
    function launchFamily(LaunchParams calldata p)
        external
        payable
        returns (bytes32 familyId, address subject, uint256 subjectOut);

    /// @notice Remove liquidity, or pass zero to collect fees. Only the family owner can call. The PoolManager
    ///         pays `recipient` directly; principal is refused until principalLockedUntil(familyId). On a member
    ///         launched with recapture, the member's recapture accrual, in every currency, goes with its fees: into
    ///         `recipient`'s claims in the member's Rules (see claimRecapture). Such a member stays collectable after all of its liquidity
    ///         is withdrawn: a zero withdraw on the empty position calls no PoolManager and moves only the accrual.
    ///         `min0` and `min1` bound the principal the removal pays. The fees the position accrued since it was last
    ///         touched are paid on top of it (`LPFeesCollected`), so they never fill a shortfall below a bound, and a
    ///         fee collection, which pays no principal, passes zero bounds. Returns everything paid, fees included.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param liquidity The liquidity to remove, or zero to collect fees.
    /// @param min0 The least currency0 principal the removal pays.
    /// @param min1 The least currency1 principal the removal pays.
    /// @param recipient The account the PoolManager pays.
    /// @param deadline The timestamp after which the call reverts.
    /// @return amount0 The currency0 paid, fees included.
    /// @return amount1 The currency1 paid, fees included.
    function withdraw(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice withdraw, delivering currency0 (bit 0) and/or currency1 (bit 1) as PoolManager ERC-6909 claims.
    /// @dev Lets the unaffected side leave while the other asset is paused, fee-bearing or restricted for the
    ///      recipient. A claim moves no token; redeem it later with redeem() or any PoolManager unlock helper.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param liquidity The liquidity to remove, or zero to collect fees.
    /// @param min0 The least currency0 principal the removal pays.
    /// @param min1 The least currency1 principal the removal pays.
    /// @param recipient The account credited the claims or tokens.
    /// @param claims Bit 0 delivers currency0 and bit 1 delivers currency1 as claims.
    /// @param deadline The timestamp after which the call reverts.
    /// @return amount0 The currency0 delivered, fees included.
    /// @return amount1 The currency1 delivered, fees included.
    function withdrawWithClaims(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        uint8 claims,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Starts a two-step transfer of every family position to `newOwner`, who must call acceptFamily.
    ///         The current owner keeps full control until then and can re-target or cancel (zero) at any time.
    /// @param familyId The family.
    /// @param newOwner The account that may accept, or zero to cancel.
    /// @param claims The current owner's own fee form on acceptance: bits (2i, 2i+1) deliver member i's
    ///        currency0/currency1 fees to it as PoolManager ERC-6909 claims instead of tokens, so a token
    ///        restriction on the current owner cannot block acceptance. Only the current owner chooses it.
    function transferFamily(bytes32 familyId, address newOwner, uint16 claims) external;

    /// @notice Completes a pending transfer. Fees earned so far are first paid to the previous owner, in the form
    ///         it chose in transferFamily. If that delivery fails, the previous owner re-targets with claims.
    /// @param familyId The family.
    function acceptFamily(bytes32 familyId) external;

    /// @notice Add to a member's existing range. Collect old fees before funding new liquidity.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param liquidity The liquidity to add.
    /// @param max0 The most currency0 the add may pull.
    /// @param max1 The most currency1 the add may pull.
    /// @param deadline The timestamp after which the call reverts.
    /// @return amount0 The currency0 pulled.
    /// @return amount1 The currency1 pulled.
    function addLiquidity(
        bytes32 familyId,
        uint8 member,
        uint128 liquidity,
        uint128 max0,
        uint128 max1,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Burns `amount` of the caller's PoolManager ERC-6909 claim for `currency` and pays `recipient`.
    /// @dev The caller must first let this Launcher burn the claim, with
    ///      poolManager.approve(launcher, currency.toId(), amount) or poolManager.setOperator(launcher, true).
    ///      Only the caller's own claims can be redeemed. Delivery is exact: `recipient` must gain exactly
    ///      `amount`, so a currency that charges a transfer fee or rebases is refused here. Such a claim stays
    ///      redeemable only through a non-exact PoolManager unlock helper (the holder's own contract or an
    ///      EIP-7702 delegation calling unlock, burn and take), or after the asset drops its fee.
    /// @param currency The currency of the claim.
    /// @param amount The claim amount to burn.
    /// @param recipient The account paid.
    function redeem(Currency currency, uint256 amount, address recipient) external;

    /// @notice Sends this contract's whole idle balance of `currency` to `recipient`. Callable by anyone.
    /// @dev Every Launcher call returns its own balances to their starting values, so an idle balance can only
    ///      be a mistaken transfer or forced ETH. No family asset is ever held here between calls; this sweep is
    ///      safe only while that holds, so any future custody must exclude its balances from it. Reverts on a
    ///      zero balance. Delivery is exact, so a fee-on-transfer stray cannot be swept; ERC-6909 claims held by
    ///      this contract are not swept.
    /// @param currency The currency to sweep.
    /// @param recipient The account paid.
    /// @return amount The amount swept.
    function sweep(Currency currency, address recipient) external returns (uint256 amount);

    /// @notice Moves member `member`'s recapture liquidity owner accrual in its Rules, in every currency, into `to`'s
    ///         claims there, payable with the Rules' `claim`, `claimTo` or `claimAsClaims`; returns how many currencies
    ///         moved. Only the family owner can call: this contract holds the launch position, the pool's liquidity
    ///         owner in its Rules, so the LP shares its Rules cannot donate (no in-range liquidity, or a currency other
    ///         than the pool's two) reach the family owner and follow the family on transfer. Every
    ///         withdraw or fee collection on the member also moves it, to that call's recipient, including a zero
    ///         withdraw after all of the member's liquidity is withdrawn.
    /// @param familyId The family.
    /// @param member The member's index.
    /// @param to The account whose claims in the member's Rules receive the accrual.
    /// @return The number of currencies moved.
    function claimRecapture(bytes32 familyId, uint8 member, address to) external returns (uint256);
}
