// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHookrReferralRegistry} from "../interfaces/IHookrReferralRegistry.sol";
import {HookrReleased} from "../base/HookrReleased.sol";

/// @title HookrReferralRegistry
/// @notice One prospective payer-authorized referrer per immutable program domain.
/// @dev The payer is whoever authorizes: msg.sender for register, the signer for registerSigned. A contract
///      that performs arbitrary calls for anyone has no owner, so anyone can bind it (and redirect its cashback);
///      commission services should attribute only EOAs and reviewed smart-account code. Self-referral through a
///      second wallet cannot be detected onchain and is not prevented.
contract HookrReferralRegistry is HookrReleased, IHookrReferralRegistry, EIP712 {
    /// @inheritdoc IHookrReferralRegistry
    bytes32 public constant override AUTHORIZATION_TYPEHASH = keccak256(
        "ReferralAuthorization(address payer,address referrer,bytes32 programKey,bytes32 codeHash,uint256 nonce,uint256 deadline)"
    );

    /// @notice Most 256-nonce bitmap words one floor advance scans (4,096 nonces).
    uint256 public constant MAX_NONCE_SCAN_WORDS = 16;

    /// @inheritdoc IHookrReferralRegistry
    mapping(bytes32 => mapping(address => Binding)) public override binding;
    /// @inheritdoc IHookrReferralRegistry
    /// @notice Lowest nonce that may still be unused; every lower nonce is consumed or invalidated. It is itself
    ///         unused unless the payer used more than MAX_NONCE_SCAN_WORDS * 256 consecutive nonces above it out
    ///         of order; check nonceUsed before signing in that case.
    mapping(address => uint256) public override nonces;
    /// @inheritdoc IHookrReferralRegistry
    mapping(bytes32 => address) public override codeOwner;
    mapping(address => mapping(uint256 => uint256)) private _usedNonceWords;

    constructor() EIP712("HookrReferralRegistry", "1") {}

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Reserve an unused referral code for the caller.
    /// @dev Codes are first-come, permanent, global labels. A code carries no economic effect: eligibility and
    ///      payouts use only the referrer address, and a binding without a code always works.
    function registerCode(bytes32 codeHash) external override {
        if (codeHash == bytes32(0) || codeOwner[codeHash] != address(0)) revert InvalidReferral();
        codeOwner[codeHash] = msg.sender;
        emit ReferralCodeRegistered(codeHash, msg.sender);
    }

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Bind the caller to one referrer for future activity in the given program.
    function register(bytes32 programKey, address referrer, bytes32 codeHash) external override {
        _register(programKey, msg.sender, referrer, codeHash);
    }

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Bind a payer using an unexpired, single-use EIP-712 or ERC-1271 authorization.
    /// @dev Nonces are single-use and unordered at or above nonces(payer): authorizations for different
    ///      programs never block each other, and one that cannot land does not hold back the rest.
    function registerSigned(
        address payer,
        address referrer,
        bytes32 programKey,
        bytes32 codeHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external override {
        if (block.timestamp > deadline) revert SignatureExpired(deadline, block.timestamp);
        if (nonceUsed(payer, nonce)) revert NonceUnavailable(payer, nonce);
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(AUTHORIZATION_TYPEHASH, payer, referrer, programKey, codeHash, nonce, deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(payer, digest, signature)) revert InvalidSignature();
        _useNonce(payer, nonce);
        _register(programKey, payer, referrer, codeHash);
    }

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Return the EIP-712 digest for a complete referral authorization.
    function authorizationDigest(
        address payer,
        address referrer,
        bytes32 programKey,
        bytes32 codeHash,
        uint256 nonce,
        uint256 deadline
    ) external view override returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(AUTHORIZATION_TYPEHASH, payer, referrer, programKey, codeHash, nonce, deadline))
        );
    }

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Invalidate every outstanding signed authorization below the supplied nonce.
    /// @dev If `nextNonce` and the nonces after it were already used out of order, the floor moves past them so
    ///      nonces() again returns an unused nonce.
    function invalidateNonce(uint256 nextNonce) external override {
        uint256 current = nonces[msg.sender];
        if (nextNonce <= current) revert NonceNotRaised(current, nextNonce);
        nonces[msg.sender] = _nextUnused(msg.sender, nextNonce);
        emit NonceInvalidated(msg.sender, nextNonce);
    }

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Return whether a payer's nonce is consumed or invalidated.
    function nonceUsed(address payer, uint256 nonce) public view override returns (bool) {
        return nonce < nonces[payer] || _usedNonceWords[payer][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Read with eth_call at a pinned receipt block to obtain its EVM block clock.
    function contractBlockNumber() external view override returns (uint256) {
        return block.number;
    }

    /// @inheritdoc IHookrReferralRegistry
    /// @notice Check immutable authorization against the activity's EVM block.number clock.
    function eligible(bytes32 programKey, address payer, address referrer, uint64 firstActivityBlock)
        external
        view
        override
        returns (bool)
    {
        Binding storage b = binding[programKey][payer];
        return b.referrer == referrer && referrer != address(0) && firstActivityBlock >= b.eligibleFromBlock
            && firstActivityBlock <= block.number;
    }

    /// @dev Mark a nonce used; when it is the floor, advance the floor to the next unused nonce.
    function _useNonce(address payer, uint256 nonce) private {
        _usedNonceWords[payer][nonce >> 8] |= 1 << (nonce & 0xff);
        emit NonceUsed(payer, nonce);
        if (nonce != nonces[payer]) return;
        nonces[payer] = _nextUnused(payer, nonce);
    }

    /// @dev Return the first nonce at or above `from` whose bit is clear, scanning whole 256-bit words (one
    ///      SLOAD each) for at most MAX_NONCE_SCAN_WORDS words; past that bound it stops at a word boundary.
    function _nextUnused(address payer, uint256 from) private view returns (uint256 next) {
        next = from;
        for (uint256 i; i < MAX_NONCE_SCAN_WORDS; ++i) {
            uint256 bit = next & 0xff;
            uint256 free = ~(_usedNonceWords[payer][next >> 8] >> bit);
            // The shift fills the top `bit` positions with zeros, which read as free; they are past this word.
            if (bit != 0) free &= type(uint256).max >> bit;
            if (free != 0) {
                unchecked {
                    return next + Math.log2(free & (0 - free));
                }
            }
            if ((next | 0xff) == type(uint256).max) return next;
            next = (next | 0xff) + 1;
        }
    }

    function _register(bytes32 key, address payer, address referrer, bytes32 codeHash) private {
        if (
            key == bytes32(0) || payer == address(0) || referrer == address(0) || payer == referrer
                || binding[key][payer].referrer != address(0)
                || (codeHash != bytes32(0) && codeOwner[codeHash] != referrer) || block.number >= type(uint64).max
        ) revert InvalidReferral();
        uint64 eligibleFrom = uint64(block.number + 1);
        binding[key][payer] = Binding(referrer, eligibleFrom, codeHash);
        emit ReferralBound(key, payer, referrer, codeHash, eligibleFrom);
    }
}
