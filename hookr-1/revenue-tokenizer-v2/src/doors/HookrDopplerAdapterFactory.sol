// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrDopplerAdapter} from "./HookrDopplerAdapter.sol";
import {IHookrDopplerAdapterFactory} from "../interfaces/IHookrDopplerAdapterFactory.sol";
import {IDopplerHookInitializer} from "../interfaces/external/IDoppler.sol";

/// @title Hookr Doppler adapter factory, part of the HookRevenue Tokenizer
/// @notice Makes Doppler adapters at predictable addresses, before the revenue token adds them, for one launch
///         platform's launches. See IHookrDopplerAdapterFactory for the rules.
/// @dev No owner. Two pins: the Doppler hook initializer and the integrator. The CREATE2 salt binds the origin, the
///      revenue token and the launch token, so the address is known from the three before the adapter exists and no
///      one takes another's. `create` runs only while the caller still holds its share and the predicted address
///      holds none, so a `create` that refuses leaves the share with its holder: no documented flow moves a share to
///      an address before an adapter is there. Another beneficiary of the same launch can park its own share at a
///      holder's predicted address (at the cost of that share) to refuse that holder's `create`; the holder moves its
///      share to a fresh address and creates from there, since the address binds the origin.
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
    /// @param integrator_ The launch platform's integrator in the Doppler Airlock; nonzero.
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
        if (Currency.unwrap(key.currency0) == revenueToken || Currency.unwrap(key.currency1) == revenueToken) {
            revert PairIsRevenueToken();
        }
        PoolId id = key.toId();
        address predicted = _predict(msg.sender, revenueToken, launchToken);
        if (i.getShares(id, predicted) != 0) revert ShareMovedBeforeCreate(predicted);
        if (i.getShares(id, msg.sender) == 0) revert NotBeneficiary(msg.sender, launchToken);
        HookrDopplerAdapter made = new HookrDopplerAdapter{salt: _salt(msg.sender, revenueToken, launchToken)}(
            revenueToken, initializer, launchToken, msg.sender
        );
        address platform = made.integrator();
        if (platform != integrator) revert IntegratorNotAllowed(platform);
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
