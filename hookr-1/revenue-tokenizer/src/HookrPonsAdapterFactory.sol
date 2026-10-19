// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrPonsAdapter} from "./HookrPonsAdapter.sol";
import {IHookrPonsAdapterFactory} from "./interfaces/IHookrPonsAdapterFactory.sol";
import {IPonsV2LaunchFactory} from "./interfaces/external/IPonsV2.sol";

/// @title Hookr Pons adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes Pons adapters at predictable addresses, before the revenue token exists. See
///         IHookrPonsAdapterFactory for the rules.
/// @dev No owner, no pin but the Pons launch factory. The CREATE2 salt binds the origin, the revenue token and the
///      memecoin, so the address is known from the three before the adapter exists and no one takes another's.
contract HookrPonsAdapterFactory is IHookrPonsAdapterFactory {
    /// @inheritdoc IHookrPonsAdapterFactory
    address public immutable launchFactory;
    /// @inheritdoc IHookrPonsAdapterFactory
    mapping(address adapter => bool) public isAdapter;

    /// @param launchFactory_ The Pons V2 launch factory; must have code.
    constructor(address launchFactory_) {
        if (launchFactory_.code.length == 0) revert InvalidConfig();
        launchFactory = launchFactory_;
    }

    /// @inheritdoc IHookrPonsAdapterFactory
    function create(address revenueToken, address memecoin) external returns (address adapter) {
        IPonsV2LaunchFactory.LaunchedToken memory launch =
            IPonsV2LaunchFactory(launchFactory).getLaunchedToken(memecoin);
        if (!launch.exists) revert UnknownLaunch(memecoin);
        if (launch.creatorFeeRecipient != msg.sender) {
            revert NotCreatorFeeRecipient(msg.sender, launch.creatorFeeRecipient);
        }
        adapter = address(
            new HookrPonsAdapter{salt: _salt(msg.sender, revenueToken, memecoin)}(
                revenueToken, launchFactory, memecoin, msg.sender
            )
        );
        isAdapter[adapter] = true;
        emit AdapterCreated(adapter, revenueToken, memecoin, msg.sender);
    }

    /// @inheritdoc IHookrPonsAdapterFactory
    function predict(address origin, address revenueToken, address memecoin) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrPonsAdapter).creationCode, abi.encode(revenueToken, launchFactory, memecoin, origin)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), _salt(origin, revenueToken, memecoin), initCodeHash
                        )
                    )
                )
            )
        );
    }

    function _salt(address origin, address revenueToken, address memecoin) private pure returns (bytes32) {
        return keccak256(abi.encode(origin, revenueToken, memecoin));
    }
}
