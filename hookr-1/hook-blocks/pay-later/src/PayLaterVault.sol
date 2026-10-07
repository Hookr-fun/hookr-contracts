// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrFamilyLauncher} from "./interfaces/IHookrFamilyLauncher.sol";
import {IPayLaterVault} from "./interfaces/IPayLaterVault.sol";
import {PayLaterTerms} from "./PayLaterTerms.sol";
import {IHookrRulesClaims} from "./interfaces/IHookrRulesClaims.sol";

/// @title Pay Later vault (off-pool sidecar)
/// @notice Owns one Hookr Market Family through the Hookr 1 Launcher, collects its founding band's LP fees, and
///         sells covered calls on the subject tokens those fees paid. Sells pay the LP fee in the subject, so the
///         subject side of the band's fees becomes inventory; the quote side is owed to the beneficiary. A buyer
///         pays a premium (a share of the strike) to reserve inventory at a fixed strike until expiry. If the price
///         rose, the buyer pays the strike and receives the tokens; otherwise the reservation lapses and the buyer
///         has lost only the premium. The vault never lends, never transfers quote to a buyer and never liquidates.
/// @dev Plugs into Hookr 1 as a sidecar with no hook change: no Rules or Advisory admission, no new root, no new
///      launcher. It uses only public Hookr 1 surfaces: `HookrLauncher.transferFamily/acceptFamily/
///      withdrawWithClaims/redeem` for custody and fees, and `PoolManager.getSlot0` for price.
///
///      Custody. While the vault owns the family, no one can remove its principal: the vault only ever calls
///      `withdraw` with zero liquidity. `releaseFamily` (beneficiary only) hands the whole family back through the
///      Launcher's two-step transfer; it asks the Launcher to deliver the vault's last fees as ERC-6909 claims, so
///      nothing the vault does can block the hand-back. Reserved inventory is already in the vault, so a release
///      never uncovers an open position.
///
///      Strike. The reference is the highest of the reference pool's spot price and every price the vault recorded
///      in the last `priceWindowBlocks` blocks, and at least one recorded price must come from an earlier block.
///      Anyone can record a price (`poke`), and so do `harvest`, `open`, `exercise` and `expire`; a block keeps the
///      highest price recorded in it. Pushing the pool price down inside one transaction therefore cannot lower a
///      strike below any honest recording in the window. The residual (every recording in the window was made by
///      the manipulator) is priced in `test/PayLaterAttacks.t.sol` and is why the factory can require a dynamic fee
///      on the reference pool. Seller-conservative in the other direction: raising the reference only raises strikes, and
///      buyers bound what they pay with `maxStrike` and `maxPremium`.
///
///      Depth. New calls are sold only while the vault still owns the family and the reference pool's price is inside
///      the founding band, and one block may reserve at most `maxBlockDepthBps` of the band's virtual subject depth
///      L * 2^96 / s, evaluated at s = the higher of the reference and the recent high: the highest recorded price,
///      decaying linearly to zero over `anchorDecayBlocks` (a creator knob; the default is about a day of parent
///      blocks). Pushing the price down never enlarges the cap past what the recent high allows, and the band's depth
///      at any lower price is larger than the depth the cap assumes. Pushing it up to shrink the cap wears off within the decay, and the
///      reference used to price a call can stay above the band for the strike window, but it is clamped to the
///      band's top (`anchorCeiling`) before sizing the cap, so the cap never falls below the band's depth there.
///      `acceptFamily` refuses a band whose liquidity fell below `bandLiquidity`, and a band whose top is less than
///      10x the spot price (A1, below). The manipulator's round
///      trips pay the band's LP fee, and the vault owns the band; with the share at or below a quarter of the LP
///      fee rate (the factory's listing rule), those fees exceed what a cheaper strike on the capped amount is worth
///      (fuzzed in `test/PayLaterAttacks.t.sol` and `test/PayLaterReview.t.sol`). Above the band's top the pool
///      holds none of the band's liquidity and cannot see the market (known limit A1, open). After a release the band
///      can be withdrawn, so opens stop; existing positions stay exercisable because their tokens are already in
///      the vault.
///
///      Top guard (A1). The creator's `topGuardBps` refuses an open while the reference price is within that share
///      below the band-top price (`guardPrice`). Near and above the top the pool holds little or none of the band's
///      liquidity, so a dust sell can pin the price there whatever the market pays elsewhere; with the guard a
///      manipulator must first sell through the guard band, and hold it there for the whole price window, before a
///      call can be struck. Priced in `test/PayLaterHookr1.t.sol`. Band reach (A1): `acceptFamily` (beneficiary only)
///      takes custody only while the band-top price is at least 10x the higher of the spot price and every price
///      recorded in the window (`custodyReachBps`, `PayLaterTerms.MIN_BAND_REACH_BPS`, the factory's listing rule), so
///      the blind spot starts a 10x rally away and no one else can time a pending hand-over with a pushed price
///      (`test/PayLaterBandReach.t.sol`).
///
///      Protocol share. `protocolShareBps` (2,000 to 5,000, fixed at deployment) of every premium is owed to the
///      Hookr protocol recipient read from the reference pool's Rules, and `payProtocol` (anyone) pays it. Strikes
///      and fees stay the beneficiary's.
///
///      Recapture. On a family member launched with the recapture lane, the LP share of a push in one of the pool's
///      two currencies is donated to the pool's in-range liquidity, so the band's part arrives with its fees through
///      `harvest`. The LP share of a push in any other currency, or one that finds no liquidity in range, accrues to
///      the liquidity owner in the member's Rules, and the Launcher moves it into the family owner's Rules claims
///      with every fee collection. While the vault owns the family that owner is the vault, so `collectRecapture`
///      (anyone) claims it and credits it like a fee.
///
///      Clock. Windows and the no-same-block-exercise rule use `block.number`, which on Robinhood Chain (Arbitrum
///      Nitro) is the parent-chain height (~12 s blocks); expiry uses `block.timestamp`.
///
///      Assets. The subject must be an exact-transfer, non-rebasing ERC20 (every subject movement is checked to the
///      unit). The quote may be native ETH (address zero) or an ERC20. Premium and strike payments are checked to the
///      unit; a fee-on-transfer quote is refused at payment time.
contract PayLaterVault is IPayLaterVault {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;

    /// @notice The Hookr 1 Launcher that holds the family's positions.
    IHookrFamilyLauncher public immutable launcher;
    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The Hookr root that initialized the reference pool.
    address public immutable root;
    /// @notice The family whose founding band feeds this vault.
    bytes32 public immutable familyId;
    /// @notice The family member whose pool prices the calls and whose quote pays for them.
    uint8 public immutable member;
    /// @notice Number of members in the family, fixed at launch.
    uint8 public immutable memberCount;
    /// @notice The reference pool.
    PoolId public immutable poolId;
    /// @notice The subject token (always an ERC20).
    Currency public immutable subject;
    /// @notice The quote currency of the reference pool; premiums and strikes are paid in it.
    Currency public immutable quote;
    /// @notice Whether the subject is currency0 of the reference pool.
    bool public immutable subjectIsCurrency0;
    /// @notice The family's owner before the hand-over. Receives every earning and may release the family.
    address public immutable beneficiary;
    /// @notice Commitment to the terms (see `PayLaterTerms.hash`).
    bytes32 public immutable termsHash;
    /// @notice The founding band's liquidity. Constant while the vault owns the family: only the owner can change it
    ///         and the vault never does. `acceptFamily` refuses a band that has since shrunk below it.
    uint128 public immutable bandLiquidity;
    /// @notice Lower tick of the founding band.
    int24 public immutable bandTickLower;
    /// @notice Upper tick of the founding band.
    int24 public immutable bandTickUpper;
    /// @notice The subject's band-top price (normalized sqrt price, Q96): the ceiling used only when sizing depth.
    ///         Above the band's top the pool holds none of the band's liquidity and the price moves for free. Raw
    ///         observations still price strikes, but their value is capped here before it can size the depth cap.
    uint256 public immutable anchorCeiling;
    /// @notice Blocks over which the recorded high decays linearly to zero: the terms' `anchorDecayBlocks`, a creator
    ///         knob inside `PayLaterTerms` bounds (the suggested 7,200 is about a day of 12-second parent blocks).
    uint256 public immutable anchorDecayBlocks;
    /// @notice The terms' `topGuardBps`: zero turns the guard off.
    uint256 public immutable topGuardBps;
    /// @notice Normalized price (sqrt price squared over 2^96) at and above which an open is refused: the band-top
    ///         price times (1 - topGuardBps / 10,000). Unused while `topGuardBps` is zero.
    uint256 public immutable guardPrice;
    /// @notice Receives the protocol share of every premium: the reference pool's Rules' `protocolRecipient()`.
    address public immutable protocolRecipient;
    /// @notice Protocol share of every premium, in basis points (2,000 to 5,000).
    uint256 public immutable protocolShareBps;

    PayLaterTerms.Terms private _terms;

    /// @notice Subject units held as inventory and not reserved by any position.
    uint128 public accountedFree;
    /// @notice Subject units reserved by active positions.
    uint128 public accountedReserved;
    /// @notice Id the next position will get.
    uint256 public nextPositionId = 1;
    /// @notice Currency owed to the beneficiary: premiums, strikes, quote-side fees and subject above the cap.
    mapping(Currency currency => uint256 amount) public owed;
    /// @notice Quote owed to `protocolRecipient`: its share of premiums not yet paid by `payProtocol`.
    uint256 public protocolOwed;
    /// @notice Cumulative quote paid to `protocolRecipient`.
    uint256 public totalProtocolPaid;

    /// @notice Cumulative premiums received, in quote units.
    uint256 public totalPremium;
    /// @notice Cumulative strike payments received, in quote units.
    uint256 public totalStrikePaid;
    /// @notice Cumulative subject units delivered to buyers.
    uint256 public totalUnitsDelivered;
    /// @notice Cumulative subject units credited: harvested fees, redeemed claims and synced balances.
    uint256 public totalSubjectCredited;
    /// @dev Recorded high (normalized sqrt price, Q96) and the block it was set; see `recentHigh`.
    uint256 private _high;
    uint256 private _highBlock;

    mapping(uint256 id => Position) private _positions;
    /// @dev Contract-clock block => highest normalized sqrt price recorded in it (zero: none).
    mapping(uint256 blockNumber => uint256 value) private _observations;
    /// @dev (block.number << 128) | subject units reserved in that block.
    uint256 private _blockOpened;
    uint256 private transient _entered;

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary(msg.sender);
        _;
    }

    /// @param launcher_ The Hookr 1 Launcher that owns the family's positions.
    /// @param familyId_ The family to take over. Its current owner must be `beneficiary_`.
    /// @param member_ The member whose pool is the price reference and whose quote pays premiums and strikes.
    /// @param beneficiary_ The family's current owner; receives all earnings and may release the family.
    /// @param terms_ Economic terms, inside `PayLaterTerms` bounds.
    /// @param protocolShareBps_ Protocol share of every premium, from 2,000 to 5,000 basis points.
    constructor(
        IHookrFamilyLauncher launcher_,
        bytes32 familyId_,
        uint8 member_,
        address beneficiary_,
        PayLaterTerms.Terms memory terms_,
        uint16 protocolShareBps_
    ) {
        if (
            beneficiary_ == address(0) || address(launcher_).code.length == 0
                || protocolShareBps_ < PayLaterTerms.MIN_PROTOCOL_SHARE_BPS
                || protocolShareBps_ > PayLaterTerms.MAX_PROTOCOL_SHARE_BPS
        ) {
            revert InvalidConfig();
        }
        if (!PayLaterTerms.valid(terms_)) revert InvalidTerms();
        IPoolManager manager = launcher_.poolManager();
        IHookrRegistry registry = launcher_.registry();
        uint8 n = launcher_.memberCount(familyId_);
        if (!registry.isLauncher(address(launcher_)) || member_ >= n) revert InvalidConfig();
        if (launcher_.familyOwner(familyId_) != beneficiary_) revert InvalidConfig();
        IHookrFamilyLauncher.Position memory p = launcher_.position(familyId_, member_);
        address root_ = address(p.key.hooks);
        PoolId id = p.key.toId();
        if (
            p.liquidity == 0 || !registry.isRoot(root_) || address(IHookrRoot(root_).poolManager()) != address(manager)
                || !IHookrRoot(root_).knownPool(id)
        ) revert InvalidConfig();
        HookrTypes.PoolConfig memory pc = IHookrRoot(root_).poolConfig(id);
        if (Currency.unwrap(pc.subject) == address(0) || Currency.unwrap(pc.subject).code.length == 0) {
            revert InvalidConfig();
        }
        address recipient = IHookrRulesClaims(pc.rules).protocolRecipient();
        if (recipient == address(0)) revert InvalidConfig();
        protocolRecipient = recipient;
        protocolShareBps = protocolShareBps_;
        launcher = launcher_;
        poolManager = manager;
        root = root_;
        familyId = familyId_;
        member = member_;
        memberCount = n;
        poolId = id;
        subject = pc.subject;
        quote = pc.quote;
        bool subjectIs0 = pc.subject == p.key.currency0;
        subjectIsCurrency0 = subjectIs0;
        bandLiquidity = p.liquidity;
        bandTickLower = p.tickLower;
        bandTickUpper = p.tickUpper;
        // Same normalization (and rounding) as `_normalize`: an in-band price never records above this.
        uint256 top = subjectIs0
            ? uint256(TickMath.getSqrtPriceAtTick(p.tickUpper))
            : FullMath.mulDivRoundingUp(Q96, Q96, TickMath.getSqrtPriceAtTick(p.tickLower));
        anchorCeiling = top;
        anchorDecayBlocks = terms_.anchorDecayBlocks;
        topGuardBps = terms_.topGuardBps;
        guardPrice = FullMath.mulDiv(FullMath.mulDiv(top, top, Q96), BPS - terms_.topGuardBps, BPS);
        beneficiary = beneficiary_;
        termsHash = PayLaterTerms.hash(terms_);
        _terms = terms_;
    }

    /// @notice Accepts native ETH: fee collection and claim redemption deliver the quote by call. Untracked ETH
    ///         (a stray transfer) is credited to the beneficiary by `sync`.
    receive() external payable {}

    /// @inheritdoc IPayLaterVault
    function terms() external view returns (PayLaterTerms.Terms memory) {
        return _terms;
    }

    /// @inheritdoc IPayLaterVault
    function acceptFamily() external nonReentrant onlyBeneficiary {
        address previous = launcher.familyOwner(familyId);
        if (previous != beneficiary) revert WrongPreviousOwner(previous);
        // The depth cap is priced on `bandLiquidity`, frozen at construction. The owner could have removed band
        // liquidity since (after listing, or while the family was released), which would void the listing rule.
        // Only the owner can change a band and the Launcher cannot re-range one, so checking here is enough.
        uint128 live = launcher.position(familyId, member).liquidity;
        if (live < bandLiquidity) revert BandLiquidityChanged(bandLiquidity, live);
        // Limit A1: above the band's top the reference cannot see the market. Custody starts (also on a re-hand after a
        // release) only while the band-top price is at least 10x the higher of the spot price and every price recorded
        // in the window, the factory's listing rule. Only the beneficiary can complete the hand-over, so no one else
        // can time a pending transfer with a pushed price, and a push around the beneficiary's own call cannot go
        // below a recording.
        uint256 reach = custodyReachBps();
        if (reach < PayLaterTerms.MIN_BAND_REACH_BPS) {
            revert BandReachTooShort(reach, PayLaterTerms.MIN_BAND_REACH_BPS);
        }
        launcher.acceptFamily(familyId);
        _observe();
        emit FamilyAccepted(familyId, previous);
    }

    /// @inheritdoc IPayLaterVault
    function releaseFamily() external nonReentrant onlyBeneficiary {
        uint16 claims = uint16((uint256(1) << (2 * uint256(memberCount))) - 1);
        launcher.transferFamily(familyId, beneficiary, claims);
        emit FamilyReleased(familyId, beneficiary, claims);
    }

    /// @inheritdoc IPayLaterVault
    function harvest(uint8 m) external nonReentrant returns (uint256 subjectIn, uint256 otherIn) {
        return _harvest(m, 0);
    }

    /// @inheritdoc IPayLaterVault
    function harvestWithClaims(uint8 m, uint8 claims)
        external
        nonReentrant
        returns (uint256 subjectIn, uint256 otherIn)
    {
        return _harvest(m, claims);
    }

    /// @dev Collects member `m`'s LP fees (zero liquidity: principal never moves). `claims` bits 0 and 1 deliver
    ///      currency0 and currency1 as PoolManager ERC-6909 claims instead of tokens (the Launcher's
    ///      `withdrawWithClaims`; zero is exactly `withdraw`). A claim is credited only when `redeemClaims` turns it
    ///      into tokens, so the token deltas measured here are what this call credits.
    function _harvest(uint8 m, uint8 claims) private returns (uint256 subjectIn, uint256 otherIn) {
        if (launcher.familyOwner(familyId) != address(this)) revert NotFamilyOwner();
        IHookrFamilyLauncher.Position memory p = launcher.position(familyId, m);
        Currency other = p.key.currency0 == subject ? p.key.currency1 : p.key.currency0;
        uint256 subjectBefore = _balance(subject);
        uint256 otherBefore = _balance(other);
        launcher.withdrawWithClaims(familyId, m, 0, 0, 0, address(this), claims, block.timestamp);
        subjectIn = _balance(subject) - subjectBefore;
        otherIn = _balance(other) - otherBefore;
        uint256 toInventory = _creditSubject(subjectIn);
        owed[other] += otherIn;
        _observe();
        _assertSolvent();
        emit Harvested(m, subjectIn, toInventory, other, otherIn);
    }

    /// @inheritdoc IPayLaterVault
    function redeemClaims(Currency currency) external nonReentrant returns (uint256 amount) {
        uint256 id = currency.toId();
        uint256 claim = poolManager.balanceOf(address(this), id);
        if (claim == 0) revert AmountZero();
        poolManager.approve(address(launcher), id, claim);
        uint256 before = _balance(currency);
        launcher.redeem(currency, claim, address(this));
        amount = _balance(currency) - before;
        _credit(currency, amount);
        _assertSolvent();
    }

    /// @inheritdoc IPayLaterVault
    function collectRecapture(uint8 m, Currency currency, bool asClaims)
        external
        nonReentrant
        returns (uint256 amount)
    {
        IHookrRulesClaims rules = _rulesOf(m);
        if (asClaims) {
            // Arrives as a PoolManager ERC-6909 claim; `redeemClaims` credits it once the currency moves again.
            amount = rules.claimAsClaims(currency, address(this));
        } else {
            uint256 before = _balance(currency);
            rules.claim(currency);
            amount = _balance(currency) - before;
            _credit(currency, amount);
            _assertSolvent();
        }
        emit RecaptureCollected(m, currency, amount, asClaims);
    }

    /// @inheritdoc IPayLaterVault
    function payProtocol() external nonReentrant returns (uint256 amount) {
        amount = protocolOwed;
        if (amount == 0) revert AmountZero();
        protocolOwed = 0;
        totalProtocolPaid += amount;
        _send(quote, protocolRecipient, amount);
        _assertSolvent();
        emit ProtocolPaid(protocolRecipient, amount);
    }

    /// @inheritdoc IPayLaterVault
    function sync(Currency currency) external nonReentrant returns (uint256 amount) {
        uint256 held = _balance(currency);
        uint256 accounted = _tracked(currency);
        if (held < accounted) revert InventoryDeficit();
        amount = held - accounted;
        if (amount == 0) revert AmountZero();
        _credit(currency, amount);
    }

    /// @inheritdoc IPayLaterVault
    function poke() external nonReentrant {
        _observe();
    }

    /// @inheritdoc IPayLaterVault
    function open(uint128 units, uint256 maxStrike, uint256 maxPremium, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 id, uint256 strike, uint256 premium)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (launcher.familyOwner(familyId) != address(this)) revert FamilyNotHeld();
        PayLaterTerms.Terms memory t = _terms;
        if (units < t.minOrderUnits || units > t.maxOrderUnits) revert BadOrderSize(units);
        if (units > accountedFree) revert InventoryShortfall(units, accountedFree);
        uint256 active = uint256(accountedReserved) + units;
        if (active > t.maxActiveUnits) revert ActiveCapExceeded(active, t.maxActiveUnits);
        uint256 word = _blockOpened;
        // forge-lint: disable-next-line(unsafe-typecast) low 128 bits hold the block's reserved units by design
        uint256 opened = (word >> 128 == block.number ? uint128(word) : 0) + units;
        if (opened > t.maxUnitsPerBlock) revert BlockCapExceeded(opened, t.maxUnitsPerBlock);
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        if (tick < bandTickLower || tick >= bandTickUpper) revert BandOutOfRange(tick);
        uint256 reference_ = _reference(t.priceWindowBlocks, _normalize(sqrtPriceX96));
        if (t.topGuardBps != 0) {
            uint256 referencePrice_ = FullMath.mulDiv(reference_, reference_, Q96);
            if (referencePrice_ >= guardPrice) revert NearBandTop(referencePrice_, guardPrice);
        }
        uint256 depth = _depth(reference_);
        if (opened * BPS > depth * t.maxBlockDepthBps) {
            revert DepthCapExceeded(opened, depth * t.maxBlockDepthBps / BPS);
        }
        (strike, premium) = _price(units, reference_, t);
        if (strike > maxStrike) revert StrikeAboveMaximum(strike, maxStrike);
        if (premium > maxPremium) revert PremiumAboveMaximum(premium, maxPremium);

        uint64 expiry = uint64(block.timestamp + t.tenor);
        id = nextPositionId++;
        _positions[id] = Position({
            holder: msg.sender,
            openedBlock: uint64(block.number),
            status: Status.Active,
            expiry: expiry,
            units: units,
            exercised: 0,
            strike: strike,
            strikePaid: 0,
            premium: premium
        });
        _blockOpened = (block.number << 128) | opened;
        accountedFree -= units;
        accountedReserved += units;
        uint256 protocolCut = premium * protocolShareBps / BPS;
        protocolOwed += protocolCut;
        owed[quote] += premium - protocolCut;
        totalPremium += premium;
        _observe();
        _collect(premium);
        _assertSolvent();
        emit PositionOpened(id, msg.sender, units, strike, premium, expiry, reference_);
    }

    /// @inheritdoc IPayLaterVault
    function exercise(uint256 id, uint128 units, uint256 maxPayment, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 payment)
    {
        Position storage p = _position(id);
        if (p.holder != msg.sender) revert NotHolder(msg.sender);
        if (p.status != Status.Active) revert NotActive(id);
        if (block.number <= p.openedBlock) revert TooEarly(id);
        if (block.timestamp >= p.expiry) revert PositionExpired(id);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);
        uint256 target = uint256(p.exercised) + units;
        if (units == 0 || target > p.units) revert BadExercise(units);
        // Cumulative ceiling: after any sequence of partial exercises the buyer has paid at least the pro-rata
        // strike, and exactly the strike once every unit is bought.
        uint256 due = FullMath.mulDivRoundingUp(p.strike, target, p.units);
        payment = due - p.strikePaid;
        if (payment > maxPayment) revert PaymentAboveMaximum(payment, maxPayment);

        // forge-lint: disable-next-line(unsafe-typecast) target <= p.units, a uint128
        p.exercised = uint128(target);
        p.strikePaid = due;
        if (target == p.units) p.status = Status.Exercised;
        accountedReserved -= units;
        owed[quote] += payment;
        totalStrikePaid += payment;
        totalUnitsDelivered += units;
        _observe();
        _collect(payment);
        _sendSubjectExact(recipient, units);
        _assertSolvent();
        emit Exercised(id, msg.sender, recipient, units, payment);
    }

    /// @inheritdoc IPayLaterVault
    function expire(uint256 id) external nonReentrant {
        Position storage p = _position(id);
        if (p.status != Status.Active) revert NotActive(id);
        if (block.timestamp < p.expiry) revert NotExpired(id);
        uint128 remaining = p.units - p.exercised;
        p.status = Status.Expired;
        accountedReserved -= remaining;
        accountedFree += remaining;
        _observe();
        emit Expired(id, remaining);
    }

    /// @inheritdoc IPayLaterVault
    function withdrawEarnings(Currency currency, address to, uint256 amount) external nonReentrant onlyBeneficiary {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (amount == 0) revert AmountZero();
        uint256 available = owed[currency];
        if (amount > available) revert AmountExceedsAvailable(amount, available);
        owed[currency] = available - amount;
        _send(currency, to, amount);
        _assertSolvent();
        emit EarningsWithdrawn(currency, to, amount);
    }

    /// @inheritdoc IPayLaterVault
    function withdrawInventory(address to, uint128 amount) external nonReentrant onlyBeneficiary {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (amount == 0) revert AmountZero();
        if (amount > accountedFree) revert AmountExceedsAvailable(amount, accountedFree);
        accountedFree -= amount;
        _send(subject, to, amount);
        _assertSolvent();
        emit InventoryWithdrawn(to, amount);
    }

    /// @inheritdoc IPayLaterVault
    function transferClaims(Currency currency, address to, uint256 amount) external nonReentrant onlyBeneficiary {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (amount == 0) revert AmountZero();
        poolManager.transfer(to, currency.toId(), amount);
        emit ClaimsTransferred(currency, to, amount);
    }

    /// @inheritdoc IPayLaterVault
    function position(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @inheritdoc IPayLaterVault
    function quoteOpen(uint128 units)
        external
        view
        returns (uint256 strike, uint256 premium, uint256 referenceSqrtPriceX96)
    {
        PayLaterTerms.Terms memory t = _terms;
        referenceSqrtPriceX96 = _reference(t.priceWindowBlocks, _spot());
        (strike, premium) = _price(units, referenceSqrtPriceX96, t);
    }

    /// @inheritdoc IPayLaterVault
    function referencePrice() external view returns (uint256) {
        return _reference(_terms.priceWindowBlocks, _spot());
    }

    /// @notice The recorded high after linear decay: the depth cap's anchor floor. Never above `anchorCeiling`.
    function recentHigh() public view returns (uint256) {
        uint256 elapsed = block.number - _highBlock;
        if (elapsed >= anchorDecayBlocks) return 0;
        return _high - _high * elapsed / anchorDecayBlocks;
    }

    /// @notice Most subject units one block may reserve under the depth cap. The raw reference still prices strikes,
    ///         but its contribution to the cap is limited to `anchorCeiling`.
    function blockDepthCap() external view returns (uint256) {
        return _depth(_reference(_terms.priceWindowBlocks, _spot())) * _terms.maxBlockDepthBps / BPS;
    }

    /// @inheritdoc IPayLaterVault
    function custodyReachBps() public view returns (uint256) {
        (uint256 high,) = _windowHigh(_terms.priceWindowBlocks, _spot());
        return PayLaterTerms.bandReachBps(anchorCeiling, high);
    }

    /// @inheritdoc IPayLaterVault
    function spotPrice() external view returns (uint256) {
        return _spot();
    }

    /// @notice The highest normalized sqrt price recorded in `blockNumber`, or zero.
    function observation(uint256 blockNumber) external view returns (uint256) {
        return _observations[blockNumber];
    }

    /// @notice Balance of `currency` the vault has accounted: owed earnings, plus inventory for the subject.
    function tracked(Currency currency) external view returns (uint256) {
        return _tracked(currency);
    }

    /// @inheritdoc IPayLaterVault
    function accountingInvariant() public view returns (bool) {
        return _balance(subject) >= _tracked(subject) && _balance(quote) >= _tracked(quote);
    }

    /// @dev The strike reference: max(spot, every recording in [now - window, now]); at least one recording must be
    ///      from an earlier block, so a single transaction cannot supply the only evidence.
    function _reference(uint256 window, uint256 spot) private view returns (uint256 best) {
        bool earlier;
        (best, earlier) = _windowHigh(window, spot);
        if (!earlier) revert NoRecentObservation();
    }

    /// @dev max(spot, every recording in [now - window, now]), and whether a recording from an earlier block exists.
    function _windowHigh(uint256 window, uint256 spot) private view returns (uint256 best, bool earlier) {
        best = spot;
        uint256 current = block.number;
        uint256 first = current > window ? current - window : 0;
        for (uint256 b = first; b <= current; ++b) {
            uint256 v = _observations[b];
            if (v == 0) continue;
            if (v > best) best = v;
            if (b < current) earlier = true;
        }
    }

    /// @dev Strike for `units` at normalized sqrt price `s` (Q96) and the terms' markup; premium on the strike.
    ///      Every step rounds up, in the vault's favour.
    function _price(uint256 units, uint256 s, PayLaterTerms.Terms memory t)
        private
        pure
        returns (uint256 strike, uint256 premium)
    {
        uint256 atReference = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(units, s, Q96), s, Q96);
        strike = FullMath.mulDivRoundingUp(atReference, BPS + t.strikeMarkupBps, BPS);
        premium = FullMath.mulDivRoundingUp(strike, t.premiumBps, BPS);
        if (premium < t.minPremium) premium = t.minPremium;
    }

    /// @dev Spot price of the subject in the quote as a Q96 square root: sqrtPriceX96 when the subject is currency0,
    ///      2^192 / sqrtPriceX96 (rounded up) when it is currency1.
    function _spot() private view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return _normalize(sqrtPriceX96);
    }

    function _normalize(uint160 sqrtPriceX96) private view returns (uint256) {
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        return subjectIsCurrency0 ? uint256(sqrtPriceX96) : FullMath.mulDivRoundingUp(Q96, Q96, sqrtPriceX96);
    }

    /// @dev Records the spot price for this block (keeping the block's highest) and refreshes the recent high. The
    ///      strike window keeps the raw price (seller-conservative); the recent high, which only sizes the depth cap,
    ///      is clamped to `anchorCeiling`, so a pump through the band's top cannot collapse the cap (review F3).
    function _observe() private {
        uint256 v = _spot();
        if (v > _observations[block.number]) {
            _observations[block.number] = v;
            emit Observed(block.number, v);
        }
        uint256 anchor = v < anchorCeiling ? v : anchorCeiling;
        if (anchor > recentHigh()) {
            _high = anchor;
            _highBlock = block.number;
        }
    }

    /// @dev Virtual subject depth of the founding band at the higher of the depth-clamped reference and recent high.
    function _depth(uint256 reference_) private view returns (uint256) {
        uint256 high = recentHigh();
        uint256 cappedReference = reference_ < anchorCeiling ? reference_ : anchorCeiling;
        return FullMath.mulDiv(bandLiquidity, Q96, cappedReference > high ? cappedReference : high);
    }

    /// @dev Credits `amount` of the subject to inventory up to the cap; the rest is owed to the beneficiary.
    function _creditSubject(uint256 amount) private returns (uint256 toInventory) {
        if (amount == 0) return 0;
        totalSubjectCredited += amount;
        uint256 held = uint256(accountedFree) + accountedReserved;
        uint256 cap = _terms.maxInventory;
        uint256 room = held >= cap ? 0 : cap - held;
        toInventory = amount < room ? amount : room;
        // forge-lint: disable-next-line(unsafe-typecast) toInventory <= room <= maxInventory <= 1e36
        accountedFree += uint128(toInventory);
        owed[subject] += amount - toInventory;
    }

    function _credit(Currency currency, uint256 amount) private {
        uint256 toInventory;
        if (currency == subject) toInventory = _creditSubject(amount);
        else owed[currency] += amount;
        emit Credited(currency, amount, toInventory);
    }

    function _tracked(Currency currency) private view returns (uint256 amount) {
        amount = owed[currency];
        if (currency == subject) amount += uint256(accountedFree) + accountedReserved;
        else if (currency == quote) amount += protocolOwed;
    }

    /// @dev The Rules of member `m`'s pool: where its recapture accrual becomes the family owner's claims.
    function _rulesOf(uint8 m) private view returns (IHookrRulesClaims) {
        PoolKey memory k = launcher.position(familyId, m).key;
        if (address(k.hooks) == address(0)) revert InvalidConfig();
        return IHookrRulesClaims(IHookrRoot(address(k.hooks)).poolConfig(k.toId()).rules);
    }

    function _position(uint256 id) private view returns (Position storage p) {
        p = _positions[id];
        if (p.status == Status.None) revert UnknownPosition(id);
    }

    function _balance(Currency currency) private view returns (uint256) {
        return Currency.unwrap(currency) == address(0)
            ? address(this).balance
            : IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// @dev Takes exactly `amount` of the quote from the caller: the call value for native, a pull for an ERC20.
    function _collect(uint256 amount) private {
        if (Currency.unwrap(quote) == address(0)) {
            if (msg.value != amount) revert WrongPayment(amount, msg.value);
            return;
        }
        if (msg.value != 0) revert WrongPayment(0, msg.value);
        if (amount == 0) return;
        IERC20 token = IERC20(Currency.unwrap(quote));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != before + amount) revert InexactTransfer();
    }

    /// @dev Delivers subject to a buyer; both sides must move by exactly `amount`.
    function _sendSubjectExact(address to, uint256 amount) private {
        IERC20 token = IERC20(Currency.unwrap(subject));
        uint256 mine = token.balanceOf(address(this));
        uint256 theirs = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) + amount != mine || token.balanceOf(to) != theirs + amount) {
            revert InexactTransfer();
        }
    }

    /// @dev Pays the beneficiary's chosen recipient; the vault's own balance must drop by exactly `amount`.
    function _send(Currency currency, address to, uint256 amount) private {
        if (Currency.unwrap(currency) == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
            return;
        }
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 mine = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) + amount != mine) revert InexactTransfer();
    }

    function _assertSolvent() private view {
        if (!accountingInvariant()) revert InventoryDeficit();
    }
}
