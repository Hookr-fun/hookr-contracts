// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @dev The read side of an ERC-8470 registry with the reference implementation's storage shape: each observation
///      keeps its findings as an array of (kind, value, param, lean), and `latestFinding` scans it in order, comparing
///      the kind first, so a finding at the end of a long observation costs what it costs on chain. The latest
///      observation is keyed by chain id, token and detector (the writer).
contract MockLaunchObservations {
    struct Finding {
        bytes32 kind;
        uint256 value;
        uint64 param;
        uint8 lean;
    }

    uint256 internal constant NOT_READ = type(uint256).max;

    uint256 public count;
    mapping(bytes32 => uint256) internal _latest;
    mapping(uint256 => Finding[]) internal _findings;

    function _key(uint256 chainId, address token, address detector) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, token, detector));
    }

    /// @dev Records an observation of `token` by `detector` (in place of `msg.sender`, for the tests) and makes it
    ///      the latest.
    function record(address token, address detector, Finding[] calldata findings) external returns (uint256 id) {
        id = ++count;
        Finding[] storage stored = _findings[id];
        for (uint256 i; i < findings.length; ++i) {
            stored.push(findings[i]);
        }
        _latest[_key(block.chainid, token, detector)] = id;
    }

    function latestFinding(uint256 chainId, address token, address detector, bytes32 kind, uint64 param)
        external
        view
        returns (uint256 observationId, uint64 observedBlock, uint64 recordedAt, uint256 value, uint8 lean)
    {
        observationId = _latest[_key(chainId, token, detector)];
        if (observationId == 0) return (0, 0, 0, NOT_READ, 0);
        Finding[] storage all = _findings[observationId];
        value = NOT_READ;
        for (uint256 i; i < all.length; ++i) {
            Finding storage f = all[i];
            if (f.kind == kind && f.param == param) {
                (value, lean) = (f.value, f.lean);
                break;
            }
        }
        return (observationId, 1, 1, value, lean);
    }
}
