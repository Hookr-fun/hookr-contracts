// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueDoor} from "../interfaces/IHookrRevenueDoor.sol";
import {IHookrDropBox} from "../interfaces/IHookrDropBox.sol";
import {IHookrDoorTerm} from "../interfaces/IHookrDoorTerm.sol";
import {IHookrRulesDoor} from "../interfaces/IHookrRulesDoor.sol";
import {IHookrFeebAdapter} from "../interfaces/IHookrFeebAdapter.sol";
import {IHookrFamilyForwarder} from "../interfaces/IHookrFamilyForwarder.sol";
import {IHookrPositionBundle} from "../interfaces/IHookrPositionBundle.sol";
import {IHookrRevenueTokenDoor} from "../interfaces/IHookrRevenueTokenDoor.sol";
import {IPositionManagerDoor} from "../interfaces/IPositionManagerDoor.sol";
import {IHookrPositionNftDoor} from "../interfaces/IHookrPositionNftDoor.sol";
import {IHookrV3PositionNftDoor} from "../interfaces/IHookrV3PositionNftDoor.sol";
import {IHookrRevenueSource} from "../interfaces/IHookrRevenueSource.sol";
import {INonfungiblePositionManagerDoor} from "../interfaces/external/INonfungiblePositionManagerDoor.sol";
import {IUniswapV3FactoryPools} from "../interfaces/external/IUniswapV3FactoryPools.sol";
import {IUniswapV3PoolFees} from "../interfaces/external/IUniswapV3PoolFees.sol";
import {IFeeSplitter} from "../interfaces/external/IFeeSplitter.sol";
import {IHookrFeebAdapterFactory} from "../interfaces/IHookrFeebAdapterFactory.sol";
import {IHookrPositionNftDoorFactory} from "../interfaces/IHookrPositionNftDoorFactory.sol";
import {IHookrV3PositionNftDoorFactory} from "../interfaces/IHookrV3PositionNftDoorFactory.sol";
import {IHookrRevenueTokenDoorFactory} from "../interfaces/IHookrRevenueTokenDoorFactory.sol";
import {IHookrPonsAdapterFactory} from "../interfaces/IHookrPonsAdapterFactory.sol";
import {IHookrDopplerAdapterFactory} from "../interfaces/IHookrDopplerAdapterFactory.sol";
import {IHookrRevenueTokenizerSourcePins} from "../interfaces/IHookrRevenueTokenizerSourcePins.sol";
import {EndKind} from "../types/EndKind.sol";
import {HookrRevenueStreamEnds} from "../libraries/HookrRevenueStreamEnds.sol";
import {HookrV3Fees} from "../libraries/HookrV3Fees.sol";

