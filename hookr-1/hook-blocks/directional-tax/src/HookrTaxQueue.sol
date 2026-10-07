// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrTreasury} from "hookr/interfaces/IHookrTreasury.sol";
import {IHookrTaxQueue} from "./interfaces/IHookrTaxQueue.sol";
import {HookrTaxQueueTypes} from "./types/HookrTaxQueueTypes.sol";
import {IHookrStraySweep} from "./interfaces/IHookrStraySweep.sol";
import {IHookrRulesClaimExit} from "./interfaces/IHookrRulesClaimExit.sol";
import {HookrFeeConversionTypes} from "./types/HookrFeeConversionTypes.sol";
import {IHookrFeeRouteRegistry} from "./interfaces/IHookrFeeRouteRegistry.sol";
import {IHookrFeeSwapExecutor} from "./interfaces/IHookrFeeSwapExecutor.sol";
import {HookrAsset} from "./libraries/HookrAsset.sol";
import {HookrCloneArgs} from "./libraries/HookrCloneArgs.sol";

/// @title HookrTaxQueue
/// @notice Claim queue for one direction of one pool's directional tax. The pool's HookrRules credits the tax to
///         this address as a quote claim during the swap; everything else happens here, later, off the trade path.
/// @dev Deployed once as an implementation by `HookrDirectionalTax`, then cloned per pool and direction as an
///      ERC-1167 proxy whose immutable arguments are the frozen `Terms`. There is no owner, setter, pause or upgrade.
///
///      Flow: `settle` pulls the Rules claim and books every unbooked quote unit, splitting it once at the frozen
///      protocol share (protocol amount rounded down, so the creator absorbs no rounding loss). The booked protocol
///      share can only leave as quote (`sweepProtocol`), to the account the frozen protocol recipient names: the
///      recipient itself when it has no code, otherwise the current `target()` of the HookrTreasury it is, the account
///      the treasury's own `collectTo` pays. The share never passes through the treasury, whose own address an issuer
///      can restrict and which forwards a token balance only within its `DELIVERY_GAS`. The creator share can only
///      leave as the route's output asset to the frozen `assetRecipient` through a signed plan (`process`), as quote to
///      `assetRecipient` when no route is set (`payCreator`), or as quote to the frozen `recoveryRecipient`
///      (`recover`) once either the route is retired and `RECOVERY_DELAY` has passed, or the booked share has waited
///      the queue's frozen `staleRecoveryDelay` (the creator's launch choice) with no successful conversion. The
///      second condition needs no owner or signer action, so a lost signer key, a never-unpaused authorizer or a
///      recipient that refuses the output cannot freeze the share.
///      These five functions are permissionless because the caller chooses no destination and, for `process`, the
///      signer's plan fixes the amount and price bound, and may name the only account allowed to run it.
///
///      Nothing here is reachable from a swap: the swap only credits a Rules claim. A failing conversion route,
///      paused authorizer, blocked recipient or unsettled queue therefore cannot fail a trade.
///      Issuer quotes: when the Rules claim cannot be pulled as the quote token (an issuer freeze of this queue, a
///      transfer fee, a pause), `settle` moves it out as PoolManager ERC-6909 claims of the quote instead, split at
///      the frozen share straight to the creator's quote destination (the asset recipient of a direct leg, the
///      recovery recipient of a routed one) and, for the protocol part, to the account `sweepProtocol` pays, which
///      can move ERC-6909 claims where a HookrTreasury cannot (it has no function that moves its own ERC-6909
///      balance). Holders turn those claims into the token through `HookrClaimRedeemer`. The pull runs with
///      exactly `CLAIM_GAS`, so the gas a caller sends never decides between the token and this exit. Booked quote
///      pays out with a measured debit: this queue's balance must fall by exactly the amount, and the recipient
///      bears any issuer transfer fee.
///
///      Quote that reaches this address by any other path (a direct transfer, another pool's royalty naming it) is
///      booked as income at the next settle, at the same split. Any other asset sent here by mistake (a token that is
///      not the quote, native ETH on an ERC-20 quote, route output sent directly) is a stray: only the route
///      registry, for its owner after the timelock, can send it on (`sweepStray`), and that path cannot reach the quote.
contract HookrTaxQueue is HookrReleased, IHookrTaxQueue, IHookrStraySweep {
    /// @notice Basis-point denominator of the protocol share.
    uint256 public constant BPS = 10_000;
    /// @notice Time after a route's retirement before the creator share can be recovered as quote, unless the share's
    ///         own stale-recovery wait ends first. The same for every queue on a route, because retirement is the
    ///         curator's act on the route, not a pool's choice.
    uint256 public constant RECOVERY_DELAY = 7 days;
    /// @notice Gas the pull of the Rules claim runs with, exactly, whatever the caller sends. A call that cannot give
    ///         the pull this much reverts `ClaimOutOfGas` before trying it, and gas above it never reaches the pull.
    ///         A quote whose delivery needs more than this leaves by the ERC-6909 exit, the same for every caller.
    uint256 public constant CLAIM_GAS = 500_000;
    /// @dev What the call itself and the code between the gas check and the call may spend, on top of the grant and
    ///      the 1/64 the call keeps back (the core lane's `LANE_MARGIN`).
    uint256 private constant CLAIM_GAS_MARGIN = 5_000;
    /// @dev Gas for reading a treasury protocol recipient's `target()`: its dispatch and one cold storage read (the
    ///      call's own account access is paid outside this grant).
    uint256 private constant TARGET_READ_GAS = 30_000;
    uint256 private constant TERMS_BYTES = 352;
    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.tax-queue")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT = 0x513cddebd8c6f45c8f40fef001877205fcca251e3048f1f53b1ceea736642700;
    /// @dev keccak256("hookr.tax-queue.transient.lock")
    bytes32 private constant LOCK = keccak256("hookr.tax-queue.transient.lock");

    address private immutable _advisory;
    address private immutable _implementation;
    /// @notice The signed-plan executor every conversion goes through.
    IHookrFeeSwapExecutor public immutable executor;
    /// @notice The route registry the executor reads; used here for route status and output asset, and the only caller
    ///         of `sweepStray`.
    IHookrFeeRouteRegistry public immutable routeRegistry;

    /// @custom:storage-location erc7201:hookr.tax-queue
    struct State {
        HookrTaxQueueTypes.Ledger ledger;
        /// @dev Routed queues only: when the current wait of the creator share began. Set when a share is booked onto
        ///      an empty creator balance, restarted by each successful conversion, cleared when the share is paid out.
        uint256 creatorWaitingSince;
    }

    error NotAClone();
    error ReentrantCall();
    error NothingDue();
    error ConversionDisabled();
    error DirectPayoutDisabled();
    error InvalidPlan();
    error AmountAboveAvailable(uint256 amount, uint256 available);
    error QuoteMismatch(uint256 expected, uint256 spent);
    error TooLittleReceived(uint256 minimum, uint256 received);
    error RouteStillActive(bytes32 routeId);
    error RecoveryDelayActive(uint256 availableAt);
    /// @notice The call has less gas than the pull of the Rules claim needs: `CLAIM_GAS`, the 1/64 the call keeps
    ///         back and a margin.
    error ClaimOutOfGas(uint256 available, uint256 required);
    /// @notice The frozen protocol recipient names no account the protocol share can be paid to (`_protocolTo`).
    error NoProtocolDestination();

    /// @param executor_ The signed-plan executor; its route registry is read once here.
    constructor(IHookrFeeSwapExecutor executor_) {
        _advisory = msg.sender;
        _implementation = address(this);
        executor = executor_;
        routeRegistry = executor_.routeRegistry();
    }

    modifier onlyClone() {
        if (address(this) == _implementation) revert NotAClone();
        _;
    }

    modifier nonReentrant() {
        bytes32 slot = LOCK;
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked != 0) revert ReentrantCall();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @notice Accepts quote paid out by the PoolManager on a Rules claim, and native route output.
    /// @dev Anything else that arrives in the quote asset is booked as income at the next settle.
    receive() external payable {}

    /// @inheritdoc IHookrTaxQueue
    /// @dev Identifies the deployer only. A clone of this implementation deployed by anyone else reports the same
    ///      value; `HookrDirectionalTax.isQueue` is the source of truth for genuine queues.
    function advisory() external view returns (address) {
        return _advisory;
    }

    /// @inheritdoc IHookrTaxQueue
    function terms() external view onlyClone returns (HookrTaxQueueTypes.Terms memory) {
        return _terms();
    }

    /// @inheritdoc IHookrTaxQueue
    function ledger() external view onlyClone returns (HookrTaxQueueTypes.Ledger memory) {
        return _state().ledger;
    }

    /// @inheritdoc IHookrTaxQueue
    function creatorWaitingSince() external view onlyClone returns (uint256) {
        return _state().creatorWaitingSince;
    }

    /// @inheritdoc IHookrTaxQueue
    /// @dev Each successful conversion restarts the wait.
    function staleRecoveryDelay() external view onlyClone returns (uint256) {
        return _terms().staleRecoveryDelay;
    }

    /// @inheritdoc IHookrTaxQueue
    function pending() external view onlyClone returns (uint256 amount) {
        HookrTaxQueueTypes.Terms memory t = _terms();
        HookrTaxQueueTypes.Ledger storage l = _state().ledger;
        amount = IHookrRules(t.rules).claimable(t.quote, address(this));
        uint256 held = HookrAsset.balanceOf(Currency.unwrap(t.quote), address(this));
        uint256 booked = l.protocolOwed + l.creatorOwed;
        if (held > booked) amount += held - booked;
    }

    /// @inheritdoc IHookrTaxQueue
    function settle() external onlyClone nonReentrant returns (uint256 income) {
        return _settle(_terms());
    }

    /// @inheritdoc IHookrTaxQueue
    /// @dev Reverts `NoProtocolDestination`, with nothing moved, when `_protocolTo` names no account.
    function sweepProtocol() external onlyClone nonReentrant returns (uint256 amount) {
        HookrTaxQueueTypes.Terms memory t = _terms();
        _settle(t);
        HookrTaxQueueTypes.Ledger storage l = _state().ledger;
        amount = l.protocolOwed;
        if (amount == 0) revert NothingDue();
        address to = _protocolTo(t, IHookrRulesClaimExit(t.rules).poolManager());
        if (to == address(0)) revert NoProtocolDestination();
        l.protocolOwed = 0;
        l.protocolSwept += amount;
        HookrAsset.sendDebit(Currency.unwrap(t.quote), to, amount);
        emit ProtocolSwept(to, amount);
    }

    /// @inheritdoc IHookrTaxQueue
    function payCreator() external onlyClone nonReentrant returns (uint256 amount) {
        HookrTaxQueueTypes.Terms memory t = _terms();
        if (t.routeId != bytes32(0)) revert DirectPayoutDisabled();
        _settle(t);
        amount = _takeCreator();
        HookrAsset.sendDebit(Currency.unwrap(t.quote), t.assetRecipient, amount);
        emit CreatorPaid(t.assetRecipient, amount, false);
    }

    /// @inheritdoc IHookrTaxQueue
    /// @dev The executor authenticates the route, strategy, amount, minimum output, expiry, nonce, adapter bytes and
    ///      caller against the authorizer's signer. This queue enforces the caller: a plan that names one runs only
    ///      from that account. The quote spent and the output received are measured here as well.
    function process(
        HookrFeeConversionTypes.ExecutionPlan calldata plan,
        bytes calldata signature,
        bytes calldata routeData
    ) external onlyClone nonReentrant returns (uint256 delivered, bytes32 planDigest) {
        HookrTaxQueueTypes.Terms memory t = _terms();
        if (t.routeId == bytes32(0)) revert ConversionDisabled();
        if (plan.strategy != address(this) || plan.routeId != t.routeId) revert InvalidPlan();
        if (plan.caller != address(0) && plan.caller != msg.sender) revert InvalidPlan();
        HookrFeeConversionTypes.Route memory r = routeRegistry.route(t.routeId);
        address quote = Currency.unwrap(t.quote);
        if (r.tokenIn != quote) revert InvalidPlan();
        _settle(t);
        State storage s = _state();
        HookrTaxQueueTypes.Ledger storage l = s.ledger;
        uint256 amount = plan.amountIn;
        if (amount == 0 || amount > l.creatorOwed) revert AmountAboveAvailable(amount, l.creatorOwed);
        l.creatorOwed -= amount;
        l.creatorConverted += amount;
        // A successful conversion restarts the stale-share wait; the whole call reverts otherwise.
        s.creatorWaitingSince = l.creatorOwed == 0 ? 0 : block.timestamp;

        uint256 quoteBefore = HookrAsset.balanceOf(quote, address(this));
        uint256 outputBefore = HookrAsset.balanceOf(r.tokenOut, address(this));
        if (quote == address(0)) {
            (, planDigest) = executor.execute{value: amount}(plan, signature, routeData);
        } else {
            HookrAsset.approveExact(quote, address(executor), amount);
            (, planDigest) = executor.execute(plan, signature, routeData);
            HookrAsset.approveExact(quote, address(executor), 0);
        }
        uint256 quoteAfter = HookrAsset.balanceOf(quote, address(this));
        if (quoteAfter > quoteBefore || quoteBefore - quoteAfter != amount) {
            revert QuoteMismatch(amount, quoteAfter > quoteBefore ? 0 : quoteBefore - quoteAfter);
        }
        uint256 outputAfter = HookrAsset.balanceOf(r.tokenOut, address(this));
        delivered = outputAfter > outputBefore ? outputAfter - outputBefore : 0;
        if (delivered < plan.minAmountOut) revert TooLittleReceived(plan.minAmountOut, delivered);
        l.outputDelivered += delivered;
        HookrAsset.send(r.tokenOut, t.assetRecipient, delivered);
        emit Converted(t.routeId, planDigest, t.assetRecipient, amount, delivered);
    }

    /// @inheritdoc IHookrTaxQueue
    /// @dev Opens at the earlier of `staleRecoveryDelay` after the current wait began (`creatorWaitingSince`) and,
    ///      for a retired route, `RECOVERY_DELAY` after retirement. On an active route with no booked share waiting it
    ///      reverts `RouteStillActive`. The wait starts only when a settle books the share, so the clock is read
    ///      before this call settles.
    function recover() external onlyClone nonReentrant returns (uint256 amount) {
        HookrTaxQueueTypes.Terms memory t = _terms();
        if (t.routeId == bytes32(0)) revert ConversionDisabled();
        HookrFeeConversionTypes.Route memory r = routeRegistry.route(t.routeId);
        uint256 since = _state().creatorWaitingSince;
        uint256 availableAt = since == 0 ? type(uint256).max : since + t.staleRecoveryDelay;
        if (r.status == HookrFeeConversionTypes.RouteStatus.RETIRED) {
            uint256 afterRetirement = uint256(r.retiredAt) + RECOVERY_DELAY;
            if (afterRetirement < availableAt) availableAt = afterRetirement;
        } else if (since == 0) {
            revert RouteStillActive(t.routeId);
        }
        // A timestamp is the intended clock for a governance delay; validator skew cannot move the recipient.
        if (block.timestamp < availableAt) revert RecoveryDelayActive(availableAt);
        _settle(t);
        amount = _takeCreator();
        HookrAsset.sendDebit(Currency.unwrap(t.quote), t.recoveryRecipient, amount);
        emit CreatorPaid(t.recoveryRecipient, amount, true);
    }

    /// @inheritdoc IHookrStraySweep
    /// @dev The quote asset is never stray: unbooked quote is income at the next settle, and the booked shares and the
    ///      Rules claim are quote. The quote balance is also measured around the transfer, so an asset that moves the
    ///      quote as a side effect (a second entry point of the same token) reverts. The ledger is not touched.
    function sweepStray(address asset, uint256 amount, address to) external onlyClone nonReentrant {
        if (msg.sender != address(routeRegistry)) revert StraySweepUnauthorized(msg.sender);
        address quote = Currency.unwrap(_terms().quote);
        if (asset == quote) revert NotStray(asset);
        uint256 held = HookrAsset.balanceOf(asset, address(this));
        if (amount == 0 || to == address(0) || amount > held) revert InvalidStraySweep(asset, amount, held);
        uint256 quoteBefore = HookrAsset.balanceOf(quote, address(this));
        HookrAsset.send(asset, to, amount);
        if (HookrAsset.balanceOf(quote, address(this)) != quoteBefore) revert SweepMovedQuote(asset);
        emit StraySwept(asset, to, amount);
    }

    /// @inheritdoc IHookrTaxQueue
    function accountingInvariant() external view onlyClone returns (bool) {
        HookrTaxQueueTypes.Terms memory t = _terms();
        HookrTaxQueueTypes.Ledger storage l = _state().ledger;
        uint256 held = HookrAsset.balanceOf(Currency.unwrap(t.quote), address(this));
        return l.income == l.protocolIncome + l.creatorIncome && l.protocolIncome == l.protocolOwed + l.protocolSwept
            && l.creatorIncome == l.creatorOwed + l.creatorConverted + l.creatorPaid
            && held >= l.protocolOwed + l.creatorOwed;
    }

    /// @dev Pulls any Rules claim, then books the quote held above what is already owed. The split rounds the
    ///      protocol amount down. Returns zero, without reverting, when nothing new is held. A pull that fails (an
    ///      issuer freeze of this address, a transfer fee, a pause, or a delivery that needs more than `CLAIM_GAS`)
    ///      pays the claim out as ERC-6909 claims instead (`_payClaimAsClaims`); it can never block paying out quote
    ///      that is already booked. A pull is not tried while the PoolManager is unlocked (it would fail for that
    ///      reason alone), and the claim is deferred.
    ///      The pull runs with exactly `CLAIM_GAS`, checked the way the core's lane checks its flush: the call must
    ///      hold the grant, the 1/64 the call keeps back and a margin, or it reverts `ClaimOutOfGas` before the pull,
    ///      and the explicit grant keeps any gas above it from the pull. How the pull ends, token or ERC-6909 exit, is
    ///      therefore the same whatever gas the caller sends, including an out-of-gas any number of frames below the
    ///      Rules. What can still differ is state: calls a caller makes earlier in the same transaction can warm the
    ///      accounts and slots the pull touches, which only makes it cheaper (it can turn an exit into a delivery,
    ///      never a delivery into an exit), and a quote whose own transfer logic reads state a caller can change
    ///      behaves as that logic does.
    function _settle(HookrTaxQueueTypes.Terms memory t) private returns (uint256 income) {
        IHookrRules rules = IHookrRules(t.rules);
        uint256 claim = rules.claimable(t.quote, address(this));
        if (claim != 0) {
            IPoolManager manager = IHookrRulesClaimExit(t.rules).poolManager();
            if (TransientStateLibrary.isUnlocked(manager)) {
                emit ClaimDeferred(claim);
            } else {
                uint256 required = CLAIM_GAS + CLAIM_GAS / 63 + CLAIM_GAS_MARGIN;
                if (gasleft() < required) revert ClaimOutOfGas(gasleft(), required);
                try rules.claim{gas: CLAIM_GAS}(t.quote) {}
                catch {
                    _payClaimAsClaims(t, manager, claim);
                }
            }
        }
        State storage s = _state();
        HookrTaxQueueTypes.Ledger storage l = s.ledger;
        uint256 held = HookrAsset.balanceOf(Currency.unwrap(t.quote), address(this));
        uint256 booked = l.protocolOwed + l.creatorOwed;
        if (held <= booked) return 0;
        income = held - booked;
        uint256 protocolAmount = income * t.protocolShareBps / BPS;
        uint256 creatorAmount = income - protocolAmount;
        if (t.routeId != bytes32(0) && l.creatorOwed == 0 && creatorAmount != 0) {
            s.creatorWaitingSince = block.timestamp;
        }
        l.protocolOwed += protocolAmount;
        l.creatorOwed += creatorAmount;
        l.income += income;
        l.protocolIncome += protocolAmount;
        l.creatorIncome += creatorAmount;
        emit Settled(income, protocolAmount, creatorAmount);
    }

    /// @dev The exit for a Rules claim the quote token will not deliver here: the claim moves to this queue as
    ///      ERC-6909 claims (`HookrRules.claimAsClaims`), no token moves, and the amount received is split at the
    ///      frozen share (protocol rounded down, as in `_settle`) and transferred on as ERC-6909 claims at once, so the
    ///      queue never holds them. The protocol part goes to the account `_protocolTo` names, read before anything
    ///      moves; the creator part to the creator's quote destination. The ledger books it as income swept and paid
    ///      in the same step, so the identities hold. If that account cannot be named, or the Rules refuse this exit
    ///      too, nothing moves and the claim stays backed in Rules (`ClaimDeferred`).
    function _payClaimAsClaims(HookrTaxQueueTypes.Terms memory t, IPoolManager manager, uint256 claim) private {
        address protocolTo;
        if (t.protocolShareBps != 0) {
            protocolTo = _protocolTo(t, manager);
            if (protocolTo == address(0)) {
                emit ClaimDeferred(claim);
                return;
            }
        }
        uint256 id = t.quote.toId();
        uint256 before = manager.balanceOf(address(this), id);
        try IHookrRulesClaimExit(t.rules).claimAsClaims(t.quote, address(this)) {}
        catch {
            emit ClaimDeferred(claim);
            return;
        }
        uint256 amount = manager.balanceOf(address(this), id) - before;
        if (amount == 0) return;
        uint256 protocolAmount = amount * t.protocolShareBps / BPS;
        uint256 creatorAmount = amount - protocolAmount;
        address creatorRecipient = t.routeId == bytes32(0) ? t.assetRecipient : t.recoveryRecipient;
        HookrTaxQueueTypes.Ledger storage l = _state().ledger;
        l.income += amount;
        l.protocolIncome += protocolAmount;
        l.protocolSwept += protocolAmount;
        l.creatorIncome += creatorAmount;
        l.creatorPaid += creatorAmount;
        if (protocolAmount != 0) manager.transfer(protocolTo, id, protocolAmount);
        if (creatorAmount != 0) manager.transfer(creatorRecipient, id, creatorAmount);
        emit ClaimPaidAsClaims(amount, protocolTo, protocolAmount, creatorRecipient, creatorAmount);
    }

    /// @dev The account the protocol share is paid to, as booked quote (`sweepProtocol`) and as the ERC-6909 exit's
    ///      part alike, or zero when none can be named. The pool's Rules accept a protocol recipient only without code
    ///      or as the treasury that answers their fee terms (HookrRules' constructor). A recipient without code is
    ///      paid itself: it holds and moves tokens and ERC-6909 claims. A recipient with code is read as a
    ///      HookrTreasury and its current `target()` is paid: the destination its owner sets behind `TARGET_DELAY`,
    ///      the account every other protocol payment reaches, the one its own `collectTo` pays and its
    ///      `collectAsClaims` credits. The treasury itself could hold the share where it cannot always move on: it has
    ///      no function that moves an ERC-6909 balance of its own (`collectAsClaims` moves only a source's claim,
    ///      `forwardBalance` only tokens), an issuer can restrict its address (the case `collectTo` routes around),
    ///      and `forwardBalance` delivers a token only within `DELIVERY_GAS`. The read is a bounded static call whose
    ///      answer must be exactly one word holding an address other than zero, this queue, the PoolManager, the
    ///      Rules and the recipient itself; anything else names none.
    function _protocolTo(HookrTaxQueueTypes.Terms memory t, IPoolManager manager) private view returns (address to) {
        address recipient = t.protocolRecipient;
        if (recipient.code.length == 0) return recipient;
        bytes4 selector = IHookrTreasury.target.selector;
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            ok := staticcall(TARGET_READ_GAS, recipient, 0x00, 0x04, 0x00, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            word := mload(0x00)
        }
        if (!ok || word >> 160 != 0) return address(0);
        to = address(uint160(word));
        if (to == address(0) || to == address(this) || to == address(manager) || to == t.rules || to == recipient) {
            return address(0);
        }
    }

    function _takeCreator() private returns (uint256 amount) {
        State storage s = _state();
        HookrTaxQueueTypes.Ledger storage l = s.ledger;
        amount = l.creatorOwed;
        if (amount == 0) revert NothingDue();
        l.creatorOwed = 0;
        l.creatorPaid += amount;
        s.creatorWaitingSince = 0;
    }

    function _terms() private view returns (HookrTaxQueueTypes.Terms memory) {
        return abi.decode(HookrCloneArgs.read(TERMS_BYTES), (HookrTaxQueueTypes.Terms));
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }
}
