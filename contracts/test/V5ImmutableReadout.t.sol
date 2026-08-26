// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {IContinuousClearingAuctionFactory} from "../src/interfaces/IContinuousClearingAuction.sol";

/// @notice Derives the eleven scalar immutable words that the deployment preflight pins for
///         HookrLaunchpadV5 (`expectedImmutableWords` in scripts/verify-deployment-preflight.mjs).
///         It deploys the launchpad with the byte-identical constructor input used by
///         script/DeployRobinhoodV5.s.sol, reads the public immutable getters, and proves the
///         32-byte encoding empirically: every solc-declared immutable slot in the deployed runtime
///         must contain exactly the encoded getter values (uints zero-extended, int24 ticks
///         sign-extended) plus the three constructor addresses. Re-run whenever a constructor
///         constant in the deploy script or the instant-open geometry changes.
contract V5ImmutableReadout is Test {
    address constant HOOKR_TOKEN = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    uint96 constant HOOKR_INSTANT_OPEN_FDV = 2_500_000e18;
    // Mirrors DeployRobinhoodV5.s.sol. The scalar immutables depend only on the FDV and the
    // in-contract supply/band constants, but the address arguments are kept identical so this
    // readout's constructor input matches production byte-for-byte.
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IContinuousClearingAuctionFactory constant CCA_FACTORY =
        IContinuousClearingAuctionFactory(0x000000001F26a0044BaA66024e7b6599c61963F8);
    uint64 constant AUCTION_DURATION_BLOCKS = 125_000;
    uint64 constant CLAIM_DELAY_BLOCKS = 0;
    uint64 constant MIGRATION_DELAY_BLOCKS = 1;
    uint96 constant INSTANT_OPEN_FDV_WEI = 2.5 ether;

    /// @dev First reference offset of each solc immutable group, from
    ///      out/HookrLaunchpadV5.sol/HookrLaunchpadV5.json .deployedBytecode.immutableReferences.
    ///      A contract change that moves these offsets makes the slot assertions below fail loudly
    ///      instead of silently reading garbage — update them from the rebuilt artifact then.
    uint256 constant GROUP_COUNT = 14;

    function _groupOffsets() private pure returns (uint256[GROUP_COUNT] memory offsets) {
        offsets = [uint256(27), 904, 2484, 2947, 4526, 4596, 4789, 6136, 6793, 8836, 8962, 9508, 10624, 22097];
    }

    function _word(bytes memory code, uint256 start) private pure returns (bytes32 word) {
        require(start + 32 <= code.length, "immutable offset out of runtime bounds");
        assembly ("memory-safe") {
            word := mload(add(add(code, 32), start))
        }
    }

    function test_printScalarImmutableWords() external {
        HookrLaunchpadV5 pad = new HookrLaunchpadV5(
            PM,
            CCA_FACTORY,
            AUCTION_DURATION_BLOCKS,
            CLAIM_DELAY_BLOCKS,
            MIGRATION_DELAY_BLOCKS,
            INSTANT_OPEN_FDV_WEI,
            HOOKR_TOKEN,
            HOOKR_INSTANT_OPEN_FDV
        );

        bytes32[3] memory addressWords = [
            bytes32(uint256(uint160(address(PM)))),
            bytes32(uint256(uint160(address(CCA_FACTORY)))),
            bytes32(uint256(uint160(HOOKR_TOKEN)))
        ];
        // `useArbSysClock` is FALSE (zero word) in this local deployment — no ArbSys precompile
        // exists here — but TRUE (0x...01) on the live 4663 deployment, where the constructor
        // probe finds the precompile. The preflight pins the PRODUCTION word. The HOOKR instant
        // set mirrors the ETH one at the 2.5M HOOKR fixed open.
        bytes32[11] memory scalarWords = [
            bytes32(uint256(pad.instantOpenFdvWei())),
            bytes32(uint256(pad.instantOpenPriceWei())),
            bytes32(uint256(pad.instantSqrtPriceX96())),
            bytes32(uint256(int256(pad.instantBandLower()))),
            bytes32(uint256(int256(pad.instantBandUpper()))),
            bytes32(uint256(pad.hookrInstantOpenFdv())),
            bytes32(uint256(pad.hookrInstantOpenPrice())),
            bytes32(uint256(pad.hookrInstantSqrtPriceX96())),
            bytes32(uint256(int256(pad.hookrBandLower()))),
            bytes32(uint256(int256(pad.hookrBandUpper()))),
            bytes32(0)
        ];

        // Empirical encoding proof: the multiset of live immutable slots must equal exactly
        // {3 address words} + {11 scalar words}; every scalar appears at least once.
        bytes memory code = address(pad).code;
        uint256[GROUP_COUNT] memory offsets = _groupOffsets();
        bool[GROUP_COUNT] memory used;
        for (uint256 i = 0; i < GROUP_COUNT; i++) {
            bytes32 live = _word(code, offsets[i]);
            bool matched = false;
            for (uint256 j = 0; j < 3 && !matched; j++) {
                if (live == addressWords[j]) matched = true;
            }
            for (uint256 j = 0; j < 11 && !matched; j++) {
                if (live == scalarWords[j] && !used[j]) {
                    used[j] = true;
                    matched = true;
                }
            }
            require(matched, "live immutable slot does not match any encoded constructor value");
        }
        for (uint256 j = 0; j < 11; j++) {
            require(used[j], "an encoded scalar word never appeared in the runtime");
        }

        console2.log("instantOpenFdvWei");
        console2.logBytes32(scalarWords[0]);
        console2.log("instantOpenPriceWei");
        console2.logBytes32(scalarWords[1]);
        console2.log("instantSqrtPriceX96");
        console2.logBytes32(scalarWords[2]);
        console2.log("instantBandLower");
        console2.logBytes32(scalarWords[3]);
        console2.log("instantBandUpper");
        console2.logBytes32(scalarWords[4]);
        console2.log("hookrInstantOpenFdv");
        console2.logBytes32(scalarWords[5]);
        console2.log("hookrInstantOpenPrice");
        console2.logBytes32(scalarWords[6]);
        console2.log("hookrInstantSqrtPriceX96");
        console2.logBytes32(scalarWords[7]);
        console2.log("hookrBandLower");
        console2.logBytes32(scalarWords[8]);
        console2.log("hookrBandUpper");
        console2.logBytes32(scalarWords[9]);
        console2.log("useArbSysClock (LOCAL=false; live 4663 deploys TRUE -> 0x...01)");
        console2.logBytes32(scalarWords[10]);
    }
}
