// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookrPositionBundle} from "../base/HookrPositionBundle.sol";
import {IHookrPositionNftDoor} from "../interfaces/IHookrPositionNftDoor.sol";
import {IPositionManagerDoor} from "../interfaces/IPositionManagerDoor.sol";

/// @title Hookr position NFT door, part of the HookRevenue Tokenizer
/// @notice A bundle of Uniswap v4 position NFTs (one pool or several) whose principal is locked until a date, or
///         forever, and whose fees the revenue token pulls. See IHookrPositionBundle for the rules.
/// @dev A collection is the PositionManager's DECREASE_LIQUIDITY of 0 followed by TAKE_PAIR to the door (the
///      v4-periphery fee-collect pattern): a decrease of 0 touches no principal. On a pool of the revenue token
///      itself (its market, or any pool pairing it) the token refuses a transfer to its own door, which would revert
///      the whole collection, so the take is split: TAKE of the other currency to the door and TAKE of the token's
///      side to 0xdead, both of the open credit, which retires that side as the forwarding retires the token. The
///      door never encodes any other action.
///
///      Gas: the tokenizer gives this door `pullGas()`: 150,000, plus 1,643,809 per position (the collection floor),
///      plus `FORWARD_ITEM_GAS` (2,340,000) per currency up to two (`FORWARD_PAGE`), clipped to 12,000,000. Measured
///      cold: a pull of three positions in two pools and their forwards (ETH to the token, an unlisted currency into
///      the stray stream) takes about 325,000 against the mocks, and on a 4663 fork a door of 64 positions on the root
///      collected all 64 in one pull with 4,848,904 of its 12,000,000. At the clip a door of two currencies or more
///      collects four positions in one pull when every hook burns 1,400,000, and forwards at least two currencies.
contract HookrPositionNftDoor is IHookrPositionNftDoor, HookrPositionBundle {
    using PoolIdLibrary for PoolKey;

    /// @dev PositionManager action codes (v4-periphery Actions): DECREASE_LIQUIDITY, TAKE and TAKE_PAIR.
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant TAKE = 0x0e;
    uint8 private constant TAKE_PAIR = 0x11;
    /// @dev v4-periphery's ActionConstants.OPEN_DELTA: a TAKE of the whole open credit.
    uint256 private constant OPEN_DELTA = 0;

    /// @dev The hook flags that run on a liquidity removal, which is what a fee collection is to the PoolManager.
    uint160 private constant REMOVE_LIQUIDITY_FLAGS = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @inheritdoc IHookrPositionNftDoor
    address public immutable hookrRoot;

    /// @dev Each position's pool, and each pool's key once: positions in the same pool share the three key slots.
    mapping(uint256 tokenId => PoolId) private _poolOf;
    mapping(PoolId poolId => PoolKey) private _keys;

    /// @param positionManager_ The Uniswap v4 PositionManager that minted the NFTs.
    /// @param revenueToken_ The revenue token every collected fee goes to.
    /// @param returnTo_ The account that hands the NFTs over and gets them back.
    /// @param unlockAt_ The unlock timestamp, after now, or FOREVER.
    /// @param tokenIds_ The position NFTs the door will hold; no duplicates, at most MAX_POSITIONS.
    /// @param hookrRoot_ The Hookr root hook address, for `isHookrPool` and `rootCount`.
    constructor(
        IPositionManagerDoor positionManager_,
        address revenueToken_,
        address returnTo_,
        uint64 unlockAt_,
        uint256[] memory tokenIds_,
        address hookrRoot_
    ) HookrPositionBundle(address(positionManager_), revenueToken_, returnTo_, unlockAt_, tokenIds_) {
        hookrRoot = hookrRoot_;
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrPositionNftDoor
    function positionManager() external view returns (IPositionManagerDoor) {
        return IPositionManagerDoor(_manager);
    }

    /// @inheritdoc IHookrPositionNftDoor
    function poolKeyOf(uint256 tokenId) external view returns (PoolKey memory) {
        return _keys[_poolOf[tokenId]];
    }

    /// @inheritdoc IHookrPositionNftDoor
    function isHookrPool(uint256 tokenId) public view returns (bool) {
        return _positions[tokenId].listed && address(_keys[_poolOf[tokenId]].hooks) == hookrRoot;
    }

    /// @inheritdoc IHookrPositionNftDoor
    function hookrPools() external view returns (bool[] memory out) {
        uint256 n = _tokenIds.length;
        out = new bool[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = isHookrPool(_tokenIds[i]);
        }
    }

    /// @inheritdoc IHookrPositionNftDoor
    function rootCount() external view returns (uint256 count) {
        uint256 n = _tokenIds.length;
        for (uint256 i; i < n; ++i) {
            if (isHookrPool(_tokenIds[i])) ++count;
        }
    }

    /// @inheritdoc IHookrPositionNftDoor
    function hookCanBlockCollection(uint256 tokenId) external view returns (bool) {
        if (!_positions[tokenId].listed) return false;
        address hooks = address(_keys[_poolOf[tokenId]].hooks);
        return hooks != hookrRoot && (uint160(hooks) & REMOVE_LIQUIDITY_FLAGS) != 0;
    }

    // ------------------------------------------------------------------ internals

    function _activatePosition(uint256 tokenId) internal override {
        IPositionManagerDoor pm = IPositionManagerDoor(_manager);
        if (pm.getPositionLiquidity(tokenId) == 0) revert NoLiquidity(tokenId);
        (PoolKey memory key,) = pm.getPoolAndPositionInfo(tokenId);
        PoolId poolId = key.toId();
        _poolOf[tokenId] = poolId;
        if (Currency.unwrap(_keys[poolId].currency1) == address(0)) {
            // Not stored yet: a real pool key always has a nonzero currency1 (currency0 < currency1).
            _keys[poolId] = key;
            _addAsset(Currency.unwrap(key.currency0));
            _addAsset(Currency.unwrap(key.currency1));
        }
    }

    /// @dev A position with no liquidity is skipped as a success: it has no fees and the PoolManager refuses to touch
    ///      an empty position.
    function _collect(uint256 tokenId) internal override returns (bool ok, bytes memory reason) {
        IPositionManagerDoor pm = IPositionManagerDoor(_manager);
        if (pm.getPositionLiquidity(tokenId) == 0) return (true, "");
        PoolKey storage key = _keys[_poolOf[tokenId]];
        try pm.modifyLiquidities{gas: COLLECT_GAS_CAP}(
            _collectData(tokenId, key.currency0, key.currency1), block.timestamp
        ) {
            emit Collected(tokenId);
            return (true, "");
        } catch {
            bytes memory data = _revertData(REASON_BYTES);
            emit CollectFailed(tokenId, data);
            return (false, data);
        }
    }

    /// @dev The collection of position `tokenId` in pool (`c0`, `c1`): DECREASE_LIQUIDITY of 0, then TAKE_PAIR to the
    ///      door; or, when one currency is the revenue token, TAKE of the other one to the door and TAKE of the
    ///      token's side to 0xdead.
    function _collectData(uint256 tokenId, Currency c0, Currency c1) private view returns (bytes memory) {
        address token = revenueToken;
        bool own0 = Currency.unwrap(c0) == token;
        bytes memory actions;
        bytes[] memory params;
        if (own0 || Currency.unwrap(c1) == token) {
            (Currency other, Currency own) = own0 ? (c1, c0) : (c0, c1);
            actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE, TAKE);
            params = new bytes[](3);
            params[1] = abi.encode(other, address(this), OPEN_DELTA);
            params[2] = abi.encode(own, DEAD, OPEN_DELTA);
        } else {
            actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);
            params = new bytes[](2);
            params[1] = abi.encode(c0, c1, address(this));
        }
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        return abi.encode(actions, params);
    }
}
