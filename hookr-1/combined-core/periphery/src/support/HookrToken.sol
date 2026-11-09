// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrToken} from "../interfaces/IHookrToken.sol";

/// @title HookrToken
/// @notice Fixed-supply ERC-20 created by HookrLauncher, with EIP-2612 permit and an on-chain tagline and logo URI.
/// @dev The entire supply is assigned once. There is no owner, mint, pause, tax or upgrade surface. The EIP-712 domain
///      permits are signed under (the token's name, version "1", block.chainid and this address) is computed on each
///      use and never cached in an immutable, so every HookrToken has the same runtime code and codehash, by which
///      HookrRules recognises a Hookr token. A permit signed under one chain id does not verify after a fork changes it.
///      The tagline and logo URI live in storage for the same reason. They are set at most once, by the account that
///      created the token and only in the transaction that created it (`setPresentation`), then never change; a token
///      that is not given them keeps both empty for good. The constructor keeps its four arguments, so a token's
///      address does not depend on them.
contract HookrToken is HookrReleased, ERC20, IERC20Permit, IERC5267, IHookrToken {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev keccak256 of the domain's version, "1".
    bytes32 private constant VERSION_HASH = keccak256("1");
    /// @dev The longest tagline and logo URI, in bytes.
    uint256 private constant MAX_TAGLINE_BYTES = 160;
    uint256 private constant MAX_LOGO_URI_BYTES = 300;

    /// @dev Each owner's next permit nonce.
    mapping(address owner => uint256) private _nonces;
    /// @inheritdoc IHookrToken
    string public tagline;
    /// @inheritdoc IHookrToken
    string public logoURI;
    /// @dev The account that created this token, until it sets the presentation or its creating transaction ends.
    address private transient _presenter;

    constructor(string memory _name, string memory _symbol, uint256 supply, address recipient) ERC20(_name, _symbol) {
        if (supply == 0) revert ZeroSupply();
        if (
            bytes(_name).length == 0 || bytes(_name).length > 64 || bytes(_symbol).length == 0
                || bytes(_symbol).length > 16
        ) {
            revert InvalidMetadata();
        }
        _mint(recipient, supply);
        _presenter = msg.sender;
    }

    /// @inheritdoc IHookrToken
    function setPresentation(string calldata tagline_, string calldata logoURI_) external {
        if (msg.sender != _presenter) revert NotPresenter();
        _presenter = address(0);
        if (bytes(tagline_).length > MAX_TAGLINE_BYTES || bytes(logoURI_).length > MAX_LOGO_URI_BYTES) {
            revert InvalidMetadata();
        }
        tagline = tagline_;
        logoURI = logoURI_;
    }

    /// @inheritdoc IERC20Permit
    /// @dev Reverts ERC2612ExpiredSignature after `deadline`, ECDSAInvalidSignature or ECDSAInvalidSignatureS for a
    ///      malformed or malleable signature, and ERC2612InvalidSigner when the signature recovers to anyone but
    ///      `owner`. An accepted permit uses `owner`'s nonce, so a signature verifies once; anyone may submit it.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);
        bytes32 structHash;
        unchecked {
            // A nonce counts up by one per accepted permit, so it never overflows.
            structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _nonces[owner]++, deadline));
        }
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash), v, r, s);
        if (signer != owner) revert ERC2612InvalidSigner(signer, owner);
        _approve(owner, spender, value);
    }

    /// @inheritdoc IERC20Permit
    function nonces(address owner) external view returns (uint256) {
        return _nonces[owner];
    }

    /// @inheritdoc IERC20Permit
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @inheritdoc IERC5267
    /// @dev Fields 0x0f: name, version, chain id and verifying contract; no salt and no extensions. The chain id is
    ///      block.chainid when read.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name_,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", name(), "1", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /// @dev keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(name), keccak256("1"), block.chainid, this)).
    function _domainSeparator() private view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), VERSION_HASH, block.chainid, address(this)));
    }
}
