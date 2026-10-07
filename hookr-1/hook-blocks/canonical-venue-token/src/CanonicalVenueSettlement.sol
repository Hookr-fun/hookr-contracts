// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {HookrLauncher} from "hookr/periphery/HookrLauncher.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {CanonicalVenueToken} from "./CanonicalVenueToken.sol";
import {CanonicalVenueTokenDeployer} from "./CanonicalVenueTokenDeployer.sol";
import {CanonicalVenueLaunch} from "./CanonicalVenueLaunch.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {ICanonicalVenueRulesClaims} from "./interfaces/ICanonicalVenueRulesClaims.sol";

/// @title CanonicalVenueSettlement
/// @notice The settlement profile for CanonicalVenueToken: the only contract that can
///         move such a token across the PoolManager boundary. It launches the token on one Hookr pool through the
///         admitted HookrLauncher, and afterwards trades and provides liquidity on that one PoolKey only.
/// @dev Structural guarantee: every PoolManager unlock this contract opens executes exactly one operation, a swap
///      or a liquidity change, on the calling token's own canonical key (read from the token, never from calldata),
///      and settles exactly that operation's deltas. Inside its own unlock a token permit is exact: written
///      immediately before the single transfer that consumes it and checked to be spent afterwards, so no permit
///      is live while any code but the token itself runs. Launcher-mediated steps (launch, the creator family's
///      add and withdraw) write a permit around one call into the pinned, reentrancy-locked HookrLauncher and
///      clear it on return: launcher -> PoolManager (only the locked launcher can use it) and, for exits,
///      PoolManager -> this contract. Catalogued quote-asset code can run while the latter is live, so every
///      launcher-mediated step checks this contract's balances to the wei against the launcher's returned
///      amounts and reverts on any extra arrival; proceeds are forwarded only after every permit is cleared.
///      No owner, no pause, no upgrade, no fee. Assets are never held between calls; anything held while idle
///      (ERC-20, native or ERC-6909 claims) is a stray that anyone may sweep. Exits (family withdraw, retrieve)
///      never consult the launcher code-hash pin, the registry or the quote catalog, so none of those can lock
///      liquidity already in the pool.
///      Donations: the Hookr root does not hook donate, so any locker can donate token claims
///      (including claims bought off-venue) to the canonical pool, and fee growth cannot tell a donation from a
///      swap fee. So a venue never pays the token side of earned LP fees as the ERC-20: retrieve, provide,
///      familyWithdraw and familyAdd deliver it as ERC-6909 claims and move only principal as the ERC-20,
///      familyWithdraw refuses a principal step if fee growth moved after its fee step, and familyAdd refuses an add
///      during which fee growth moved (FeesMoved). Token claims then leave the PoolManager only by a sale on
///      the canonical pool (CanonicalVenuePeriphery.sellClaims), a venue trade like any other.
///      Identity: on a root whose curatedRouter is not this contract (the phase-one release plan pins the Universal
///      Router) these swaps are unauthenticated: the payer the root sees is this contract, and a partially filled
///      exact-input buy reverts UnauthenticatedRefund. On a root built with curatedRouter = this contract,
///      `msgSender()` authenticates the end user.
///      Advisory slot: a launch binds either no advisory or exactly `sessionAdvisory`, the HookrSessionAdvisory fixed
///      at construction, as a BEFORE_SWAP advisory that is not fail-open. Its surcharge is the creator's off-market
///      fee schedule. Its `bind` runs while the launch permit is live and only reads the registry and the Rules
///      configuration and writes its own storage; its swap and liquidity checks are static calls that run before
///      any permit is written. Every other advisory is refused.
contract CanonicalVenueSettlement is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice New-token parameters. The token address is CREATE2 from (creator, salt).
    struct TokenSpec {
        string name;
        string symbol;
        uint256 supply;
        bytes32 salt;
    }

    /// @notice One swap on a canonical pool.
    /// @dev `buy` spends the quote for the token. Exact input: `amount` is spent and `bound` is the minimum output.
    ///      Exact output: `amount` is received and `bound` is the maximum input. A zero price limit means none.
    struct Swap {
        address token;
        bool buy;
        bool exactInput;
        uint128 amount;
        uint128 bound;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint256 deadline;
    }

    /// @notice The canonical venue record of a token this contract launched. `rules` is the pool's HookrRules, read
    ///         from the root at launch: where the founding position's recapture accrual is kept.
    struct Venue {
        address root;
        Currency quote;
        bytes32 familyId;
        address lpOwner;
        address pendingLpOwner;
        address rules;
    }

    enum Op {
        SWAP,
        MODIFY
    }

    /// @dev The committed content of one unlock. Hash-checked in the callback.
    struct Call {
        Op op;
        PoolKey key;
        address token;
        address payer;
        address recipient;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bool exactInput;
        uint256 amount;
        uint256 bound;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        uint256 bound0;
        uint256 bound1;
        bool quoteAsClaims;
    }

    address public constant DEAD = address(0xdead);
    bytes32 private constant LOCK = keccak256("hookr.canonical-venue.lock");
    bytes32 private constant PAYER = keccak256("hookr.canonical-venue.payer");
    bytes32 private constant PENDING = keccak256("hookr.canonical-venue.pending");
    /// @dev HookrSessionAdvisory's configuration schema: keccak256 of its Schedule type string.
    bytes32 private constant SESSION_SCHEMA = keccak256(
        "SessionSchedule(uint24 regularPips,uint24 preMarketPips,uint24 afterHoursPips,uint24 overnightPips,uint24 closedPips,uint16 openRampSeconds,uint16 closeRampSeconds,uint8 flags)"
    );

    /// @notice The v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The Hookr registry that admits roots, launchers and quotes.
    IHookrRegistry public immutable registry;
    /// @notice The admitted Hookr launcher used for launch and the creator family.
    HookrLauncher public immutable launcher;
    /// @notice The launcher's code hash, pinned at construction and checked on launch only.
    bytes32 public immutable launcherCodeHash;
    /// @notice The token factory this contract created; only this contract can deploy through it.
    CanonicalVenueTokenDeployer public immutable tokenDeployer;
    /// @notice The only advisory a launch may bind: a HookrSessionAdvisory, fixed at construction. Zero when this
    ///         settlement refuses every advisory.
    address public immutable sessionAdvisory;
    /// @notice The launch module this contract created and reaches only by DELEGATECALL (see CanonicalVenueLaunch).
    address public immutable launchModule;

    mapping(address token => Venue) private _venues;

    error Reentered();
    error InvalidWiring();
    error InvalidLaunch();
    error QuoteNotCatalogued(Currency quote);
    error AdvisoryUnsupported();
    error UnknownToken(address token);
    error NotLpOwner(address caller);
    error NotPendingLpOwner(address caller);
    error InvalidRecipient(address recipient);
    error InvalidSwap();
    error InvalidLiquidity();
    error InvalidValue();
    error Expired();
    error Slippage();
    error InvalidCallback();
    error PermitNotConsumed(address from, address to);
    error BalanceMismatch();
    error UnexpectedNative();
    error FeesMoved();

    event CanonicalLaunched(
        address indexed token,
        PoolId indexed poolId,
        address indexed creator,
        address root,
        bytes32 familyId,
        uint256 supply,
        uint256 retained
    );
    event VenueSwap(
        address indexed token,
        address indexed payer,
        address indexed recipient,
        bool buy,
        uint256 amountIn,
        uint256 amountOut
    );
    event LiquidityModified(
        address indexed token,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        int128 delta0,
        int128 delta1
    );
    event FamilyWithdrawn(
        address indexed token,
        address indexed lpOwner,
        address recipient,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event FamilyAdded(
        address indexed token, address indexed lpOwner, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event LpOwnerTransferStarted(address indexed token, address indexed lpOwner, address indexed pendingLpOwner);
    event LpOwnerTransferred(address indexed token, address indexed lpOwner);
    event Swept(Currency indexed currency, address indexed to, uint256 amount);
    event ClaimsSwept(Currency indexed currency, address indexed to, uint256 amount);
    event RecaptureClaimed(address indexed token, address indexed to, uint256 currencies);

    /// @param manager The v4 PoolManager.
    /// @param registry_ The Hookr registry.
    /// @param launcher_ The admitted HookrLauncher; its code hash is pinned.
    /// @param sessionAdvisory_ The HookrSessionAdvisory launches may bind, or zero to refuse every advisory. A nonzero
    ///        address must be a contract that reports the session schedule schema.
    constructor(IPoolManager manager, IHookrRegistry registry_, HookrLauncher launcher_, address sessionAdvisory_) {
        if (
            address(manager).code.length == 0 || address(registry_).code.length == 0
                || address(launcher_).code.length == 0 || address(launcher_.poolManager()) != address(manager)
                || address(launcher_.registry()) != address(registry_)
        ) revert InvalidWiring();
        if (sessionAdvisory_ != address(0)) {
            if (sessionAdvisory_.code.length == 0) revert InvalidWiring();
            try IHookrAdvisory(sessionAdvisory_).configSchemaHash() returns (bytes32 schema) {
                if (schema != SESSION_SCHEMA) revert InvalidWiring();
            } catch {
                revert InvalidWiring();
            }
        }
        poolManager = manager;
        registry = registry_;
        launcher = launcher_;
        launcherCodeHash = address(launcher_).codehash;
        sessionAdvisory = sessionAdvisory_;
        CanonicalVenueTokenDeployer deployer = new CanonicalVenueTokenDeployer(manager);
        tokenDeployer = deployer;
        launchModule = address(new CanonicalVenueLaunch(manager, registry_, launcher_, deployer, sessionAdvisory_));
    }

    /// @notice The venue record of a launched token; zero fields for unknown tokens.
    function venue(address token) external view returns (Venue memory) {
        return _venues[token];
    }

    /// @notice Whether this contract deployed and launched `token`. This is the provenance an app should check.
    function isCanonicalToken(address token) public view returns (bool) {
        return _venues[token].root != address(0);
    }

    /// @notice The end user of the operation in progress, for a root that names this contract as curatedRouter.
    /// @dev Zero when idle. A root reading zero refuses the swap, so this can never downgrade identity.
    function msgSender() external view returns (address) {
        return address(uint160(_tget(PAYER)));
    }

    /// @notice The v4 position salt used for `owner`'s own positions in any canonical pool. Token prediction and
    ///         position reads live in CanonicalVenuePeriphery (this contract is at the EIP-170 limit).
    function positionSalt(address owner) public pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }

    /// @notice Deploys a CanonicalVenueToken and opens its one canonical Hookr pool through the admitted launcher.
    /// @dev `member` is the HookrLauncher member; the launcher overwrites its subject, quote and liquidityOwner.
    ///      Advisory slot, the creator's choice: with `member.config.advisory` zero every advisory field must be zero
    ///      and `advisoryData` empty. Otherwise the advisory must be `sessionAdvisory`, with `advisoryPhases`
    ///      BEFORE_SWAP and `advisoryFailOpen` false, and `advisoryData` is its ABI-encoded
    ///      IHookrSessionAdvisory.Schedule. The session advisory bounds every tier by its root admission cap and the
    ///      open plus close ramps by the shortest regular session; the root requires `advisoryGasLimit` to equal the
    ///      admission's gas limit and reserves the admission cap inside the pool cap. This contract owns the
    ///      launcher family and records the caller as its LP owner. Retained supply goes to `supplyRecipient`;
    ///      unused quote returns to the caller. The quote must be in the registry's reviewed quote catalog.
    ///      msg.value is the native quote budget (zero for an ERC-20 quote) plus the launcher's launch fee as it reads
    ///      in this call (`IHookrLaunchFee.launchFee`, zero at deploy), exactly; the launcher pays the fee to the
    ///      treasury's target.
    ///      Runs in CanonicalVenueLaunch, the module this contract created, by DELEGATECALL (this contract's context,
    ///      storage and permits); the arguments, checks, results, events and errors are unchanged. A royalty paid to
    ///      this contract is refused (`InvalidRecipient`).
    /// @return token The new token.
    /// @return familyId The launcher family that holds the founding position.
    function launch(TokenSpec calldata, address, IHookrLauncher.Member calldata, bytes calldata, address, uint256)
        external
        payable
        returns (address, bytes32)
    {
        address module = launchModule;
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            let ok := delegatecall(gas(), module, p, calldatasize(), 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }

    /// @notice Swaps on the token's canonical pool only. The caller pays the input and is the payer identity.
    /// @dev The caller approves this contract for the token (sells) or the ERC-20 quote (buys). Native input is
    ///      sent as msg.value equal to the maximum input; the unused part is refunded.
    function swap(Swap calldata p) external payable returns (uint256 amountIn, uint256 amountOut) {
        _enter(msg.sender);
        Venue storage v = _venue(p.token);
        if (block.timestamp > p.deadline) revert Expired();
        _checkRecipient(p.recipient);
        if (p.amount == 0 || p.amount > uint128(type(int128).max) || p.bound == 0) revert InvalidSwap();
        PoolKey memory key = CanonicalVenueToken(p.token).canonicalPoolKey();
        bool tokenIs0 = Currency.unwrap(key.currency0) == p.token;
        bool zeroForOne = p.buy ? !tokenIs0 : tokenIs0;
        Currency input = p.buy ? v.quote : Currency.wrap(p.token);
        Currency output = p.buy ? Currency.wrap(p.token) : v.quote;
        uint256 maximum = p.exactInput ? p.amount : p.bound;
        bool nativeIn = Currency.unwrap(input) == address(0);
        if (msg.value != (nativeIn ? maximum : 0)) revert InvalidValue();
        uint256 nativeBase = address(this).balance - msg.value;

        Call memory c;
        c.op = Op.SWAP;
        c.key = key;
        c.token = p.token;
        c.payer = msg.sender;
        c.recipient = p.recipient;
        c.zeroForOne = zeroForOne;
        c.amountSpecified = p.exactInput ? -int256(uint256(p.amount)) : int256(uint256(p.amount));
        c.sqrtPriceLimitX96 = p.sqrtPriceLimitX96 != 0
            ? p.sqrtPriceLimitX96
            : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        c.exactInput = p.exactInput;
        c.amount = p.amount;
        c.bound = p.bound;
        (amountIn, amountOut) = abi.decode(_unlock(c), (uint256, uint256));

        if (Currency.unwrap(output) == address(0)) HookrSettlement.send(output, p.recipient, amountOut);
        if (nativeIn) HookrSettlement.send(input, msg.sender, maximum - amountIn);
        if (address(this).balance != nativeBase) revert BalanceMismatch();
        _exit();
        emit VenueSwap(p.token, msg.sender, p.recipient, p.buy, amountIn, amountOut);
    }

    /// @notice Adds liquidity to the caller's own position in the canonical pool.
    /// @dev Refused by Hookr Rules while the launch guard runs (only the launcher may add then). Fees the
    ///      position already earned are paid to the caller. Native currency0 is sent as msg.value == max0.
    /// @return delta0 Caller's currency0 delta (negative paid, positive received).
    /// @return delta1 Caller's currency1 delta.
    function provide(
        address token,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 max0,
        uint128 max1,
        uint256 deadline
    ) external payable returns (int128 delta0, int128 delta1) {
        _enter(msg.sender);
        _venue(token);
        if (block.timestamp > deadline) revert Expired();
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidLiquidity();
        PoolKey memory key = CanonicalVenueToken(token).canonicalPoolKey();
        if (msg.value != (Currency.unwrap(key.currency0) == address(0) ? max0 : 0)) revert InvalidValue();
        uint256 nativeBase = address(this).balance - msg.value;
        (delta0, delta1) =
            _modify(key, token, tickLower, tickUpper, int256(uint256(liquidity)), max0, max1, msg.sender, false);
        HookrSettlement.send(Currency.wrap(address(0)), msg.sender, address(this).balance - nativeBase);
        _exit();
        emit LiquidityModified(token, msg.sender, tickLower, tickUpper, int256(uint256(liquidity)), delta0, delta1);
    }

    /// @notice Removes liquidity from the caller's own position, or collects its fees with `liquidity` zero.
    /// @dev The token side of earned fees is minted to `recipient` as ERC-6909 claims and the returned token delta
    ///      is principal only; `provide` does the same with the fees an addition collects.
    /// @param quoteAsClaims Deliver the quote side as PoolManager ERC-6909 claims (for a paused or restricted
    ///        quote asset). Token principal is always delivered as the ERC-20.
    function retrieve(
        address token,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        bool quoteAsClaims,
        uint256 deadline
    ) external returns (int128 delta0, int128 delta1) {
        _enter(msg.sender);
        _venue(token);
        if (block.timestamp > deadline) revert Expired();
        _checkRecipient(recipient);
        if (liquidity > uint128(type(int128).max)) revert InvalidLiquidity();
        PoolKey memory key = CanonicalVenueToken(token).canonicalPoolKey();
        uint256 nativeBase = address(this).balance;
        (delta0, delta1) = _modify(
            key, token, tickLower, tickUpper, -int256(uint256(liquidity)), min0, min1, recipient, quoteAsClaims
        );
        HookrSettlement.send(Currency.wrap(address(0)), recipient, address(this).balance - nativeBase);
        _exit();
        emit LiquidityModified(token, msg.sender, tickLower, tickUpper, -int256(uint256(liquidity)), delta0, delta1);
    }

    /// @notice Removes founding liquidity (or collects its fees with `liquidity` zero) for the LP owner.
    /// @dev The launcher keeps its principal lock until the guard ends; fees are always collectable. Proceeds
    ///      arrive here under a PoolManager -> settlement permit, are checked to the wei against the launcher's
    ///      returned amounts (so nothing can ride the permit in), and are forwarded after the permit is cleared.
    ///      `quoteAsClaims` delivers the quote side as ERC-6909 claims, which runs no quote-asset code.
    ///      `min0`/`min1` bound the principal the launcher's removal pays (HookrLauncher.withdraw): the fees the
    ///      position accrued since it was last touched are paid on top and never fill a shortfall, so a fee collection
    ///      (`liquidity` zero), which pays no principal, takes zero bounds and refuses any other (`Slippage`).
    ///      The fees are collected first, straight to `recipient`, with the token side as claims and no permit live;
    ///      with `liquidity` zero that is the whole call. Otherwise that fee step removes one unit of the liquidity, paid the same way: a removal makes a lane root donate the released part
    ///      of a pending recapture LP share before the position's fees are computed, so that share is collected here as
    ///      claims too, not carried by the principal step as the ERC-20. The principal step then removes the rest
    ///      (bounded by `min0`/`min1`, returning its own amounts; the fee step's amounts are in the launcher's
    ///      LPFeesCollected event), and it reverts FeesMoved if the position earned any token-side fee between the two
    ///      steps, so it can only carry principal.
    function familyWithdraw(
        address token,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        address recipient,
        bool quoteAsClaims,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1) {
        _enter(msg.sender);
        Venue storage v = _venue(token);
        if (msg.sender != v.lpOwner) revert NotLpOwner(msg.sender);
        _checkRecipient(recipient);
        bool tokenIs0 = Currency.unwrap(CanonicalVenueToken(token).canonicalPoolKey().currency0) == token;
        // With liquidity, one unit is removed here so that a lane root's recapture flush lands in this step.
        uint128 flushUnit = liquidity == 0 ? 0 : 1;
        (uint256 f0, uint256 f1) = launcher.withdrawWithClaims(
            v.familyId,
            0,
            flushUnit,
            liquidity == 0 ? min0 : 0,
            liquidity == 0 ? min1 : 0,
            recipient,
            (quoteAsClaims ? (tokenIs0 ? 2 : 1) : 0) | (tokenIs0 ? 1 : 2),
            deadline
        );
        if (liquidity == 0) {
            _exit();
            emit FamilyWithdrawn(token, msg.sender, recipient, 0, f0, f1);
            return (f0, f1);
        }
        uint128 principal = liquidity - flushUnit;
        bytes32 mark = _tokenFeeMark(v, token, tokenIs0);
        Currency quote = v.quote;
        // Recapture accrual so far goes straight to the recipient; what the step itself moves here is passed on below.
        launcher.claimRecapture(v.familyId, 0, recipient);
        uint256 tokenBase = IERC20(token).balanceOf(address(this));
        uint256 quoteBase = quoteAsClaims
            ? poolManager.balanceOf(address(this), quote.toId())
            : HookrSettlement.balance(quote, address(this));

        _permit(token, address(poolManager), address(this), type(uint256).max);
        (amount0, amount1) = launcher.withdrawWithClaims(
            v.familyId, 0, principal, min0, min1, address(this), quoteAsClaims ? (tokenIs0 ? 2 : 1) : 0, deadline
        );
        _permit(token, address(poolManager), address(this), 0);
        if (_tokenFeeMark(v, token, tokenIs0) != mark) revert FeesMoved();

        (uint256 tokenAmount, uint256 quoteAmount) = tokenIs0 ? (amount0, amount1) : (amount1, amount0);
        uint256 quoteNow = quoteAsClaims
            ? poolManager.balanceOf(address(this), quote.toId())
            : HookrSettlement.balance(quote, address(this));
        if (IERC20(token).balanceOf(address(this)) != tokenBase + tokenAmount || quoteNow != quoteBase + quoteAmount) {
            revert BalanceMismatch();
        }
        if (tokenAmount != 0) IERC20(token).safeTransfer(recipient, tokenAmount);
        if (quoteAsClaims) {
            if (quoteAmount != 0) poolManager.transfer(recipient, quote.toId(), quoteAmount);
        } else {
            HookrSettlement.send(quote, recipient, quoteAmount);
        }
        _passAccrual(v, token, recipient);
        _exit();
        emit FamilyWithdrawn(token, msg.sender, recipient, liquidity, amount0, amount1);
    }

    /// @notice Adds `liquidity` to the founding position for the LP owner. Earned fees and unused inputs return to the
    ///         caller.
    /// @dev Two launcher calls with exact accounting: first the earned fees are paid straight to the caller, the token
    ///      side as ERC-6909 claims, with no permit live, and this contract's balances are checked unchanged to the
    ///      wei; then the addition runs with only a launcher -> PoolManager permit. Because the fees were just
    ///      collected, the launcher's own pre-add collection moves nothing; a token fee accruing before step 2 would
    ///      meet no permit there, so the call reverts rather than pay it as the ERC-20.
    ///      A fully withdrawn founding position (liquidity zero) skips step 1: the withdrawal already paid its fees,
    ///      a zero-liquidity position earns none, the launcher refuses to collect from it, and the launcher's own
    ///      pre-add collection is skipped for it too. Step 2 reverts FeesMoved if the position earned a token-side fee
    ///      while it ran: a donation made by a catalogued ERC-20 quote's code while the launcher funds itself would
    ///      otherwise be netted into the add and refunded as the ERC-20.
    ///      Arb recapture: on a lane root every add and every nonzero removal first donates the released part of a
    ///      pending LP share, once per L2 block. Once the family's principal lock has ended, step 1 also removes one
    ///      unit of the position, so that flush lands in step 1 and the founding part of the share is paid with the
    ///      fees; step 2 adds `liquidity` plus that unit, so the position grows by exactly `liquidity`, `max0`/`max1`
    ///      bound that addition and the returned amounts are its own (the unit's principal comes back with the fees).
    ///      While principal is locked nothing can be removed, the flush runs inside the add and the PoolManager nets
    ///      the founding part into the add's delta: a quote-side part below the add's quote amount comes back with
    ///      the unused quote, one above it makes the launcher refuse the add (InvalidFunding), and a token-side part
    ///      is refused (FeesMoved, or InvalidFunding above the add's token amount). A venue trade earlier in the same
    ///      L2 block flushes the share first.
    function familyAdd(address token, uint128 liquidity, uint128 max0, uint128 max1, uint256 deadline)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        _enter(msg.sender);
        Venue storage v = _venue(token);
        if (msg.sender != v.lpOwner) revert NotLpOwner(msg.sender);
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidLiquidity();
        bool tokenIs0 = Currency.unwrap(CanonicalVenueToken(token).canonicalPoolKey().currency0) == token;
        Currency quote = v.quote;
        bool nativeQuote = Currency.unwrap(quote) == address(0);
        (uint256 tokenMax, uint256 quoteMax) =
            tokenIs0 ? (uint256(max0), uint256(max1)) : (uint256(max1), uint256(max0));
        if (msg.value != (nativeQuote ? quoteMax : 0)) revert InvalidValue();
        uint256 tokenBase = IERC20(token).balanceOf(address(this));
        uint256 quoteBase = HookrSettlement.balance(quote, address(this)) - msg.value;

        // 1. Collect earned fees, exactly (none to collect from a fully withdrawn position). As claims they go
        //    straight to the caller and stay out of this contract's accounting. Once the principal lock has ended one
        //    unit goes with them, so a lane root's arb recapture flush lands here and not in the add.
        uint128 flushUnit;
        if (launcher.position(v.familyId, 0).liquidity != 0) {
            if (block.number >= launcher.principalLockedUntil(v.familyId)) flushUnit = 1;
            launcher.claimRecapture(v.familyId, 0, msg.sender);
            launcher.withdrawWithClaims(v.familyId, 0, flushUnit, 0, 0, msg.sender, tokenIs0 ? 1 : 2, deadline);
            _passAccrual(v, token, msg.sender);
        }
        if (
            IERC20(token).balanceOf(address(this)) != tokenBase
                || HookrSettlement.balance(quote, address(this)) != quoteBase + msg.value
        ) revert BalanceMismatch();

        // 2. Fund and add. The position must earn no token-side fee until the add is done: a catalogued ERC-20
        //    quote's code runs while the launcher funds itself, and a donation then would be netted into the add's
        //    token delta and refunded here as the ERC-20. A position without liquidity earns nothing.
        bytes32 mark = launcher.position(v.familyId, 0).liquidity != 0 ? _tokenFeeMark(v, token, tokenIs0) : bytes32(0);
        _pull(Currency.wrap(token), msg.sender, tokenMax);
        IERC20(token).forceApprove(address(launcher), tokenMax);
        if (!nativeQuote) {
            _pull(quote, msg.sender, quoteMax);
            IERC20(Currency.unwrap(quote)).forceApprove(address(launcher), quoteMax);
        }
        _permit(token, address(launcher), address(poolManager), tokenMax);
        (amount0, amount1) = launcher.addLiquidity{value: nativeQuote ? quoteMax : 0}(
            v.familyId, 0, liquidity + flushUnit, max0, max1, deadline
        );
        _permit(token, address(launcher), address(poolManager), 0);
        if (mark != 0 && _tokenFeeMark(v, token, tokenIs0) != mark) revert FeesMoved();
        IERC20(token).forceApprove(address(launcher), 0);
        if (!nativeQuote) IERC20(Currency.unwrap(quote)).forceApprove(address(launcher), 0);

        // 3. Everything above the starting balances is the caller's: the unused inputs, checked exactly.
        (uint256 tokenPaid, uint256 quotePaid) = tokenIs0 ? (amount0, amount1) : (amount1, amount0);
        uint256 tokenBack = tokenMax - tokenPaid;
        uint256 quoteBack = quoteMax - quotePaid;
        if (
            IERC20(token).balanceOf(address(this)) != tokenBase + tokenBack
                || HookrSettlement.balance(quote, address(this)) != quoteBase + quoteBack
        ) revert BalanceMismatch();
        if (tokenBack != 0) IERC20(token).safeTransfer(msg.sender, tokenBack);
        HookrSettlement.send(quote, msg.sender, quoteBack);
        _exit();
        emit FamilyAdded(token, msg.sender, liquidity, amount0, amount1);
    }

    /// @notice Moves the founding position's recapture accrual (Hookr 1 recapture lane), in every currency, into
    ///         `to`'s claims in the pool's HookrRules. Only the LP owner. Returns how many currencies moved.
    /// @dev This contract owns the launcher family, so the launcher credits the accrual to whoever this contract
    ///      names. Every family withdraw and fee collection also moves it, to that call's recipient. `to` then claims
    ///      it from the Rules: the token side only with `claimAsClaims` (a Rules `claim` of the token would move the
    ///      ERC-20 out of the PoolManager without a permit and reverts `VenueOnly`), the quote side in any form.
    function familyClaimRecapture(address token, address to) external returns (uint256 moved) {
        _enter(msg.sender);
        Venue storage v = _venue(token);
        if (msg.sender != v.lpOwner) revert NotLpOwner(msg.sender);
        _checkRecipient(to);
        moved = launcher.claimRecapture(v.familyId, 0, to);
        _exit();
        emit RecaptureClaimed(token, to, moved);
    }

    /// @notice Starts a two-step transfer of the founding position's LP ownership. Zero cancels.
    function transferLpOwner(address token, address next) external {
        _notEntered();
        Venue storage v = _venue(token);
        if (msg.sender != v.lpOwner) revert NotLpOwner(msg.sender);
        if (next == address(this) || next == address(poolManager) || next == address(launcher)) {
            revert InvalidRecipient(next);
        }
        v.pendingLpOwner = next;
        emit LpOwnerTransferStarted(token, msg.sender, next);
    }

    /// @notice Completes a pending LP ownership transfer.
    function acceptLpOwner(address token) external {
        _notEntered();
        Venue storage v = _venue(token);
        if (msg.sender != v.pendingLpOwner || msg.sender == address(0)) revert NotPendingLpOwner(msg.sender);
        v.lpOwner = msg.sender;
        v.pendingLpOwner = address(0);
        emit LpOwnerTransferred(token, msg.sender);
    }

    /// @notice Sends this contract's whole idle balance of `currency` to `to`. Anyone may call while idle.
    /// @dev Every operation returns balances to their starting values, so an idle balance is a mistaken transfer
    ///      or forced ETH. Moving a canonical token out of this contract is an ordinary transfer, not a crossing.
    function sweep(Currency currency, address to) external returns (uint256 amount) {
        _enter(msg.sender);
        if (to == address(0) || to == address(this) || to == address(poolManager)) revert InvalidRecipient(to);
        amount = HookrSettlement.balance(currency, address(this));
        HookrSettlement.send(currency, to, amount);
        _exit();
        emit Swept(currency, to, amount);
    }

    /// @notice Sends this contract's whole idle ERC-6909 claim balance of `currency` to `to`. Anyone may call while
    ///         idle.
    /// @dev No operation leaves claims here between calls (quote-as-claims exits forward them in the same call), so
    ///      an idle claim is a mistaken transfer. It moves on as a claim: no ERC-20 crosses the PoolManager boundary.
    function sweepClaims(Currency currency, address to) external returns (uint256 amount) {
        _enter(msg.sender);
        if (to == address(0) || to == address(this) || to == address(poolManager)) revert InvalidRecipient(to);
        amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount != 0) poolManager.transfer(to, currency.toId(), amount);
        _exit();
        emit ClaimsSwept(currency, to, amount);
    }

    /// @notice Executes only the committed operation on the committed canonical key.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _tget(LOCK) == 0 || _tget(PENDING) != uint256(keccak256(data))) {
            revert InvalidCallback();
        }
        _tset(PENDING, 0);
        Call memory c = abi.decode(data, (Call));
        if (c.op == Op.SWAP) return _swapLeg(c);
        return _modifyLeg(c);
    }

    function _swapLeg(Call memory c) private returns (bytes memory) {
        BalanceDelta d = poolManager.swap(c.key, SwapParams(c.zeroForOne, c.amountSpecified, c.sqrtPriceLimitX96), "");
        (int128 inDelta, int128 outDelta) = c.zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        if (inDelta >= 0 || outDelta <= 0) revert InvalidSwap();
        uint256 amountIn = uint256(-int256(inDelta));
        uint256 amountOut = uint256(int256(outDelta));
        if (c.exactInput) {
            if (amountIn > c.amount || amountOut < c.bound) revert Slippage();
        } else {
            if (amountOut != c.amount || amountIn > c.bound) revert Slippage();
        }
        Currency input = c.zeroForOne ? c.key.currency0 : c.key.currency1;
        Currency output = c.zeroForOne ? c.key.currency1 : c.key.currency0;
        _debit(input, c.token, c.payer, amountIn);
        _credit(output, c.token, c.recipient, amountOut, false);
        return abi.encode(amountIn, amountOut);
    }

    function _modifyLeg(Call memory c) private returns (bytes memory) {
        (BalanceDelta d, BalanceDelta fees) = poolManager.modifyLiquidity(
            c.key, ModifyLiquidityParams(c.tickLower, c.tickUpper, c.liquidityDelta, c.salt), ""
        );
        int128 d0 = d.amount0();
        int128 d1 = d.amount1();
        // Token-side fees as claims: the ERC-20 settles principal only and the fee part is minted to
        // the recipient as claims, so a donation can never come back out as the ERC-20.
        int128 tokenFees;
        if (Currency.unwrap(c.key.currency0) == c.token) {
            tokenFees = fees.amount0();
            d0 -= tokenFees;
        } else {
            tokenFees = fees.amount1();
            d1 -= tokenFees;
        }
        if (c.liquidityDelta > 0) {
            if ((d0 < 0 && uint256(-int256(d0)) > c.bound0) || (d1 < 0 && uint256(-int256(d1)) > c.bound1)) {
                revert Slippage();
            }
        } else {
            if (d0 < 0 || d1 < 0) revert InvalidLiquidity();
            if (uint256(int256(d0)) < c.bound0 || uint256(int256(d1)) < c.bound1) revert Slippage();
        }
        _settleDelta(c.key.currency0, c.token, d0, c.payer, c.recipient, c.quoteAsClaims);
        _settleDelta(c.key.currency1, c.token, d1, c.payer, c.recipient, c.quoteAsClaims);
        if (tokenFees > 0) {
            HookrSettlement.mintTo(poolManager, Currency.wrap(c.token), c.recipient, uint128(tokenFees));
        }
        return abi.encode(d0, d1);
    }

    function _settleDelta(
        Currency currency,
        address token,
        int128 delta,
        address payer,
        address recipient,
        bool asClaims
    ) private {
        if (delta < 0) _debit(currency, token, payer, uint256(-int256(delta)));
        else if (delta > 0) _credit(currency, token, recipient, uint256(int256(delta)), asClaims);
    }

    /// @dev Pays `amount` of `currency` owed to the PoolManager from `payer`.
    function _debit(Currency currency, address token, address payer, uint256 amount) private {
        if (amount == 0) return;
        if (Currency.unwrap(currency) == token) {
            poolManager.sync(currency);
            uint256 before = IERC20(token).balanceOf(payer);
            _permit(token, payer, address(poolManager), amount);
            IERC20(token).safeTransferFrom(payer, address(poolManager), amount);
            _spent(token, payer, address(poolManager));
            if (before - IERC20(token).balanceOf(payer) != amount || poolManager.settle() != amount) {
                revert BalanceMismatch();
            }
        } else if (Currency.unwrap(currency) == address(0)) {
            HookrSettlement.pay(poolManager, currency, address(this), amount);
        } else {
            HookrSettlement.pay(poolManager, currency, payer, amount);
        }
    }

    /// @dev Takes `amount` of `currency` owed by the PoolManager for `recipient`. Native output is taken here and
    ///      forwarded after the unlock; the token goes straight to the recipient under an exact permit.
    function _credit(Currency currency, address token, address recipient, uint256 amount, bool asClaims) private {
        if (amount == 0) return;
        if (Currency.unwrap(currency) == token) {
            _permit(token, address(poolManager), recipient, amount);
            HookrSettlement.takeTo(poolManager, currency, recipient, amount);
            _spent(token, address(poolManager), recipient);
        } else if (asClaims) {
            HookrSettlement.mintTo(poolManager, currency, recipient, amount);
        } else if (Currency.unwrap(currency) == address(0)) {
            HookrSettlement.take(poolManager, currency, amount);
        } else {
            HookrSettlement.takeTo(poolManager, currency, recipient, amount);
        }
    }

    function _modify(
        PoolKey memory key,
        address token,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        uint256 bound0,
        uint256 bound1,
        address recipient,
        bool quoteAsClaims
    ) private returns (int128 delta0, int128 delta1) {
        Call memory c;
        c.op = Op.MODIFY;
        c.key = key;
        c.token = token;
        c.payer = msg.sender;
        c.recipient = recipient;
        c.tickLower = tickLower;
        c.tickUpper = tickUpper;
        c.liquidityDelta = liquidityDelta;
        c.salt = positionSalt(msg.sender);
        c.bound0 = bound0;
        c.bound1 = bound1;
        c.quoteAsClaims = quoteAsClaims;
        (delta0, delta1) = abi.decode(_unlock(c), (int128, int128));
    }

    function _unlock(Call memory c) private returns (bytes memory result) {
        bytes memory data = abi.encode(c);
        _tset(PENDING, uint256(keccak256(data)));
        result = poolManager.unlock(data);
        if (_tget(PENDING) != 0) revert InvalidCallback();
    }

    function _venue(address token) private view returns (Venue storage v) {
        v = _venues[token];
        if (v.root == address(0)) revert UnknownToken(token);
    }

    /// @dev Passes recapture accrual the launcher credited to this contract during a family step on to `to`, as
    ///      ERC-6909 claims (no token code runs). A step moves accrual only in the pool's two currencies (the rest
    ///      was moved to `to` before it). Nothing else credits this contract in the Rules: its swaps name no trader on
    ///      a root whose curated router is not this contract, and a royalty to it is refused at launch.
    function _passAccrual(Venue storage v, address token, address to) private {
        ICanonicalVenueRulesClaims rules = ICanonicalVenueRulesClaims(v.rules);
        if (rules.claimable(Currency.wrap(token), address(this)) != 0) rules.claimAsClaims(Currency.wrap(token), to);
        if (rules.claimable(v.quote, address(this)) != 0) rules.claimAsClaims(v.quote, to);
    }

    function _pull(Currency currency, address from, uint256 amount) private {
        if (amount == 0) return;
        IERC20 asset = IERC20(Currency.unwrap(currency));
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(from, address(this), amount);
        if (asset.balanceOf(address(this)) != before + amount) revert BalanceMismatch();
    }

    /// @dev The founding position's token-side fee growth inside, as the PoolManager last recorded it for that
    ///      position. Every modification of the position (a collection, an add, a removal) sets it to the current
    ///      value, so it changes across a step exactly when the position earned a token-side fee since the previous
    ///      step, and that fee rode the step's delta. Hashed, so a mark is never zero.
    function _tokenFeeMark(Venue storage v, address token, bool tokenIs0) private view returns (bytes32) {
        IHookrLauncher.Position memory p = launcher.position(v.familyId, 0);
        (, uint256 inside0, uint256 inside1) = poolManager.getPositionInfo(
            CanonicalVenueToken(token).canonicalPoolId(),
            address(launcher),
            p.tickLower,
            p.tickUpper,
            keccak256(abi.encode(v.familyId, uint8(0)))
        );
        return keccak256(abi.encode(tokenIs0 ? inside0 : inside1));
    }

    function _permit(address token, address from, address to, uint256 amount) private {
        CanonicalVenueToken(token).setVenuePermit(from, to, amount);
    }

    function _spent(address token, address from, address to) private view {
        if (CanonicalVenueToken(token).venuePermit(from, to) != 0) revert PermitNotConsumed(from, to);
    }

    function _checkRecipient(address recipient) private view {
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(poolManager)
                || recipient == DEAD || recipient == address(launcher)
        ) revert InvalidRecipient(recipient);
    }

    function _enter(address payer) private {
        if (_tget(LOCK) != 0) revert Reentered();
        _tset(LOCK, 1);
        _tset(PAYER, uint256(uint160(payer)));
    }

    function _exit() private {
        _tset(LOCK, 0);
        _tset(PAYER, 0);
    }

    function _notEntered() private view {
        if (_tget(LOCK) != 0) revert Reentered();
    }

    function _tget(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _tset(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }

    /// @notice Accepts native currency only from the PoolManager or the launcher during an operation.
    receive() external payable {
        if (_tget(LOCK) == 0 || (msg.sender != address(poolManager) && msg.sender != address(launcher))) {
            revert UnexpectedNative();
        }
    }
}
