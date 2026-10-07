// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {CanonicalVenueToken} from "./CanonicalVenueToken.sol";
import {CanonicalVenueSettlement} from "./CanonicalVenueSettlement.sol";

/// @title CanonicalVenuePeriphery
/// @notice Sells ERC-6909 claims of a canonical-venue token on its canonical pool,
///         which is how an LP turns token-side fees paid as claims into the quote, and serves the read helpers the
///         settlement has no bytecode room for (token address prediction, a caller's position liquidity).
/// @dev Outside the token's trust boundary: it never moves the token's ERC-20 and cannot write a venue permit (only
///      the settlement can), so a fault here can cost only its own caller's claims or quote. A sale burns claims
///      from the caller only, never from anyone else, so an approval given to this contract is exercised only in
///      that holder's own call. No owner, no fee, no upgrade; holds nothing between calls. The sale is an ordinary
///      unauthenticated swap on the canonical key and pays what any sale pays there (the LP fee, including a
///      dynamic fee); it moves the canonical price like any holder's sale.
contract CanonicalVenuePeriphery is IUnlockCallback {
    using StateLibrary for IPoolManager;

    /// @notice One sale of token claims for the quote on the token's canonical pool.
    /// @dev Exact input: `amount` claims are sold and `bound` is the minimum quote out. Exact output: `amount` quote
    ///      is received and `bound` is the maximum claims in. A zero price limit means none.
    struct Sale {
        address token;
        bool exactInput;
        uint128 amount;
        uint128 bound;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint256 deadline;
    }

    bytes32 private constant LOCK = keccak256("hookr.canonical-venue.periphery.lock");
    bytes32 private constant PENDING = keccak256("hookr.canonical-venue.periphery.pending");

    /// @notice The v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The settlement whose tokens this contract serves.
    CanonicalVenueSettlement public immutable settlement;

    error InvalidWiring();
    error UnknownToken(address token);
    error InvalidRecipient(address recipient);
    error InvalidSale();
    error Expired();
    error Slippage();
    error InvalidCallback();
    error Reentered();
    error UnexpectedNative();

    event ClaimsSold(
        address indexed token, address indexed seller, address indexed recipient, uint256 claimsIn, uint256 quoteOut
    );

    /// @param settlement_ The canonical-venue settlement; the PoolManager is read from it.
    constructor(CanonicalVenueSettlement settlement_) {
        if (address(settlement_).code.length == 0) revert InvalidWiring();
        IPoolManager manager = settlement_.poolManager();
        if (address(manager).code.length == 0) revert InvalidWiring();
        poolManager = manager;
        settlement = settlement_;
    }

    /// @notice Predicts the address `settlement.launch` would deploy for `creator` (the settlement namespaces the
    ///         salt as keccak256(abi.encode(creator, spec.salt))).
    function predictToken(
        address creator,
        CanonicalVenueSettlement.TokenSpec calldata spec,
        address root,
        Currency quote,
        int24 tickSpacing
    ) external view returns (address) {
        return settlement.tokenDeployer()
            .predict(
                keccak256(abi.encode(creator, spec.salt)), spec.name, spec.symbol, spec.supply, quote, tickSpacing, root
            );
    }

    /// @notice Liquidity of `owner`'s own settlement position in `token`'s canonical pool.
    function positionLiquidity(address token, address owner, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint128)
    {
        return poolManager.getPositionLiquidity(
            CanonicalVenueToken(token).canonicalPoolId(),
            Position.calculatePositionKey(address(settlement), tickLower, tickUpper, settlement.positionSalt(owner))
        );
    }

    /// @notice Sells the caller's ERC-6909 claims of `p.token` for the quote on the token's canonical pool.
    /// @dev The caller first lets this contract burn the claims: poolManager.approve(this, tokenId, amount) or
    ///      poolManager.setOperator(this, true). Native quote is taken here and forwarded after the unlock; an ERC-20
    ///      quote is paid to the recipient by the PoolManager.
    function sellClaims(Sale calldata p) external returns (uint256 claimsIn, uint256 quoteOut) {
        if (_tget(LOCK) != 0) revert Reentered();
        _tset(LOCK, 1);
        if (!settlement.isCanonicalToken(p.token)) revert UnknownToken(p.token);
        if (block.timestamp > p.deadline) revert Expired();
        if (p.recipient == address(0) || p.recipient == address(this) || p.recipient == address(poolManager)) {
            revert InvalidRecipient(p.recipient);
        }
        if (p.amount == 0 || p.amount > uint128(type(int128).max) || p.bound == 0) revert InvalidSale();
        PoolKey memory key = CanonicalVenueToken(p.token).canonicalPoolKey();
        bool zeroForOne = Currency.unwrap(key.currency0) == p.token;
        Currency quote = zeroForOne ? key.currency1 : key.currency0;
        uint256 nativeBase = address(this).balance;

        bytes memory data = abi.encode(msg.sender, p, key, zeroForOne);
        _tset(PENDING, uint256(keccak256(data)));
        (claimsIn, quoteOut) = abi.decode(poolManager.unlock(data), (uint256, uint256));
        if (_tget(PENDING) != 0) revert InvalidCallback();

        if (Currency.unwrap(quote) == address(0)) HookrSettlement.send(quote, p.recipient, quoteOut);
        if (address(this).balance != nativeBase) revert UnexpectedNative();
        _tset(LOCK, 0);
        emit ClaimsSold(p.token, msg.sender, p.recipient, claimsIn, quoteOut);
    }

    /// @notice Executes only the committed sale.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _tget(LOCK) == 0 || _tget(PENDING) != uint256(keccak256(data))) {
            revert InvalidCallback();
        }
        _tset(PENDING, 0);
        (address payer, Sale memory p, PoolKey memory key, bool zeroForOne) =
            abi.decode(data, (address, Sale, PoolKey, bool));
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams(
                zeroForOne,
                p.exactInput ? -int256(uint256(p.amount)) : int256(uint256(p.amount)),
                p.sqrtPriceLimitX96 != 0
                    ? p.sqrtPriceLimitX96
                    : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
            ),
            ""
        );
        (int128 inDelta, int128 outDelta) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        if (inDelta >= 0 || outDelta <= 0) revert InvalidSale();
        uint256 claimsIn = uint256(-int256(inDelta));
        uint256 quoteOut = uint256(int256(outDelta));
        if (p.exactInput) {
            if (claimsIn > p.amount || quoteOut < p.bound) revert Slippage();
        } else {
            if (quoteOut != p.amount || claimsIn > p.bound) revert Slippage();
        }
        poolManager.burn(payer, Currency.wrap(p.token).toId(), claimsIn);
        Currency quote = zeroForOne ? key.currency1 : key.currency0;
        if (Currency.unwrap(quote) == address(0)) HookrSettlement.take(poolManager, quote, quoteOut);
        else HookrSettlement.takeTo(poolManager, quote, p.recipient, quoteOut);
        return abi.encode(claimsIn, quoteOut);
    }

    function _tget(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _tset(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }

    /// @notice Accepts native currency only from the PoolManager during a sale.
    receive() external payable {
        if (_tget(LOCK) == 0 || msg.sender != address(poolManager)) revert UnexpectedNative();
    }
}
