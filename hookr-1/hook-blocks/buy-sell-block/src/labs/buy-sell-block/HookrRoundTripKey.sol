// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Round-trip identity key
/// @notice The one key both the record book and the Buy/Sell Selective Block advisory use for a trader.
/// @dev Every key is the pair (identity, transaction origin). The identity is the authenticated payer of an
///      authenticated swap, and the contract that called the pool for an unauthenticated one. Keying an authenticated
///      swap by its payer alone let every user of one shared contract in front of the pinned or curated router share
///      one key, so a third party could refuse all of them with a dust trade. With the origin in the key, two
///      users only share a key if they share both the identity and the transaction origin. Under ERC-4337 the origin
///      is the bundler's EOA for every user operation it sends, so smart accounts that trade through one shared
///      contract by way of one bundler do share a key: a third party's dust trade sent that way refuses their opposite
///      trade through that contract until the next block (a disclosed limit). An account that calls the
///      pinned or curated router itself is its own payer and keeps its own key.
library HookrRoundTripKey {
    /// @notice Returns the key of a trader.
    function trader(address sender, address payer, bool authenticated, address origin) internal pure returns (bytes32) {
        return keccak256(abi.encode(authenticated ? payer : sender, origin));
    }
}
