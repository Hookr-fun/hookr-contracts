// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";

/// @title Hookr revenue tokenizer storage
/// @notice The tokenizer's state at one fixed slot, so the tokenizer and the linked libraries it delegatecalls read and
///         write the same records without handing storage references across a call.
/// @dev Internal functions only: nothing here is linked. The slot is `keccak256("hookr.revenue.tokenizer") - 1`, clear
///      of every slot Solidity assigns.
library HookrRevenueTokenizerStorage {
    /// @notice One stream as stored: its end is read live, never stored.
    /// @param kind The stream's kind.
    /// @param legBps Hookr's leg of its door.
    /// @param addedAt When it was added.
    /// @param door The door the token pulls.
    /// @param family The family's index in the forwarder for a family or the market; zero otherwise. A family
    ///        released from the forwarder can be registered there again under a new index, so the record keeps the
    ///        index of its own registration rather than looking the family up.
    /// @param id The family, the NFT id, the inner token or the source's kind; zero otherwise.
    struct Stream {
        IHookrRevenueTokenizer.StreamKind kind;
        uint16 legBps;
        uint40 addedAt;
        address door;
        uint32 family;
        bytes32 id;
    }

    /// @notice Every live dependency, fixed at construction.
    struct Pins {
        address launcher;
        address lock;
        address root;
        address treasury;
        address collector;
        address bridgeFactory;
        address poolManager;
        address positionManager;
        address positionManagerV3;
        address positionDoorFactory;
        address v3PositionDoorFactory;
        address feebAdapterFactory;
        address revenueTokenDoorFactory;
        address ponsAdapterFactory;
        address dopplerAdapterFactory;
        address tokenCode0;
        address tokenCode1;
    }

    /// @notice Everything the tokenizer keeps.
    struct Layout {
        Pins pins;
        mapping(address rules => bool) admittedRules;
        address[] rulesList;
        mapping(address vault => bool) admittedVaults;
        address[] vaultList;
        mapping(address token => IHookrRevenueTokenizer.Tokenization) tokenizations;
        address[] tokens;
        mapping(address token => Stream[]) streams;
        mapping(address creator => mapping(bytes32 termsHash => bool)) termsUsed;
    }

    bytes32 internal constant SLOT = bytes32(uint256(keccak256("hookr.revenue.tokenizer")) - 1);

    /// @notice The tokenizer's state.
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
