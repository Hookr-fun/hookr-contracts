// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IHookrRevenueToken} from "hookrevenue-v2/interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueTokenizer} from "hookrevenue-v2/interfaces/IHookrRevenueTokenizer.sol";
import {HookrTimeShares} from "./HookrTimeShares.sol";
import {IHookrTimeSharesFactory} from "./interfaces/IHookrTimeSharesFactory.sol";

/// @title Hookr time shares factory
/// @notice One canonical `HookrTimeShares` per revenue token, created by anyone, at an address that follows from the
///         token (CREATE2, salt the token's address), with the roll tip Hookr proposes: 50 basis points of the ETH
///         a roll attributes, at most 0.01 ETH a roll. Bound to one HookRevenue Tokenizer at construction: only the
///         revenue tokens that tokenizer minted get time shares here. No owner; nothing here can change.
contract HookrTimeSharesFactory is IHookrTimeSharesFactory {
    /// @inheritdoc IHookrTimeSharesFactory
    uint16 public constant TIP_BPS = 50;
    /// @inheritdoc IHookrTimeSharesFactory
    uint256 public constant TIP_CAP = 0.01 ether;

    /// @inheritdoc IHookrTimeSharesFactory
    IHookrRevenueTokenizer public immutable tokenizer;

    /// @inheritdoc IHookrTimeSharesFactory
    mapping(address token => address) public sharesOf;

    /// @dev The time shares' creation code, stored as the code of two data contracts made by the constructor, so
    ///      that this contract's runtime does not embed it: the shares can grow to their own size limit.
    address private immutable _codeA;
    address private immutable _codeB;

    /// @param tokenizer_ The HookRevenue Tokenizer whose revenue tokens this factory serves; it must have code and a
    ///        launcher.
    constructor(IHookrRevenueTokenizer tokenizer_) {
        if (address(tokenizer_).code.length == 0 || tokenizer_.launcher() == address(0)) {
            revert InvalidTokenizer(address(tokenizer_));
        }
        tokenizer = tokenizer_;
        bytes memory code = type(HookrTimeShares).creationCode;
        uint256 half = code.length / 2;
        _codeA = _store(code, 0, half);
        _codeB = _store(code, half, code.length - half);
    }

    /// @inheritdoc IHookrTimeSharesFactory
    function predict(IHookrRevenueToken token) external view returns (address) {
        return Create2.computeAddress(_salt(token), keccak256(_creationCode(token)));
    }

    /// @inheritdoc IHookrTimeSharesFactory
    /// @dev The tokenizer writes its record of a token (`tokenizations(token).creator`) only right after it deploys
    ///      the token itself from its own audited code, so a record proves the address is that tokenizer's own token;
    ///      a code-hash compare cannot, the runtime code embeds immutables that differ per token. The token must also
    ///      name the tokenizer. That the token is live, that its drop box points back at it and that its clock is the
    ///      block number are checked by the time shares' constructor (the factory embeds its creation code, and the
    ///      limit on this contract's size leaves no room to check them twice); its `InvalidConfig` comes through.
    function create(IHookrRevenueToken token) external returns (address shares) {
        if (sharesOf[address(token)] != address(0)) revert AlreadyCreated(address(token));
        if (tokenizer.tokenizations(address(token)).creator == address(0)) revert NotTokenized(address(token));
        if (token.tokenizer() != address(tokenizer)) revert WrongTokenizer(address(token));
        bytes memory init = _creationCode(token);
        bytes32 salt = _salt(token);
        assembly ("memory-safe") {
            shares := create2(0, add(init, 32), mload(init), salt)
            if iszero(shares) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        sharesOf[address(token)] = shares;
        emit Created(address(token), shares);
    }

    function _salt(IHookrRevenueToken token) private pure returns (bytes32) {
        return bytes32(uint256(uint160(address(token))));
    }

    /// @dev The time shares' creation code with the constructor arguments, read back from the two data contracts.
    function _creationCode(IHookrRevenueToken token) private view returns (bytes memory init) {
        address a = _codeA;
        address b = _codeB;
        uint256 lenA = a.code.length;
        uint256 lenB = b.code.length;
        init = new bytes(lenA + lenB + 96);
        assembly ("memory-safe") {
            let p := add(init, 32)
            extcodecopy(a, p, 0, lenA)
            extcodecopy(b, add(p, lenA), 0, lenB)
            let q := add(p, add(lenA, lenB))
            mstore(q, token)
            mstore(add(q, 32), TIP_BPS)
            mstore(add(q, 64), TIP_CAP)
        }
    }

    /// @dev Deploys `code[from:from+len]` as the runtime code of a new contract (never called).
    function _store(bytes memory code, uint256 from, uint256 len) private returns (address stored) {
        // PUSH2 len, DUP1, PUSH1 12, PUSH0, CODECOPY, PUSH0, RETURN... written with PUSH1 0 for old-EVM safety.
        bytes memory init = abi.encodePacked(hex"61", uint16(len), hex"80600c6000396000f3", _slice(code, from, len));
        assembly ("memory-safe") {
            stored := create(0, add(init, 32), mload(init))
        }
        if (stored == address(0)) revert InvalidTokenizer(address(0));
    }

    function _slice(bytes memory data, uint256 from, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(out, 32), add(add(data, 32), from), len)
        }
    }
}
