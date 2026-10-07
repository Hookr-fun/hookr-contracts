// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrForwarder
/// @notice Executes Permit2-witness signed swap intents through HookrRouter.swapFor. Stateless: no owner, no admin.
interface IHookrForwarder {
    /// @notice Signed as the Permit2 witness. Every field reaches the router unchanged.
    struct HookrSwapIntent {
        /// @notice The pool.
        PoolKey key;
        /// @notice The swap's direction.
        bool zeroForOne;
        /// @notice Negative for exact input, positive for exact output (gross output on sells).
        int128 amountSpecified; // < 0 exact input; > 0 exact output (gross output on sells)
        /// @notice For exact input the least net output to the recipient; for exact output the most input, fee
        ///         excluded.
        uint128 amountBound; // exact input: minimum NET output to recipient; exact output: maximum input (fee excluded)
        /// @notice The swap's price limit.
        uint160 sqrtPriceLimitX96;
        /// @notice The output receiver and the root's beneficiary, for a pot prize.
        address recipient; // output receiver and Root beneficiary (pot prize)
        /// @notice Zero for any submitter, then `relayerFee` must be zero; otherwise the only allowed caller.
        address relayer; // zero = any submitter (then relayerFee must be zero); otherwise the only allowed msg.sender
        /// @notice The relayer's fee in raw units of the pool's quote: input side on buys, output side on sells
        ///         (refused on a pool with an advisory).
        uint256 relayerFee; // raw units of the pool's QUOTE currency; input side on buys, output side on sells
        // (an output-side fee is refused on a pool with an advisory)
        /// @notice Zero, or the Programs receipt sink.
        address engagement; // zero, or the Programs receipt sink
        /// @notice At most eight program ids; empty when `engagement` is zero.
        uint256[] campaigns; // <= 8 program ids; empty when engagement is zero
        /// @notice The forwarder-scoped unordered nonce, from which the Permit2 nonce is derived.
        uint256 nonce; // forwarder-scoped unordered nonce; the Permit2 nonce is derived from it
        /// @notice The timestamp after which the intent is void; also the Permit2 deadline and the router deadline.
        uint256 deadline; // unix seconds; also the Permit2 deadline and the router deadline
    }

    /// @notice Optional EIP-2612 permit(owner → PERMIT2) for tokens with no Permit2 allowance yet. value == 0 skips it.
    struct TokenPermit {
        /// @notice The permit's allowance; zero skips it.
        uint256 value;
        /// @notice The permit's deadline.
        uint256 deadline;
        /// @notice The signature's recovery id.
        uint8 v;
        /// @notice The signature's r.
        bytes32 r;
        /// @notice The signature's s.
        bytes32 s;
    }

    /// @notice Emitted once per executed intent.
    /// @param intentHash The intent's EIP-712 hash.
    /// @param owner The signer whose input was swapped.
    /// @param relayer The account that submitted the intent.
    /// @param poolId The pool.
    /// @param amountIn The input pulled from the owner.
    /// @param amountOut The output delivered to the recipient.
    /// @param relayerFee The relayer's fee, in raw units of the pool's quote.
    /// @param feeFromInput Whether the fee was taken from the input side.
    event IntentExecuted(
        bytes32 indexed intentHash,
        address indexed owner,
        address indexed relayer,
        PoolId poolId,
        uint256 amountIn,
        uint256 amountOut,
        uint256 relayerFee,
        bool feeFromInput
    );

    /// @notice The call re-entered the forwarder.
    error Reentered();
    /// @notice The intent's `deadline` has passed at `timestamp`.
    error IntentExpired(uint256 deadline, uint256 timestamp);
    /// @notice The intent names `expected` as its relayer, not the `caller`.
    error WrongRelayer(address expected, address caller);
    /// @notice The intent breaks a rule; `field` names it: 1 amountSpecified, 2 amountBound, 3 recipient, 4 campaigns,
    ///         5 owner, 6 relayer, 7 an output-side relayer fee above the exact output.
    error InvalidIntent(uint8 field); // 1 amountSpecified, 2 amountBound, 3 recipient, 4 campaigns, 5 owner, 6 relayer,
    // 7 output-side relayerFee above the exact output
    /// @notice A relayer fee on the output side is refused on a pool with the advisory `advisory`.
    error OutputFeeOnAdvisedPool(address advisory);
    /// @notice The pool's root `root` is not one this forwarder serves.
    error UnsupportedPool(address root);
    /// @notice The intent's input is native currency, which Permit2 cannot pull.
    error NativeInputUnsupported();
    /// @notice Permit2 pulled `received` of `token`, not the `expected` amount.
    error InexactPull(address token, uint256 expected, uint256 received);
    /// @notice The forwarder's balance of `token` changed from `before` to `afterwards` across the call.
    error ResidualBalance(address token, uint256 before, uint256 afterwards);
    /// @notice The recipient's balance of the output currency (zero address: native) rose by less than the signed
    ///         bound: the net minimum on exact input, or the exact output less an output-side relayer fee.
    error OutputShort(address token, uint256 minimum, uint256 received);

