// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrPaymaster} from "../interfaces/IHookrPaymaster.sol";
import {IPaymaster} from "../interfaces/external/IPaymaster.sol";
import {IEntryPoint} from "../interfaces/external/IEntryPoint.sol";
import {PackedUserOperation} from "../interfaces/external/PackedUserOperation.sol";
import {HookrGoverned} from "../base/HookrGoverned.sol";
import {IHookrCompliance} from "../interfaces/IHookrCompliance.sol";
import {HookrRelease} from "../libraries/HookrRelease.sol";
import {HookrAccountCalls} from "../libraries/HookrAccountCalls.sol";
import {HookrPaymasterAdmin, RULES_READ_GAS, PROTOCOL_FEE_PAID} from "../libraries/HookrPaymasterAdmin.sol";

/// @title HookrPaymaster
/// @notice ERC-4337 v0.7 paymaster. Every op is precharged in validation from the account's credit or an allowlisted
///         token, and settled in postOp to internal ledgers only. Ops that paid the Hookr protocol fee (read from the
///         Rules transient ledger) receive a capped rebate from an explicitly funded budget.
/// @dev Validation touches only own storage and sender-associated token slots, with no TIMESTAMP and no transient
///      storage (ERC-7562, staked paymaster). postOp makes only bounded, size-checked staticcalls and never transfers.
///      postOp charges its own gas limit, a tail for the EntryPoint's work after postOp and the EntryPoint's unused-gas
///      penalty, so the charge bounds what the deposit pays. The rebate path runs only while gasleft() still covers
///      its next step plus SETTLE_GAS, so the required settlement cannot be starved.
///      Fee attribution is per transaction and per paymaster: fund at most one paymaster per Rules ledger.
///      Cold configuration paths run in the linked library HookrPaymasterAdmin and the call-data policy in the linked
///      library HookrAccountCalls, both by DELEGATECALL.
///      Each brake voids every queued operation of the kind that would undo it, whatever its arguments; the owner
///      removes a guardian that abuses this at once.
contract HookrPaymaster is IHookrPaymaster, HookrGoverned {
    uint256 internal constant POST_OP_GAS_MIN = 240_000;
    uint256 internal constant POST_OP_GAS_MAX = 300_000;
    /// @dev EntryPoint v0.7 work after postOp returns that no op gas limit meters.
    uint256 internal constant POST_OP_TAIL_GAS = 10_000;
    /// @dev EntryPoint v0.7 penalty on unused execution gas (callGasLimit + paymasterPostOpGasLimit).
    uint256 internal constant PENALTY_PERCENT = 10;
    /// @dev Upper bound on settlement after the rebate path: three cold zero-to-nonzero SSTOREs and the event.
    uint256 internal constant SETTLE_GAS = 80_000;
    /// @dev Upper bound on the rebate bookkeeping: policy reads and three SSTOREs, two of them zero-to-nonzero.
    uint256 internal constant REBATE_WRITE_GAS = 60_000;
    /// @dev Upper bound on one rules x quote read: the stipend, a cold account, a cold token config and the marker.
    uint256 internal constant PAIR_GAS = 22_000;
    /// @dev Upper bound on the rebate screen: the stipend, a cold account and encoding.
    uint256 internal constant SCREEN_GAS = 55_000;
    uint256 internal constant MAX_REBATE_QUOTES = 4;
    /// @dev Bounded gas for the rebate-time sanctions read, sized for one sanctions source call.
    uint256 internal constant SCREEN_READ_GAS = 50_000;
    uint16 internal constant MAX_REBATE_BPS = 5_000;
    uint32 internal constant MIN_UNSTAKE_DELAY = 86_400;
    uint256 internal constant PAYMASTER_DATA_LENGTH = 95;

    bytes32 internal constant UNPAUSE = keccak256("UNPAUSE");
    bytes32 internal constant SET_TOKEN = keccak256("SET_TOKEN");
    bytes32 internal constant SET_POLICY = keccak256("SET_POLICY");
    bytes32 internal constant ALLOW_CALL = keccak256("ALLOW_CALL");
    bytes32 internal constant ALLOW_SPENDER = keccak256("ALLOW_SPENDER");
    bytes32 internal constant ADD_REBATE_RULES = keccak256("ADD_REBATE_RULES");
    bytes32 internal constant SET_REBATE_QUOTES = keccak256("SET_REBATE_QUOTES");
    bytes32 internal constant GRANT_KEEPER = keccak256("GRANT_KEEPER");
    bytes32 internal constant GRANT_GUARDIAN = keccak256("GRANT_GUARDIAN");
    bytes32 internal constant SET_TREASURY = keccak256("SET_TREASURY");

    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.paymaster")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STATE_SLOT = 0x08d5fe45e50bf728db3645c9206cf377f026ff723c23f083af009451257fbd00;
    /// @dev keccak256("hookr.paymaster.transient.attributed")
    bytes32 private constant ATTRIBUTED = 0x7b02fc0db59d0c369e10ec493eebbde697b231c76b389b16da7c90bc9e7ca4da;
    /// @dev keccak256("hookr.paymaster.transient.lock")
    bytes32 private constant LOCK = 0x79c0f46e351bd195d1aa103544b0a38f74087f7c04a09623f98db91cd9a5fb82;

    /// @custom:storage-location erc7201:hookr.paymaster
    struct State {
        address treasury;
        bool paused;
        Policy policy;
        address[] rebateRules;
        address[] rebateQuotes;
        uint256 rebateBudgetWei;
        mapping(address token => TokenConfig) tokens;
        mapping(address token => Rate) rates;
        mapping(bytes24 call => uint8) calls;
        mapping(address spender => bool) approvalSpenders;
        mapping(address keeper => bool) keepers;
        mapping(address guardian => bool) guardians;
        mapping(address account => mapping(address token => uint256)) credit;
        mapping(address token => uint256) totalCredit;
        mapping(address token => uint256) revenue;
        mapping(uint256 day => uint256) rebateSpentWei;
        mapping(address account => uint256) accountRebate;
        mapping(address token => HookrPaymasterAdmin.RateAnchor) rateAnchors;
    }

    address internal immutable ENTRY_POINT;
    address internal immutable COMPLIANCE;

    /// @param entryPoint_ EntryPoint v0.7.
    /// @param compliance_ HookrCompliance, or zero to disable screening.
    /// @param owner_ Governance owner.
    /// @param delay_ Timelock delay.
    /// @param treasury_ Receiver of revenue, deposit and stake withdrawals.
    constructor(address entryPoint_, address compliance_, address owner_, uint48 delay_, address treasury_)
        HookrGoverned(owner_, delay_)
    {
        if (entryPoint_.code.length == 0) revert InvalidAddress(entryPoint_);
        if (treasury_ == address(0)) revert InvalidAddress(treasury_);
        ENTRY_POINT = entryPoint_;
        COMPLIANCE = compliance_;
        _state().treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    modifier onlyEntryPoint() {
        _onlyEntryPoint();
        _;
    }

    modifier nonReentrant() {
        _enter();
        _;
        assembly ("memory-safe") {
            tstore(LOCK, 0)
        }
    }

    modifier onlyGuardianOrOwner() {
        _onlyGuardianOrOwner();
        _;
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(PackedUserOperation calldata op, bytes32 userOpHash, uint256 maxCost)
        external
        override
        onlyEntryPoint
        returns (bytes memory context, uint256 validationData)
    {
        State storage s = _state();
        if (s.paused) revert SponsorshipPaused();
        bytes calldata pnd = op.paymasterAndData;
        if (pnd.length != PAYMASTER_DATA_LENGTH) revert InvalidPaymasterData(pnd.length);
        uint256 postOpGas = uint128(bytes16(pnd[36:52]));
        if (postOpGas < POST_OP_GAS_MIN || postOpGas > POST_OP_GAS_MAX) {
            revert PostOpGasOutOfRange(postOpGas, POST_OP_GAS_MIN, POST_OP_GAS_MAX);
        }
        uint8 rawMode = uint8(pnd[52]);
        if (rawMode > uint8(Mode.TOKEN)) revert InvalidMode(rawMode);
        address token = address(bytes20(pnd[53:73]));
        uint256 maxCharge = uint128(bytes16(pnd[73:89]));
        uint48 validUntil = uint48(bytes6(pnd[89:95]));
        if (validUntil == 0) revert InvalidPaymasterData(pnd.length);
        if (maxCost > s.policy.maxCostWei) revert CostAboveCap(maxCost, s.policy.maxCostWei);
        uint256 maxFeePerGas = uint128(uint256(op.gasFees));
        if (maxFeePerGas > s.policy.maxFeePerGasWei) revert FeePerGasAboveCap(maxFeePerGas, s.policy.maxFeePerGasWei);

        HookrAccountCalls.check(s.calls, s.approvalSpenders, op.callData);

        address sender = op.sender;
        if (s.policy.screenSanctions && COMPLIANCE != address(0)) {
            if (IHookrCompliance(COMPLIANCE).isSanctionedLocal(sender)) revert SenderSanctioned(sender);
        }

        Context memory c;
        c.account = sender;
        c.maxCost = maxCost;
        c.executionGasLimit = uint128(uint256(op.accountGasLimits)) + postOpGas;
        c.postOpGasLimit = postOpGas;
        c.userOpHash = userOpHash;
        uint48 until = validUntil;
        if (rawMode == uint8(Mode.CREDIT)) {
            if (token != address(0)) revert InvalidMode(rawMode);
            c.mode = Mode.CREDIT;
            c.required = maxCost;
            if (maxCost > maxCharge) revert ChargeAboveLimit(maxCost, maxCharge);
            uint256 available = s.credit[sender][address(0)];
            if (available < maxCost) revert InsufficientCredit(available, maxCost);
            s.credit[sender][address(0)] = available - maxCost;
            s.totalCredit[address(0)] -= maxCost;
            c.rate = 1e18;
        } else {
            if (op.initCode.length != 0) revert AccountNotDeployed(sender);
            c.mode = Mode.TOKEN;
            c.token = token;
            uint48 rateUntil;
            (c.required, c.rate, c.markupBps, rateUntil) = _required(s, token, maxCost);
            if (c.required > maxCharge) revert ChargeAboveLimit(c.required, maxCharge);
            uint256 fromCredit = s.credit[sender][token];
            if (fromCredit > c.required) fromCredit = c.required;
            if (fromCredit != 0) {
                s.credit[sender][token] -= fromCredit;
                s.totalCredit[token] -= fromCredit;
            }
            uint256 remainder = c.required - fromCredit;
            if (remainder != 0) _pullExact(token, sender, remainder);
            if (rateUntil < until) until = rateUntil;
        }
        context = abi.encode(c);
        validationData = uint256(until) << 160;
    }

    /// @inheritdoc IPaymaster
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        external
        override
        onlyEntryPoint
    {
        State storage s = _state();
        Context memory c = abi.decode(context, (Context));
        uint256 overheadGas = c.postOpGasLimit + POST_OP_TAIL_GAS + c.executionGasLimit * PENALTY_PERCENT / 100;
        uint256 costWei = actualGasCost + overheadGas * actualUserOpFeePerGas;
        if (costWei > c.maxCost) costWei = c.maxCost;

        uint256 feeWei;
        uint256 rebateWei;
        if (mode == PostOpMode.opSucceeded && s.policy.rebateBps != 0 && s.rebateBudgetWei != 0) {
            bool complete;
            (feeWei, complete) = _attributeFees(s, c);
            if (
                complete && feeWei != 0 && _hasGas(SCREEN_GAS + REBATE_WRITE_GAS) && !_sanctionedForRebate(c.account)
                    && _hasGas(REBATE_WRITE_GAS)
            ) {
                rebateWei = _rebate(s, c.account, costWei, feeWei);
            }
        }

        address t = c.mode == Mode.CREDIT ? address(0) : c.token;
        uint256 chargeWei = costWei - rebateWei;
        uint256 charged;
        if (c.mode == Mode.CREDIT) {
            charged = chargeWei;
        } else {
            charged = _ceilDiv(_ceilDiv(chargeWei * c.rate, 1e18) * (10_000 + uint256(c.markupBps)), 10_000);
            if (charged > c.required) charged = c.required;
        }
        uint256 refund = c.required - charged;
        if (refund != 0) {
            s.credit[c.account][t] += refund;
            s.totalCredit[t] += refund;
        }
        s.revenue[t] += charged;
        emit UserOperationSettled(
            c.account,
            c.userOpHash,
            t,
            c.mode,
            mode == PostOpMode.opSucceeded,
            costWei,
            feeWei,
            rebateWei,
            charged,
            refund
        );
    }

    /// @inheritdoc IHookrPaymaster
    function depositCredit(address account) external payable override {
        if (account == address(0)) revert InvalidAddress(account);
        State storage s = _state();
        s.credit[account][address(0)] += msg.value;
        s.totalCredit[address(0)] += msg.value;
        emit CreditDeposited(account, address(0), msg.sender, msg.value);
    }

    /// @inheritdoc IHookrPaymaster
    function depositTokenCredit(address token, address account, uint256 amount) external override nonReentrant {
        State storage s = _state();
        if (token == address(0) || !s.tokens[token].enabled) revert UnsupportedToken(token);
        if (account == address(0)) revert InvalidAddress(account);
        _pullExact(token, msg.sender, amount);
        s.credit[account][token] += amount;
        s.totalCredit[token] += amount;
        emit CreditDeposited(account, token, msg.sender, amount);
    }

    /// @inheritdoc IHookrPaymaster
    function withdrawCredit(address token, address to, uint256 amount) external override nonReentrant {
        if (to == address(0)) revert InvalidAddress(to);
        State storage s = _state();
        uint256 available = s.credit[msg.sender][token];
        if (available < amount) revert InsufficientCredit(available, amount);
        s.credit[msg.sender][token] = available - amount;
        s.totalCredit[token] -= amount;
        _send(token, to, amount);
        emit CreditWithdrawn(msg.sender, token, to, amount);
    }

    /// @inheritdoc IHookrPaymaster
    function fundRebates() external payable override {
        if (msg.sender != owner() && msg.sender != _state().treasury) revert Unauthorized(msg.sender);
        IEntryPoint(ENTRY_POINT).depositTo{value: msg.value}(address(this));
        _state().rebateBudgetWei += msg.value;
        emit RebatesFunded(msg.sender, msg.value);
    }

    /// @inheritdoc IHookrPaymaster
    function refillDeposit(uint256 amount) external override nonReentrant {
        State storage s = _state();
        uint256 available = s.revenue[address(0)];
        if (amount > available) revert AmountExceedsRevenue(amount, available);
        s.revenue[address(0)] = available - amount;
        IEntryPoint(ENTRY_POINT).depositTo{value: amount}(address(this));
        emit DepositRefilled(amount);
    }

    /// @inheritdoc IHookrPaymaster
    function withdrawRevenue(address token, uint256 amount) external override onlyOwner nonReentrant {
        State storage s = _state();
        uint256 available = s.revenue[token];
        if (amount > available) revert AmountExceedsRevenue(amount, available);
        s.revenue[token] = available - amount;
        _send(token, s.treasury, amount);
        emit RevenueWithdrawn(token, s.treasury, amount);
    }

    /// @inheritdoc IHookrPaymaster
    function withdrawDeposit(uint256 amount) external override onlyOwner {
        State storage s = _state();
        IEntryPoint(ENTRY_POINT).withdrawTo(payable(s.treasury), amount);
        uint256 remaining = IEntryPoint(ENTRY_POINT).balanceOf(address(this));
        if (s.rebateBudgetWei > remaining) s.rebateBudgetWei = remaining;
        emit DepositWithdrawn(s.treasury, amount);
    }

    /// @inheritdoc IHookrPaymaster
    function addStake(uint32 unstakeDelaySec) external payable override onlyOwner {
        if (unstakeDelaySec < MIN_UNSTAKE_DELAY) revert InvalidDelay(uint48(unstakeDelaySec));
        IEntryPoint(ENTRY_POINT).addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @inheritdoc IHookrPaymaster
    function unlockStake() external override onlyOwner {
        IEntryPoint(ENTRY_POINT).unlockStake();
    }

    /// @inheritdoc IHookrPaymaster
    function withdrawStake() external override onlyOwner {
        IEntryPoint(ENTRY_POINT).withdrawStake(payable(_state().treasury));
    }

    /// @inheritdoc IHookrPaymaster
    function sweepUntracked(address token) external override onlyOwner nonReentrant {
        State storage s = _state();
        uint256 held = token == address(0) ? address(this).balance : _balanceOf(token, address(this));
        uint256 tracked = s.totalCredit[token] + s.revenue[token];
        uint256 amount = held > tracked ? held - tracked : 0;
        _send(token, s.treasury, amount);
        emit UntrackedSwept(token, s.treasury, amount);
    }

    /// @inheritdoc IHookrPaymaster
    function setRate(address token, uint128 tokenPerEth, uint32 ttl) external override {
        State storage s = _state();
        HookrPaymasterAdmin.setRate(s.tokens, s.rates, s.rateAnchors, s.keepers, token, tokenPerEth, ttl);
    }

    /// @inheritdoc IHookrPaymaster
    function pause() external override onlyGuardianOrOwner {
        _state().paused = true;
        _invalidateQueued(UNPAUSE);
        emit PauseSet(true, msg.sender);
    }

    /// @inheritdoc IHookrPaymaster
    function haltRebates() external override onlyGuardianOrOwner {
        _state().policy.rebateBps = 0;
        _invalidateQueued(SET_POLICY);
        emit RebatesHalted(msg.sender);
    }

    /// @inheritdoc IHookrPaymaster
    function disableToken(address token) external override onlyGuardianOrOwner {
        _state().tokens[token].enabled = false;
        _invalidateQueued(SET_TOKEN);
        emit TokenDisabled(token);
    }

    /// @inheritdoc IHookrPaymaster
    function revokeCall(address target, bytes4 selector) external override onlyGuardianOrOwner {
        delete _state().calls[HookrAccountCalls.callKey(target, selector)];
        _invalidateQueued(ALLOW_CALL);
        emit CallSet(target, selector, false, false);
    }

    /// @inheritdoc IHookrPaymaster
    function revokeApprovalSpender(address spender) external override onlyGuardianOrOwner {
        delete _state().approvalSpenders[spender];
        _invalidateQueued(ALLOW_SPENDER);
        emit ApprovalSpenderSet(spender, false);
    }

    /// @inheritdoc IHookrPaymaster
    function revokeKeeper(address keeper) external override onlyGuardianOrOwner {
        delete _state().keepers[keeper];
        _invalidateQueued(GRANT_KEEPER);
        emit KeeperSet(keeper, false);
    }

    /// @inheritdoc IHookrPaymaster
    function removeRebateRules(address rules) external override onlyGuardianOrOwner {
        _invalidateQueued(ADD_REBATE_RULES);
        HookrPaymasterAdmin.removeRebateRules(_state().rebateRules, rules);
    }

    /// @inheritdoc IHookrPaymaster
    function revokeGuardian(address guardian) external override onlyOwner {
        delete _state().guardians[guardian];
        _invalidateQueued(GRANT_GUARDIAN);
        emit GuardianSet(guardian, false);
    }

    /// @inheritdoc IHookrPaymaster
    function unpause() external override onlyOwner {
        _consume(UNPAUSE, "");
        _state().paused = false;
        emit PauseSet(false, msg.sender);
    }

    /// @inheritdoc IHookrPaymaster
    function setToken(address token, TokenConfig calldata config, uint128 initialRate) external override onlyOwner {
        _consume(SET_TOKEN, abi.encode(token, config, initialRate));
        State storage s = _state();
        HookrPaymasterAdmin.setToken(s.tokens, s.rates, s.rateAnchors, token, config, initialRate);
    }

    /// @inheritdoc IHookrPaymaster
    function setPolicy(Policy calldata newPolicy) external override onlyOwner {
        _consume(SET_POLICY, abi.encode(newPolicy));
        if (newPolicy.rebateBps > MAX_REBATE_BPS) revert InvalidPolicy(1);
        if (newPolicy.maxCostWei == 0) revert InvalidPolicy(2);
        if (newPolicy.maxFeePerGasWei == 0) revert InvalidPolicy(3);
        _state().policy = newPolicy;
        emit PolicySet(newPolicy);
    }

    /// @inheritdoc IHookrPaymaster
    function allowCall(address target, bytes4 selector, bool valueAllowed) external override onlyOwner {
        _consume(ALLOW_CALL, abi.encode(target, selector, valueAllowed));
        _state().calls[HookrAccountCalls.callKey(target, selector)] = valueAllowed ? 3 : 1;
        emit CallSet(target, selector, true, valueAllowed);
    }

    /// @inheritdoc IHookrPaymaster
    function allowApprovalSpender(address spender) external override onlyOwner {
        _consume(ALLOW_SPENDER, abi.encode(spender));
        _state().approvalSpenders[spender] = true;
        emit ApprovalSpenderSet(spender, true);
    }

    /// @inheritdoc IHookrPaymaster
    function addRebateRules(address rules) external override onlyOwner {
        _consume(ADD_REBATE_RULES, abi.encode(rules));
        HookrPaymasterAdmin.addRebateRules(_state().rebateRules, rules);
    }

    /// @inheritdoc IHookrPaymaster
    function setRebateQuotes(address[] calldata quotes) external override onlyOwner {
        _consume(SET_REBATE_QUOTES, abi.encode(quotes));
        if (quotes.length > MAX_REBATE_QUOTES) revert TooManyEntries(quotes.length, MAX_REBATE_QUOTES);
        _state().rebateQuotes = quotes;
        emit RebateQuotesSet(quotes);
    }

    /// @inheritdoc IHookrPaymaster
    function grantKeeper(address keeper) external override onlyOwner {
        _consume(GRANT_KEEPER, abi.encode(keeper));
        _state().keepers[keeper] = true;
        emit KeeperSet(keeper, true);
    }

    /// @inheritdoc IHookrPaymaster
    function grantGuardian(address guardian) external override onlyOwner {
        _refuseDelegated(guardian);
        _consume(GRANT_GUARDIAN, abi.encode(guardian));
        _state().guardians[guardian] = true;
        emit GuardianSet(guardian, true);
    }

    /// @inheritdoc IHookrPaymaster
    function setTreasury(address newTreasury) external override onlyOwner {
        _consume(SET_TREASURY, abi.encode(newTreasury));
        if (newTreasury == address(0)) revert InvalidAddress(newTreasury);
        _state().treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /// @inheritdoc IHookrPaymaster
    function entryPoint() external view override returns (address) {
        return ENTRY_POINT;
    }

    /// @inheritdoc IHookrPaymaster
    function compliance() external view override returns (address) {
        return COMPLIANCE;
    }

    /// @inheritdoc IHookrPaymaster
    function treasury() external view override returns (address) {
        return _state().treasury;
    }

    /// @inheritdoc IHookrPaymaster
    function paused() external view override returns (bool) {
        return _state().paused;
    }

    /// @inheritdoc IHookrPaymaster
    function policy() external view override returns (Policy memory) {
        return _state().policy;
    }

    /// @inheritdoc IHookrPaymaster
    function tokenConfig(address token) external view override returns (TokenConfig memory) {
        return _state().tokens[token];
    }

    /// @inheritdoc IHookrPaymaster
    function rate(address token) external view override returns (Rate memory) {
        return _state().rates[token];
    }

    /// @inheritdoc IHookrPaymaster
    function credit(address account, address token) external view override returns (uint256) {
        return _state().credit[account][token];
    }

    /// @inheritdoc IHookrPaymaster
    function totalCredit(address token) external view override returns (uint256) {
        return _state().totalCredit[token];
    }

    /// @inheritdoc IHookrPaymaster
    function revenue(address token) external view override returns (uint256) {
        return _state().revenue[token];
    }

    /// @inheritdoc IHookrPaymaster
    function rebateBudget() external view override returns (uint256) {
        return _state().rebateBudgetWei;
    }

    /// @inheritdoc IHookrPaymaster
    function rebateRules() external view override returns (address[] memory) {
        return _state().rebateRules;
    }

    /// @inheritdoc IHookrPaymaster
    function rebateQuotes() external view override returns (address[] memory) {
        return _state().rebateQuotes;
    }

    /// @inheritdoc IHookrPaymaster
    function callPolicy(address target, bytes4 selector)
        external
        view
        override
        returns (bool allowed, bool valueAllowed)
    {
        uint8 flags = _state().calls[HookrAccountCalls.callKey(target, selector)];
        return (flags & 1 != 0, flags & 2 != 0);
    }

    /// @inheritdoc IHookrPaymaster
    function isApprovalSpender(address spender) external view override returns (bool) {
        return _state().approvalSpenders[spender];
    }

    /// @inheritdoc IHookrPaymaster
    function quoteCharge(Mode mode, address token, uint256 maxCost)
        external
        view
        override
        returns (uint256 required, uint48 validUntil)
    {
        if (mode == Mode.CREDIT) return (maxCost, type(uint48).max);
        (required,,, validUntil) = _required(_state(), token, maxCost);
    }

    /// @inheritdoc IHookrPaymaster
    function releaseId() external pure override returns (uint256) {
        return HookrRelease.ID;
    }

    function _required(State storage s, address token, uint256 maxCost)
        private
        view
        returns (uint256 required, uint256 tokenRate, uint16 markupBps, uint48 rateUntil)
    {
        TokenConfig memory cfg = s.tokens[token];
        if (token == address(0) || !cfg.enabled) revert UnsupportedToken(token);
        if (cfg.peg) {
            (tokenRate, rateUntil) = (1e18, type(uint48).max);
        } else {
            Rate memory r = s.rates[token];
            (tokenRate, rateUntil) = (r.tokenPerEth, r.expiresAt);
        }
        if (tokenRate == 0) revert RateUnavailable(token);
        markupBps = cfg.markupBps;
        required = _ceilDiv(_ceilDiv(maxCost * tokenRate, 1e18) * (10_000 + uint256(markupBps)), 10_000);
    }

    /// @dev complete is false when gas ran short before every pair was read; the op then gets no rebate.
    function _attributeFees(State storage s, Context memory c) private returns (uint256 feeWei, bool complete) {
        address[] memory rulesList = s.rebateRules;
        address[] memory quotes = s.rebateQuotes;
        for (uint256 i; i < rulesList.length; ++i) {
            for (uint256 j; j < quotes.length; ++j) {
                if (!_hasGas(PAIR_GAS + SCREEN_GAS + REBATE_WRITE_GAS)) return (feeWei, false);
                (bool ok, uint256 paid) = _readFee(rulesList[i], c.account, quotes[j]);
                if (!ok) continue;
                bytes32 key = keccak256(abi.encode(ATTRIBUTED, c.account, rulesList[i], quotes[j]));
                uint256 seen;
                assembly ("memory-safe") {
                    seen := tload(key)
                }
                if (paid > seen) {
                    assembly ("memory-safe") {
                        tstore(key, paid)
                    }
                    feeWei += _toWei(s, paid - seen, quotes[j], c);
                }
            }
        }
        complete = true;
    }

    /// @dev True while `need` gas plus the settlement reserve remains.
    function _hasGas(uint256 need) private view returns (bool) {
        return gasleft() >= need + SETTLE_GAS;
    }

    function _toWei(State storage s, uint256 amount, address quote, Context memory c) private view returns (uint256) {
        if (quote == address(0) || s.tokens[quote].peg) return amount;
        if (c.mode == Mode.TOKEN && quote == c.token) return amount * 1e18 / c.rate;
        return 0;
    }

    function _rebate(State storage s, address account, uint256 costWei, uint256 feeWei)
        private
        returns (uint256 rebateWei)
    {
        Policy memory p = s.policy;
        uint256 day = block.timestamp / 1 days;
        rebateWei = costWei;
        rebateWei = _min(rebateWei, feeWei * p.rebateBps / 10_000);
        rebateWei = _min(rebateWei, p.perOpRebateCapWei);
        uint256 packed = s.accountRebate[account];
        uint256 used = packed >> 192 == day ? uint256(uint192(packed)) : 0;
        rebateWei = _min(rebateWei, p.perAccountDailyRebateCapWei > used ? p.perAccountDailyRebateCapWei - used : 0);
        uint256 spent = s.rebateSpentWei[day];
        rebateWei = _min(rebateWei, p.dailyRebateCapWei > spent ? p.dailyRebateCapWei - spent : 0);
        rebateWei = _min(rebateWei, s.rebateBudgetWei);
        if (rebateWei == 0) return 0;
        s.rebateBudgetWei -= rebateWei;
        s.rebateSpentWei[day] = spent + rebateWei;
        s.accountRebate[account] = (day << 192) | (used + rebateWei);
    }

    /// @dev Bounded staticcall to rules.protocolFeePaid(account, quote); ok only for exactly 32 bytes returned.
    function _readFee(address rules, address account, address quote) private view returns (bool ok, uint256 paid) {
        bytes memory data = abi.encodeWithSelector(PROTOCOL_FEE_PAID, account, quote);
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(RULES_READ_GAS, rules, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
            if and(ok, eq(size, 32)) {
                returndatacopy(0, 0, 32)
                paid := mload(0)
            }
        }
        ok = ok && size == 32;
    }

    /// @dev No compliance → not sanctioned. A listed wallet, a source outage, or a failed or malformed read counts as
    ///      sanctioned (no rebate).
    function _sanctionedForRebate(address account) private view returns (bool) {
        if (COMPLIANCE == address(0)) return false;
        bytes memory data = abi.encodeCall(IHookrCompliance.sanctionStatus, (account));
        address target = COMPLIANCE;
        bool ok;
        uint256 size;
        uint256 listed;
        uint256 sourceFailed;
        assembly ("memory-safe") {
            ok := staticcall(SCREEN_READ_GAS, target, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
            if and(ok, eq(size, 64)) {
                returndatacopy(0, 0, 64)
                listed := mload(0)
                sourceFailed := mload(32)
            }
        }
        return !ok || size != 64 || listed != 0 || sourceFailed != 0;
    }

    function _pullExact(address token, address from, uint256 amount) private {
        uint256 before = _balanceOf(token, address(this));
        if (!_tokenCall(token, abi.encodeWithSelector(0x23b872dd, from, address(this), amount))) {
            revert InexactTransfer(token, amount, 0);
        }
        uint256 received = _balanceOf(token, address(this)) - before;
        if (received != amount) revert InexactTransfer(token, amount, received);
    }

    function _send(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            if (!sent) revert NativeTransferFailed();
            return;
        }
        if (!_tokenCall(token, abi.encodeWithSelector(0xa9059cbb, to, amount)) || token.code.length == 0) {
            revert InexactTransfer(token, amount, 0);
        }
    }

    /// @dev True when the call succeeded and returned nothing or an ABI-encoded true.
    function _tokenCall(address token, bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(data);
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    function _balanceOf(address token, address account) private view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!ok || ret.length < 32) revert UnsupportedToken(token);
        return abi.decode(ret, (uint256));
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _onlyEntryPoint() private view {
        if (msg.sender != ENTRY_POINT) revert NotEntryPoint(msg.sender);
    }

    function _enter() private {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(LOCK)
        }
        if (locked) revert Reentered();
        assembly ("memory-safe") {
            tstore(LOCK, 1)
        }
    }

    function _onlyGuardianOrOwner() private view {
        if (msg.sender != owner() && !_state().guardians[msg.sender]) revert NotGuardian(msg.sender);
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
