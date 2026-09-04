// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The hook's claim surface the burner pulls its accrued flywheel fees from.
interface IHookClaims {
    function claim() external;
    function claimableWei(address account) external view returns (uint256);
}

/// @title HookrFlywheelBurner
/// @notice The sink of the HOOKR flywheel: every ETH-paired generation-5 pool pays a 0.3%
///         protocol fee per swap, the hook accrues it to this contract's claim balance, and
///         anyone may pull it here, and the owner may market-buy HOOKR through the canonical ETH/HOOKR pool —
///         every HOOKR received is transferred to 0xdEaD in the same transaction.
///
/// @dev Collection is permissionless, but spending protocol ETH is owner-gated. A permissionless
///      caller-controlled `minHookrOut` would let an attacker manipulate the pool, deliberately
///      accept the bad fill on the burner's behalf, and unwind against the protocol-funded order.
///      The owner must supply a current execution bound; the per-call ceiling and one-call-per-block
///      throttle remain defense in depth. The pool key is a construction constant (the canonical
///      hookless ETH/HOOKR pool); if that venue is ever retired the owner can migrate the balance —
///      loudly, to a contract only.
contract HookrFlywheelBurner is IUnlockCallback {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    /// @notice The HOOKR token this contract exists to burn.
    address public immutable hookrToken;
    /// @dev The canonical ETH/HOOKR pool's non-address key fields, pinned at construction.
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;

    address public owner;
    /// @notice The generation-5 hook whose flywheel fees accrue to this contract. Set once.
    address public hook;
    /// @notice Per-call buyback ceiling; the sandwich-surface bound. Owner-tunable.
    uint96 public maxBuybackWei = 0.25 ether;
    /// @notice One buyback per block: a second call in the same block reverts.
    uint40 public lastBuybackBlock;

    uint256 public totalEthSpent;
    uint256 public totalHookrBurned;

    uint256 private unlocked = 1;

    event HookSet(address indexed hook);
    event MaxBuybackSet(uint96 maxBuybackWei);
    event FlywheelCollected(uint256 amountWei);
    event BuybackBurned(address indexed caller, uint256 ethIn, uint256 hookrBurned);
    event BalanceMigrated(address indexed to, uint256 amountWei);

    error NotOwner();
    error NotPoolManager();
    error CallbackNotActive();
    error ZeroAddress();
    error HookAlreadySet();
    error Reentrancy();
    error NothingToBuy();
    error BuybackTooLarge(uint256 requested, uint256 ceiling);
    error BuybackThisBlockAlready();
    error ZeroMinimumOutput();
    error TooLittleReceived(uint256 minimum, uint256 received);
    error UnexpectedDelta();
    error SettlementMismatch(uint256 expected, uint256 settled);
    error MigrateToEoa();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (unlocked != 1) revert Reentrancy();
        unlocked = 2;
        _;
        unlocked = 1;
    }

    constructor(IPoolManager poolManager_, address hookrToken_, uint24 poolFee_, int24 poolTickSpacing_) {
        if (address(poolManager_) == address(0) || hookrToken_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        hookrToken = hookrToken_;
        poolFee = poolFee_;
        poolTickSpacing = poolTickSpacing_;
        owner = msg.sender;
    }

    function contractName() external pure returns (string memory) {
        return "HookrFlywheelBurner";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.0.1";
    }

    /// @notice Wire the generation-5 hook once, after its CREATE2 deployment (the hook takes this
    ///         contract's address as a constructor immutable, so the burner must exist first).
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        emit HookSet(hook_);
    }

    function setMaxBuybackWei(uint96 ceiling) external onlyOwner {
        maxBuybackWei = ceiling;
        emit MaxBuybackSet(ceiling);
    }

    /// @notice Pull every accrued flywheel fee from the hook into this contract. Permissionless.
    function collect() external {
        uint256 before = address(this).balance;
        IHookClaims(hook).claim();
        emit FlywheelCollected(address(this).balance - before);
    }

    /// @notice Market-buy HOOKR with collected flywheel ETH and burn every token received.
    ///         Owner-executed with an explicit output bound, bounded per call, and throttled to
    ///         one call per block.
    /// @param ethIn ETH to spend, at most `maxBuybackWei` and at most the current balance.
    /// @param minHookrOut The owner's reviewed execution bound; the burn reverts under it.
    function buybackAndBurn(uint256 ethIn, uint256 minHookrOut)
        external
        onlyOwner
        nonReentrant
        returns (uint256 burned)
    {
        if (ethIn == 0 || ethIn > address(this).balance) revert NothingToBuy();
        if (minHookrOut == 0) revert ZeroMinimumOutput();
        if (ethIn > maxBuybackWei) revert BuybackTooLarge(ethIn, maxBuybackWei);
        if (block.number == lastBuybackBlock) revert BuybackThisBlockAlready();
        lastBuybackBlock = uint40(block.number);

        uint256 spent;
        (spent, burned) = abi.decode(poolManager.unlock(abi.encode(ethIn, minHookrOut)), (uint256, uint256));

        // Record what the pool ACTUALLY charged. The callback tolerates a pool that could not
        // absorb the whole request (the residue simply stays here for the next buyback), and the
        // lifetime stat must not overstate the flywheel's real spend — the UI renders it.
        totalEthSpent += spent;
        totalHookrBurned += burned;
        // Solmate/OZ-style tokens return true; HOOKR is a standard ERC20. A failed burn transfer
        // must revert the whole buyback rather than strand bought HOOKR here.
        if (!IERC20(hookrToken).transfer(DEAD, burned)) revert TransferFailed();
        emit BuybackBurned(msg.sender, spent, burned);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (unlocked != 2) revert CallbackNotActive();
        (uint256 ethIn, uint256 minHookrOut) = abi.decode(rawData, (uint256, uint256));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(hookrToken),
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(0))
        });
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        if (delta.amount0() >= 0 || delta.amount1() <= 0) revert UnexpectedDelta();
        uint256 spent = uint256(-int256(delta.amount0()));
        uint256 received = uint256(int256(delta.amount1()));
        if (spent > ethIn) revert UnexpectedDelta();
        if (received < minHookrOut) revert TooLittleReceived(minHookrOut, received);

        uint256 paid = poolManager.settle{value: spent}();
        if (paid != spent) revert SettlementMismatch(spent, paid);
        poolManager.take(key.currency1, address(this), received);
        return abi.encode(spent, received);
    }

    /// @notice Owner escape hatch for a retired trading venue: move the un-bought balance to a
    ///         successor CONTRACT (never an EOA), loudly. Already-burned HOOKR is gone forever.
    function migrateTo(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (to.code.length == 0) revert MigrateToEoa();
        uint256 amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit BalanceMigrated(to, amount);
    }

    receive() external payable {}
}
