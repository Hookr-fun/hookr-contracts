// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrRulesStorage as S} from "./HookrRulesStorage.sol";

/// @notice Shared tail and mask recipes. The core alone writes each appended word.
/// @dev Tail readers are internal: including this helper never introduces a library DELEGATECALL in a module.
library HookrBlockCall {
    error InvalidBlockCall();
    error InvalidBlockMasks();

    uint8 internal constant MASK_BIND = 0;
    uint8 internal constant MASK_ADD_LIQUIDITY = 1;
    uint8 internal constant MASK_QUOTE_BUY = 2;
    uint8 internal constant MASK_QUOTE_SELL = 3;
    uint8 internal constant MASK_SETTLE_BUY = 4;
    uint8 internal constant MASK_SETTLE_SELL = 5;
    uint8 internal constant MASK_GUARD_ONLY = 6;
    uint8 internal constant MASK_CHARGING = 7;

    uint32 internal constant HOT_FIELDS = ((uint32(1) << 27) - 1) ^ (uint32(1) << 18);
    uint128 internal constant PRIZE_CAP_FIELDS = uint128(131_071) << 97;
    // The prize cap belongs to Recapture, rather than a block-table slot.
    uint128 internal constant BLOCK_COLD_FIELDS = ((uint128(1) << 123) - 1) ^ PRIZE_CAP_FIELDS;

    struct Quote {
        uint256 context;
        uint128 cold;
        uint256 lp;
        uint256 take;
        uint256 burn;
        uint256 hookr;
    }

    struct Settle {
        uint256 context;
        uint128 cold;
        uint24 finalTake;
        uint256 protocol;
    }

    function lane(uint256 hooks, uint8 index) internal pure returns (uint32) {
        if (index > MASK_CHARGING) revert InvalidBlockMasks();
        return uint32(hooks >> (uint256(index) * 32));
    }

    function coldFields(uint256 coldMasks) internal pure returns (uint128) {
        return uint128(coldMasks);
    }

    function coldReaders(uint256 coldMasks) internal pure returns (uint32) {
        return uint32(coldMasks >> 128);
    }

    /// @dev Check the supplied module masks before applying this instance's expanded allowed-hot mask.
    function validateMasks(uint256 hooks, uint256 coldMasks) internal pure {
        if (coldMasks >> 160 != 0 || coldFields(coldMasks) & ~BLOCK_COLD_FIELDS != 0) revert InvalidBlockMasks();
        uint32 supported;
        for (uint8 i; i < MASK_GUARD_ONLY; ++i) {
            uint32 mask = lane(hooks, i);
            if (mask & ~HOT_FIELDS != 0) revert InvalidBlockMasks();
            supported |= mask;
        }
        uint32 auxiliary = lane(hooks, MASK_GUARD_ONLY) | lane(hooks, MASK_CHARGING) | coldReaders(coldMasks);
        if (auxiliary & ~supported != 0) revert InvalidBlockMasks();
    }

    function bindTail() internal pure returns (uint256 context, uint128 cold, uint32 hot, uint16 protocolShareBps) {
        // key5 + PoolConfig14 argument words, selector4, tail128.
        _exact(740);
        uint256 coldWord;
        uint256 hotWord;
        uint256 shareWord;
        assembly ("memory-safe") {
            context := calldataload(sub(calldatasize(), 128))
            coldWord := calldataload(sub(calldatasize(), 96))
            hotWord := calldataload(sub(calldatasize(), 64))
            shareWord := calldataload(sub(calldatasize(), 32))
        }
        _context(context, S.Hook.Bind);
        if (coldWord >> 128 != 0 || hotWord >> 32 != 0 || shareWord >> 16 != 0) revert InvalidBlockCall();
        return (context, uint128(coldWord), uint32(hotWord), uint16(shareWord));
    }

    function addLiquidityTail() internal pure returns (uint256 context, uint128 cold) {
        _exact(132);
        return _two(S.Hook.AddLiquidity);
    }

    function quoteTail() internal pure returns (Quote memory q) {
        // SwapContext13 + SwapSimulation4 argument words, selector4, tail192.
        _exact(740);
        uint256 coldWord;
        assembly ("memory-safe") {
            let start := sub(calldatasize(), 192)
            mstore(q, calldataload(start))
            coldWord := calldataload(add(start, 32))
            mstore(add(q, 32), coldWord)
            mstore(add(q, 64), calldataload(add(start, 64)))
            mstore(add(q, 96), calldataload(add(start, 96)))
            mstore(add(q, 128), calldataload(add(start, 128)))
            mstore(add(q, 160), calldataload(add(start, 160)))
        }
        _context(q.context, S.Hook.Quote);
        if (coldWord >> 128 != 0) revert InvalidBlockCall();
    }

    function settleTail() internal pure returns (Settle memory z) {
        // SwapContext13 + Settlement8 argument words, selector4, tail128.
        _exact(804);
        uint256 coldWord;
        uint256 takeWord;
        assembly ("memory-safe") {
            let start := sub(calldatasize(), 128)
            mstore(z, calldataload(start))
            coldWord := calldataload(add(start, 32))
            mstore(add(z, 32), coldWord)
            takeWord := calldataload(add(start, 64))
            mstore(add(z, 64), takeWord)
            mstore(add(z, 96), calldataload(add(start, 96)))
        }
        _context(z.context, S.Hook.Settle);
        if (coldWord >> 128 != 0 || takeWord >> 24 != 0) revert InvalidBlockCall();
    }

    function outTail() internal pure returns (uint256 context, uint128 cold) {
        // blockOut(bytes): selector4, canonical offset32, length32, padded bytes, tail64.
        uint256 length;
        uint256 offset;
        uint256 size;
        assembly ("memory-safe") {
            length := calldatasize()
            offset := calldataload(4)
            size := calldataload(36)
        }
        if (length < 132 || offset != 32 || size > length - 132) revert InvalidBlockCall();
        uint256 padded = (size + 31) & ~uint256(31);
        if (length != padded + 132) revert InvalidBlockCall();
        uint256 padding = padded - size;
        if (padding != 0) {
            uint256 word;
            assembly ("memory-safe") { word := calldataload(add(68, size)) }
            if (word >> ((32 - padding) * 8) != 0) revert InvalidBlockCall();
        }
        return _two(S.Hook.Out);
    }

    function _two(S.Hook expected) private pure returns (uint256 context, uint128 cold) {
        _need(64);
        uint256 coldWord;
        assembly ("memory-safe") {
            context := calldataload(sub(calldatasize(), 64))
            coldWord := calldataload(sub(calldatasize(), 32))
        }
        _context(context, expected);
        if (coldWord >> 128 != 0) revert InvalidBlockCall();
        return (context, uint128(coldWord));
    }

    function _context(uint256 context, S.Hook expected) private pure {
        if (S.contextHook(context) != expected) revert InvalidBlockCall();
        if (expected != S.Hook.Bind && context & S.CTX_FUNDED != 0) revert InvalidBlockCall();
    }

    function _need(uint256 tailBytes) private pure {
        uint256 length;
        assembly ("memory-safe") { length := calldatasize() }
        if (length < tailBytes + 4) revert InvalidBlockCall();
    }

    function _exact(uint256 expected) private pure {
        uint256 length;
        assembly ("memory-safe") { length := calldatasize() }
        if (length != expected) revert InvalidBlockCall();
    }
}
