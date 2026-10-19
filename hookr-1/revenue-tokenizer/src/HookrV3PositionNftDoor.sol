// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrV3PositionNftDoor} from "./interfaces/IHookrV3PositionNftDoor.sol";
import {HookrForward} from "./libraries/HookrForward.sol";
import {INonfungiblePositionManagerDoor} from "./interfaces/external/INonfungiblePositionManagerDoor.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";

/// @title Hookr v3 position NFT door, part of the HookRevenue Tokenizer
/// @notice The v3 position-NFT door of the HookRevenue Tokenizer: a bundle of Uniswap v3 position NFTs whose
///         principal is locked until a chosen date, or forever, and whose fees anyone can push to a revenue token.
///         The v4 door (HookrPositionNftDoor) for the v3 NonfungiblePositionManager; see IHookrV3PositionNftDoor
///         for what differs.
/// @dev Lifecycle, all inside the factory's `create` transaction: the constructor fixes the revenue token, the unlock
///      time and the NFT list (at most MAX_POSITIONS); the manager hands each listed NFT over (`onERC721Received`
///      records who deposited it); the factory calls `activate`, which checks the door owns every listed NFT, that
///      each has liquidity, and reads each one's pool (token0, token1, fee) into the asset list with native ETH in
///      the wrapper's place. After that the door has no owner and nothing can be changed: no NFT can be added, moved
///      out or have its liquidity decreased until `release`, and a door with unlock FOREVER never releases.
///
///      `pull` collects each position with one `collect` (both maxima at their largest, paid to the door), each
///      collection in its own `try` with at most COLLECT_GAS_CAP gas, and reads each asset's balance with at most
///      BALANCE_GAS (a read that fails is reported and skipped), so one position (or a hostile token in its pool)
///      can neither block the others nor eat more than the caps. The manager pokes the pool first when the
///      position has liquidity, so one call collects everything owed, in the pool's two ERC-20s. The native side
///      arrives as the manager's WETH9: the door unwraps its whole wrapper balance with UNWRAP_GAS (a refusal is
///      reported, the wrapper waits for a later pull) and forwards native ETH in its place. Then it forwards every
///      asset it holds to the revenue token: native ETH by a plain call (the revenue token's `receive` is empty),
///      ERC-20s by `transfer`; each forward is its own attempt with `FORWARD_GAS`, and a refused one leaves that
///      asset in the door for a later `pull` without touching the forwards after it. The revenue token recognizes
///      income by balance delta in its own sync, so the door never calls into it otherwise.
///
///      Every collection must find `COLLECT_GAS_FLOOR` left or the call reverts, so a token that burns its whole cap
///      on each collection sets the cost of a whole-list `pull` or `release`; `pullSome` and `releaseSome` take a
///      list of the door's own token ids, so an honest position is collected and released on its own gas whatever
///      the others' tokens do; the whole-list forms stay for the revenue token's sync and the plain case.
///
///      Fees are the only value that can leave through `pull`: `collect` touches no liquidity, and the door never
///      calls `decreaseLiquidity` or `burn`. `release` works NFT by NFT: a strict final collection, then the NFT goes
///      back to its depositor by a plain `transferFrom` (so a depositor that is a contract without
///      `onERC721Received` still gets it). An NFT whose final collection fails stays in the door and can be released
///      later; it never holds the others, and no fee ever rides out on an NFT. There is no grace period that would
///      make the final collection best-effort: that would let the issuer of a hostile pool token block collection
///      past the unlock and walk out with the fees, which hurts the revenue token's holders, while a held NFT only
///      costs its own depositor.
contract HookrV3PositionNftDoor is IHookrV3PositionNftDoor {
    /// @inheritdoc IHookrV3PositionNftDoor
    uint64 public constant FOREVER = type(uint64).max;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public constant MAX_POSITIONS = 64;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public constant COLLECT_GAS_CAP = 1_500_000;
    /// @inheritdoc IHookrV3PositionNftDoor
    /// @dev Reading the position, encoding the call, the events.
    uint256 public constant COLLECT_GAS_MARGIN = 120_000;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public constant COLLECT_GAS_FLOOR = (COLLECT_GAS_CAP * 64) / 63 + COLLECT_GAS_MARGIN;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public constant FORWARD_GAS = 300_000;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public constant BALANCE_GAS = 50_000;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public constant UNWRAP_GAS = 100_000;

    /// @inheritdoc IHookrV3PositionNftDoor
    INonfungiblePositionManagerDoor public immutable positionManager;
    /// @inheritdoc IHookrV3PositionNftDoor
    address public immutable revenueToken;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint64 public immutable unlockAt;
    /// @inheritdoc IHookrV3PositionNftDoor
    address public immutable factory;
    /// @inheritdoc IHookrV3PositionNftDoor
    address public immutable wrappedNative;

    /// @dev What the door keeps per listed position, in one slot: who handed it over (zero until it arrives), that
    ///      it is on the list, and whether it went back.
    struct Position {
        address depositor;
        bool listed;
        bool released;
    }

    /// @dev A listed position's pool, read once at activation.
    struct Pool {
        address token0;
        address token1;
        uint24 fee;
    }

    uint256[] private _tokenIds;
    address[] private _assets;
    mapping(uint256 tokenId => Position) private _positions;
    mapping(uint256 tokenId => Pool) private _pools;
    mapping(address asset => bool) private _isAsset;
    /// @inheritdoc IHookrV3PositionNftDoor
    bool public active;
    /// @inheritdoc IHookrV3PositionNftDoor
    bool public released;
    /// @inheritdoc IHookrV3PositionNftDoor
    uint256 public releasedCount;
    bool private transient _entered;

    modifier nonReentrant() {
        if (_entered) revert Reentered();
        _entered = true;
        _;
        _entered = false;
    }

    modifier whenActive() {
        if (!active) revert NotActive();
        _;
    }

    /// @param positionManager_ The Uniswap v3 NonfungiblePositionManager that minted the NFTs.
    /// @param revenueToken_ The revenue token every collected fee goes to.
    /// @param unlockAt_ The unlock timestamp, after now, or FOREVER.
    /// @param tokenIds_ The position NFTs the door will hold; no duplicates, at most MAX_POSITIONS.
    /// @param wrappedNative_ The manager's WETH9, unwrapped before forwarding.
    constructor(
        INonfungiblePositionManagerDoor positionManager_,
        address revenueToken_,
        uint64 unlockAt_,
        uint256[] memory tokenIds_,
        address wrappedNative_
    ) {
        if (revenueToken_ == address(0)) revert RevenueTokenZero();
        if (unlockAt_ != FOREVER && unlockAt_ <= block.timestamp) revert UnlockNotInFuture(unlockAt_, block.timestamp);
        if (tokenIds_.length == 0) revert NoPositions();
        if (tokenIds_.length > MAX_POSITIONS) revert TooManyPositions(tokenIds_.length, MAX_POSITIONS);
        for (uint256 i; i < tokenIds_.length; ++i) {
            uint256 tokenId = tokenIds_[i];
            Position storage p = _positions[tokenId];
            if (p.listed) revert DuplicateToken(tokenId);
            p.listed = true;
        }
        positionManager = positionManager_;
        revenueToken = revenueToken_;
        unlockAt = unlockAt_;
        factory = msg.sender;
        wrappedNative = wrappedNative_;
        _tokenIds = tokenIds_;
    }

    // ------------------------------------------------------------------ creation

    /// @notice Accepts a listed NFT from the manager while the door is being created and records who sent it.
    /// @dev Returns the selector and nothing else. Any other sender, any unlisted token, a second delivery of the
    ///      same token or a delivery after activation reverts.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert OnlyPositionManager();
        if (active) revert NotAccepting();
        Position storage p = _positions[tokenId];
        if (!p.listed) revert NotListed(tokenId);
        if (p.depositor != address(0)) revert AlreadyReceived(tokenId);
        p.depositor = from;
        return this.onERC721Received.selector;
    }

    /// @notice Called by the factory once every listed NFT has been handed over: checks the door owns each one and
    ///         that each has liquidity, reads each one's pool and fixes the asset list (native ETH in the wrapper's
    ///         place). After this call nothing about the door can change.
    function activate() external {
        if (msg.sender != factory) revert OnlyFactory();
        if (active) revert AlreadyActive();
        uint256 n = _tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = _tokenIds[i];
            if (_positions[tokenId].depositor == address(0)) revert NotReceived(tokenId);
            if (positionManager.ownerOf(tokenId) != address(this)) revert NotOwned(tokenId);
            (,, address token0, address token1, uint24 fee,,, uint128 liquidity,,,,) =
                positionManager.positions(tokenId);
            if (liquidity == 0) revert NoLiquidity(tokenId);
            _pools[tokenId] = Pool(token0, token1, fee);
            _addAsset(token0);
            _addAsset(token1);
        }
        active = true;
        emit Activated(revenueToken, unlockAt, _tokenIds, _assets);
    }

    /// @dev Lists a pool token once, native ETH standing for the wrapper.
    function _addAsset(address token) private {
        address asset = token == wrappedNative ? address(0) : token;
        if (_isAsset[asset]) return;
        _isAsset[asset] = true;
        _assets.push(asset);
    }

    // ------------------------------------------------------------------ actions

    /// @inheritdoc IHookrV3PositionNftDoor
    function pull() external nonReentrant whenActive {
        _pull(_tokenIds);
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function pullSome(uint256[] calldata ids) external nonReentrant whenActive {
        _pull(_checked(ids));
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function release() external nonReentrant whenActive {
        _release(_tokenIds);
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function releaseSome(uint256[] calldata ids) external nonReentrant whenActive {
        _release(_checked(ids));
    }

    /// @dev Collects each listed position in `ids` that is still here, then forwards everything the door holds.
    function _pull(uint256[] memory ids) private {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = ids[i];
            if (_positions[tokenId].released) continue;
            _collect(tokenId);
        }
        _forwardAll();
    }

    /// @dev Releases each listed position in `ids` that is still here, after a strict final collection of each, then
    ///      forwards everything the door holds. Reverts when none moved.
    function _release(uint256[] memory ids) private {
        if (released) revert AlreadyReleased();
        if (unlockAt == FOREVER) revert LockedForever();
        if (block.timestamp < unlockAt) revert StillLocked(unlockAt, block.timestamp);
        uint256 n = ids.length;
        uint256 moved;
        bool anyHeld;
        uint256 firstHeld;
        bytes memory firstReason;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = ids[i];
            Position storage p = _positions[tokenId];
            if (p.released) continue;
            (bool ok, bytes memory reason) = _collect(tokenId);
            if (!ok) {
                if (!anyHeld) (anyHeld, firstHeld, firstReason) = (true, tokenId, reason);
                emit ReleaseHeld(tokenId);
                continue;
            }
            p.released = true;
            ++moved;
            address depositor = p.depositor;
            positionManager.transferFrom(address(this), depositor, tokenId);
            emit Released(tokenId, depositor);
        }
        if (moved == 0) revert NoneReleased(firstHeld, firstReason);
        releasedCount += moved;
        if (releasedCount == _tokenIds.length) released = true;
        _forwardAll();
    }

    /// @dev A caller's id list: not empty, every id on the door's list (`NotListed` otherwise). A repeated id is
    ///      collected once more and never released twice (`released` is set before the next one is read).
    function _checked(uint256[] calldata ids) private view returns (uint256[] memory out) {
        uint256 n = ids.length;
        if (n == 0) revert NoPositions();
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = ids[i];
            if (!_positions[tokenId].listed) revert NotListed(tokenId);
            out[i] = tokenId;
        }
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    /// @dev A released NFT is known as listed and released, so `release` never moves it again; it goes back to its
    ///      depositor here instead of staying in the door for good.
    function rescueUnlisted(uint256 tokenId) external nonReentrant whenActive {
        Position storage p = _positions[tokenId];
        if (p.listed && !p.released) revert Listed(tokenId);
        if (positionManager.ownerOf(tokenId) != address(this)) revert NotOwned(tokenId);
        address to = p.listed ? p.depositor : _positions[_tokenIds[0]].depositor;
        positionManager.transferFrom(address(this), to, tokenId);
        emit UnlistedReturned(tokenId, to);
    }

    /// @dev Collects one position's fees into the door with at most COLLECT_GAS_CAP gas. A position with no liquidity
    ///      and nothing owed is skipped as a success: it has no fees to collect. Returns whether the collection went
    ///      through and, if not, the revert data (empty when the cap ran out).
    function _collect(uint256 tokenId) private returns (bool ok, bytes memory reason) {
        uint256 left = gasleft();
        if (left < COLLECT_GAS_FLOOR) revert InsufficientGas(tokenId, left, COLLECT_GAS_FLOOR);
        (,,,,,,, uint128 liquidity,,, uint128 owed0, uint128 owed1) = positionManager.positions(tokenId);
        if (liquidity == 0 && owed0 == 0 && owed1 == 0) return (true, "");
        INonfungiblePositionManagerDoor.CollectParams memory params =
            INonfungiblePositionManagerDoor.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max);
        try positionManager.collect{gas: COLLECT_GAS_CAP}(params) returns (uint256 amount0, uint256 amount1) {
            emit Collected(tokenId, amount0, amount1);
            return (true, "");
        } catch (bytes memory data) {
            emit CollectFailed(tokenId, data);
            return (false, data);
        }
    }

    /// @dev Unwraps the door's whole wrapper balance to native ETH with `UNWRAP_GAS`, then tries to send everything
    ///      the door holds of every asset to the revenue token. Each asset is its own attempt with `FORWARD_GAS`: a
    ///      refused forward is reported and the asset waits in the door for the next `pull`, and the assets after it
    ///      are forwarded all the same; nothing ever goes anywhere but the revenue token.
    function _forwardAll() private {
        _unwrap();
        uint256 n = _assets.length;
        for (uint256 i; i < n; ++i) {
            address asset = _assets[i];
            (bool read, uint256 amount) = _held(asset);
            if (!read) {
                emit BalanceReadFailed(asset);
                continue;
            }
            if (amount == 0) continue;
            if (_forward(asset, amount)) emit Forwarded(asset, amount);
            else emit ForwardFailed(asset, amount);
        }
    }

    /// @dev The door's balance of `asset`: the native balance, or a `balanceOf` read with `BALANCE_GAS` that may
    ///      fail (`read` false) without reverting the call, so one pool token's issuer cannot hold every position's
    ///      fees and principal behind a view.
    function _held(address asset) private view returns (bool read, uint256 amount) {
        if (asset == address(0)) return (true, address(this).balance);
        return HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
    }

    /// @dev One unwrap of the wrapper balance with `UNWRAP_GAS`, by a plain call so a wrapper that reverts, burns gas
    ///      or has no code is reported and never fatal; the native ETH lands in `receive`. The balance read is capped
    ///      too (`BalanceReadFailed`), since the wrapper is an upgradeable proxy on the live chain. The wrapper is the
    ///      manager's, fixed at creation, so what it answers after a successful call is trusted as the balance it
    ///      paid out.
    function _unwrap() private {
        (bool read, uint256 amount) = HookrForward.balanceOf(wrappedNative, address(this), BALANCE_GAS);
        if (!read) {
            emit BalanceReadFailed(wrappedNative);
            return;
        }
        if (amount == 0) return;
        (bool ok,) = wrappedNative.call{gas: UNWRAP_GAS}(abi.encodeCall(IWETH9.withdraw, (amount)));
        if (ok) emit Unwrapped(amount);
        else emit UnwrapFailed(amount);
    }

    /// @dev One forward to the revenue token with `FORWARD_GAS`: a plain call for native ETH, `transfer` for an ERC-20
    ///      that copies at most one word of its answer (HookrForward: a token that returns nothing counts as success
    ///      when it has code; a returned word must be nonzero). The cap keeps a transfer that burns gas from taking
    ///      63/64 of the pull and starving the forwards after it, and the one-word copy keeps a large answer from
    ///      costing the door anything past the cap. Never reverts.
    function _forward(address asset, uint256 amount) private returns (bool ok) {
        if (asset == address(0)) return HookrForward.send(revenueToken, amount, FORWARD_GAS);
        return HookrForward.transfer(asset, revenueToken, amount, FORWARD_GAS);
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    /// @dev The revenue token's own `dropStray` then splits it. Native ETH, the wrapper and the door's assets are `pull`'s.
    function forwardUnlisted(address asset) external nonReentrant whenActive returns (uint256 amount) {
        if (asset == address(0) || _isAsset[asset] || asset == wrappedNative) revert ListedAsset(asset);
        bool read;
        (read, amount) = HookrForward.balanceOf(asset, address(this), BALANCE_GAS);
        if (!read || amount == 0) revert NothingToForward(asset);
        if (!HookrForward.transfer(asset, revenueToken, amount, FORWARD_GAS)) revert ForwardRefused(asset);
        emit UnlistedForwarded(asset, amount);
    }

    /// @notice Takes the native ETH an unwrap pays out. Anything sent here goes to the revenue token on the next
    ///         `pull`.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrV3PositionNftDoor
    function tokenIds() external view returns (uint256[] memory) {
        return _tokenIds;
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function depositorOf(uint256 tokenId) external view returns (address) {
        return _positions[tokenId].depositor;
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function releasedOf(uint256 tokenId) external view returns (bool) {
        return _positions[tokenId].released;
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function assets() external view returns (address[] memory) {
        return _assets;
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function poolOf(uint256 tokenId) external view returns (address token0, address token1, uint24 fee) {
        Pool storage p = _pools[tokenId];
        return (p.token0, p.token1, p.fee);
    }

    /// @inheritdoc IHookrV3PositionNftDoor
    function canRelease() external view returns (bool) {
        return active && !released && unlockAt != FOREVER && block.timestamp >= unlockAt;
    }
}
