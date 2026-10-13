// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {IHookrFeeBridge, IHookrFeeBridgeFactory} from "./interfaces/IHookrFeeBridge.sol";

/// @title Hookr fee bridge
/// @notice Pays another pool's LPs. Name it as a royalty payee or a tax recipient (or send it anything in its
///         currency), and a keeper drips it: each drip donates a capped amount of what it holds to the in-range LPs of
///         the destination pool fixed when it was made, for a tip of at most 1% of what it donates. A donation pays in
///         the pool's own currencies, so the bridge holds and pays one side of the destination. Anyone may create a
///         bridge, fund it and collect() into it; only an account its factory lists as a keeper may record() or drip().
/// @dev No owner, no admin, no rescue: every term is immutable and nothing but a drip moves what a bridge holds. The
///      factory's owner chooses the keepers, so a keeper it lists (a hostile one, or a leaked key) can take what the
///      first factory let anyone take, up to maxPerDrip every minBlocks, until the owner removes it. Hookr's roots take
///      no donate callback, so a donation to a Hookr pool needs no hook change and runs no outside code; the bridge
///      refuses a destination whose hook takes one. Blocks here are block.number, which on Robinhood Chain (4663) is
///      Ethereum's height: about 12 s a block.
///      Why keepers. A donation pays whoever is in range when it lands. With record() and drip() open to anyone (the
///      first factory), one actor could add liquidity, drip and remove it in one transaction, and with capital held
///      for one transaction raise the liquidity reference maxJumpBps a block until such an add passed the jump check:
///      at 10%, 49 records in separate blocks to 100x (about 10 minutes on 4663), after which it took about 99% of
///      each drip. Here only keepers record and drip. 4663 orders transactions with a first-come sequencer and has no
///      public mempool, so nobody but the sequencer and the keeper's own RPC sees a keeper's record or drip before it
///      is sequenced: an outsider can neither raise the reference nor wrap a drip in its own transaction, which makes
///      one-transaction (flash) capital useless. To share a drip, liquidity must be in range when the keeper's drip
///      lands, at a time the keeper picks at random; while the liquidity in range at the keeper's record stays,
///      liquidity added after the record (public once sequenced) is held by the jump check to at most
///      maxJumpBps / (10,000 + maxJumpBps) of the drip.
///      The guards are unchanged: a drip needs a record of in-range liquidity (and the tick) from an earlier block, the
///      price still in the record's tick-spacing bucket, and in-range liquidity at most maxJumpBps above the record. A
///      record is bounded rather than trusted, even a keeper's: none is taken while the PoolManager is unlocked, one
///      per block, and each may lower the reference freely but raise it by at most maxJumpBps (at least 1%). A drip
///      records at its own block but never raises the reference: liquidity added after the keeper's record shares
///      that drip (up to the jump) and counts toward the reference only once a later keeper record sees it, so drips
///      minBlocks apart cannot compound it. A reference belongs to a bucket: in another bucket a record starts from
///      the anchor (the bucket of the last drip, or of the first record) less the liquidity that left range on the
///      way, never adding what entered.
///      What remains: liquidity held in range across a keeper's window shares drips as any LP's does, and liquidity
///      added after a record can take the share of LPs who leave before the drip; the hard limit on what one actor,
///      or a hostile keeper, can take stays maxPerDrip every minBlocks; on a chain with a public mempool keepers would
///      have to submit privately. While no keeper acts, funds wait in the bridge until the owner lists one; were the
///      owner's and every keeper's keys lost, they would wait for good, since nothing else moves them. The receive
///      path writes nothing, so a tax or royalty payment in native lands in full.
contract HookrFeeBridge is HookrReleased, IHookrFeeBridge, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Fewest blocks a bridge may require between drips.
    uint32 public constant MIN_MIN_BLOCKS = 1;
    /// @notice Most blocks a bridge may require between drips.
    uint32 public constant MAX_MIN_BLOCKS = 100_000;
    /// @notice Largest tip (1% of what a drip donates).
    uint16 public constant MAX_TIP_BPS = 100;
    /// @notice Suggested tip (0.5%). The app's default; not enforced.
    uint16 public constant DEFAULT_TIP_BPS = 50;
    /// @notice Suggested liquidity jump tolerance (2%). The app's default; not enforced. Records come only from
    ///         keepers, at times outsiders cannot see coming, so a tight tolerance costs little: honest in-range
    ///         liquidity rarely moves 2% between a keeper's record and its drip. While the liquidity in range at the
    ///         keeper's record stays, the tolerance also bounds what liquidity added after the record can take of a
    ///         drip: maxJumpBps / (10,000 + maxJumpBps), about 196 bps at 2% (909 bps at 10%).
    uint16 public constant DEFAULT_MAX_JUMP_BPS = 200;

    uint256 private constant BPS = 10_000;
    /// @dev Least a record may raise the reference by, so a bridge with a tiny jump tolerance still catches up with
    ///      real growth.
    uint256 private constant MIN_RAISE_BPS = 100;
    /// @dev Most tick-bitmap words (256 spacings each) and boundaries a record reads to carry the anchor across a price
    ///      move. Past either it stops subtracting, which leaves the carried reference too high, never too low.
    uint256 private constant MAX_CARRY_WORDS = 4;
    uint256 private constant MAX_CARRY_TICKS = 16;
    /// @dev A carry lowers the anchor to at most 1 / MAX_CARRY_DROP of it. What leaves range is read from the ticks as
    ///      they are now, so a position added for the occasion can make it look larger; the floor bounds that grief to
    ///      log(10) / log(1 + jump) records (25 at 10%).
    uint256 private constant MAX_CARRY_DROP = 10;
    uint8 private constant IDLE = 1;
    uint8 private constant BUSY = 2;
    uint8 private constant DONATING = 3;

    /// @inheritdoc IHookrFeeBridge
    address public immutable factory;
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrFeeBridge
    PoolId public immutable destinationId;
    /// @inheritdoc IHookrFeeBridge
    Currency public immutable currency;
    /// @inheritdoc IHookrFeeBridge
    uint128 public immutable maxPerDrip;
    /// @inheritdoc IHookrFeeBridge
    uint32 public immutable minBlocks;
    /// @inheritdoc IHookrFeeBridge
    uint16 public immutable tipBps;
    /// @inheritdoc IHookrFeeBridge
    uint16 public immutable maxJumpBps;

    Currency private immutable _currency0;
    Currency private immutable _currency1;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    address private immutable _hooks;
    bool private immutable _isCurrency0;

    uint8 private _lock = IDLE;
    /// @inheritdoc IHookrFeeBridge
    uint64 public lastDripBlock;
    uint64 private _recordBlock;
    int24 private _recordTick;
    int24 private _anchorTick;
    uint128 private _recordLiquidity;
    uint128 private _anchorLiquidity;

    /// @param manager The PoolManager (passed by the factory).
    /// @param t The terms. Codes: 1 PoolManager; 2 a hook that takes donate callbacks; 3 not a valid key; 4 currency not a
    ///        side of the key; 5 maxPerDrip; 6 minBlocks; 7 tip; 8 jump.
    constructor(IPoolManager manager, Terms memory t) {
        factory = msg.sender;
        if (address(manager).code.length == 0) revert InvalidBridge(1);
        uint160 hookFlags = uint160(address(t.key.hooks));
        if (hookFlags & (Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG) != 0) revert InvalidBridge(2);
        if (
            Currency.unwrap(t.key.currency0) >= Currency.unwrap(t.key.currency1)
                || t.key.tickSpacing < TickMath.MIN_TICK_SPACING || t.key.tickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidBridge(3);
        bool first = Currency.unwrap(t.currency) == Currency.unwrap(t.key.currency0);
        if (!first && Currency.unwrap(t.currency) != Currency.unwrap(t.key.currency1)) revert InvalidBridge(4);
        if (t.maxPerDrip == 0 || t.maxPerDrip > uint128(type(int128).max)) revert InvalidBridge(5);
        if (t.minBlocks < MIN_MIN_BLOCKS || t.minBlocks > MAX_MIN_BLOCKS) revert InvalidBridge(6);
        if (t.tipBps > MAX_TIP_BPS) revert InvalidBridge(7);
        if (t.maxJumpBps > BPS) revert InvalidBridge(8);
        poolManager = manager;
        destinationId = t.key.toId();
        currency = t.currency;
        maxPerDrip = t.maxPerDrip;
        minBlocks = t.minBlocks;
        tipBps = t.tipBps;
        maxJumpBps = t.maxJumpBps;
        _currency0 = t.key.currency0;
        _currency1 = t.key.currency1;
        _fee = t.key.fee;
        _tickSpacing = t.key.tickSpacing;
        _hooks = address(t.key.hooks);
        _isCurrency0 = first;
    }

    /// @inheritdoc IHookrFeeBridge
    function destination() public view returns (PoolKey memory) {
        return PoolKey(_currency0, _currency1, _fee, _tickSpacing, IHooks(_hooks));
    }

    /// @inheritdoc IHookrFeeBridge
    function recorded() external view returns (uint64 blockNumber, uint128 liquidity) {
        return (_recordBlock, _recordLiquidity);
    }

    /// @inheritdoc IHookrFeeBridge
    function recordedTick() external view returns (int24) {
        return _recordTick;
    }

    /// @inheritdoc IHookrFeeBridge
    function anchor() external view returns (int24 tick, uint128 liquidity) {
        return (_anchorTick, _anchorLiquidity);
    }

    /// @inheritdoc IHookrFeeBridge
    function held() public view returns (uint256) {
        return HookrSettlement.balance(currency, address(this));
    }

    /// @inheritdoc IHookrFeeBridge
    /// @dev Caller-independent: it answers for a keeper's drip, and a keeper job reads it before sending one.
    function ready() external view returns (bool) {
        if (_lock != IDLE || held() == 0 || poolManager.isUnlocked()) return false;
        if (lastDripBlock != 0 && block.number < uint256(lastDripBlock) + minBlocks) return false;
        (uint128 liquidity, int24 tick) = _state();
        if (liquidity == 0 || _recordBlock == 0 || _recordBlock >= block.number) return false;
        return _bucket(tick) == _bucket(_recordTick) && !_jumped(liquidity);
    }

    /// @inheritdoc IHookrFeeBridge
    /// @dev Moves nothing out: it asks `rules` to pay the bridge's own claim to the bridge. A contract that is not a
    ///      Rules can only fail the call or pay nothing.
    function collect(address rules) external returns (uint256 amount) {
        if (_lock != IDLE) revert Reentered();
        if (IHookrRules(rules).claimable(currency, address(this)) == 0) return 0;
        _lock = BUSY;
        uint256 before = held();
        IHookrRules(rules).claim(currency);
        amount = held() - before;
        _lock = IDLE;
    }

    /// @inheritdoc IHookrFeeBridge
    /// @dev Order: keeper, lock, unlocked manager. The keeper check comes first so that a call from anyone else stops
    ///      before it reads or writes any of the bridge's state. It is a view call (STATICCALL) to the factory that
    ///      made this bridge, so it can neither re-enter nor change state; the lock after it still stops a keeper
    ///      re-entering (a tip recipient or rules contract that is also a keeper). Refused while the PoolManager is
    ///      unlocked, so liquidity added and removed around it inside one unlock never reaches a record, even a
    ///      keeper's.
    function record() external returns (bool) {
        _onlyKeeper();
        if (_lock != IDLE) revert Reentered();
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        (uint128 liquidity, int24 tick) = _state();
        return _record(liquidity, tick);
    }

    /// @inheritdoc IHookrFeeBridge
    /// @dev Order: keeper (first, for the reasons record() gives), lock, unlocked manager, gap, recipient, liquidity
    ///      and price against an earlier record, amount and tip, donation through one unlock, tip last, then a fresh
    ///      record so the next drip needs a later block again. That record keeps the lower of the reference and the
    ///      liquidity just paid over: a drip may lower the reference but never raises it.
    function drip(address tipTo) external returns (uint256 donated, uint256 tip) {
        _onlyKeeper();
        if (_lock != IDLE) revert Reentered();
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        _lock = BUSY;
        if (lastDripBlock != 0 && block.number < uint256(lastDripBlock) + minBlocks) {
            revert TooSoon(uint256(lastDripBlock) + minBlocks);
        }
        if (tipBps != 0 && (tipTo == address(0) || tipTo == address(this))) revert InvalidTipRecipient(tipTo);
        uint256 amount = held();
        if (amount == 0) revert NothingToDrip();
        if (amount > maxPerDrip) amount = maxPerDrip;
        (uint128 liquidity, int24 tick) = _state();
        if (liquidity == 0) revert NoLiquidity();
        if (_recordBlock == 0 || _recordBlock >= block.number) revert NeedsEarlierRecord(_recordBlock);
        // Inside one bucket the same positions are in range, so the jump check below sees every arrival. Across a
        // boundary a swap can trade recorded liquidity for new liquidity at the same total.
        if (_bucket(tick) != _bucket(_recordTick)) revert PriceMoved(_recordTick, tick);
        if (_jumped(liquidity)) revert LiquidityJumped(_recordLiquidity, liquidity);

        // tipBps of what is donated, exactly: tip * BPS <= donated * tipBps, and donated + tip == amount <= maxPerDrip.
        tip = amount * tipBps / (BPS + tipBps);
        donated = amount - tip;
        if (donated != 0) {
            _lock = DONATING;
            poolManager.unlock(abi.encode(donated));
            if (_lock != BUSY) revert InvalidCallback();
        }
        if (tip != 0) HookrSettlement.send(currency, tipTo, tip);
        // block.number fits uint64 for the life of any chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        lastDripBlock = uint64(block.number);
        // Never raised: liquidity that arrived after the keeper's record (which this drip paid, up to maxJumpBps) counts
        // only once a later keeper record sees it, so drips minBlocks apart cannot compound the reference.
        _record(liquidity < _recordLiquidity ? liquidity : _recordLiquidity, tick);
        // The bucket a drip was paid in becomes the anchor later records in other buckets carry from.
        (_anchorTick, _anchorLiquidity) = (tick, _recordLiquidity);
        emit Dripped(msg.sender, tipTo, donated, tip, liquidity);
        _lock = IDLE;
    }

    /// @notice Donates and settles inside drip(). Only the PoolManager, only while donating.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _lock != DONATING) revert InvalidCallback();
        uint256 amount = abi.decode(data, (uint256));
        (uint256 amount0, uint256 amount1) = _isCurrency0 ? (amount, uint256(0)) : (uint256(0), amount);
        BalanceDelta delta = poolManager.donate(destination(), amount0, amount1, "");
        int128 owed = _isCurrency0 ? delta.amount0() : delta.amount1();
        // A donation's delta is the negative of what was donated, exactly.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (owed >= 0 || uint256(uint128(-owed)) != amount) revert InvalidCallback();
        HookrSettlement.pay(poolManager, currency, address(this), amount);
        _lock = BUSY;
        return "";
    }

    /// @notice A native bridge takes native from anyone and writes nothing, so a tax or royalty pays in full; a token
    ///         bridge refuses native, which it could never donate.
    receive() external payable {
        if (!currency.isAddressZero()) revert UnexpectedNative(msg.sender);
    }

    /// @dev Reverts unless the factory that made this bridge lists the caller as a keeper now: a keeper the owner
    ///      removes is refused from its next call on.
    function _onlyKeeper() private view {
        if (!IHookrFeeBridgeFactory(factory).isKeeper(msg.sender)) revert NotKeeper(msg.sender);
    }

    /// @dev In-range liquidity (zero for a pool not yet initialized) and the current tick.
    function _state() private view returns (uint128 liquidity, int24 tick) {
        uint160 sqrtPriceX96;
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(destinationId);
        if (sqrtPriceX96 != 0) liquidity = poolManager.getLiquidity(destinationId);
    }

    /// @dev The tick-spacing bucket of `tick`: every position boundary is a multiple of the spacing, so the positions in
    ///      range are the same anywhere inside one bucket.
    function _bucket(int24 tick) private view returns (int24 bucket) {
        int24 spacing = _tickSpacing;
        bucket = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --bucket;
    }

    function _jumped(uint128 liquidity) private view returns (bool) {
        return uint256(liquidity) * BPS > uint256(_recordLiquidity) * (BPS + maxJumpBps);
    }

    function _record(uint128 liquidity, int24 tick) private returns (bool) {
        if (_recordBlock == block.number) return false;
        bool first = _recordBlock == 0;
        uint128 reference_ = first ? liquidity : _bounded(liquidity, tick);
        // block.number fits uint64 for the life of any chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        _recordBlock = uint64(block.number);
        _recordTick = tick;
        _recordLiquidity = reference_;
        if (first || _bucket(tick) == _bucket(_anchorTick)) (_anchorTick, _anchorLiquidity) = (tick, reference_);
        emit LiquidityRecorded(_recordBlock, reference_);
        return true;
    }

    /// @dev The next reference: the current in-range liquidity, lowered freely but raised at most maxJumpBps (at least
    ///      MIN_RAISE_BPS) over the last reference for this bucket. That is the anchor's in the anchor's bucket, the
    ///      last record's while the price stays in its bucket, and otherwise the anchor carried here. A last reference
    ///      of zero (only when the anchor's bucket itself read empty) takes the current liquidity, as the first record
    ///      does.
    function _bounded(uint128 liquidity, int24 tick) private view returns (uint128) {
        int24 bucket = _bucket(tick);
        uint256 last;
        if (bucket == _bucket(_anchorTick)) last = _anchorLiquidity;
        else if (bucket == _bucket(_recordTick) && _recordLiquidity != 0) last = _recordLiquidity;
        else last = _carry(_anchorLiquidity, _anchorTick, tick);
        if (last == 0 || liquidity <= last) return liquidity;
        uint256 raise = maxJumpBps > MIN_RAISE_BPS ? maxJumpBps : MIN_RAISE_BPS;
        uint256 cap = last * (BPS + raise) / BPS;
        // cap < liquidity, a uint128, in this branch.
        // forge-lint: disable-next-line(unsafe-typecast)
        return cap < liquidity ? uint128(cap) : liquidity;
    }

    /// @dev The anchor carried from its bucket to `toTick`'s. Crossing a boundary takes the positions that end there out
    ///      of range, so their liquidity (from the boundary's gross and net) comes off; positions that start there are
    ///      not added, because one added for the occasion could be among them. Never below 1 / MAX_CARRY_DROP of the
    ///      anchor. Reads at most MAX_CARRY_WORDS bitmap words and MAX_CARRY_TICKS boundaries, then stops subtracting.
    function _carry(uint256 last, int24 fromTick, int24 toTick) private view returns (uint256) {
        uint256 floor = last / MAX_CARRY_DROP;
        int24 from = _bucket(fromTick);
        int24 to = _bucket(toTick);
        bool up = to > from;
        // The boundaries crossed, as compressed ticks: from + 1 .. to going up, to + 1 .. from going down.
        int24 lo = up ? from + 1 : to + 1;
        int24 hi = up ? to : from;
        // A compressed tick >> 8 is a bitmap word position, which fits int16.
        // forge-lint: disable-next-line(unsafe-typecast)
        int16 firstWord = int16(lo >> 8);
        // forge-lint: disable-next-line(unsafe-typecast)
        int16 lastWord = int16(hi >> 8);
        uint256 counted;
        for (int16 w = firstWord; w <= lastWord; ++w) {
            uint256 word = poolManager.getTickBitmap(destinationId, w);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (w == firstWord) word &= type(uint256).max << (uint24(lo) & 0xff);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (w == lastWord) word &= type(uint256).max >> (255 - (uint24(hi) & 0xff));
            while (word != 0) {
                uint8 bit = BitMath.leastSignificantBit(word);
                word &= word - 1;
                // forge-lint: disable-next-line(unsafe-typecast)
                int24 boundary = (int24(w) * 256 + int24(uint24(bit))) * _tickSpacing;
                (uint128 gross, int128 net) = poolManager.getTickLiquidity(destinationId, boundary);
                // Up through a boundary the positions whose upper tick it is leave range, down through it those whose
                // lower tick it is: (gross - net) / 2 and (gross + net) / 2.
                int256 twice = up ? int256(uint256(gross)) - net : int256(uint256(gross)) + net;
                if (twice > 0) {
                    // twice > 0 here.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    uint256 leaving = uint256(twice) / 2;
                    if (leaving >= last - floor) return floor;
                    last -= leaving;
                }
                if (++counted == MAX_CARRY_TICKS) return last;
            }
            // w - firstWord >= 0 here.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (uint256(uint16(w - firstWord)) + 1 == MAX_CARRY_WORDS) break;
        }
        return last;
    }
}

