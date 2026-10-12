// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {TwoVenueExecutor} from "../mocks/TwoVenueExecutor.sol";
import {Actor} from "../mocks/Actors.sol";

/// @notice A King of the Pool lane pool on HookrRoot with a two-venue executor and a reference pool for the same
///         pair: the shared setup of the creator wash, pot release and frame debt shift suites.
abstract contract KothWashFixture is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TwoVenueExecutor internal arb;
    PoolKey internal key;
    PoolKey internal ref;
    bytes32 internal family;
    Currency internal subject;

    function setUp() public virtual {
        _setUpLane();
        arb = _twoVenueExecutor(1e24);
        _openLane(address(arb));
        (key, family) = _openPoolWithFamily(ETH, _washRules(), _kothRc());
        subject = _subjectOf(key);
        ref = _seedReference(key);
    }

    /// @dev The King of the Pool pool's native rules: the protocol takes 1% of every buy (25% of 4% LP Rewards), and
    ///      the prize ceiling is half of it.
    function _washRules() internal pure virtual returns (HookrTypes.RulesConfig memory) {
        return _laneRules(true);
    }

    /// @dev Unauthenticated round trips (no leader, no trader leg) whose arb recaptures fill the pot.
    function _fillPotWithUnauthenticatedTraffic(uint256 rounds) internal {
        Actor filler = _newActor(key);
        for (uint256 i; i < rounds; ++i) {
            filler.directSwap(key, true, -2e22, MIN_PRICE);
            filler.directSwap(key, false, -filler.lastDelta1(), MAX_PRICE);
        }
    }
}
