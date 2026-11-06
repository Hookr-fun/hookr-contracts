// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrPositionBundle} from "../base/HookrPositionBundle.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {IHookrV3PositionNftDoor} from "../interfaces/IHookrV3PositionNftDoor.sol";
import {INonfungiblePositionManagerDoor} from "../interfaces/external/INonfungiblePositionManagerDoor.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";

/// @title Hookr v3 position NFT door, part of the HookRevenue Tokenizer
/// @notice A bundle of Uniswap v3 position NFTs whose principal is locked until a date, or forever, and whose fees the
///         revenue token pulls. See IHookrPositionBundle and IHookrV3PositionNftDoor for the rules.
/// @dev Fees are the only value a collection moves: `collect` touches no liquidity, and the door never calls
///      `decreaseLiquidity` or `burn`. The wrapper is the manager's, fixed at creation; the door unwraps its whole
///      wrapper balance with UNWRAP_GAS before the token pull's forwards (a refusal is reported and the wrapper waits),
///      and native ETH is always one of its currencies, so wrapper sent here by anyone reaches the token too. On a
///      pool of the revenue token itself a collection asks for nothing on the token's side (its maximum is 0): the
///      manager pays both sides to one recipient and the token refuses a transfer to its own door, so that side stays
///      in the position and goes back with the NFT at release; the tokenizer refuses a position on such a pool
///      (`V3PairIsRevenueToken`), so this stays only as a guard.
///
///      Gas: the tokenizer gives this door `pullGas()`: 150,000, plus 160,000 for the unwrap, plus 1,643,809 per
///      position, plus `FORWARD_ITEM_GAS` (2,340,000) per currency up to two (`FORWARD_PAGE`), clipped to 12,000,000.
///      Measured cold: a pull of two positions, the unwrap and three forwards (one into the stray stream) takes about
///      395,000.
contract HookrV3PositionNftDoor is IHookrV3PositionNftDoor, HookrPositionBundle {
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public constant UNWRAP_GAS = 100_000;

    /// @inheritdoc IHookrV3PositionNftDoor
    address public immutable wrappedNative;

    /// @dev A listed position's pool, read once at activation.
    struct Pool {
        address token0;
        address token1;
        uint24 fee;
    }

    mapping(uint256 tokenId => Pool) private _pools;

    /// @param positionManager_ The Uniswap v3 NonfungiblePositionManager that minted the NFTs.
    /// @param revenueToken_ The revenue token every collected fee goes to.
    /// @param returnTo_ The account that hands the NFTs over and gets them back.
    /// @param unlockAt_ The unlock timestamp, after now, or FOREVER.
    /// @param tokenIds_ The position NFTs the door will hold; no duplicates, at most MAX_POSITIONS.
    /// @param wrappedNative_ The manager's WETH9, unwrapped before forwarding.
    constructor(
        INonfungiblePositionManagerDoor positionManager_,
        address revenueToken_,
        address returnTo_,
        uint64 unlockAt_,
        uint256[] memory tokenIds_,
        address wrappedNative_
    ) HookrPositionBundle(address(positionManager_), revenueToken_, returnTo_, unlockAt_, tokenIds_) {
        wrappedNative = wrappedNative_;
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function positionManager() external view returns (INonfungiblePositionManagerDoor) {
        return INonfungiblePositionManagerDoor(_manager);
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function poolOf(uint256 tokenId) external view returns (address token0, address token1, uint24 fee) {
        Pool storage p = _pools[tokenId];
        return (p.token0, p.token1, p.fee);
    }

    /// @dev Lists the pool's two tokens, native ETH standing for the wrapper.
    function _activatePosition(uint256 tokenId) internal override {
        (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) =
            INonfungiblePositionManagerDoor(_manager).positions(tokenId);
        if (liquidity == 0) revert NoLiquidity(tokenId);
        _pools[tokenId] = Pool(token0, token1, fee);
        _addAsset(token0 == wrappedNative ? address(0) : token0);
        _addAsset(token1 == wrappedNative ? address(0) : token1);
    }

    /// @dev Collects everything owed except on the revenue token's own side, whose maximum is 0. A position with no
    ///      liquidity and nothing to collect is skipped as a success.
    function _collect(uint256 tokenId) internal override returns (bool ok, bytes memory reason) {
        INonfungiblePositionManagerDoor pm = INonfungiblePositionManagerDoor(_manager);
        (,, address token0, address token1,,,, uint128 liquidity,,, uint128 owed0, uint128 owed1) =
            pm.positions(tokenId);
        address token = revenueToken;
        uint128 max0 = token0 == token ? 0 : type(uint128).max;
        uint128 max1 = token1 == token ? 0 : type(uint128).max;
        if (liquidity == 0 && (owed0 == 0 || max0 == 0) && (owed1 == 0 || max1 == 0)) return (true, "");
        INonfungiblePositionManagerDoor.CollectParams memory params =
            INonfungiblePositionManagerDoor.CollectParams(tokenId, address(this), max0, max1);
        try pm.collect{gas: COLLECT_GAS_CAP}(params) returns (uint256 amount0, uint256 amount1) {
            emit Collected(tokenId, amount0, amount1);
            return (true, "");
        } catch {
            bytes memory data = _revertData(REASON_BYTES);
            emit CollectFailed(tokenId, data);
            return (false, data);
        }
    }

    /// @dev One unwrap of the wrapper balance with `UNWRAP_GAS`, by a plain call so a wrapper that reverts, burns gas
    ///      or has no code is reported and never fatal; the native ETH lands in `receive`. The balance read is capped
    ///      too, since the wrapper is an upgradeable proxy on the live chain.
    function _beforeForward() internal override {
        (bool read, uint256 amount) = HookrForward.balanceOf(wrappedNative, address(this), BALANCE_GAS);
        if (!read || amount == 0) return;
        (bool ok,) = wrappedNative.call{gas: UNWRAP_GAS}(abi.encodeCall(IWETH9.withdraw, (amount)));
        if (ok) emit Unwrapped(amount);
        else emit UnwrapFailed(amount);
    }

    /// @dev The unwrap's balance read and call, each with 64/63 of its cap, and the door's work around them.
    function _pullTailGas() internal pure override returns (uint256) {
        return 160_000;
    }

    /// @dev The wrapper is the door's own too: only the token's pull unwraps and forwards it.
    function _isOwnAsset(address asset) internal view override returns (bool) {
        return asset == wrappedNative || _isAsset[asset];
    }
}