    /// @notice A constructor address that must hold code does not.
    error NoCode(address account);

    /// @notice A token call failed or returned false.
    error TokenCallFailed(address token, bytes4 selector);

    /// @notice Pulls the signed input through Permit2 and swaps it for `owner` (0xc66d5707).
    /// @param intent The signed swap intent.
    /// @param owner The signer.
    /// @param signature The Permit2 witness signature.
    /// @return amountIn The input pulled from the owner.
    /// @return amountOut The output delivered to the recipient.
    function execute(HookrSwapIntent calldata intent, address owner, bytes calldata signature)
        external
        returns (uint256 amountIn, uint256 amountOut);

    /// @notice As execute, first trying an EIP-2612 permit(owner → PERMIT2) (0xfd41acb8).
    /// @param intent The signed swap intent.
    /// @param owner The signer.
    /// @param signature The Permit2 witness signature.
    /// @param tokenPermit The optional EIP-2612 permit for the input token.
    /// @return amountIn The input pulled from the owner.
    /// @return amountOut The output delivered to the recipient.
    function executeWithTokenPermit(
        HookrSwapIntent calldata intent,
        address owner,
        bytes calldata signature,
        TokenPermit calldata tokenPermit
    ) external returns (uint256 amountIn, uint256 amountOut);

    /// @notice EIP-712 struct hash of `intent`, used as the Permit2 witness.
    /// @param intent The intent.
    /// @return The intent's struct hash.
    function hashIntent(HookrSwapIntent calldata intent) external pure returns (bytes32);
    /// @notice The exact Permit2 `permitted` the owner must sign: input token, amount, and whether the fee is input-side.
    /// @param intent The intent.
    /// @return token The input token the owner signs for.
    /// @return amount The amount the owner signs for.
    /// @return feeFromInput Whether the relayer's fee is taken from the input side.
    function pullOf(HookrSwapIntent calldata intent)
        external
        view
        returns (address token, uint256 amount, bool feeFromInput);
    /// @notice The Permit2 unordered nonce an intent nonce maps to.
    /// @param intentNonce The intent's nonce.
    /// @return The Permit2 nonce.
    function permit2Nonce(uint256 intentNonce) external view returns (uint256);
    /// @notice The Permit2 bitmap word and bit for an intent nonce (for invalidateUnorderedNonces).
    /// @param intentNonce The intent's nonce.
    /// @return wordPos The Permit2 bitmap word.
    /// @return mask The bit within the word.
    function nonceWord(uint256 intentNonce) external view returns (uint256 wordPos, uint256 mask);
    /// @notice Whether `owner` has consumed or cancelled `intentNonce`.
    /// @param owner The signer.
    /// @param intentNonce The intent's nonce.
    /// @return True when the nonce was consumed or cancelled.
    function isNonceUsed(address owner, uint256 intentNonce) external view returns (bool);
    /// @notice The Permit2 witness type string.
    /// @return The Permit2 witness type string.
    function WITNESS_TYPE_STRING() external pure returns (string memory);
    /// @notice keccak256 of the HookrSwapIntent type string.
    /// @return The type hash.
    function INTENT_TYPEHASH() external pure returns (bytes32);
    /// @notice Permit2 (0x000000000022D473030F116dDEE9F6B43aC78BA3).
    /// @return The Permit2 contract.
    function permit2() external view returns (address);
    /// @notice The HookrRouter (predicted CREATE3 address).
    /// @return The router.
    function router() external view returns (address);
    /// @notice The HookrRegistry.
    /// @return The registry.
    function registry() external view returns (address);
    /// @notice The shared release identity (1).
    /// @return The release id.
    function releaseId() external view returns (uint256);
}
