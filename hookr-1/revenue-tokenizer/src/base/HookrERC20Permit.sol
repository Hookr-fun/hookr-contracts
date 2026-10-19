// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IHookrERC20Permit} from "../interfaces/IHookrERC20Permit.sol";
import {HookrAuthorizations} from "./HookrAuthorizations.sol";

/// @title Hookr ERC-20 permit
/// @notice EIP-2612 for an ERC-20 whose holder may be a contract: `permit` sets an allowance from the owner's
///         signature, taken as `v`, `r`, `s` (the standard form) or as bytes, and verified for an EOA (ECDSA) or a
///         contract account (ERC-1271) alike. Sequential nonces per owner, as the standard requires; the domain is the
///         token's name, version "1".
/// @dev The one departure from OpenZeppelin's ERC20Permit is the verifier (HookrAuthorizations._verify), so a smart
///      wallet or an EIP-7702 account can sign a permit. Permit2 needs nothing from here: it works with any ERC-20
///      once the holder approves it, by `approve` or by `permit`.
abstract contract HookrERC20Permit is ERC20, IHookrERC20Permit, HookrAuthorizations {
    /// @inheritdoc IHookrERC20Permit
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @inheritdoc IERC20Permit
    mapping(address owner => uint256) public nonces;

    /// @inheritdoc IERC20Permit
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        _permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    /// @inheritdoc IHookrERC20Permit
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes calldata signature)
        external
    {
        _permit(owner, spender, value, deadline, signature);
    }

    /// @inheritdoc IERC20Permit
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IHookrERC20Permit
    function version() external pure returns (string memory) {
        return "1";
    }

    function _permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) private {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        uint256 nonce;
        // A nonce only ever grows by one per permit, so it never reaches 2^256.
        unchecked {
            nonce = nonces[owner]++;
        }
        _verify(owner, keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline)), signature);
        _approve(owner, spender, value);
    }
}
