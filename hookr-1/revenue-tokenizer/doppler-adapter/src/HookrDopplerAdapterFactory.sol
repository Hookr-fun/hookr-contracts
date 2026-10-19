// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrDopplerAdapter} from "./HookrDopplerAdapter.sol";
import {IHookrDopplerAdapterFactory} from "./interfaces/IHookrDopplerAdapterFactory.sol";
import {IDopplerHookInitializer} from "./interfaces/external/IDoppler.sol";

/// @title Hookr Doppler adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes Doppler adapters at predictable addresses, before the revenue token exists, for one launchpad's
///         launches. See IHookrDopplerAdapterFactory for the rules.
/// @dev No owner. Two pins: the Doppler hook initializer and the integrator. The CREATE2 salt binds the origin, the
///      revenue token and the launch token, so the address is known from the three before the adapter exists and no
///      one takes another's.
contract HookrDopplerAdapterFactory is IHookrDopplerAdapterFactory {
    using PoolIdLibrary for PoolKey;

    /// @inheritdoc IHookrDopplerAdapterFactory
    uint256 public constant COLLECT_CHECK_GAS = 1_000_000;

    /// @inheritdoc IHookrDopplerAdapterFactory
    address public immutable initializer;
    /// @inheritdoc IHookrDopplerAdapterFactory
    address public immutable integrator;
    /// @inheritdoc IHookrDopplerAdapterFactory
    mapping(address adapter => bool) public isAdapter;

    /// @param initializer_ The Doppler hook initializer; must have code.
    /// @param integrator_ The launchpad's integrator in the Doppler Airlock; nonzero.
    constructor(address initializer_, address integrator_) {
        if (initializer_.code.length == 0 || integrator_ == address(0)) revert InvalidConfig();
        initializer = initializer_;
        integrator = integrator_;
    }

    /// @notice Lets Doppler's native payout land during `checkCollect` (always undone), so a share of a native ETH
    ///         launch moved to the factory can never make that check fail. ETH sent here directly stays here.
    receive() external payable {}

    /// @inheritdoc IHookrDopplerAdapterFactory
    function create(address revenueToken, address launchToken) external returns (address adapter) {
        IDopplerHookInitializer i = IDopplerHookInitializer(initializer);
        (,,,,, PoolKey memory key,) = i.getState(launchToken);
        PoolId id = key.toId();
        if (i.getShares(id, msg.sender) == 0 && i.getShares(id, _predict(msg.sender, revenueToken, launchToken)) == 0) {
            revert NotBeneficiary(msg.sender, launchToken);
        }
        HookrDopplerAdapter made = new HookrDopplerAdapter{salt: _salt(msg.sender, revenueToken, launchToken)}(
            revenueToken, initializer, launchToken, msg.sender
        );
        address launchpad = made.integrator();
        if (launchpad != integrator) revert LaunchpadNotAllowed(launchpad);
        try this.checkCollect(id) {}
        catch (bytes memory reason) {
            if (reason.length != 4 || bytes4(reason) != CollectFits.selector) revert CollectTooHeavy();
        }
        adapter = address(made);
        isAdapter[adapter] = true;
        emit AdapterCreated(adapter, revenueToken, launchToken, msg.sender);
    }

    /// @inheritdoc IHookrDopplerAdapterFactory
    function checkCollect(PoolId pool) external {
        IDopplerHookInitializer(initializer).collectFees{gas: COLLECT_CHECK_GAS}(pool);
        revert CollectFits();
    }

    /// @inheritdoc IHookrDopplerAdapterFactory
    function predict(address origin, address revenueToken, address launchToken) external view returns (address) {
        return _predict(origin, revenueToken, launchToken);
    }

    function _predict(address origin, address revenueToken, address launchToken) private view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrDopplerAdapter).creationCode, abi.encode(revenueToken, initializer, launchToken, origin)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), _salt(origin, revenueToken, launchToken), initCodeHash
                        )
                    )
                )
            )
        );
    }

    function _salt(address origin, address revenueToken, address launchToken) private pure returns (bytes32) {
        return keccak256(abi.encode(origin, revenueToken, launchToken));
    }
}