/// @title Hookr fee bridge factory
/// @notice Makes fee bridges at CREATE2 addresses keyed by (creator, salt), and keeps the keeper list every bridge it
///         made checks on each record() and drip(). Anyone may create and fund a bridge.
/// @dev The owner (the release deployer at deploy, Hookr's Safe after the release handover) has one power: it adds and
///      removes keepers, which takes effect at once on every bridge made here, since a bridge asks on every call. It
///      has no path to a bridge's funds or terms and cannot stop funding or collect(); there is no pause, rescue or
///      renounce, and ownership moves only in two steps (the pending owner accepts). Choosing the keepers is still
///      power over drips: a keeper it lists can take up to maxPerDrip every minBlocks from each bridge, as anyone could
///      from the first factory's bridges, so the owner is trusted to list only keys whose calls nobody else can
///      trigger. The constructor takes the owner and first keeper explicitly: under CREATE3 its msg.sender is the
///      CREATE3 proxy, not the deployer.
///      A keeper must be an account whose calls nobody else can trigger. Never list a Family Pinger (anyone may ping
///      one), a relayer, or any contract or delegated account with an open entry point: it would hand record() and
///      drip() back to everyone, and with them the one-transaction attack keepers close. The Family Pinger factory
///      deployed with the first bridge factory (0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1) recognises bridges only
///      through that factory's isBridge, so it cannot run bridges made here.
contract HookrFeeBridgeFactory is HookrReleased, IHookrFeeBridgeFactory {
    /// @inheritdoc IHookrFeeBridgeFactory
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrFeeBridgeFactory
    mapping(address bridge => bool) public isBridge;
    /// @inheritdoc IHookrFeeBridgeFactory
    mapping(address account => bool) public isKeeper;
    /// @inheritdoc IHookrFeeBridgeFactory
    address public owner;
    /// @inheritdoc IHookrFeeBridgeFactory
    address public pendingOwner;

    /// @param manager The PoolManager every bridge donates through.
    /// @param owner_ The owner, nonzero (the release deployer; the Safe takes over by transferOwnership and accept).
    /// @param keeper_ The first keeper, nonzero.
    constructor(IPoolManager manager, address owner_, address keeper_) {
        if (owner_ == address(0) || keeper_ == address(0)) revert InvalidAddress(address(0));
        poolManager = manager;
        owner = owner_;
        isKeeper[keeper_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperSet(keeper_, true);
    }

    /// @notice Makes a bridge for `terms`. Permissionless.
    function create(IHookrFeeBridge.Terms calldata terms, bytes32 salt) external returns (address bridge) {
        bridge = address(new HookrFeeBridge{salt: _salt(msg.sender, salt)}(poolManager, terms));
        isBridge[bridge] = true;
        emit BridgeCreated(bridge, msg.sender, IHookrFeeBridge(bridge).destinationId(), terms.currency);
    }

    /// @notice The address create(terms, salt) called by `creator` deploys to.
    function predict(address creator, IHookrFeeBridge.Terms calldata terms, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(HookrFeeBridge).creationCode, abi.encode(poolManager, terms)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(creator, salt), initHash))))
        );
    }

    /// @inheritdoc IHookrFeeBridgeFactory
    function setKeeper(address keeper, bool allowed) external {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        if (keeper == address(0)) revert InvalidAddress(keeper);
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @inheritdoc IHookrFeeBridgeFactory
    /// @dev Zero cancels a pending transfer (OwnershipTransferStarted then names zero); it never clears the owner.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(msg.sender, newOwner);
    }

    /// @inheritdoc IHookrFeeBridgeFactory
    /// @dev The zero address can never accept, so with nothing pending nobody can.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert Unauthorized(msg.sender);
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
