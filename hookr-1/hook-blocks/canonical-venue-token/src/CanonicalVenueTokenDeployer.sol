// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CanonicalVenueToken} from "./CanonicalVenueToken.sol";

/// @title CanonicalVenueTokenDeployer
/// @notice CREATE2 factory for CanonicalVenueToken, owned by exactly one settlement.
/// @dev Created by the settlement's constructor so the token creation code sits in the settlement's initcode, not
///      its runtime (keeps the settlement under EIP-170). Only that settlement can deploy, and every token it
///      deploys names that settlement as its sole permit writer. Salts are namespaced by creator upstream.
contract CanonicalVenueTokenDeployer {
    /// @notice The only caller, and the permit writer of every token deployed here.
    address public immutable settlement;
    /// @notice The PoolManager every token deployed here guards.
    IPoolManager public immutable poolManager;

    /// @notice Only the settlement can deploy.
    error NotSettlement(address caller);
    /// @notice The creator already used this salt with these parameters.
    error TokenExists(address token);

    /// @param manager The v4 PoolManager.
    constructor(IPoolManager manager) {
        settlement = msg.sender;
        poolManager = manager;
    }

    /// @notice Deploys a token whose whole supply goes to the settlement for launch.
    /// @param salt The already creator-namespaced CREATE2 salt.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param supply Fixed supply.
    /// @param quote The canonical quote currency.
    /// @param tickSpacing The canonical tick spacing.
    /// @param root The canonical hook (a Hookr root).
    /// @return token The deployed token.
    function deploy(
        bytes32 salt,
        string calldata name_,
        string calldata symbol_,
        uint256 supply,
        Currency quote,
        int24 tickSpacing,
        address root
    ) external returns (address token) {
        if (msg.sender != settlement) revert NotSettlement(msg.sender);
        address predicted = predict(salt, name_, symbol_, supply, quote, tickSpacing, root);
        if (predicted.code.length != 0) revert TokenExists(predicted);
        token = address(
            new CanonicalVenueToken{salt: salt}(
                name_,
                symbol_,
                supply,
                settlement,
                poolManager,
                settlement,
                quote,
                LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing,
                root
            )
        );
    }

    /// @notice Predicts the address `deploy` would use.
    function predict(
        bytes32 salt,
        string calldata name_,
        string calldata symbol_,
        uint256 supply,
        Currency quote,
        int24 tickSpacing,
        address root
    ) public view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(CanonicalVenueToken).creationCode,
                abi.encode(
                    name_,
                    symbol_,
                    supply,
                    settlement,
                    poolManager,
                    settlement,
                    quote,
                    LPFeeLibrary.DYNAMIC_FEE_FLAG,
                    tickSpacing,
                    root
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }
}
