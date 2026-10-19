// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IHookrRevenueToken} from "fee-tokenizer/interfaces/IHookrRevenueToken.sol";
import {HookrTimeShares} from "./HookrTimeShares.sol";
import {IHookrTimeSharesFactory} from "./interfaces/IHookrTimeSharesFactory.sol";

/// @title Hookr time shares factory
/// @notice One canonical `HookrTimeShares` per revenue token, created by anyone, at an address that follows from the
///         token (CREATE2, salt the token's address), with the roll tip Hookr proposes: 50 basis points of the ETH
///         a roll attributes, at most 0.01 ETH a roll. No owner; nothing here can change.
contract HookrTimeSharesFactory is IHookrTimeSharesFactory {
    /// @inheritdoc IHookrTimeSharesFactory
    uint16 public constant TIP_BPS = 50;
    /// @inheritdoc IHookrTimeSharesFactory
    uint256 public constant TIP_CAP = 0.01 ether;

    /// @inheritdoc IHookrTimeSharesFactory
    mapping(address token => address) public sharesOf;

    /// @inheritdoc IHookrTimeSharesFactory
    function predict(IHookrRevenueToken token) external view returns (address) {
        return Create2.computeAddress(_salt(token), keccak256(_creationCode(token)));
    }

    /// @inheritdoc IHookrTimeSharesFactory
    /// @dev The time shares' constructor checks the token itself (code, assets, native first) and its revert comes
    ///      through as it is.
    function create(IHookrRevenueToken token) external returns (address shares) {
        if (sharesOf[address(token)] != address(0)) revert AlreadyCreated(address(token));
        shares = address(new HookrTimeShares{salt: _salt(token)}(token, TIP_BPS, TIP_CAP));
        sharesOf[address(token)] = shares;
        emit Created(address(token), shares);
    }

    function _salt(IHookrRevenueToken token) private pure returns (bytes32) {
        return bytes32(uint256(uint160(address(token))));
    }

    function _creationCode(IHookrRevenueToken token) private pure returns (bytes memory) {
        return abi.encodePacked(type(HookrTimeShares).creationCode, abi.encode(token, TIP_BPS, TIP_CAP));
    }
}
