// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {IHookrRulesView} from "./interfaces/IHookrRulesView.sol";
import {IHookrSwapRewardMinter} from "./interfaces/IHookrSwapRewardMinter.sol";
import {IHookrRewardMintTarget} from "./interfaces/IHookrRewardMintTarget.sol";
import {HookrSwapRewardAccount} from "./HookrSwapRewardAccount.sol";

/// @title Hookr swap reward minter
/// @notice One immutable reward programme. Reward slices arrive as HookrRules quote claims on per-beneficiary
///         reward accounts; `settle` pulls them, mints the reward at the frozen rate, splits the funded slice between
///         the creator and the protocol, and refunds a TRADER-mode beneficiary any slice the programme could not
///         reward. Nothing here runs during a swap, and no swap depends on anything this contract does.
/// @dev Invariants (tested): minted <= lifetimeRewardCap; minted * 1e18 <= fundedSlice * rewardPerQuoteWad (every
///      reward unit was paid for at the frozen rate, so there are no free emissions); the quote this contract
///      holds covers creatorOwed + protocolOwed + refundsOwed; pulled = funded + excess for every settlement.
///      Every parameter is an immutable validated here once. There is no owner, pause, upgrade or sweep of
///      anything but the three ledgers above, and `rescue`, which forwards a claim this programme can never settle
///      (another currency or another Rules) from a reward account to that account's beneficiary.
contract HookrSwapRewardMinter is IHookrSwapRewardMinter {
    using SafeERC20 for IERC20;

    /// @notice Scale of `rewardPerQuoteWad`.
    uint256 public constant WAD = 1e18;
    /// @notice Basis-point denominator of the protocol share.
    uint256 public constant BPS = 10_000;
    /// @notice The smallest nonzero reward slice a side may set, in pips of the quote leg. Zero turns a side off.
    uint24 public constant MIN_REWARD_TAKE_PIPS = 1;
    /// @notice The reward slice ceiling of each side: 5% of the quote leg.
    uint24 public constant MAX_REWARD_TAKE_PIPS = 50_000;
    /// @notice The launch default reward slice on buys: 1% of the quote leg.
    uint24 public constant DEFAULT_BUY_TAKE_PIPS = 10_000;
    /// @notice The launch default reward slice on sells: 1% of the quote output.
    uint24 public constant DEFAULT_SELL_TAKE_PIPS = 10_000;
    /// @notice The house protocol floor inside the slice (2,000 bps). A pool's rules may require more through their own
    ///         `minProtocolShareBps`, and the slice never pays the protocol less than either.
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice The protocol share ceiling inside the slice, the same 50% ceiling every Hookr add-on keeps.
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice The launch default protocol share inside the slice: the floor.
    uint16 public constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice Gas stipend of the reward asset's `isRewardMinter` readiness read.
    uint256 public constant READY_GAS = 30_000;
    /// @notice Smallest accepted rate: one reward unit per 1e18 raw quote units of slice.
    uint256 public constant MIN_RATE = 1;
    /// @notice Largest accepted rate: 1e18 reward units per quote unit.
    uint256 public constant MAX_RATE = 1e36;
    /// @notice The launch default rate: one raw reward unit per raw quote unit of slice.
    uint256 public constant DEFAULT_RATE = 1e18;
    /// @notice Bounds on the frozen `mintReward` stipend. The floor fits the reference token's most expensive mint (the
    ///         first ever, to a new holder: about 47k warm, 49k cold) with margin; a lower stipend would skip that
    ///         mint, and in FIXED mode split the traders' slice with no reward.
    uint32 public constant MIN_MINT_GAS = 100_000;
    uint32 public constant MAX_MINT_GAS = 1_000_000;
    /// @notice The launch default `mintReward` stipend: about three times the reference token's most expensive mint.
    uint32 public constant DEFAULT_MINT_GAS = 150_000;
    /// @dev Gas kept back so a stipend call is never starved by the 63/64 rule (call cost plus return handling).
    uint256 private constant CALL_RESERVE = 10_000;
    uint256 private constant IDLE = 1;
    uint256 private constant BUSY = 2;
    uint256 private constant PULLING = 3;
    uint256 private constant RESCUING = 4;
    uint256 private constant RESCUING_NATIVE = 5;

    /// @notice The factory that created and attested this minter.
    address public immutable factory;
    /// @inheritdoc IHookrSwapRewardMinter
    address public immutable rules;
    /// @notice The PoolManager behind `rules`; the only accepted sender of native quote.
    address public immutable poolManager;
    /// @inheritdoc IHookrSwapRewardMinter
    Currency public immutable quote;
    /// @inheritdoc IHookrSwapRewardMinter
    PoolId public immutable poolId;
    /// @inheritdoc IHookrSwapRewardMinter
    address public immutable advisory;
    /// @inheritdoc IHookrSwapRewardMinter
    Mode public immutable mode;
    /// @notice The reward recipient in FIXED and SIDECAR; zero in TRADER.
    address public immutable fixedRecipient;
    /// @notice The reward asset.
    address public immutable rewardToken;
    /// @notice Receives the creator part of every funded slice.
    address public immutable creatorRecipient;
    /// @inheritdoc IHookrSwapRewardMinter
    address public immutable protocolRecipient;
    /// @notice The protocol part of every funded slice, in basis points. Set by the factory, not the creator.
    uint16 public immutable protocolShareBps;
    /// @inheritdoc IHookrSwapRewardMinter
    uint24 public immutable buyTakePips;
    /// @inheritdoc IHookrSwapRewardMinter
    uint24 public immutable sellTakePips;
    /// @notice Reward units per raw quote unit of slice, scaled by 1e18.
    uint256 public immutable rewardPerQuoteWad;
    /// @notice Reward-unit ceiling one swap's slice can fund.
    uint256 public immutable maxRewardPerSwap;
    /// @notice Reward-unit ceiling over the programme's life.
    uint256 public immutable lifetimeRewardCap;
    /// @notice Quote-slice ceiling of one swap: floor(maxRewardPerSwap * 1e18 / rewardPerQuoteWad).
    uint256 public immutable maxSlicePerSwap;
    /// @notice Gas stipend of each `mintReward` call.
    uint32 public immutable mintGasLimit;
    /// @inheritdoc IHookrSwapRewardMinter
    uint40 public immutable endsAt;
    /// @notice keccak256 of the reward account's creation code; every account of this minter shares it.
    bytes32 public immutable accountInitCodeHash;

    /// @notice Reward units minted so far.
    uint256 public minted;
    /// @notice Quote slice consumed as reward funding so far.
    uint256 public fundedSlice;
    /// @notice Quote pulled from reward accounts so far.
    uint256 public pulledTotal;
    /// @notice Quote owed to `creatorRecipient`.
    uint256 public creatorOwed;
    /// @notice Quote owed to `protocolRecipient`.
    uint256 public protocolOwed;
    /// @notice Total quote owed to TRADER-mode beneficiaries as refunds of slices the programme could not reward.
    uint256 public refundsOwed;
    /// @notice Settlements whose reward mint failed.
    uint256 public skippedMints;
    /// @notice Quote refund owed to each beneficiary.
    mapping(address beneficiary => uint256) public refundOf;
    uint256 private _status = IDLE;

    error InvalidParams(uint256 check);
    error Reentered();
    error InvalidBeneficiary(address beneficiary);
    error NothingToSettle(address beneficiary);
    error NothingOwed();
    error BalanceMismatch();
    error InsufficientGas();
    error UnexpectedNative();
    error TransferFailed();
    error AccountMismatch(address expected, address deployed);
    error ProgrammeClaim();
    error NothingToRescue(address beneficiary);

    /// @notice A beneficiary's pending slices were settled.
    /// @param reward Reward units minted (zero if the mint failed or the lifetime cap is spent).
    /// @param funded Quote slice consumed as funding and split between creator and protocol.
    /// @param excess Quote slice not rewarded: refunded in TRADER mode, split otherwise.
    event Settled(
        address indexed beneficiary,
        address indexed account,
        uint256 pulled,
        uint256 reward,
        uint256 funded,
        uint256 excess
    );
    /// @notice The reward asset refused or failed a mint of `reward`; the slice was not charged as funding.
    event RewardMintSkipped(address indexed beneficiary, uint256 reward);
    /// @notice The reward account of `beneficiary` was created.
    event AccountCreated(address indexed beneficiary, address indexed account);
    /// @notice Quote left this contract to `to`. `kind` 0 creator, 1 protocol, 2 refund.
    event Paid(uint8 indexed kind, address indexed to, uint256 amount);
    /// @notice A claim this programme can never settle left `beneficiary`'s reward account for `beneficiary`.
    event Rescued(
        address indexed beneficiary,
        address indexed account,
        address indexed claimRules,
        Currency currency,
        uint256 amount
    );

    /// @param p The creator's programme choices.
    /// @param protocolShareBps_ The factory's protocol share, from 2,000 to 5,000 bps.
    constructor(Params memory p, uint16 protocolShareBps_) {
        _validate(p, protocolShareBps_);
        factory = msg.sender;
        rules = p.rules;
        poolManager = address(IHookrRulesView(p.rules).poolManager());
        quote = p.quote;
        poolId = p.poolId;
        advisory = p.advisory;
        mode = p.mode;
        fixedRecipient = p.fixedRecipient;
        rewardToken = p.rewardToken;
        creatorRecipient = p.creatorRecipient;
        protocolRecipient = IHookrRulesView(p.rules).protocolRecipient();
        protocolShareBps = protocolShareBps_;
        buyTakePips = p.buyTakePips;
        sellTakePips = p.sellTakePips;
        rewardPerQuoteWad = p.rewardPerQuoteWad;
        maxRewardPerSwap = p.maxRewardPerSwap;
        lifetimeRewardCap = p.lifetimeRewardCap;
        maxSlicePerSwap = Math.mulDiv(p.maxRewardPerSwap, WAD, p.rewardPerQuoteWad);
        mintGasLimit = p.mintGasLimit;
        endsAt = p.endsAt;
        accountInitCodeHash = keccak256(type(HookrSwapRewardAccount).creationCode);
    }

    /// @inheritdoc IHookrSwapRewardMinter
    function accountOf(address beneficiary) public view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(beneficiary), accountInitCodeHash))
                )
            )
        );
    }

    /// @notice Quote slices credited to `beneficiary`'s reward account and not yet settled.
    function pendingOf(address beneficiary) public view returns (uint256) {
        return IHookrRules(rules).claimable(quote, accountOf(beneficiary));
    }

    /// @inheritdoc IHookrSwapRewardMinter
    /// @dev A bounded STATICCALL: a revert, a gas burn or anything but a 32-byte `true` reads as not ready.
    ///      Reverts `InsufficientGas` if the caller cannot give the asset its full stipend, so a short gas limit can
    ///      never be used to turn the slice off.
    function rewardReady() public view returns (bool ready) {
        if (gasleft() < READY_GAS + READY_GAS / 63 + CALL_RESERVE) revert InsufficientGas();
        bytes memory input = abi.encodeCall(IHookrRewardMintTarget.isRewardMinter, (address(this)));
        address target = rewardToken;
        uint256 stipend = READY_GAS;
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            ok := staticcall(stipend, target, add(input, 32), mload(input), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            word := mload(0)
        }
        ready = ok && word == 1;
    }

    /// @inheritdoc IHookrSwapRewardMinter
    /// @dev TRADER mode charges only authenticated swaps and attributes them to the payer (the identity HookrRoot
    ///      authenticated through the pinned router, quoter or curated router). Room is the smaller of the per-swap
    ///      slice cap and the slice the unspent lifetime cap can still reward, less what this beneficiary already has
    ///      pending. In FIXED mode that is exact; in TRADER mode other beneficiaries' pending slices are invisible
    ///      here, so settlement refunds any slice the lifetime cap can no longer reward. From `endsAt` on (when set)
    ///      the room is zero: the programme stops charging, and slices already paid still settle.
    function quoteRoom(address payer, bool authenticated) external view returns (address recipient, uint256 room) {
        address identity;
        if (mode == Mode.TRADER) {
            if (!authenticated || payer == address(0)) return (address(0), 0);
            identity = payer;
        } else if (mode == Mode.FIXED) {
            identity = fixedRecipient;
        } else {
            return (address(0), 0);
        }
        recipient = accountOf(identity);
        if (endsAt != 0 && block.timestamp >= endsAt) return (recipient, 0);
        uint256 remaining = lifetimeRewardCap - minted;
        if (remaining == 0) return (recipient, 0);
        uint256 budget = Math.mulDiv(remaining, WAD, rewardPerQuoteWad);
        uint256 pending = IHookrRules(rules).claimable(quote, recipient);
        if (budget <= pending || !rewardReady()) return (recipient, 0);
        room = budget - pending;
        if (room > maxSlicePerSwap) room = maxSlicePerSwap;
    }

    /// @notice What `settle(beneficiary)` would do now if the reward mint succeeds.
    function previewSettle(address beneficiary)
        external
        view
        returns (uint256 amount, uint256 reward, uint256 funded, uint256 excess)
    {
        amount = pendingOf(beneficiary);
        (reward, funded) = _terms(amount);
        excess = amount - funded;
    }

    /// @notice Pulls `beneficiary`'s pending slices, mints the reward, and books the funded slice and any refund.
    /// @dev Permissionless: the reward always goes to the beneficiary and a TRADER-mode refund is always owed to the
    ///      beneficiary, so the caller chooses only the timing. In FIXED and SIDECAR modes the beneficiary must be the
    ///      fixed recipient. The reward is min(floor(pulled * rate / 1e18), lifetime cap left). If the mint fails
    ///      (the asset reverts, burns its stipend or returns the wrong magic) nothing is minted and the whole pull is
    ///      treated as unrewarded. A caller that cannot give the mint its full stipend is refused, so a short gas
    ///      limit cannot force that failure.
    /// @return amount Quote pulled from the beneficiary's reward account.
    /// @return reward Reward units minted to the beneficiary.
    function settle(address beneficiary) external returns (uint256 amount, uint256 reward) {
        if (_status != IDLE) revert Reentered();
        if (beneficiary == address(0) || (mode != Mode.TRADER && beneficiary != fixedRecipient)) {
            revert InvalidBeneficiary(beneficiary);
        }
        _status = PULLING;
        address account = _account(beneficiary);
        uint256 balanceBefore = _balance();
        amount = HookrSwapRewardAccount(account).pull(rules, quote);
        if (amount == 0) revert NothingToSettle(beneficiary);
        if (_balance() != balanceBefore + amount) revert BalanceMismatch();
        _status = BUSY;
        pulledTotal += amount;

        uint256 funded;
        (reward, funded) = _terms(amount);
        if (reward != 0) {
            minted += reward;
            if (!_mint(beneficiary, reward)) {
                minted -= reward;
                ++skippedMints;
                emit RewardMintSkipped(beneficiary, reward);
                reward = 0;
                funded = 0;
            }
        }
        uint256 excess = amount - funded;
        fundedSlice += funded;
        _split(funded);
        if (excess != 0) {
            if (mode == Mode.TRADER) {
                refundOf[beneficiary] += excess;
                refundsOwed += excess;
            } else {
                _split(excess);
            }
        }
        emit Settled(beneficiary, account, amount, reward, funded, excess);
        _status = IDLE;
    }

    /// @notice Forwards to `beneficiary` a claim credited to its reward account that this programme can never settle:
    ///         one in another currency, or one held by another Rules contract (a royalty or take someone pointed at
    ///         the account). Permissionless: the whole claim always goes to the beneficiary, never to the caller.
    /// @dev The programme's own pair (`rules`, `quote`) is refused, so no one can take back a paid slice: that claim
    ///      only ever leaves through `settle`. The account pulls with the claim's own `claimTo`; the amount forwarded
    ///      is what this contract measurably received in `currency` during the pull, so a contract passed as
    ///      `claimRules` can at most donate to the beneficiary. The ledgers are untouched: a pull in the quote is
    ///      forwarded in full before the call ends. Reentry is refused throughout. A beneficiary that refuses the
    ///      currency makes the call revert and leaves the claim where it was.
    /// @param beneficiary The account's beneficiary: any address in TRADER mode, the fixed recipient otherwise.
    /// @param claimRules The contract holding the claim.
    /// @param currency The claim's currency; address zero is native.
    /// @return amount The amount forwarded.
    function rescue(address beneficiary, address claimRules, Currency currency) external returns (uint256 amount) {
        if (_status != IDLE) revert Reentered();
        if (claimRules == rules && Currency.unwrap(currency) == Currency.unwrap(quote)) revert ProgrammeClaim();
        if (
            beneficiary == address(0) || beneficiary == address(this)
                || (mode != Mode.TRADER && beneficiary != fixedRecipient)
        ) revert InvalidBeneficiary(beneficiary);
        _status = Currency.unwrap(currency) == address(0) ? RESCUING_NATIVE : RESCUING;
        address account = _account(beneficiary);
        uint256 balanceBefore = _balanceOf(currency);
        HookrSwapRewardAccount(account).pull(claimRules, currency);
        uint256 balanceAfter = _balanceOf(currency);
        if (balanceAfter < balanceBefore) revert BalanceMismatch();
        amount = balanceAfter - balanceBefore;
        if (amount == 0) revert NothingToRescue(beneficiary);
        _status = BUSY;
        _sendCurrency(currency, beneficiary, amount);
        emit Rescued(beneficiary, account, claimRules, currency, amount);
        _status = IDLE;
    }

    /// @notice Pays everything owed to the creator recipient. Permissionless.
    function sweepCreator() external returns (uint256 amount) {
        _enter();
        amount = creatorOwed;
        if (amount == 0) revert NothingOwed();
        creatorOwed = 0;
        _send(creatorRecipient, amount);
        emit Paid(0, creatorRecipient, amount);
        _status = IDLE;
    }

    /// @notice Pays everything owed to the protocol recipient. Permissionless.
    function sweepProtocol() external returns (uint256 amount) {
        _enter();
        amount = protocolOwed;
        if (amount == 0) revert NothingOwed();
        protocolOwed = 0;
        _send(protocolRecipient, amount);
        emit Paid(1, protocolRecipient, amount);
        _status = IDLE;
    }

    /// @notice Pays the caller's refund to `to`.
    function withdrawRefund(address to) external returns (uint256 amount) {
        if (to == address(0) || to == address(this)) revert InvalidBeneficiary(to);
        amount = _takeRefund(msg.sender);
        _send(to, amount);
        emit Paid(2, to, amount);
        _status = IDLE;
    }

    /// @notice Pays `beneficiary`'s refund to `beneficiary`. Permissionless, for beneficiaries that cannot call.
    function pushRefund(address beneficiary) external returns (uint256 amount) {
        amount = _takeRefund(beneficiary);
        _send(beneficiary, amount);
        emit Paid(2, beneficiary, amount);
        _status = IDLE;
    }

    /// @notice Accepts native quote only from the PoolManager while a reward account is being pulled, and native
    ///         currency from any sender while a native rescue pull runs (the rescue forwards all of it to the
    ///         beneficiary).
    receive() external payable {
        if (_status == RESCUING_NATIVE) return;
        if (Currency.unwrap(quote) != address(0) || msg.sender != poolManager || _status != PULLING) {
            revert UnexpectedNative();
        }
    }

    /// @dev reward = min(floor(amount * rate / 1e18), lifetime left). Only the slice that pays for that reward at the
    ///      frozen rate, rounded up, counts as funding; the rest is excess (refunded in TRADER mode, split otherwise).
    ///      This holds whether the lifetime cap or the floor clips the reward, so a slice worth less than one reward
    ///      unit is never kept as funding. funded <= amount because reward * 1e18 / rate <= amount and amount is a
    ///      whole number.
    function _terms(uint256 amount) private view returns (uint256 reward, uint256 funded) {
        reward = Math.mulDiv(amount, rewardPerQuoteWad, WAD);
        uint256 left = lifetimeRewardCap - minted;
        if (reward > left) reward = left;
        funded = Math.mulDiv(reward, WAD, rewardPerQuoteWad, Math.Rounding.Ceil);
    }

    function _mint(address to, uint256 amount) private returns (bool ok) {
        uint256 stipend = mintGasLimit;
        if (gasleft() < stipend + stipend / 63 + CALL_RESERVE) revert InsufficientGas();
        bytes memory input = abi.encodeCall(IHookrRewardMintTarget.mintReward, (to, amount));
        address target = rewardToken;
        uint256 word;
        assembly ("memory-safe") {
            ok := call(stipend, target, 0, add(input, 32), mload(input), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            word := mload(0)
        }
        ok = ok && bytes32(word) == bytes32(IHookrRewardMintTarget.mintReward.selector);
    }

    function _split(uint256 amount) private {
        if (amount == 0) return;
        uint256 protocolPart = amount * protocolShareBps / BPS;
        protocolOwed += protocolPart;
        creatorOwed += amount - protocolPart;
    }

    function _takeRefund(address beneficiary) private returns (uint256 amount) {
        _enter();
        amount = refundOf[beneficiary];
        if (amount == 0) revert NothingOwed();
        refundOf[beneficiary] = 0;
        refundsOwed -= amount;
    }

    function _enter() private {
        if (_status != IDLE) revert Reentered();
        _status = BUSY;
    }

    /// @dev The reward account of `beneficiary`, created on first use.
    function _account(address beneficiary) private returns (address account) {
        account = accountOf(beneficiary);
        if (account.code.length == 0) {
            address deployed = address(new HookrSwapRewardAccount{salt: _salt(beneficiary)}());
            if (deployed != account) revert AccountMismatch(account, deployed);
            emit AccountCreated(beneficiary, account);
        }
    }

    function _send(address to, uint256 amount) private {
        _sendCurrency(quote, to, amount);
    }

    function _sendCurrency(Currency currency, address to, uint256 amount) private {
        if (Currency.unwrap(currency) == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    function _balance() private view returns (uint256) {
        return _balanceOf(quote);
    }

    function _balanceOf(Currency currency) private view returns (uint256) {
        address asset = Currency.unwrap(currency);
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _salt(address beneficiary) private pure returns (bytes32) {
        return bytes32(uint256(uint160(beneficiary)));
    }

    /// @dev Numbered checks so a refused deployment names the rule it broke.
    function _validate(Params memory p, uint16 share) private view {
        if (p.rules.code.length == 0) revert InvalidParams(1);
        if (address(IHookrRulesView(p.rules).poolManager()).code.length == 0) revert InvalidParams(2);
        // HookrRoot opens pools only on the registry's quote catalog (UnqualifiedQuote), and the advisory pins the
        // programme's quote to the pool's quote at bind, so here the quote only has to be native or a contract.
        if (Currency.unwrap(p.quote) != address(0) && Currency.unwrap(p.quote).code.length == 0) {
            revert InvalidParams(3);
        }
        if (IHookrRulesView(p.rules).protocolRecipient() == address(0)) revert InvalidParams(4);
        if (p.rewardToken.code.length == 0 || p.creatorRecipient == address(0)) revert InvalidParams(5);
        if (p.rewardPerQuoteWad < MIN_RATE || p.rewardPerQuoteWad > MAX_RATE) revert InvalidParams(6);
        if (
            p.maxRewardPerSwap == 0 || p.lifetimeRewardCap < p.maxRewardPerSwap
                || p.lifetimeRewardCap > type(uint128).max
        ) revert InvalidParams(7);
        if (p.mintGasLimit < MIN_MINT_GAS || p.mintGasLimit > MAX_MINT_GAS) revert InvalidParams(8);
        if (share < MIN_PROTOCOL_SHARE_BPS || share > MAX_PROTOCOL_SHARE_BPS) revert InvalidParams(9);
        // The slice's protocol share is never below the protocol share the pool's rules require of every pool.
        if (share < IHookrRulesView(p.rules).minProtocolShareBps()) revert InvalidParams(15);
        if (p.mode == Mode.SIDECAR) {
            if (
                p.fixedRecipient == address(0) || p.advisory != address(0) || p.buyTakePips != 0 || p.sellTakePips != 0
                    || p.endsAt != 0
            ) {
                revert InvalidParams(10);
            }
        } else {
            if ((p.mode == Mode.TRADER) != (p.fixedRecipient == address(0))) revert InvalidParams(11);
            if (p.advisory.code.length == 0) revert InvalidParams(12);
            // Each side is off (zero) or inside the slice bounds, and at least one side charges.
            if (
                _outOfBounds(p.buyTakePips) || _outOfBounds(p.sellTakePips)
                    || (p.buyTakePips == 0 && p.sellTakePips == 0)
            ) {
                revert InvalidParams(13);
            }
            // One swap must be able to pay at least one wei of slice after the advisory's one-wei rounding margin.
            uint256 slice = Math.mulDiv(p.maxRewardPerSwap, WAD, p.rewardPerQuoteWad);
            if (slice < 2 || slice > type(uint128).max) revert InvalidParams(14);
            // A window that has already closed would bind a pool that can never charge.
            if (p.endsAt != 0 && p.endsAt <= block.timestamp) revert InvalidParams(16);
        }
    }

    function _outOfBounds(uint24 take) private pure returns (bool) {
        return take != 0 && (take < MIN_REWARD_TAKE_PIPS || take > MAX_REWARD_TAKE_PIPS);
    }
}
