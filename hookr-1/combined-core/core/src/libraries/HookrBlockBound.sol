// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Immutable module bind answer. Minima are gross buy-charge pips, before the protocol split.
library HookrBlockBound {
    error InvalidBound();
    struct Bound {
        uint24 buyMaxLp;
        uint24 buyMaxTake;
        uint24 sellMaxLp;
        uint24 sellMaxTake;
        uint24 minBuyPotCharge;
        uint24 minBuyOtherCharge;
        uint8 buyOutflows;
        uint8 sellOutflows;
    }
    // Six uint24 lanes at 0/24/48/72/96/120; outflow masks at 144/152; 160..255 reserved.
    function pack(Bound memory b) internal pure returns (uint256) {
        if (b.buyOutflows > 31 || b.sellOutflows > 31) revert InvalidBound();
        return uint256(b.buyMaxLp) | uint256(b.buyMaxTake) << 24 | uint256(b.sellMaxLp) << 48
            | uint256(b.sellMaxTake) << 72 | uint256(b.minBuyPotCharge) << 96
            | uint256(b.minBuyOtherCharge) << 120 | uint256(b.buyOutflows) << 144
            | uint256(b.sellOutflows) << 152;
    }
    function unpack(uint256 word) internal pure returns (Bound memory b) {
        if (word >> 160 != 0) revert InvalidBound();
        b = Bound(uint24(word), uint24(word >> 24), uint24(word >> 48), uint24(word >> 72),
            uint24(word >> 96), uint24(word >> 120), uint8(word >> 144), uint8(word >> 152));
        if (b.buyOutflows > 31 || b.sellOutflows > 31) revert InvalidBound();
    }
    /// @dev Checked aggregate sums, with the union of each side's outflow mask. C2 checks aggregate caps.
    function combine(uint256 left, uint256 right) internal pure returns (uint256) {
        Bound memory a = unpack(left); Bound memory b = unpack(right);
        return pack(Bound(_sum(a.buyMaxLp, b.buyMaxLp), _sum(a.buyMaxTake, b.buyMaxTake),
            _sum(a.sellMaxLp, b.sellMaxLp), _sum(a.sellMaxTake, b.sellMaxTake),
            _sum(a.minBuyPotCharge, b.minBuyPotCharge), _sum(a.minBuyOtherCharge, b.minBuyOtherCharge),
            a.buyOutflows | b.buyOutflows, a.sellOutflows | b.sellOutflows));
    }
    function _sum(uint24 a, uint24 b) private pure returns (uint24) {
        uint256 total = uint256(a) + b;
        if (total > type(uint24).max) revert InvalidBound();
        return uint24(total);
    }
    uint8 internal constant ALLOW_CUT = 1;
    uint8 internal constant ALLOW_EXIT = 2;
    uint8 internal constant ALLOW_HOLDER = 4;
    uint8 internal constant ALLOW_STORM = 8;
    uint8 internal constant ALLOW_WALLET = 16;
    uint8 internal constant ALLOW_WINDOWS = 32;
    uint8 internal constant ALLOW_SANDWICH = 64;
    uint8 internal constant ALLOW_CROWN = 128;

    /// @notice Translate the eight block bits to scattered hot fields BEFORE applying a module's hook masks.
    /// The crown has no hot bit: its separate allowed bit is checked through enabledBlocks.
    function expandAllowed(uint8 allowed) internal pure returns (uint32 hot) {
        if (allowed & ALLOW_CUT != 0) hot |= uint32(0x1ffff) | uint32(7 << 24);
        if (allowed & ALLOW_EXIT != 0) hot |= uint32(1 << 20);
        if (allowed & ALLOW_HOLDER != 0) hot |= uint32(1 << 21);
        if (allowed & ALLOW_STORM != 0) hot |= uint32(1 << 22);
        if (allowed & ALLOW_WALLET != 0) hot |= uint32(1 << 19);
        if (allowed & ALLOW_WINDOWS != 0) hot |= uint32(1 << 23);
        if (allowed & ALLOW_SANDWICH != 0) hot |= uint32(1 << 17);
    }
    /// @dev Called after the Settings codec validates the carriers. A prize-cap-only crown is still a block field.
    function enabledBlocks(uint32 hot, uint128 cold, bool crownOn) internal pure returns (uint8 enabled) {
        if (hot & 0x3fff != 0) enabled |= ALLOW_CUT;
        if (hot & uint32(1 << 20) != 0) enabled |= ALLOW_EXIT;
        if (hot & uint32(1 << 21) != 0) enabled |= ALLOW_HOLDER;
        if (hot & uint32(1 << 22) != 0) enabled |= ALLOW_STORM;
        if (hot & uint32(1 << 19) != 0) enabled |= ALLOW_WALLET;
        if (hot & uint32(1 << 23) != 0) enabled |= ALLOW_WINDOWS;
        if (hot & uint32(1 << 17) != 0) enabled |= ALLOW_SANDWICH;
        if (crownOn || (cold >> 97) & 0x1ffff != 0) enabled |= ALLOW_CROWN;
    }
}
