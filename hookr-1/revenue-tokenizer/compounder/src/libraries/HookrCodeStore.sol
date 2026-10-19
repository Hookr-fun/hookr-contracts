// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrCodeChunk} from "./HookrCodeChunk.sol";

/// @title Hookr code store
/// @notice Keeps a contract's creation code on chain in pieces (HookrCodeChunk) and puts it back together to deploy
///         from. The compounder's creation code is larger than one contract's runtime may be, so the factory cannot
///         carry it in its own code or in a linked library; it writes it here once, at its own construction, and
///         reads it on every `create`.
library HookrCodeStore {
    /// @notice Most bytes one chunk holds: 24,000, under the runtime size limit with the chunk's leading STOP.
    uint256 internal constant CHUNK_BYTES = 24_000;

    /// @notice Writes `code` as chunks and returns them in order.
    function write(bytes memory code) internal returns (address[] memory chunks) {
        uint256 length = code.length;
        uint256 count = (length + CHUNK_BYTES - 1) / CHUNK_BYTES;
        chunks = new address[](count);
        for (uint256 i; i < count; ++i) {
            uint256 start = i * CHUNK_BYTES;
            uint256 size = length - start < CHUNK_BYTES ? length - start : CHUNK_BYTES;
            bytes memory piece = new bytes(size);
            assembly ("memory-safe") {
                mcopy(add(piece, 32), add(add(code, 32), start), size)
            }
            chunks[i] = address(new HookrCodeChunk(piece));
        }
    }

    /// @notice Reads the code `chunks` hold, in order, each without its leading STOP.
    function read(address[] memory chunks) internal view returns (bytes memory code) {
        uint256 total;
        uint256 count = chunks.length;
        for (uint256 i; i < count; ++i) {
            total += chunks[i].code.length - 1;
        }
        code = new bytes(total);
        uint256 offset;
        for (uint256 i; i < count; ++i) {
            address chunk = chunks[i];
            uint256 size = chunk.code.length - 1;
            assembly ("memory-safe") {
                extcodecopy(chunk, add(add(code, 32), offset), 1, size)
            }
            offset += size;
        }
    }
}
