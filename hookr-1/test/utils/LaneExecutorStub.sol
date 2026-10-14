// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @dev A recapture executor stand-in that reports a fixed partner share.
contract LaneExecutorStub {
    uint16 internal immutable rate;

    constructor(uint16 rate_) {
        rate = rate_;
    }

    function partnerBps() external view returns (uint16) {
        return rate;
    }
}

/// @dev LaneExecutorStub with other runtime code, to etch over a pinned executor: a codehash drift.
contract LaneExecutorStubV2 is LaneExecutorStub {
    constructor() LaneExecutorStub(1_000) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}
