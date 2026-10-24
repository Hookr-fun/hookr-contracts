// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrPonsAdapter} from "./HookrPonsAdapter.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrPonsAdapterFactory} from "../interfaces/IHookrPonsAdapterFactory.sol";
import {IPonsV2LaunchFactory} from "../interfaces/external/IPonsV2.sol";

/// @title Hookr Pons adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes Pons adapters at predictable addresses, before the revenue token adds them. See
///         IHookrPonsAdapterFactory for the rules.
/// @dev No owner, no pin but the Pons launch factory. The CREATE2 salt binds the origin, the revenue token and the
///      memecoin, so the address is known from the three before the adapter exists and no one takes another's. A
///      revenue token that already has code must answer `isDoor` in one word (`NotARevenueToken`), the same read the
///      adapter's `abort` makes, so no adapter is made that could never be aborted.
contract HookrPonsAdapterFactory is IHookrPonsAdapterFactory {
    /// @dev Gas the admission read at creation gets: the adapter's own `isDoor` read cap (BALANCE_GAS).
    uint256 private constant IS_DOOR_READ_GAS = 50_000;

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
        if (launch.pairToken == revenueToken) revert PairIsRevenueToken();
        if (revenueToken.code.length != 0) {
            (bool read,) = HookrForward.read(
                revenueToken, abi.encodeCall(IHookrRevenueToken.isDoor, (address(this))), IS_DOOR_READ_GAS
            );
            if (!read) revert NotARevenueToken(revenueToken);
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
