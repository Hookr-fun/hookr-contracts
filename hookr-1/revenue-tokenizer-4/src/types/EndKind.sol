// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Stream end kinds, part of the HookRevenue Tokenizer
/// @notice When a stream ends, as a door or a source answers it.
/// @param FOREVER Nothing can move the stream away from the token.
/// @param AT_BLOCK The stream ends at parent block `at` (a locked family).
/// @param AT_TIME The stream ends at timestamp `at`.
/// @param REVOCABLE Someone else can move the stream away; `at` is the earliest moment a pending revocation takes
///        effect, or zero when none is pending.
/// @param ENDED The stream no longer pays the token (released, or revoked).
enum EndKind {
    FOREVER,
    AT_BLOCK,
    AT_TIME,
    REVOCABLE,
    ENDED
}
