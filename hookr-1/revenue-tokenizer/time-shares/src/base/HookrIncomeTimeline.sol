// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookrDays} from "../libraries/HookrDays.sol";
import {IHookrTimeShares} from "../interfaces/IHookrTimeShares.sol";

/// @title Hookr income timeline, part of the time shares
/// @notice The record of how the locked revenue tokens' income is spread over time. Every settle writes a point:
///         a timestamp and, per asset, the income attributed so far per locked revenue token (the index, scaled by
///         1e36). Income found at a settle is attributed to the whole stretch since the previous point, so the index
///         is a straight line between two points, and a day's share is the index at the day's end less the index at
///         its start, each read off the line. A late settle therefore spreads what it finds pro rata to time over
///         the days it covers, and nothing written at an earlier point ever moves.
/// @dev The points are append-only (`_times` strictly increasing, one index per asset at each). Attribution divides
///      what arrived by the revenue tokens locked during the stretch; the remainder, and everything that arrives
///      while nothing is locked, waits in `_carry` for the next attribution. A day's index is final once its end lies
///      at or before the last point, and is then cached, so a day that is claimed or traded often costs one read per
///      asset instead of two searches.
///
///      Bounds: a revenue token recognizes at most 2^128 - 1 units of an asset over its life, so every index stays
///      below 2^128 x 1e36 < 2^248 (the smallest divisor is one locked revenue token), and a holder's credit, its
///      units times an index difference, stays below the same bound because a day's units never exceed the revenue
///      tokens locked while that day's income was attributed.
abstract contract HookrIncomeTimeline is IHookrTimeShares {
    /// @inheritdoc IHookrTimeShares
    uint256 public constant SCALE = 1e36;
    /// @inheritdoc IHookrTimeShares
    uint256 public constant MAX_ASSETS = 4;
    /// @inheritdoc IHookrTimeShares
    uint32 public constant FOREVER = type(uint32).max;

    /// @dev How many assets the revenue token has, fixed at construction.
    uint256 internal immutable _assetCount;

    /// @dev The settle points' timestamps, strictly increasing; `_times[0]` is the construction.
    uint64[] internal _times;
    /// @dev Per asset and point, the income attributed so far per locked revenue token, scaled.
    mapping(uint256 asset => mapping(uint256 point => uint256)) internal _indexAt;
    /// @dev Per asset, scaled income not yet in the index.
    uint256[MAX_ASSETS] internal _carry;
    /// @dev Per day that has ended and been settled, every asset's final per-unit index; `_final` says which.
    mapping(uint256 day => uint256[MAX_ASSETS]) private _finalIndex;
    mapping(uint256 day => bool) private _final;

    /// @param assetCount_ The revenue token's number of assets, 1 to `MAX_ASSETS`.
    constructor(uint256 assetCount_) {
        if (assetCount_ == 0 || assetCount_ > MAX_ASSETS) revert InvalidConfig();
        _assetCount = assetCount_;
        _times.push(uint64(block.timestamp));
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrTimeShares
    function assetCount() external view returns (uint256) {
        return _assetCount;
    }

    /// @inheritdoc IHookrTimeShares
    function pointCount() external view returns (uint256) {
        return _times.length;
    }

    /// @inheritdoc IHookrTimeShares
    function pointAt(uint256 k) external view returns (uint64 timestamp, uint256[] memory indexes) {
        if (k >= _times.length) revert UnknownPoint(k);
        timestamp = _times[k];
        uint256 n = _assetCount;
        indexes = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            indexes[i] = _indexAt[i][k];
        }
    }

    /// @inheritdoc IHookrTimeShares
    function index(uint256 asset) external view returns (uint256) {
        _checkAsset(asset);
        return _indexAt[asset][_times.length - 1];
    }

    /// @inheritdoc IHookrTimeShares
    function carry(uint256 asset) external view returns (uint256) {
        _checkAsset(asset);
        return _carry[asset];
    }

    /// @inheritdoc IHookrTimeShares
    function currentDay() external view returns (uint256) {
        return HookrDays.dayOf(block.timestamp);
    }

    // ------------------------------------------------------------------ internals

    /// @dev `UnknownAsset` past the last asset.
    function _checkAsset(uint256 asset) internal view {
        if (asset >= _assetCount) revert UnknownAsset(asset);
    }

    /// @dev The last point's timestamp.
    function _lastTime() internal view returns (uint64) {
        return _times[_times.length - 1];
    }

    /// @dev Attributes `growth` (units per asset, found since the last point) to the stretch from the last point to
    ///      now, over `locked` revenue tokens: a new point at this timestamp whose index is the last one plus
    ///      `(growth x SCALE + carry) / locked`, the remainder carried. With nothing locked the whole amount is
    ///      carried and the index stays flat. A settle in the same second as the last point has no stretch of its
    ///      own: what it found waits in the carry for the next stretch, and the point stays as it was, so nothing
    ///      that was read off the line at that second (a lock's start, a holder's checkpoint) ever moves.
    function _attribute(uint256[MAX_ASSETS] memory growth, uint256 locked) internal {
        uint256 n = _assetCount;
        uint256 last = _times.length - 1;
        uint64 now_ = uint64(block.timestamp);
        if (now_ <= _times[last]) {
            for (uint256 i; i < n; ++i) {
                if (growth[i] != 0) _carry[i] += growth[i] * SCALE;
            }
            return;
        }
        _times.push(now_);
        uint256 k = last + 1;
        for (uint256 i; i < n; ++i) {
            uint256 idx = _indexAt[i][last];
            uint256 carried = _carry[i];
            uint256 total = growth[i] * SCALE + carried;
            if (locked == 0) {
                if (growth[i] != 0) _carry[i] = total;
            } else if (total != 0) {
                uint256 delta = total / locked;
                uint256 rest = total - delta * locked;
                if (rest != carried) _carry[i] = rest;
                if (delta != 0) {
                    idx += delta;
                    emit IncomeAttributed(i, (total - rest) / SCALE, idx);
                }
            }
            _indexAt[i][k] = idx;
        }
        emit Settled(now_, locked);
    }

    /// @dev Every asset's index at `t`, read off the settled line: zero before the first point, flat after the last.
    function _lineAt(uint64 t) internal view returns (uint256[MAX_ASSETS] memory g) {
        uint256 n = _assetCount;
        uint256 last = _times.length - 1;
        if (t >= _times[last]) {
            for (uint256 i; i < n; ++i) {
                g[i] = _indexAt[i][last];
            }
            return g;
        }
        if (t < _times[0]) return g;
        uint256 k = _locate(t);
        uint64 tk = _times[k];
        if (t == tk) {
            for (uint256 i; i < n; ++i) {
                g[i] = _indexAt[i][k];
            }
            return g;
        }
        uint64 tn = _times[k + 1];
        for (uint256 i; i < n; ++i) {
            uint256 gk = _indexAt[i][k];
            g[i] = gk + Math.mulDiv(_indexAt[i][k + 1] - gk, t - tk, tn - tk);
        }
    }

    /// @dev Every asset's index at `t` on the line extended by a virtual point at this timestamp, `nowIndex` (what a
    ///      settle now would write): the settled line up to the last point, a straight line from there to now.
    function _lineAtPreview(uint64 t, uint256[MAX_ASSETS] memory nowIndex)
        internal
        view
        returns (uint256[MAX_ASSETS] memory g)
    {
        uint64 lastT = _lastTime();
        if (t <= lastT) return _lineAt(t);
        uint64 now_ = uint64(block.timestamp);
        if (t >= now_) return nowIndex;
        g = _lineAt(lastT);
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            g[i] += Math.mulDiv(nowIndex[i] - g[i], t - lastT, now_ - lastT);
        }
    }

    /// @dev The largest `k` with `_times[k] <= t`, for `_times[0] <= t < _times[last]`.
    function _locate(uint64 t) private view returns (uint256 low) {
        uint256 high = _times.length - 1;
        while (high - low > 1) {
            uint256 mid = (low + high) >> 1;
            if (_times[mid] <= t) low = mid;
            else high = mid;
        }
    }

    /// @dev Day `day`'s per-unit index in every asset from the settled line, and whether it is final (the day ended
    ///      at or before the last point). Zero for a day that had not started at the last point.
    function _dayLine(uint256 day) private view returns (uint256[MAX_ASSETS] memory u, bool isFinal) {
        uint64 lastT = _lastTime();
        uint256 start = HookrDays.startOf(day);
        if (start >= lastT) return (u, false);
        uint256 end = HookrDays.endOf(day);
        isFinal = end <= lastT;
        uint256[MAX_ASSETS] memory a = _lineAt(uint64(start));
        uint256[MAX_ASSETS] memory b = _lineAt(uint64(end));
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            u[i] = b[i] - a[i];
        }
    }

    /// @dev Day `day`'s per-unit index in every asset as the settled line has it, cached once final. For the paths
    ///      that write (transfers, mints, claims).
    function _dayIndexes(uint256 day) internal returns (uint256[MAX_ASSETS] memory u) {
        if (day > FOREVER) revert InvalidDay(day);
        if (_final[day]) return _finalIndex[day];
        bool isFinal;
        (u, isFinal) = _dayLine(day);
        if (isFinal) {
            _final[day] = true;
            uint256 n = _assetCount;
            for (uint256 i; i < n; ++i) {
                if (u[i] != 0) _finalIndex[day][i] = u[i];
            }
        }
    }

    /// @dev `_dayIndexes` without the cache write, for views that read the settled line.
    function _dayIndexesSettled(uint256 day) internal view returns (uint256[MAX_ASSETS] memory u) {
        if (day > FOREVER) revert InvalidDay(day);
        if (_final[day]) return _finalIndex[day];
        (u,) = _dayLine(day);
    }

    /// @dev Day `day`'s per-unit index in every asset on the line extended to now by `nowIndex`: what a settle now
    ///      would make it.
    function _dayIndexesPreview(uint256 day, uint256[MAX_ASSETS] memory nowIndex)
        internal
        view
        returns (uint256[MAX_ASSETS] memory u)
    {
        if (day > FOREVER) revert InvalidDay(day);
        if (_final[day]) return _finalIndex[day];
        uint256 start = HookrDays.startOf(day);
        if (start >= block.timestamp) return u;
        uint256[MAX_ASSETS] memory a = _lineAtPreview(uint64(start), nowIndex);
        uint256[MAX_ASSETS] memory b = _lineAtPreview(uint64(HookrDays.endOf(day)), nowIndex);
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            u[i] = b[i] - a[i];
        }
    }
}
