// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title Hookr ERC-20 permit
/// @notice EIP-2612 (`permit`, `nonces`, `DOMAIN_SEPARATOR`) for a token whose holder may be a contract: the standard
///         `v`, `r`, `s` form, a bytes form for ERC-1271 signers, and the domain version for signers that build the
///         domain from `name()` and `version()`.
interface IHookrERC20Permit is IERC20Permit {
    /// @notice The EIP-712 type hash of `permit`:
    ///         `Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)`.
    function PERMIT_TYPEHASH() external view returns (bytes32);
    /// @notice `permit` with the signature as bytes: an EOA's 65-byte `r || s || v`, or whatever `owner`'s code accepts
    ///         through ERC-1271.
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes calldata signature) external;
    /// @notice The EIP-712 domain version, "1".
    function version() external pure returns (string memory);
}
