// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRevenueToken} from "../HookrRevenueToken.sol";

/// @title Hookr revenue token deployer
/// @notice Deploys the tokenizer's revenue tokens with CREATE2, so the tokenizer knows a token's address before it exists:
///         a new launch names the revenue token as every pool's `royaltyTo` before the token is deployed, because the token
///         lists the launch's new subject as an asset and the ledger refuses an asset with no code.
/// @dev An external library: the tokenizer reaches it by delegatecall, so `address(this)` is the tokenizer and the
///      token is created from the tokenizer's address, while the token's creation code lives here. The tokenizer could
///      not carry the token's, the forwarder's and the adapter's creation code itself: its runtime would pass the
///      24,576-byte limit, and its init code the 49,152-byte one. Linked at deploy, like the release's own libraries.
library HookrRevenueTokenDeployer {
    /// @notice What a revenue token is born with, beside the tokenizer and the PoolManager.
    struct TokenArgs {
        string name;
        string symbol;
        uint256 supply;
        Currency[] assets;
        uint32 streamSeconds;
        uint16 tipBps;
        bytes32 termsHash;
    }

    /// @notice The address `deploy(a, salt, poolManager)` creates from the calling tokenizer.
    function predict(TokenArgs memory a, bytes32 salt, address poolManager) external view returns (address) {
        return Create2.computeAddress(salt, _initCodeHash(address(this), a, poolManager), address(this));
    }

    /// @notice The init code hash of the revenue token `tokenizer` would deploy with `a` and `poolManager`: what a
    ///         view that runs under a staticcall (where `address(this)` is the library, not the tokenizer) computes
    ///         the CREATE2 address from, against the tokenizer it names.
    function initCodeHash(address tokenizer, TokenArgs memory a, address poolManager) external pure returns (bytes32) {
        return _initCodeHash(tokenizer, a, poolManager);
    }

    /// @notice Deploys a pending revenue token at the predicted address, naming the calling tokenizer.
    function deploy(TokenArgs memory a, bytes32 salt, address poolManager) external returns (address token) {
        token = address(
            new HookrRevenueToken{salt: salt}(
                address(this), a.name, a.symbol, a.supply, a.assets, a.streamSeconds, a.tipBps, a.termsHash, poolManager
            )
        );
    }

    function _initCodeHash(address tokenizer, TokenArgs memory a, address poolManager) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(HookrRevenueToken).creationCode,
                abi.encode(
                    tokenizer, a.name, a.symbol, a.supply, a.assets, a.streamSeconds, a.tipBps, a.termsHash, poolManager
                )
            )
        );
    }
}
