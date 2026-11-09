// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";

/// @title Hookr revenue token deployer
/// @notice Builds a revenue token's init code from the two halves of its creation code (`HookrRevenueTokenCode`) and its
///         constructor arguments, predicts its CREATE2 address, and creates it. The calling contract is the deployer, so
///         the tokenizer, and its libraries under delegatecall, create every token from the tokenizer's address.
/// @dev Internal functions only. A half is read from its contract's runtime past the leading STOP byte.
library HookrRevenueTokenDeployer {
    /// @notice The token's init code: both halves, then `abi.encode` of the constructor's arguments.
    /// @param code0 The contract holding the first half.
    /// @param code1 The contract holding the second half.
    /// @param tokenizer The token's tokenizer.
    /// @param collector The leg collector.
    /// @param t The creator's terms.
    /// @param streamSeconds The release period as the terms give it: zero for income claimable at once.
    /// @param poolManager The PoolManager.
    function initCode(
        address code0,
        address code1,
        address tokenizer,
        address collector,
        IHookrRevenueTokenizer.TokenTerms calldata t,
        uint32 streamSeconds,
        address poolManager
    ) internal view returns (bytes memory code) {
        Currency[] memory assets = new Currency[](t.assets.length + 1);
        for (uint256 i; i < t.assets.length; ++i) {
            assets[i + 1] = t.assets[i];
        }
        bytes memory args = abi.encode(
            tokenizer,
            collector,
            t.name,
            t.symbol,
            t.supply,
            assets,
            streamSeconds,
            t.tipBps,
            t.termsHash,
            poolManager,
            t.streamManager,
            t.openStreams
        );
        uint256 n0 = code0.code.length - 1;
        uint256 n1 = code1.code.length - 1;
        uint256 n = n0 + n1 + args.length;
        code = new bytes(n);
        assembly ("memory-safe") {
            let p := add(code, 0x20)
            extcodecopy(code0, p, 1, n0)
            extcodecopy(code1, add(p, n0), 1, n1)
            mcopy(add(p, add(n0, n1)), add(args, 0x20), mload(args))
        }
    }

    /// @notice The address `deploy` gives `code` with `salt` from `deployer`.
    function predict(address deployer, bytes32 salt_, bytes memory code) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt_, keccak256(code))))));
    }

    /// @notice Creates `code` with `salt` from the calling contract. The caller refuses a repeated (creator, terms
    ///         hash) before, so the address is free; a constructor revert is bubbled as is.
    function deploy(bytes memory code, bytes32 salt_) internal returns (address token) {
        assembly ("memory-safe") {
            token := create2(0, add(code, 0x20), mload(code), salt_)
            if and(iszero(token), gt(returndatasize(), 0)) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        if (token == address(0)) revert IHookrRevenueTokenizer.InvalidConfig();
    }

    /// @notice A revenue token's salt: the creator and the terms hash.
    function salt(address creator, bytes32 termsHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, termsHash));
    }
}