/// @title Hookr revenue state view
/// @notice One call for what an app shows about a revenue token: its terms and listed assets, a page of its doors with
///         each one's kind, leg, live end and whether it is the tokenizer's own, and for a holder its claimable income
///         in every asset and a page of the drops it can claim.
/// @dev Read-only and stateless, as Uniswap's StateView: every figure is read from the token, its drop box, its doors
///      and the tokenizer at the moment of the call. A source's end and pending income, and every read of a v3
///      position's manager, factory and pool, are made within a gas cap and checked for shape, so a source or a pool
///      that does not answer reads `ENDED` or unread and never takes the view down.
contract HookrRevenueStateView {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice A sync transaction's own cost before its first door: the intrinsic 21,000 and the calldata of
    ///         `syncRange` (68 bytes, all counted nonzero), then the entry, the reentrancy lock, the `live` read and
    ///         the door count. A rollup's data fee comes on top.
    uint256 public constant SYNC_BASE_GAS = 30_000;
    /// @notice What a sync spends on each door outside its stipend: the door's load, the gas check, the call to an
    ///         account not yet touched, the `DoorPulled` event and the memory each door takes.
    uint256 public constant DOOR_GAS = 9_000;
    /// @notice What a sync spends outside the stipend on each call a RULES door's asset takes (a `claimable` read
    ///         and a `claim`), and on each balance read of a listed ERC-20 around a legged door's pull.
    uint256 public constant CALL_GAS = 1_000;
    /// @notice What a leg payment costs outside the token's `LEG_GAS`: the leg's math, the `transfer` calldata, the call and
    ///         the `LegPaid` event.
    uint256 public constant LEG_PAYMENT_GAS = 2_500;
    /// @notice What the leg in native ETH costs on top: the call's value transfer.
    uint256 public constant NATIVE_LEG_GAS = 9_000;
    /// @notice What a leg in native ETH can spend inside the token's `LEG_GAS` when the token's leg collector is the
    ///         tokenizer's own HookrLegCollector, whose `receive` is empty; any other collector is priced at the whole
    ///         `LEG_GAS`. An ERC-20's leg is always priced at `LEG_GAS`: its `transfer` is the asset's own code, and a
    ///         revenue token's can need nearly all of it.
    uint256 public constant COLLECTOR_RECEIVE_GAS = 5_000;
    /// @notice What the first touch of each listed asset costs a page that reads them: its slot and, for an ERC-20,
    ///         its account; the leg collector's account counts as one more.
    uint256 public constant ASSET_TOUCH_GAS = 4_700;
    /// @notice What the end of a sync spends on each listed asset outside its balance read: the recognition, the first
    ///         writes of the asset's two ledger slots and `IncomeRecognized`.
    uint256 public constant RECOGNITION_GAS = 55_000;
    /// @notice What the end of a sync spends once: the tip and the bridge slice, each a native transfer to an account
    ///         that takes ETH plainly, and `Synced`.
    uint256 public constant SETTLE_GAS = 40_000;
    /// @notice Gas each read of a v3 position's manager, factory or pool gets.
    uint256 public constant V3_READ_GAS = 100_000;
    /// @dev The same balance-read cap the position doors use before forwarding a held currency.
    uint256 internal constant POSITION_BALANCE_GAS = 50_000;
    /// @notice Gas a source's `pendingIncome` gets.
    uint256 public constant SOURCE_INCOME_GAS = 500_000;
    /// @notice The most currencies a source's `pendingIncome` answer may name to be read.
    uint256 public constant MAX_SOURCE_CURRENCIES = 8;

    /// @notice A token's terms, accounting and record.
    struct TokenState {
        string name;
        string symbol;
        uint256 supply;
        uint256 earningSupply;
        uint32 streamSeconds;
        uint16 tipBps;
        bytes32 termsHash;
        bool live;
        bool openStreams;
        address streamManager;
        address pendingStreamManager;
        address bridge;
        uint16 bridgeBps;
        address dropBox;
        address legCollector;
        uint256 doorCount;
        uint256 streamCount;
        IHookrRevenueTokenizer.Tokenization record;
        IHookrRevenueToken.Asset[] assets;
    }

    /// @notice One door as the app shows it.
    /// @param firstParty Whether the door is the tokenizer's own make: an admitted Rules, the token's forwarder, a door
    ///        of one of its factories, or a source made by the pinned Pons or Doppler adapter factory.
    struct DoorState {
        uint256 index;
        IHookrRevenueToken.DoorKind kind;
        address target;
        uint32 gas;
        uint16 legBps;
        EndKind endKind;
        uint64 end;
        bool firstParty;
    }

    /// @notice One stream as the app shows it, with its door, who gets the right back and what it has earned that a
    ///         pull would deliver.
    /// @param record The tokenizer's record, its end read live.
    /// @param doorIndex The token's door the stream goes through.
    /// @param gas The door's stipend.
    /// @param returnTo Who gets the right back at the end of its term, or zero (a Rules ledger, a source).
    /// @param pendingRead Whether `pending` was read: false for a source whose `pendingIncome` does not answer in
    ///        shape within its cap, and for a position door when a held balance cannot be read, or a v3 manager,
    ///        factory or pool cannot be read; their
    ///        `pending` is empty, never zeros.
    /// @param pending Per listed asset, in the token's order: income waiting at the right or door, before Hookr's leg.
    ///        A paged pull may collect or forward only part. A position door's figure includes its already collected
    ///        balances once, plus its held positions' uncollected fees: on v4 before any hook's take on removal,
    ///        on v3 what the manager's
    ///        `collect` would pay now. A v3 door's held and uncollected wrapped native are counted as ETH, never as
    ///        the wrapper too. A FEEB adapter's is its held ETH plus, while it holds the NFT, the vault's pending ETH
    ///        and the vault's share of what the fee
    ///        splitter's collect would pay out now (its ETH and the position's uncollected native fees, before any
    ///        hook's take on removal); a basket's is the native ETH the door holds, the inner token's claimable income
    ///        and the door's share of the inner drops its next pull visits, its native figure net of the sync's tip and
    ///        Fee Bridge slice (`holderShareOfPulledEth`), so with no leg on a basket door it is what the holders
    ///        gain; a source's is its own `pendingIncome`. A currency the token does not list is not counted, and the token itself is
    ///        never listed: the fees on its own side of a position (a pool pairing the token, such as its market) go
    ///        to 0xdead or stay with the position, never to the holders.
    struct StreamState {
        uint256 index;
        IHookrRevenueTokenizer.StreamRecord record;
        uint256 doorIndex;
        uint32 gas;
        address returnTo;
        bool pendingRead;
        uint256[] pending;
    }

    /// @notice One page of a sync plan: doors `start` to `start + count - 1`, whose worst case is `gas`.
    /// @param gas The gas limit of a `syncRange(start, count)` transaction that pulls the page even when every door
    ///        burns its whole stipend.
    /// @param overBudget Whether this one door alone needs more than the budget asked for.
    struct SyncPage {
        uint256 start;
        uint256 count;
        uint256 gas;
        bool overBudget;
    }

    /// @notice A holder's position.
    struct HolderState {
        uint256 balance;
        uint256[] claimable;
        uint256 dropCount;
    }

    /// @notice A drop the holder can claim now.
    struct DropState {
        uint256 dropId;
        address asset;
        uint256 claimable;
    }

    /// @notice The tokenizer whose tokens this view reads.
    IHookrRevenueTokenizer public immutable tokenizer;

    constructor(IHookrRevenueTokenizer tokenizer_) {
        tokenizer = tokenizer_;
    }

    /// @notice `token`'s terms, accounting, every listed asset and the tokenizer's record of it.
    function tokenState(address token) external view returns (TokenState memory s) {
        IHookrRevenueToken t = IHookrRevenueToken(token);
        s.name = IERC20Metadata(token).name();
        s.symbol = IERC20Metadata(token).symbol();
        s.supply = t.totalSupply();
        s.earningSupply = t.earningSupply();
        s.streamSeconds = t.streamSeconds();
        s.tipBps = t.tipBps();
        s.termsHash = t.termsHash();
        s.live = t.live();
        s.openStreams = t.openStreams();
        s.streamManager = t.streamManager();
        s.pendingStreamManager = t.pendingStreamManager();
        s.bridge = t.bridge();
        s.bridgeBps = t.bridgeBps();
        s.dropBox = t.dropBox();
        s.legCollector = t.legCollector();
        s.doorCount = t.doorCount();
        s.streamCount = tokenizer.streamCount(token);
        s.record = tokenizer.tokenizations(token);
        uint256 n = t.assetCount();
        s.assets = new IHookrRevenueToken.Asset[](n);
        for (uint256 i; i < n; ++i) {
            s.assets[i] = t.assetAt(i);
        }
    }

    /// @notice Up to `count` of `token`'s doors from `start`, each with its live end.
    function doorsPage(address token, uint256 start, uint256 count) external view returns (DoorState[] memory out) {
        IHookrRevenueToken.Door[] memory list = IHookrRevenueToken(token).doors(start, count);
        address forwarder = tokenizer.tokenizations(token).forwarder;
        out = new DoorState[](list.length);
        for (uint256 i; i < list.length; ++i) {
            IHookrRevenueToken.Door memory d = list[i];
            DoorState memory s = out[i];
            s.index = start + i;
            s.kind = d.kind;
            s.target = d.target;
            s.gas = d.gas;
            s.legBps = d.legBps;
            (s.endKind, s.end) = _ends(d);
            s.firstParty = _firstParty(d, forwarder);
        }
    }

    /// @notice Up to `count` of `token`'s streams from `start`, each with its door, stipend, return address and pending
    ///         income per listed asset; and the listed assets the figures are in.
    function streamsPage(address token, uint256 start, uint256 count)
        external
        view
        returns (Currency[] memory assets, StreamState[] memory out)
    {
        IHookrRevenueToken t = IHookrRevenueToken(token);
        uint256 n = t.assetCount();
        assets = new Currency[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = t.assetAt(i).currency;
        }
        IHookrRevenueTokenizer.StreamRecord[] memory records = tokenizer.streams(token, start, count);
        out = new StreamState[](records.length);
        for (uint256 i; i < records.length; ++i) {
            StreamState memory s = out[i];
            s.index = start + i;
            s.record = records[i];
            s.doorIndex = t.doorIndexOf(records[i].door);
            s.gas = t.doorAt(s.doorIndex).gas;
            _fill(token, s, assets);
        }
    }

    /// @notice Doors `start` to `start + count - 1` of `token`, grouped in order into pages a sync transaction of
    ///         `gasBudget` can pull. A page's figure is its worst case, every door burning its whole stipend: the
    ///         transaction's own `SYNC_BASE_GAS`; each door's stipend (a RULES door's one read and one claim per listed
    ///         asset, each at its stipend) and `DOOR_GAS`; around a legged door's pull, each listed ERC-20's balance
    ///         read twice at the token's `BALANCE_GAS` and a leg payment per listed asset at `LEG_GAS` (native ETH's at
    ///         `COLLECTOR_RECEIVE_GAS` when the leg collector is the tokenizer's own); the first touch
    ///         of the listed assets; then the larger of two: the token's `SYNC_RESERVE_GAS`, which the token must
    ///         still have before the page's last door, or what the sync spends after that door's pull (its balance
    ///         reads and leg payments, then the end of the sync: each listed ERC-20's balance read at `BALANCE_GAS`,
    ///         `RECOGNITION_GAS` per listed asset and `SETTLE_GAS`). A door that alone exceeds the budget gets a page of
    ///         its own, marked. Paged, so its cost follows `count`, not the token's door count.
    /// @dev The token checks `stipend + SYNC_RESERVE_GAS` before every call to a door, and of those the last door's
    ///      check binds, since every door before it has spent its whole cost by then; when what the sync spends after
    ///      that door's pull is more than the reserve, that spend binds instead.
    function syncPlan(address token, uint256 gasBudget, uint256 start, uint256 count)
        external
        view
        returns (SyncPage[] memory pages)
    {
        IHookrRevenueToken t = IHookrRevenueToken(token);
        IHookrRevenueToken.Door[] memory doors = t.doors(start, count);
        uint256 assetsN = t.assetCount();
        uint256 reserve = t.SYNC_RESERVE_GAS();
        uint256 touch = assetsN * ASSET_TOUCH_GAS + ASSET_TOUCH_GAS;
        uint256 balanceGas = t.BALANCE_GAS();
        uint256 legGas = t.LEG_GAS();
        uint256 nativeLegGas = _nativeLegGas(t, legGas);
        uint256 settle = (assetsN - 1) * (balanceGas + CALL_GAS) + assetsN * RECOGNITION_GAS + SETTLE_GAS + touch;
        SyncPage[] memory all = new SyncPage[](doors.length);
        uint256 p;
        uint256 spent;
        bool touched;
        for (uint256 i; i < doors.length; ++i) {
            (uint256 cost, uint256 tail, bool reads) = _doorCost(doors[i], assetsN, balanceGas, legGas, nativeLegGas);
            bool pageReads = touched || reads;
            uint256 gas = SYNC_BASE_GAS + spent + _last(cost, tail, pageReads ? touch : 0, reserve, settle);
            if (p != 0 && gas <= gasBudget && !all[p - 1].overBudget) {
                all[p - 1].count += 1;
                all[p - 1].gas = gas;
            } else {
                (spent, pageReads) = (0, reads);
                gas = SYNC_BASE_GAS + _last(cost, tail, reads ? touch : 0, reserve, settle);
                all[p++] = SyncPage(start + i, 1, gas, gas > gasBudget);
            }
            spent += cost;
            touched = pageReads;
        }
        pages = new SyncPage[](p);
        for (uint256 i; i < p; ++i) {
            pages[i] = all[i];
        }
    }

    /// @dev What a page's last door adds to its figure: its cost up to its pull, the first touch of the assets when
    ///      the page reads them and the reserve the token checks for before it, or, when more, its whole cost and the
    ///      end of the sync (`settle`, which touches every listed asset itself).
    function _last(uint256 cost, uint256 tail, uint256 touch, uint256 reserve, uint256 settle)
        private
        pure
        returns (uint256)
    {
        uint256 checked = cost - tail + touch + reserve;
        uint256 spends = cost + settle;
        return checked > spends ? checked : spends;
    }

    /// @dev What door `d` costs a sync at most when it burns its whole stipend (`cost`); the part of it after its pull
    ///      (`tail`: a legged door's balance reads and leg payments), which the reserve carries when the door is a
    ///      page's last; and whether it reads the listed assets (a RULES or a legged door). Native ETH, always asset
    ///      0, is read without a call, and its leg spends at most `nativeLegGas` (`_nativeLegGas`).
    function _doorCost(
        IHookrRevenueToken.Door memory d,
        uint256 assetsN,
        uint256 balanceGas,
        uint256 legGas,
        uint256 nativeLegGas
    ) private pure returns (uint256 cost, uint256 tail, bool reads) {
        if (d.kind == IHookrRevenueToken.DoorKind.RULES) {
            return (DOOR_GAS + 2 * assetsN * (uint256(d.gas) + CALL_GAS), 0, true);
        }
        cost = DOOR_GAS + d.gas;
        if (d.legBps == 0) return (cost, 0, false);
        uint256 balanceReads = (assetsN - 1) * (balanceGas + CALL_GAS);
        tail =
            balanceReads + (assetsN - 1) * (legGas + LEG_PAYMENT_GAS) + nativeLegGas + LEG_PAYMENT_GAS + NATIVE_LEG_GAS;
        return (cost + balanceReads + tail, tail, true);
    }

    /// @dev What a native leg can spend inside its `LEG_GAS` cap: `COLLECTOR_RECEIVE_GAS` when `t`'s leg collector is
    ///      this view's tokenizer's own (an empty `receive`, read from the tokenizer within `V3_READ_GAS`), the whole
    ///      `legGas` for any other collector or when the tokenizer does not answer.
    function _nativeLegGas(IHookrRevenueToken t, uint256 legGas) private view returns (uint256) {
        (bool ok, bytes memory ret) = _read(address(tokenizer), abi.encodeCall(IHookrRevenueTokenizer.collector, ()), 1);
        if (ok && _word(ret, 0) == uint256(uint160(t.legCollector())) && COLLECTOR_RECEIVE_GAS < legGas) {
            return COLLECTOR_RECEIVE_GAS;
        }
        return legGas;
    }

    /// @notice `holder`'s balance, claimable income in every listed asset, and how many drops the box has.
    function holderState(address token, address holder) external view returns (HolderState memory s) {
        IHookrRevenueToken t = IHookrRevenueToken(token);
        s.balance = t.balanceOf(holder);
        uint256 n = t.assetCount();
        s.claimable = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            s.claimable[i] = t.claimable(holder, i);
        }
        s.dropCount = IHookrDropBox(t.dropBox()).dropCount();
    }

    /// @notice The drops among ids `start` to `start + count - 1` that `holder` can claim now, with the amount.
    function openDrops(address token, address holder, uint256 start, uint256 count)
        external
        view
        returns (DropState[] memory out)
    {
        IHookrDropBox box = IHookrDropBox(IHookrRevenueToken(token).dropBox());
        uint256 n = box.dropCount();
        if (start >= n) return out;
        if (count > n - start) count = n - start;
        DropState[] memory all = new DropState[](count);
        uint256 k;
        for (uint256 i; i < count; ++i) {
            uint256 id = start + i;
            uint256 amount = box.claimable(id, holder);
            if (amount == 0) continue;
            all[k++] = DropState(id, box.dropAt(id).asset, amount);
        }
        out = new DropState[](k);
        for (uint256 i; i < k; ++i) {
            out[i] = all[i];
        }
    }

    /// @dev The return address and pending income of stream `s`.
    function _fill(address token, StreamState memory s, Currency[] memory assets) private view {
        IHookrRevenueTokenizer.StreamKind kind = s.record.kind;
        address door = s.record.door;
        if (kind == IHookrRevenueTokenizer.StreamKind.SOURCE) {
            _sourcePending(door, s, assets);
            return;
        }
        if (
            kind == IHookrRevenueTokenizer.StreamKind.POSITIONS_V3
                || kind == IHookrRevenueTokenizer.StreamKind.POSITIONS
        ) {
            s.returnTo = IHookrDoorTerm(door).returnTo();
            uint256[] memory pending = new uint256[](assets.length);
            bool read = kind == IHookrRevenueTokenizer.StreamKind.POSITIONS_V3
                ? _v3PositionsPending(door, pending, assets)
                : _positionsPending(door, pending, assets);
            if (read) (s.pendingRead, s.pending) = (true, pending);
            return;
        }
        s.pendingRead = true;
        s.pending = new uint256[](assets.length);
        if (kind == IHookrRevenueTokenizer.StreamKind.RULES) {
            for (uint256 a; a < assets.length; ++a) {
                s.pending[a] = IHookrRulesDoor(door).claimable(assets[a], token);
            }
        } else if (kind == IHookrRevenueTokenizer.StreamKind.FAMILY || kind == IHookrRevenueTokenizer.StreamKind.MARKET)
        {
            _familyPending(s, assets);
        } else if (kind == IHookrRevenueTokenizer.StreamKind.FEEB) {
            s.returnTo = IHookrDoorTerm(door).returnTo();
            s.pending[0] = _feebPending(IHookrFeebAdapter(door));
        } else {
            s.returnTo = IHookrDoorTerm(door).returnTo();
            _basketPending(token, IHookrRevenueTokenDoor(door), s.pending, assets);
        }
    }

    /// @dev A basket door's held native ETH (its next pull forwards it first), its inner income and its share of the
    ///      inner drops its next pull visits: from its drop cursor, at most `DROPS_PER_PULL` of them, each credited to
    ///      the drop's asset (a pull leaves drops in currencies the token does not list, which `_credit` skips too).
    ///      The native figure is then taken net of the sync's tip and bridge slice (`holderShareOfPulledEth`); a
    ///      basket door has no leg, so the figure is what the holders gain.
    function _basketPending(
        address token,
        IHookrRevenueTokenDoor door,
        uint256[] memory pending,
        Currency[] memory assets
    ) private view {
        _credit(pending, assets, Currency.wrap(address(0)), address(door).balance);
        IHookrRevenueToken inner = IHookrRevenueToken(door.inner());
        uint256 m = inner.assetCount();
        for (uint256 j; j < m; ++j) {
            _credit(pending, assets, inner.assetAt(j).currency, inner.claimable(address(door), j));
        }
        IHookrDropBox box = IHookrDropBox(door.innerDropBox());
        uint256 id = door.dropCursor();
        uint256 end = id + door.DROPS_PER_PULL();
        uint256 n = box.dropCount();
        if (end > n) end = n;
        for (; id < end; ++id) {
            uint256 owed = box.claimable(id, address(door));
            if (owed != 0) _credit(pending, assets, Currency.wrap(box.dropAt(id).asset), owed);
        }
        if (assets.length != 0 && assets[0].isAddressZero()) pending[0] = holderShareOfPulledEth(token, pending[0]);
    }

    /// @notice What `token`'s holders keep of `eth` native ETH a sync pulls: less the sync caller's tip (`tipBps`, only
    ///         from `MIN_TIP_PULL`), then less the Fee Bridge's `bridgeBps` of the rest, as the token's sync takes them
    ///         (Hookr's leg, where a door has one, comes off before this). Figured as if `eth` were the sync's whole
    ///         native pull: a sync of several doors tips on their sum, so doors each below `MIN_TIP_PULL` can still
    ///         pay a tip together.
    function holderShareOfPulledEth(address token, uint256 eth) public view returns (uint256) {
        IHookrRevenueToken t = IHookrRevenueToken(token);
        if (eth >= t.MIN_TIP_PULL()) eth -= FullMath.mulDiv(eth, t.tipBps(), 10_000);
        if (t.bridge() != address(0)) eth -= FullMath.mulDiv(eth, t.bridgeBps(), 10_000);
        return eth;
    }

    /// @dev A family's uncollected fees, member by member, as its forwarder reads them, for the family's own
    ///      registration (`StreamRecord.family`). The forwarder's first registration (index 0) also carries, once per
    ///      forwarder, what the next pull forwards from the forwarder itself: its balance of each listed currency on
    ///      its own list (`currencies()`: native ETH and its families' pool currencies, the only ones a pull forwards;
    ///      a released family's final collection waits there) and its own Rules credit over `rulesCredits`. A listed
    ///      currency off that list that someone sends the forwarder is not counted: no pull delivers it, and
    ///      `dropStray` moves it to the drop box. A failed or malformed balance read leaves that stream unread.
    function _familyPending(StreamState memory s, Currency[] memory assets) private view {
        IHookrFamilyForwarder forwarder = IHookrFamilyForwarder(s.record.door);
        uint256 index = s.record.family;
        IHookrFamilyForwarder.Family memory f = forwarder.familyAt(index);
        s.returnTo = f.returnTo;
        if (index == 0) {
            if (!_positionHeld(address(forwarder), forwarder.currencies(), address(0), s.pending, assets)) {
                (s.pendingRead, s.pending) = (false, new uint256[](0));
                return;
            }
            IHookrFamilyForwarder.RulesCredit[] memory credits = forwarder.rulesCredits();
            for (uint256 k; k < credits.length; ++k) {
                Currency c = credits[k].currency;
                _credit(s.pending, assets, c, IHookrRulesDoor(credits[k].rules).claimable(c, address(forwarder)));
            }
        }
        if (f.released) return;
        IHookrLauncher launcher = IHookrLauncher(forwarder.launcher());
        uint8 members = launcher.memberCount(f.id);
        for (uint8 m; m < members; ++m) {
            PoolKey memory key = launcher.position(f.id, m).key;
            (uint256 amount0, uint256 amount1) = forwarder.pendingFees(index, m);
            _credit(s.pending, assets, key.currency0, amount0);
            _credit(s.pending, assets, key.currency1, amount1);
        }
    }

    /// @dev The door's held balances once, then every position it still holds: fees inside its range since its last
    ///      collection, read from the PoolManager (the PositionManager owns the position, salted by the id).
    function _positionsPending(address door, uint256[] memory pending, Currency[] memory assets)
        private
        view
        returns (bool)
    {
        IHookrPositionBundle bundle = IHookrPositionBundle(door);
        if (!_positionHeld(door, bundle.assets(), address(0), pending, assets)) return false;
        IPositionManagerDoor posm = IHookrPositionNftDoor(door).positionManager();
        IPoolManager manager = IPoolManager(posm.poolManager());
        uint256[] memory ids = bundle.tokenIds();
        for (uint256 i; i < ids.length; ++i) {
            if (bundle.releasedOf(ids[i])) continue;
            (PoolKey memory key, uint256 fee0, uint256 fee1) = _v4Fees(posm, manager, ids[i]);
            if (!_positionCredit(pending, assets, key.currency0, fee0)) return false;
            if (!_positionCredit(pending, assets, key.currency1, fee1)) return false;
        }
        return true;
    }

    /// @dev Balances a position door's pull forwards, once per door rather than once per NFT. Only listed currencies
    ///      in the door's own currency list count. A v3 door always unwraps its wrapper into native ETH, even when no
    ///      pool uses it; the wrapper is never also counted as a listed ERC-20. Failed or malformed capped reads and
    ///      sums past uint256 leave the whole figure unread.
    function _positionHeld(
        address door,
        address[] memory currencies,
        address wrapped,
        uint256[] memory pending,
        Currency[] memory assets
    ) private view returns (bool) {
        for (uint256 a; a < assets.length; ++a) {
            address asset = Currency.unwrap(assets[a]);
            if (asset == address(0)) {
                uint256 held = door.balance;
                if (wrapped != address(0)) {
                    (bool ok, bytes memory ret) =
                        _call(wrapped, abi.encodeCall(IERC20.balanceOf, (door)), POSITION_BALANCE_GAS, 32);
                    if (!ok || ret.length != 32) return false;
                    uint256 amount = _word(ret, 0);
                    if (amount > type(uint256).max - held) return false;
                    held += amount;
                }
                pending[a] = held;
                continue;
            }
            if (asset == wrapped) continue;
            for (uint256 c; c < currencies.length; ++c) {
                if (currencies[c] != asset) continue;
                (bool ok, bytes memory ret) =
                    _call(asset, abi.encodeCall(IERC20.balanceOf, (door)), POSITION_BALANCE_GAS, 32);
                if (!ok || ret.length != 32) return false;
                pending[a] = _word(ret, 0);
                break;
            }
        }
        return true;
    }

    /// @dev Adds a position's uncollected fee to its listed currency, refusing an overflowing aggregate.
    function _positionCredit(uint256[] memory pending, Currency[] memory assets, Currency currency, uint256 amount)
        private
        pure
        returns (bool)
    {
        for (uint256 a; a < assets.length; ++a) {
            if (Currency.unwrap(assets[a]) != Currency.unwrap(currency)) continue;
            if (amount > type(uint256).max - pending[a]) return false;
            pending[a] += amount;
            break;
        }
        return true;
    }

    /// @dev A v4 position's fees inside its range since its last collection, on each side, with its pool key.
    function _v4Fees(IPositionManagerDoor posm, IPoolManager manager, uint256 tokenId)
        private
        view
        returns (PoolKey memory key, uint256 fee0, uint256 fee1)
    {
        uint256 info;
        (key, info) = posm.getPoolAndPositionInfo(tokenId);
        int24 lower = int24(uint24(info >> 8));
        int24 upper = int24(uint24(info >> 32));
        PoolId id = key.toId();
        (uint128 liquidity, uint256 last0, uint256 last1) =
            manager.getPositionInfo(id, address(posm), lower, upper, bytes32(tokenId));
        (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(id, lower, upper);
        unchecked {
            fee0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fee1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /// @dev A FEEB adapter's pending ETH: the ETH it already holds, which every pull forwards (after the release, the
    ///      final claim); once the adapter no longer holds the NFT (released, or moved by the vault) nothing more, since
    ///      a pull then claims nothing for the token; otherwise also the vault's figure, plus, while the position sits
    ///      with a fee splitter (`splitter()`), the vault's share of the native side that the splitter's `collectFees`
    ///      would pay out now: the splitter's ETH balance and the position's uncollected native fees, times the
    ///      vault's `nativeBps`, floored as the splitter floors it. The splitter's code is the adapter's pinned hash, so
    ///      its answers are read as they come.
    function _feebPending(IHookrFeebAdapter adapter) private view returns (uint256 eth) {
        eth = address(adapter).balance;
        if (!adapter.bound()) return eth;
        (uint256 owed,) = adapter.pending();
        eth += owed;
        address splitter = adapter.splitter();
        if (splitter == address(0)) return eth;
        address vault = adapter.vault();
        IFeeSplitter.FeeSplit[] memory splits = IFeeSplitter(splitter).getSplits();
        uint256 bps;
        for (uint256 i; i < splits.length; ++i) {
            if (splits[i].recipient == vault) bps = splits[i].nativeBps;
        }
        if (bps == 0) return eth;
        IPositionManagerDoor posm = IPositionManagerDoor(adapter.positionManager());
        (PoolKey memory key, uint256 fee0,) = _v4Fees(posm, IPoolManager(posm.poolManager()), adapter.tokenId());
        if (!key.currency0.isAddressZero()) return eth;
        uint256 native = splitter.balance + fee0;
        if (native > type(uint256).max / 10_000) return eth;
        eth += native * bps / 10_000;
    }

    /// @dev Every position a v3 door still holds: what the manager's `collect` would pay it now (HookrV3Fees), the
    ///      wrapped native side counted as ETH, since the door unwraps it before forwarding. False when any read does
    ///      not answer in shape within `V3_READ_GAS`.
    function _v3PositionsPending(address door, uint256[] memory pending, Currency[] memory assets)
        private
        view
        returns (bool)
    {
        IHookrPositionBundle bundle = IHookrPositionBundle(door);
        address manager = address(IHookrV3PositionNftDoor(door).positionManager());
        address wrapped = IHookrV3PositionNftDoor(door).wrappedNative();
        if (!_positionHeld(door, bundle.assets(), wrapped, pending, assets)) return false;
        (bool ok, bytes memory ret) = _read(manager, abi.encodeCall(INonfungiblePositionManagerDoor.factory, ()), 1);
        if (!ok) return false;
        address factory = _address(ret, 0);
        uint256[] memory ids = bundle.tokenIds();
        for (uint256 i; i < ids.length; ++i) {
            if (bundle.releasedOf(ids[i])) continue;
            (bool read, address token0, address token1, uint256 fee0, uint256 fee1) = _v3Owed(manager, factory, ids[i]);
            if (!read) return false;
            if (!_positionCredit(pending, assets, Currency.wrap(token0 == wrapped ? address(0) : token0), fee0)) {
                return false;
            }
            if (!_positionCredit(pending, assets, Currency.wrap(token1 == wrapped ? address(0) : token1), fee1)) {
                return false;
            }
        }
        return true;
    }

    /// @dev What the manager's `collect` would pay position `tokenId` now on each side, with the pool's two tokens.
    ///      A position with no liquidity is owed what it already has: the manager pokes no pool for it.
    function _v3Owed(address manager, address factory, uint256 tokenId)
        private
        view
        returns (bool ok, address token0, address token1, uint256 fee0, uint256 fee1)
    {
        bytes memory p;
        (ok, p) = _read(manager, abi.encodeCall(INonfungiblePositionManagerDoor.positions, (tokenId)), 12);
        if (!ok) return (false, address(0), address(0), 0, 0);
        token0 = _address(p, 2);
        token1 = _address(p, 3);
        uint128 liquidity = uint128(_word(p, 7));
        fee0 = uint128(_word(p, 10));
        fee1 = uint128(_word(p, 11));
        if (liquidity == 0) return (true, token0, token1, fee0, fee1);
        bytes memory ret;
        (ok, ret) =
            _read(factory, abi.encodeCall(IUniswapV3FactoryPools.getPool, (token0, token1, uint24(_word(p, 4)))), 1);
        if (!ok) return (false, address(0), address(0), 0, 0);
        address pool = _address(ret, 0);
        int24 lower = int24(int256(_word(p, 5)));
        int24 upper = int24(int256(_word(p, 6)));
        (ok, ret) = _read(pool, abi.encodeCall(IUniswapV3PoolFees.slot0, ()), 7);
        if (!ok) return (false, address(0), address(0), 0, 0);
        int24 tick = int24(int256(_word(ret, 1)));
        bytes memory lo;
        bytes memory up;
        (ok, lo) = _read(pool, abi.encodeCall(IUniswapV3PoolFees.ticks, (lower)), 8);
        if (ok) (ok, up) = _read(pool, abi.encodeCall(IUniswapV3PoolFees.ticks, (upper)), 8);
        if (!ok) return (false, address(0), address(0), 0, 0);
        (ok, ret) = _read(pool, abi.encodeCall(IUniswapV3PoolFees.feeGrowthGlobal0X128, ()), 1);
        if (!ok) return (false, address(0), address(0), 0, 0);
        uint256 inside = HookrV3Fees.feeGrowthInside(lower, upper, tick, _word(ret, 0), _word(lo, 2), _word(up, 2));
        fee0 = HookrV3Fees.owed(liquidity, inside, _word(p, 8), uint128(fee0));
        (ok, ret) = _read(pool, abi.encodeCall(IUniswapV3PoolFees.feeGrowthGlobal1X128, ()), 1);
        if (!ok) return (false, address(0), address(0), 0, 0);
        inside = HookrV3Fees.feeGrowthInside(lower, upper, tick, _word(ret, 0), _word(lo, 3), _word(up, 3));
        fee1 = HookrV3Fees.owed(liquidity, inside, _word(p, 9), uint128(fee1));
    }

    /// @dev A source's `pendingIncome`, called with `SOURCE_INCOME_GAS` and read only when it answers two canonically
    ///      encoded arrays of the same length, at most `MAX_SOURCE_CURRENCIES` long, every currency a clean address
    ///      and no sum past 2^256. Anything else leaves the stream unread, never zeros.
    function _sourcePending(address source, StreamState memory s, Currency[] memory assets) private view {
        (bool ok, bytes memory ret) = _call(
            source,
            abi.encodeCall(IHookrRevenueSource.pendingIncome, ()),
            SOURCE_INCOME_GAS,
            128 + 64 * MAX_SOURCE_CURRENCIES
        );
        if (!ok || ret.length < 128) return;
        uint256 n = _word(ret, 2);
        if (
            n > MAX_SOURCE_CURRENCIES || ret.length != 128 + 64 * n || _word(ret, 0) != 64
                || _word(ret, 1) != 96 + 32 * n || _word(ret, 3 + n) != n
        ) return;
        uint256[] memory pending = new uint256[](assets.length);
        for (uint256 j; j < n; ++j) {
            uint256 currency = _word(ret, 3 + j);
            if (currency >> 160 != 0) return;
            uint256 amount = _word(ret, 4 + n + j);
            for (uint256 a; a < assets.length; ++a) {
                if (Currency.unwrap(assets[a]) != address(uint160(currency))) continue;
                if (pending[a] > type(uint256).max - amount) return;
                pending[a] += amount;
                break;
            }
        }
        (s.pendingRead, s.pending) = (true, pending);
    }

    /// @dev A staticcall of `data` on `target` with `V3_READ_GAS` that must answer exactly `words` words.
    function _read(address target, bytes memory data, uint256 words) private view returns (bool ok, bytes memory ret) {
        (ok, ret) = _call(target, data, V3_READ_GAS, 32 * words);
        ok = ok && ret.length == 32 * words;
    }

    /// @dev A staticcall of `data` on `target` with `cap` gas whose answer is copied only when it did not revert and
    ///      is at most `maxSize` bytes, so an answer of any size costs the view nothing. No code is not an answer.
    function _call(address target, bytes memory data, uint256 cap, uint256 maxSize)
        private
        view
        returns (bool ok, bytes memory ret)
    {
        if (target.code.length == 0) return (false, ret);
        assembly ("memory-safe") {
            ok := staticcall(cap, target, add(data, 0x20), mload(data), 0, 0)
            let size := returndatasize()
            ok := and(ok, iszero(gt(size, maxSize)))
            if ok {
                ret := mload(0x40)
                mstore(ret, size)
                returndatacopy(add(ret, 0x20), 0, size)
                mstore(0x40, add(ret, and(add(size, 0x3f), not(0x1f))))
            }
        }
    }

    /// @dev Word `i` of an answer the caller has checked is long enough.
    function _word(bytes memory ret, uint256 i) private pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(ret, shl(5, add(i, 1))))
        }
    }

    /// @dev Word `i` of an answer as an address, its upper bits dropped.
    function _address(bytes memory ret, uint256 i) private pure returns (address) {
        return address(uint160(_word(ret, i)));
    }

    /// @dev Adds `amount` to the slot of `currency` among `assets`; a currency not listed is not counted.
    function _credit(uint256[] memory pending, Currency[] memory assets, Currency currency, uint256 amount)
        private
        pure
    {
        if (amount == 0) return;
        for (uint256 a; a < assets.length; ++a) {
            if (assets[a] == currency) {
                pending[a] += amount;
                return;
            }
        }
    }

    function _ends(IHookrRevenueToken.Door memory d) private view returns (EndKind, uint64) {
        if (d.kind == IHookrRevenueToken.DoorKind.RULES) return (EndKind.FOREVER, 0);
        if (d.kind == IHookrRevenueToken.DoorKind.SOURCE) return HookrRevenueStreamEnds.sourceEnds(d.target);
        return IHookrRevenueDoor(d.target).ends();
    }

    function _firstParty(IHookrRevenueToken.Door memory d, address forwarder) private view returns (bool) {
        IHookrRevenueToken.DoorKind kind = d.kind;
        address target = d.target;
        if (kind == IHookrRevenueToken.DoorKind.RULES) return tokenizer.isAdmittedRules(target);
        if (kind == IHookrRevenueToken.DoorKind.FORWARDER) return target == forwarder;
        if (kind == IHookrRevenueToken.DoorKind.FEEB) {
            return IHookrFeebAdapterFactory(tokenizer.feebAdapterFactory()).isAdapter(target);
        }
        if (kind == IHookrRevenueToken.DoorKind.POSITIONS) {
            return IHookrPositionNftDoorFactory(tokenizer.positionDoorFactory()).isDoor(target);
        }
        if (kind == IHookrRevenueToken.DoorKind.POSITIONS_V3) {
            return IHookrV3PositionNftDoorFactory(tokenizer.v3PositionDoorFactory()).isDoor(target);
        }
        if (kind == IHookrRevenueToken.DoorKind.REVENUE_TOKEN) {
            return IHookrRevenueTokenDoorFactory(tokenizer.revenueTokenDoorFactory()).isDoor(target);
        }
        IHookrRevenueTokenizerSourcePins pins = IHookrRevenueTokenizerSourcePins(address(tokenizer));
        address pons = pins.ponsAdapterFactory();
        address doppler = pins.dopplerAdapterFactory();
        return (pons != address(0) && IHookrPonsAdapterFactory(pons).isAdapter(target))
            || (doppler != address(0) && IHookrDopplerAdapterFactory(doppler).isAdapter(target));
    }
}
