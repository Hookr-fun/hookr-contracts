// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {HookrTimeShareWrapper} from "./HookrTimeShareWrapper.sol";
import {IHookrTimeShares} from "./interfaces/IHookrTimeShares.sol";
import {IHookrTimeShareWrapperFactory} from "./interfaces/IHookrTimeShareWrapperFactory.sol";

/// @title Hookr time share wrapper factory
/// @notice Opens one `HookrTimeShareWrapper` per day per time shares contract, for anyone, at an address that
///         follows from the time shares and the day (CREATE2, salt their hash). The time shares never need to know
///         a wrapper: it is a holder of units like any other. No owner; nothing here can change.
contract HookrTimeShareWrapperFactory is IHookrTimeShareWrapperFactory {
    /// @inheritdoc IHookrTimeShareWrapperFactory
    mapping(address shares => mapping(uint256 day => address)) public wrapperOf;

    /// @inheritdoc IHookrTimeShareWrapperFactory
    function predict(IHookrTimeShares shares, uint256 day) external view returns (address) {
        return Create2.computeAddress(_salt(shares, day), keccak256(_creationCode(shares, day)));
    }

    /// @inheritdoc IHookrTimeShareWrapperFactory
    /// @dev The wrapper's constructor checks the time shares (code) and the day (at most `FOREVER`) and its revert
    ///      comes through as it is.
    function open(IHookrTimeShares shares, uint256 day) external returns (address wrapper) {
        if (wrapperOf[address(shares)][day] != address(0)) revert AlreadyOpen(address(shares), day);
        wrapper = address(new HookrTimeShareWrapper{salt: _salt(shares, day)}(shares, day));
        wrapperOf[address(shares)][day] = wrapper;
        emit Opened(address(shares), day, wrapper);
    }

    function _salt(IHookrTimeShares shares, uint256 day) private pure returns (bytes32) {
        return keccak256(abi.encode(shares, day));
    }

    function _creationCode(IHookrTimeShares shares, uint256 day) private pure returns (bytes memory) {
        return abi.encodePacked(type(HookrTimeShareWrapper).creationCode, abi.encode(shares, day));
    }
}
