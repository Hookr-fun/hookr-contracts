// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {HookrForwarding} from "./HookrForwarding.sol";
import {HookrDoorTerm} from "./HookrDoorTerm.sol";
import {IHookrPositionBundle} from "../interfaces/IHookrPositionBundle.sol";

/// @title Hookr position bundle, part of the HookRevenue Tokenizer
/// @notice The part the v4 and v3 position-NFT doors share (IHookrPositionBundle): the NFT list, the receipt from one
///         account, activation, the paged token pull, `pullSome`, the per-NFT release and the rescue of non-principal
///         NFTs. A door adds how a position is read at activation and how it is collected.
/// @dev Fees are the only value a collection moves, and each collection is its own `try` with at most
///      COLLECT_GAS_CAP gas, and its revert data is read only to `REASON_BYTES`, so one position (or a hostile hook or
///      token in its pool) can neither block the others nor eat more than the cap. A token pull walks the list from a cursor and starts a collection only while
///      `COLLECT_GAS_FLOOR` plus the forwarding reserve is left, so it always ends inside its stipend and the next
///      pull carries on where it stopped; the currencies are forwarded the same way, in turn from their own cursor.
///      `release` works NFT by NFT: a strict final collection, then the NFT goes back to `returnTo` by a plain
///      `transferFrom` (so a contract without `onERC721Received` still gets it). An NFT whose final collection fails
///      stays in the door and can be released later; it never holds the others, and no fee rides out on an NFT but a
///      v3 position's fee in the revenue token itself, which the token never lets into its own door.
///
///      The currency list starts with native ETH, so ETH that reaches the door by any route is forwarded too, and
///      never holds the revenue token itself: the token refuses a transfer to its own door, so a collection never
///      brings that side here.
abstract contract HookrPositionBundle is IHookrPositionBundle, HookrForwarding, HookrDoorTerm {
    /// @inheritdoc IHookrPositionBundle
    uint256 public constant MAX_POSITIONS = 64;
    /// @inheritdoc IHookrPositionBundle
    uint256 public constant COLLECT_GAS_CAP = 1_500_000;
    /// @inheritdoc IHookrPositionBundle
    uint256 public constant COLLECT_GAS_MARGIN = 120_000;
    /// @inheritdoc IHookrPositionBundle
    uint256 public constant COLLECT_GAS_FLOOR = (COLLECT_GAS_CAP * 64) / 63 + COLLECT_GAS_MARGIN;
    /// @inheritdoc IHookrPositionBundle
    uint256 public constant FORWARD_PAGE = 2;
    /// @inheritdoc IHookrPositionBundle
    uint256 public constant PULL_BASE_GAS = 150_000;
    /// @dev Gas a token pull keeps for the cursor writes and its return after the last forward.
    uint256 internal constant END_GAS = 30_000;
    /// @dev How much of a failed collection's revert data a door reads, logs and returns: the selector and four words.
    uint256 internal constant REASON_BYTES = 132;

    /// @dev What the door keeps per listed position, in one slot.
    struct Position {
        bool listed;
        bool received;
        bool released;
    }

    /// @dev The position manager that minted the NFTs.
    address internal immutable _manager;
    /// @inheritdoc IHookrPositionBundle
    address public immutable factory;

    uint256[] internal _tokenIds;
    address[] internal _assets;
    mapping(uint256 tokenId => Position) internal _positions;
    mapping(address asset => bool) internal _isAsset;
    /// @inheritdoc IHookrPositionBundle
    bool public active;
    /// @inheritdoc IHookrPositionBundle
    bool public released;
    /// @dev Where the next token pull starts collecting, and forwarding.
    uint32 internal _cursor;
    uint32 internal _assetCursor;
    /// @inheritdoc IHookrPositionBundle
    uint256 public releasedCount;

    modifier whenActive() {
        if (!active) revert NotActive();
        _;
    }

    /// @param manager The position manager that minted the NFTs.
    /// @param revenueToken_ The revenue token every collected fee goes to.
    /// @param returnTo_ The account that hands every NFT over and gets each back at release.
    /// @param unlockAt_ The unlock timestamp, after now, or FOREVER.
    /// @param tokenIds_ The position NFTs the door will hold; no duplicates, 1 to MAX_POSITIONS.
    constructor(address manager, address revenueToken_, address returnTo_, uint64 unlockAt_, uint256[] memory tokenIds_)
        HookrForwarding(revenueToken_)
        HookrDoorTerm(returnTo_, unlockAt_)
    {
        if (tokenIds_.length == 0) revert NoPositions();
        if (tokenIds_.length > MAX_POSITIONS) revert TooManyPositions(tokenIds_.length, MAX_POSITIONS);
        for (uint256 i; i < tokenIds_.length; ++i) {
            Position storage p = _positions[tokenIds_[i]];
            if (p.listed) revert DuplicateToken(tokenIds_[i]);
            p.listed = true;
        }
        _manager = manager;
        factory = msg.sender;
        _tokenIds = tokenIds_;
        _addAsset(address(0));
    }

    // ------------------------------------------------------------------ creation

    /// @notice Accepts a listed NFT from the position manager while the door is being created, from `returnTo` alone.
    /// @dev Returns the selector and nothing else. Any other sender or origin, any unlisted token, a second delivery of
    ///      the same token or a delivery after activation reverts.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != _manager) revert OnlyPositionManager();
        if (active || from != returnTo) revert NotAccepting();
        Position storage p = _positions[tokenId];
        if (!p.listed) revert NotListed(tokenId);
        if (p.received) revert AlreadyReceived(tokenId);
        p.received = true;
        return this.onERC721Received.selector;
    }

    /// @notice Called by the factory once every listed NFT has been handed over: checks the door owns each one,
    ///         reads each one's pool and fixes the currency list. After this call the list cannot change.
    function activate() external {
        if (msg.sender != factory) revert OnlyFactory();
        if (active) revert AlreadyActive();
        uint256 n = _tokenIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = _tokenIds[i];
            if (!_positions[tokenId].received) revert NotReceived(tokenId);
            if (IERC721(_manager).ownerOf(tokenId) != address(this)) revert NotOwned(tokenId);
            _activatePosition(tokenId);
        }
        active = true;
        emit Activated(revenueToken, unlockAt, _tokenIds, _assets);
    }

    // ------------------------------------------------------------------ actions

    /// @notice Collects a page of positions and forwards the door's currencies to the revenue token. Only the revenue
    ///         token. After the release it only forwards what the final collections left here.
    /// @dev Starts at the cursor and collects each held position while `COLLECT_GAS_FLOOR` plus the forwarding reserve
    ///      is left, at most one lap; then forwards the currencies in turn while `FORWARD_ITEM_GAS` is left. Never
    ///      reverts for want of gas: what it could not reach waits for the next pull.
    function pull() external onlyRevenueToken nonReentrant whenActive {
        uint256 n = _tokenIds.length;
        uint256 m = _assets.length;
        uint256 need =
            COLLECT_GAS_FLOOR + (m < FORWARD_PAGE ? m : FORWARD_PAGE) * FORWARD_ITEM_GAS + _pullTailGas() + END_GAS;
        uint256 cursor = _cursor;
        if (!released) {
            for (uint256 k; k < n; ++k) {
                uint256 tokenId = _tokenIds[cursor];
                if (!_positions[tokenId].released) {
                    if (gasleft() < need) break;
                    _collect(tokenId);
                }
                cursor = cursor + 1 == n ? 0 : cursor + 1;
            }
        }
        _beforeForward();
        uint256 a = _assetCursor;
        for (uint256 k; k < m; ++k) {
            if (gasleft() < FORWARD_ITEM_GAS + END_GAS) break;
            _forwardHeld(_assets[a]);
            a = a + 1 == m ? 0 : a + 1;
        }
        (_cursor, _assetCursor) = (uint32(cursor), uint32(a));
    }

    /// @inheritdoc IHookrPositionBundle
    function pullSome(uint256[] calldata ids) external nonReentrant whenActive {
        uint256[] memory list = _checked(ids);
        for (uint256 i; i < list.length; ++i) {
            uint256 tokenId = list[i];
            if (_positions[tokenId].released) continue;
            _requireCollectGas(tokenId);
            _collect(tokenId);
        }
    }

    /// @inheritdoc IHookrPositionBundle
    function release() external nonReentrant whenActive {
        _release(_tokenIds);
    }

    /// @inheritdoc IHookrPositionBundle
    function releaseSome(uint256[] calldata ids) external nonReentrant whenActive {
        _release(_checked(ids));
    }

    /// @inheritdoc IHookrPositionBundle
    function rescueUnlisted(uint256 tokenId) external nonReentrant whenActive {
        Position storage p = _positions[tokenId];
        if (p.listed && !p.released) revert Listed(tokenId);
        if (IERC721(_manager).ownerOf(tokenId) != address(this)) revert NotOwned(tokenId);
        IERC721(_manager).transferFrom(address(this), returnTo, tokenId);
        emit UnlistedReturned(tokenId, returnTo);
    }

    /// @notice Takes the native fees a collection pays out. Anything sent here goes to the revenue token on its next
    ///         pull: native ETH is always one of the door's currencies.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrPositionBundle
    function tokenIds() external view returns (uint256[] memory) {
        return _tokenIds;
    }

    /// @inheritdoc IHookrPositionBundle
    function assets() external view returns (address[] memory) {
        return _assets;
    }

    /// @inheritdoc IHookrPositionBundle
    function releasedOf(uint256 tokenId) external view returns (bool) {
        return _positions[tokenId].released;
    }

    /// @inheritdoc IHookrPositionBundle
    function canRelease() external view returns (bool) {
        return active && !released && unlockAt != FOREVER && block.timestamp >= unlockAt;
    }

    /// @inheritdoc IHookrPositionBundle
    function pullGas() external view returns (uint32) {
        uint256 m = _assets.length;
        uint256 gas = PULL_BASE_GAS + _pullTailGas() + _tokenIds.length * COLLECT_GAS_FLOOR
            + (m < FORWARD_PAGE ? m : FORWARD_PAGE) * FORWARD_ITEM_GAS;
        return uint32(gas < MAX_STIPEND ? gas : MAX_STIPEND);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Reads position `tokenId` at activation: reverts `NoLiquidity` on an empty one, records its pool and adds
    ///      its currencies (`_addAsset`).
    function _activatePosition(uint256 tokenId) internal virtual;

    /// @dev Collects one position's fees into the door with at most COLLECT_GAS_CAP gas. A position with nothing to
    ///      collect is a success. Returns whether it went through and, if not, the revert data cut to REASON_BYTES.
    function _collect(uint256 tokenId) internal virtual returns (bool ok, bytes memory reason);

    /// @dev The last call's revert data, cut to its first `max` bytes: one bounded copy, whatever the callee returned.
    function _revertData(uint256 max) internal pure returns (bytes memory data) {
        assembly ("memory-safe") {
            let size := returndatasize()
            if gt(size, max) { size := max }
            data := mload(0x40)
            mstore(data, size)
            returndatacopy(add(data, 0x20), 0, size)
            mstore(0x40, add(add(data, 0x20), and(add(size, 31), not(31))))
        }
    }

    /// @dev Runs once per token pull before the forwards (the v3 door unwraps its wrapper here).
    function _beforeForward() internal virtual {}

    /// @dev The gas `_beforeForward` may take, kept back from the collections.
    function _pullTailGas() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @dev Lists a currency once; never the revenue token, which no collection brings here.
    function _addAsset(address asset) internal {
        if (asset == revenueToken || _isAsset[asset]) return;
        _isAsset[asset] = true;
        _assets.push(asset);
    }

    function _isOwnAsset(address asset) internal view virtual override returns (bool) {
        return _isAsset[asset];
    }

    function _isReleased() internal view override returns (bool) {
        return released;
    }

    /// @dev Reverts `InsufficientGas` unless the next collection can get its full cap.
    function _requireCollectGas(uint256 tokenId) private view {
        uint256 left = gasleft();
        if (left < COLLECT_GAS_FLOOR) revert InsufficientGas(tokenId, left, COLLECT_GAS_FLOOR);
    }

    /// @dev Releases each listed position in `ids` that is still here, after a strict final collection into the door.
    ///      Reverts when none moved. Forwards nothing: the token's next pull does.
    function _release(uint256[] memory ids) private {
        if (released) revert AlreadyReleased();
        _requireUnlocked();
        uint256 n = ids.length;
        uint256 moved;
        bool anyHeld;
        uint256 firstHeld;
        bytes memory firstReason;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = ids[i];
            Position storage p = _positions[tokenId];
            if (p.released) continue;
            _requireCollectGas(tokenId);
            (bool ok, bytes memory reason) = _collect(tokenId);
            if (!ok) {
                if (!anyHeld) (anyHeld, firstHeld, firstReason) = (true, tokenId, reason);
                emit ReleaseHeld(tokenId);
                continue;
            }
            p.released = true;
            ++moved;
            IERC721(_manager).transferFrom(address(this), returnTo, tokenId);
            emit Released(tokenId, returnTo);
        }
        if (moved == 0) revert NoneReleased(firstHeld, firstReason);
        releasedCount += moved;
        if (releasedCount == _tokenIds.length) released = true;
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
}
