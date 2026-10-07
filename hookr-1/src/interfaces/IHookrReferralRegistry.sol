// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrReferralRegistry
/// @notice One immutable, payer-authorized referrer per program domain.
interface IHookrReferralRegistry {
    /// @notice A payer's referral for one program domain.
    /// @dev Block fields use the EVM block.number clock, which can differ from RPC receipt height.
    struct Binding {
        /// @notice The referrer the payer authorized.
        address referrer;
        /// @notice The first EVM block whose activity counts, after the block of the binding.
        uint64 eligibleFromBlock;
        /// @notice The referral code the binding names, or zero.
        bytes32 codeHash;
    }

    /// @notice The program key, payer, referrer or code is invalid, the payer is its own referrer, or the payer is
    ///         already bound in the domain. A code registration also fails when the code is zero or taken.
    error InvalidReferral();
    /// @notice The authorization's signature is not the payer's.
    error InvalidSignature();
    /// @notice The authorization's `deadline` passed before `timestamp`.
    error SignatureExpired(uint256 deadline, uint256 timestamp);
    /// @notice `payer`'s `nonce` is consumed or invalidated.
    error NonceUnavailable(address payer, uint256 nonce);
    /// @notice The requested nonce floor `requested` does not rise above the `current` one.
    error NonceNotRaised(uint256 current, uint256 requested);

    /// @notice A referral code was reserved.
    /// @param codeHash The code's hash.
    /// @param referrer The referrer that reserved it.
    event ReferralCodeRegistered(bytes32 indexed codeHash, address indexed referrer);

    /// @notice A payer was bound to a referrer in a program domain.
    /// @param programKey The program domain.
    /// @param payer The payer.
    /// @param referrer The referrer.
    /// @param codeHash The referral code the binding names, or zero.
    /// @param eligibleFromBlock The first EVM block whose activity counts.
    event ReferralBound(
        bytes32 indexed programKey,
        address indexed payer,
        address indexed referrer,
        bytes32 codeHash,
        uint64 eligibleFromBlock
    );
    /// @notice A payer's authorization nonce was consumed.
    /// @param payer The payer.
    /// @param nonce The nonce.
    event NonceUsed(address indexed payer, uint256 nonce);
    /// @notice A payer invalidated every nonce below a floor.
    /// @param payer The payer.
    /// @param nextNonce The new floor.
    event NonceInvalidated(address indexed payer, uint256 nextNonce);

    /// @notice Return the EIP-712 referral authorization type hash.
    /// @return The type hash.
    function AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    /// @notice Return a payer's referrer, first eligible EVM block and optional referral code.
    /// @param programKey The program domain.
    /// @param payer The payer.
    /// @return referrer The payer's referrer, or zero.
    /// @return eligibleFromBlock The first EVM block whose activity counts.
    /// @return codeHash The referral code the binding names, or zero.
    function binding(bytes32 programKey, address payer)
        external
        view
        returns (address referrer, uint64 eligibleFromBlock, bytes32 codeHash);

    /// @notice Return the lowest nonce that may still be unused; every lower nonce is consumed or invalidated.
    /// @dev Sequential signers can keep signing with this value: it is unused unless the payer used more than
    ///      4,096 consecutive nonces above it out of order, so check nonceUsed in that case. Nonces at or above it
    ///      are single-use in any order.
    /// @param payer The payer.
    /// @return The lowest nonce that may still be unused.
    function nonces(address payer) external view returns (uint256);

    /// @notice Return whether a payer's nonce is consumed or invalidated.
    /// @param payer The payer.
    /// @param nonce The nonce.
    /// @return True when the nonce is consumed or invalidated.
    function nonceUsed(address payer, uint256 nonce) external view returns (bool);

    /// @notice Return the referrer who registered a code, or zero if unregistered.
    /// @param codeHash The code's hash.
    /// @return The referrer that registered the code, or zero.
    function codeOwner(bytes32 codeHash) external view returns (address);

    /// @notice Reserve an unused referral code for the caller. Codes are first-come global labels with no
    ///         economic effect; eligibility and payouts use only the referrer address.
    /// @param codeHash The code's hash, not zero.
    function registerCode(bytes32 codeHash) external;

    /// @notice Bind the caller to a referrer for activity after the current EVM block.
    /// @param programKey The program domain.
    /// @param referrer The referrer.
    /// @param codeHash The referral code the binding names, or zero.
    function register(bytes32 programKey, address referrer, bytes32 codeHash) external;

    /// @notice Bind a payer using an unexpired, single-use EIP-712 or ERC-1271 authorization.
    /// @dev Distinct errors: SignatureExpired, NonceUnavailable, InvalidSignature, then InvalidReferral.
    /// @param payer The payer who authorized the binding.
    /// @param referrer The referrer.
    /// @param programKey The program domain.
    /// @param codeHash The referral code the binding names, or zero.
    /// @param nonce The payer's single-use nonce.
    /// @param deadline The timestamp after which the authorization is void.
    /// @param signature The payer's EIP-712 or ERC-1271 signature.
    function registerSigned(
        address payer,
        address referrer,
        bytes32 programKey,
        bytes32 codeHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /// @notice Return the EIP-712 digest for a complete referral authorization.
    /// @param payer The payer.
    /// @param referrer The referrer.
    /// @param programKey The program domain.
    /// @param codeHash The referral code the binding names, or zero.
    /// @param nonce The payer's single-use nonce.
    /// @param deadline The timestamp after which the authorization is void.
    /// @return The EIP-712 digest the payer signs.
    function authorizationDigest(
        address payer,
        address referrer,
        bytes32 programKey,
        bytes32 codeHash,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32);

    /// @notice Invalidate every outstanding signed authorization below the supplied nonce; emits NonceInvalidated.
    /// @dev The floor then moves past any nonces at or above `nextNonce` that were already used out of order.
    /// @param nextNonce The new nonce floor.
    function invalidateNonce(uint256 nextNonce) external;

    /// @notice Return the EVM block clock, which can differ from an RPC receipt's height.
    /// @return The EVM block number.
    function contractBlockNumber() external view returns (uint256);

    /// @notice Check that a binding preceded the activity and the activity clock is not in the future.
    /// @param programKey The program domain.
    /// @param payer The payer.
    /// @param referrer The referrer the activity is credited to.
    /// @param firstActivityBlock The EVM block of the payer's first activity.
    /// @return True when the payer's binding names the referrer and precedes the activity, and the activity block is
    ///         not in the future.
    function eligible(bytes32 programKey, address payer, address referrer, uint64 firstActivityBlock)
        external
        view
        returns (bool);
}
