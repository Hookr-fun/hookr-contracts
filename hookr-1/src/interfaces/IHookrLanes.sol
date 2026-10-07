// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrLanes
/// @notice The registry's recapture lane for one root: the partner executor a new recapture pool of the root freezes,
///         pinned to its runtime codehash, with the share of each arb recapture the partner keeps; and, for every
///         executor opened on the root, one live switch that the root reads on each swap of a pool that froze it: on
///         or off, and the gas every lane call gets. A lane opens through the registry timelock, as a queued `OPEN_LANE`
///         operation (`keccak256("OPEN_LANE")`) executed with `openLaneOf`, which also turns the executor's switch on at
///         the opening's gas cap. Brakes act at once: `closeLaneOf` closes the lane to new pools, `stopExecutorLane`
///         switches an executor off on every pool that froze it, and `tuneExecutorLane` lowers its gas. Switching an
///         executor back on, and raising its gas, is a queued `LANE_ON` operation (`keccak256("LANE_ON")`) executed
///         with `startExecutorLaneAt`.
/// @dev A root that reads its lane freezes the executor, its codehash and the partner share per pool when the pool
///      opens, so a later opening or close never reaches a pool already open and no brake can point a pool at another
///      executor. Only the executor's switch reaches open pools, and it can only skip or shrink their arb recaptures.
///      An owned root (IHookrOwnedRoots) takes its template's open lane at registration with the switch off and the
///      registration as its last brake (`ExecutorLaneSet(root, executor, false, gasCap, factory)`): `activeLaneOf` reads
///      empty for it, so it opens no pool with arb recapture, and none of its pools pays the lane's gas floor, until a
///      timelocked `LANE_ON` or `OPEN_LANE` queued after the registration starts its lane.
interface IHookrLanes {
    /// @notice A queued `OPEN_LANE` operation gave `root` the lane `executor`, pinned to the runtime codehash
    ///         `codeHash`, with `gasCap` gas per lane call and a partner share of `partnerBps`. It replaces any
    ///         earlier lane of `root` for new pools.
    /// @param root The root.
    /// @param executor The partner executor.
    /// @param codeHash The executor's pinned runtime codehash.
    /// @param gasCap The gas each lane call gets.
    /// @param partnerBps The partner's share of each arb recapture, in basis points.
    event LaneOpened(
        address indexed root, address indexed executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps
    );

    /// @notice A brake closed `root`'s lane to new pools. Openings queued before it can no longer execute.
    /// @param root The root.
    /// @param by The owner or guardian that closed the lane.
    event LaneClosed(address indexed root, address indexed by);

    /// @notice `executor`'s switch on `root` is now `on` with `gasCap` gas per lane call, set by `by`: an opening, a
    ///         switch-on, or a brake (off, or a lowered cap).
    /// @param root The root.
    /// @param executor The executor.
    /// @param on Whether the switch is on.
    /// @param gasCap The gas each lane call gets.
    /// @param by The account that set the switch.
    event ExecutorLaneSet(address indexed root, address indexed executor, bool on, uint32 gasCap, address indexed by);

    /// @notice `currency` joined (`added`) or left the recapture settlement set, by `by`: a queued `ADD_SETTLEMENT`
    ///         operation (`keccak256("ADD_SETTLEMENT")`, arguments `abi.encode(currency)`) or a brake. Zero is native
    ///         ETH.
    /// @param currency The currency; zero is native ETH.
    /// @param added True when the currency joined the set, false when it left.
    /// @param by The account that changed the set.
    event SettlementCurrencySet(address indexed currency, bool added, address indexed by);

    /// @notice The recapture settlement set: the currencies, besides a pool's own two, in which every lane executor may
    ///         push an arb recapture (IHookrLaneRoot.settleRecapture). Native ETH (zero), WETH and USDG at genesis; at
    ///         most 8. Additions are timelocked; a brake removes a member at once.
    /// @return The currencies in the settlement set.
    function settlementCurrencies() external view returns (address[] memory);

    /// @notice Whether `currency` is in the recapture settlement set.
    /// @param currency The currency.
    /// @return True when the currency is in the settlement set.
    function isSettlementCurrency(address currency) external view returns (bool);

    /// @notice Returns `root`'s open lane for new pools, or zeros when it has none: never opened, closed, the
    ///         executor's runtime codehash differs from the pinned one, or its switch is off.
    /// @dev A nonzero lane's executor held non-delegated code with that codehash, `gasCap` is the executor's live cap
    ///      (50,000 to 5,000,000) and `partnerBps` is at most 2,500, each checked when the opening was queued and
    ///      again when it executed. The executor's own `partnerBps()` is never read.
    /// @param root The root whose lane to read.
    /// @return executor The partner executor, or zero.
    /// @return codeHash The executor's pinned runtime codehash, or zero.
    /// @return gasCap The gas every lane call receives, or zero.
    /// @return partnerBps The partner's share of each arb recapture in basis points, or zero.
    function activeLaneOf(address root)
        external
        view
        returns (address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps);

    /// @notice Returns `executor`'s live switch on `root`: whether pools of the root that froze it recapture, and the
    ///         gas each lane call gets. Read by the root once per swap of such a pool. Zeros for an executor never
    ///         opened on the root.
    /// @param root The root.
    /// @param executor The executor.
    /// @return on Whether pools that froze the executor recapture.
    /// @return gasCap The gas each lane call gets.
    function executorLane(address root, address executor) external view returns (bool on, uint32 gasCap);
}
