// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HookrForwarding} from "../base/HookrForwarding.sol";
import {HookrDoorTerm} from "../base/HookrDoorTerm.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {IHookrDropBox} from "../interfaces/IHookrDropBox.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueTokenDoor} from "../interfaces/IHookrRevenueTokenDoor.sol";

/// @title Hookr revenue token door, part of the HookRevenue Tokenizer
/// @notice Shares of an inner revenue token held for an outer one. See IHookrRevenueTokenDoor for the rules.
/// @dev A pull: (1) native ETH the door holds, to the outer token. (2) The inner token's income, asset by asset from
///      the income cursor, the asset the last pull ran out of gas at, so every asset is reached in turn however much
///      the ones before it take: each asset the door is owed (`claimable`, a capped read) is claimed on its own with
///      the inner token's strict `claim` and CLAIM_GAS, straight into the outer token, or to 0xdead when the asset is
///      the outer token itself (which refuses its own shares), so no claim ever meets the outer token and no credit
///      strands. An asset whose claim fails (frozen, or refusing the outer token) stays owed and holds up none of the
///      others: the door reads at most `REASON_BYTES` of its revert data, so a failed claim costs the pull its cap and
///      little more however long that data is; an inner asset the outer token does not list lands there as a stray, which the outer token's
///      `dropStray` hands to its drop box (an immediate drop at a release period under an hour, the stray stream at
///      an hour or more). (3) Up to DROPS_PER_PULL inner drops from the drop cursor, each only with DROP_ITEM_GAS
///      left: the door's share is claimed into the door by the box's own `claim` with DROP_CLAIM_GAS, with no capped
///      pre-read, so it is found however long the door's checkpoint archive grows, and forwarded to the outer
///      token when the outer token lists the drop's asset (native ETH always), or claimed straight to 0xdead when
///      the drop is of the outer token itself. A drop in any other currency is left where it is (`DropLeft`) at
///      every release period, not only at zero: anyone can open drops in any ERC-20, and copying each one into the
///      outer box would make every basket level above it pay for it again (at a release period under an hour one
///      outer drop per inner one). `claimDrop` still takes it on request and forwards it into the outer box; the
///      executor has no `claimDrop` step, so a keeper or the holder calls it. A drop the door has no share in is
///      skipped; one whose claim fails is reported and can be claimed later with `claimDrop`, as can any drop from
///      the door's first one on that the drop cursor has not reached, so a queue of drops nobody wants never holds a
///      real one behind it. The inner shares are the door's principal: only `release` moves them.
///
///      Keepers: an inner asset whose claim burns its whole cap is retried on every pull (it stays owed), so a door
///      over an inner token that lists such an asset costs about 11.1M gas on every pull, and a queue of inner drops
///      in a listed currency whose claim burns its cap costs about 6.4M (four claims). On a token with open streams
///      anyone can add such a door. Three of them starve a full `sync()`: simulate each door and pull through
///      `syncSome` with an exclusion list.
///
///      Gas: the tokenizer gives this door `PULL_GAS` (12,000,000, the token's largest stipend). The claim caps are
///      sized for the costliest asset an inner token can list, a revenue token of this tokenizer with eight assets,
///      at its costliest moment: each of the eight has its first income streaming, so the claim releases all eight
///      streams and writes a first credit for both sides in every asset. Measured cold, its strict claim into an
///      outer token holding it takes 1,175,338 and a drop share of it into the door 1,146,341. A pull starts an asset
///      only with `INCOME_ITEM_GAS` left and a drop only with `DROP_ITEM_GAS` left, so at that worst it claims at
///      least six inner assets, and the cursor brings the rest first on the next pull; an ordinary pull claims every
///      asset and goes on to four drops. Measured cold against the mocks: a pull that claims income in two assets and
///      four drops into the outer box takes about 560,000.
contract HookrRevenueTokenDoor is IHookrRevenueTokenDoor, HookrForwarding, HookrDoorTerm {
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public constant CLAIM_GAS = 1_600_000;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public constant INCOME_ITEM_GAS = 1_700_000;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public constant DROP_CLAIM_GAS = 1_600_000;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public constant DROPS_PER_PULL = 4;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public constant DROP_ITEM_GAS = 4_050_000;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint32 public constant PULL_GAS = 12_000_000;
    /// @dev Gas a pull keeps for a cursor write and its return after the last asset or drop.
    uint256 internal constant END_GAS = 30_000;
    /// @dev The most revert data of a failed inner claim the door reads and logs in `IncomeClaimFailed`: the error's
    ///      selector and its first four words. An inner asset's revert data reaches the door unchanged through the
    ///      inner token's `safeTransfer`, so copying or logging all of it would let two assets reverting with about
    ///      500,000 bytes each run a pull out of gas and undo its other claims. A failed drop claim is read only to its
    ///      selector.
    uint256 internal constant REASON_BYTES = 132;

    /// @inheritdoc IHookrRevenueTokenDoor
    address public immutable inner;
    /// @inheritdoc IHookrRevenueTokenDoor
    address public immutable innerDropBox;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public immutable firstDrop;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public dropCursor;
    /// @inheritdoc IHookrRevenueTokenDoor
    bool public released;
    /// @inheritdoc IHookrRevenueTokenDoor
    uint256 public incomeCursor;

    /// @param outer The revenue token every pull pays.
    /// @param inner_ The revenue token whose shares the door holds; it must exist, and differ from `outer`.
    /// @param returnTo_ The account the shares go back to.
    /// @param unlockAt_ The unlock timestamp, after now, or FOREVER.
    constructor(address outer, address inner_, address returnTo_, uint64 unlockAt_)
        HookrForwarding(outer)
        HookrDoorTerm(returnTo_, unlockAt_)
    {
        if (inner_ == outer) revert SameToken();
        address box = IHookrRevenueToken(inner_).dropBox();
        inner = inner_;
        innerDropBox = box;
        uint256 first = IHookrDropBox(box).dropCount();
        firstDrop = first;
        dropCursor = first;
    }

    /// @notice Takes native drops claimed into the door, forwarded at once; anything else sent here is forwarded by
    ///         the next pull.
    receive() external payable {}

    /// @inheritdoc IHookrRevenueTokenDoor
    function shares() external view returns (uint256) {
        return IERC20(inner).balanceOf(address(this));
    }

    /// @notice Forwards native ETH the door holds, claims the inner token's income into the outer token and the
    ///         door's share of the next inner drops. Only the outer token.
    function pull() external onlyRevenueToken nonReentrant {
        if (address(this).balance != 0) _forwardHeld(address(0));
        _claimIncome();
        uint256 id = dropCursor;
        uint256 count = IHookrDropBox(innerDropBox).dropCount();
        uint256 end = id + DROPS_PER_PULL < count ? id + DROPS_PER_PULL : count;
        for (; id < end; ++id) {
            if (gasleft() < DROP_ITEM_GAS + END_GAS) break;
            _claimDrop(id, true);
        }
        dropCursor = id;
    }

    /// @inheritdoc IHookrRevenueTokenDoor
    /// @dev A drop the door claimed already has nothing claimable left, so it is skipped here and when the cursor
    ///      reaches it.
    function claimDrop(uint256 dropId) external nonReentrant {
        if (dropId < firstDrop || dropId >= IHookrDropBox(innerDropBox).dropCount()) {
            revert IHookrDropBox.UnknownDrop(dropId);
        }
        _claimDrop(dropId, false);
    }

    /// @inheritdoc IHookrRevenueTokenDoor
    function release() external nonReentrant {
        if (released) revert AlreadyReleased();
        _requireUnlocked();
        released = true;
        uint256 amount = IERC20(inner).balanceOf(address(this));
        if (amount != 0) IERC20(inner).safeTransfer(returnTo, amount);
        emit Released(returnTo, amount);
    }

    /// @dev Each inner asset the door is owed, one lap from the income cursor, by the inner token's strict `claim`
    ///      with CLAIM_GAS: into the outer token, or to 0xdead when the asset is the outer token itself. Starts an
    ///      asset only with INCOME_ITEM_GAS left; the asset it stops at is where the next pull starts (the inner token
    ///      only ever adds assets, so the cursor stays one of them). A claim that fails stays owed for a later pull,
    ///      and its revert data is read and logged only to `REASON_BYTES`. Never reverts.
    function _claimIncome() private {
        IHookrRevenueToken it = IHookrRevenueToken(inner);
        address outer = revenueToken;
        uint256 own = type(uint256).max;
        if (it.isAsset(Currency.wrap(outer))) own = it.assetOf(Currency.wrap(outer));
        uint256 n = it.assetCount();
        uint256 start = incomeCursor;
        uint256 i = start;
        for (uint256 k; k < n; ++k) {
            if (gasleft() < INCOME_ITEM_GAS + END_GAS) {
                if (i != start) incomeCursor = i;
                return;
            }
            (bool read, uint256 owed) = HookrForward.read(
                address(it), abi.encodeCall(IHookrRevenueToken.claimable, (address(this), i)), BALANCE_GAS
            );
            if (read && owed != 0) {
                try it.claim{gas: CLAIM_GAS}(i, i == own ? DEAD : outer) returns (uint256 amount) {
                    if (i == own) emit Retired(amount);
                    else emit IncomeClaimed(i, amount);
                } catch {
                    emit IncomeClaimFailed(i, _revertData(REASON_BYTES));
                }
            }
            i = i + 1 == n ? 0 : i + 1;
        }
    }

    /// @dev The door's share of drop `dropId`, claimed into the door and forwarded, or claimed straight to 0xdead when
    ///      the drop is of the outer token itself, by the box's own `claim` with DROP_CLAIM_GAS and no pre-read: the
    ///      share is the door's balance at the drop's snapshot, a search over its checkpoint archive that anyone can
    ///      lengthen with dust transfers, so a read under a smaller cap could be made to fail for good. A drop the
    ///      door has no share in, or claimed already, is skipped quietly (the box's `NothingToClaim` and
    ///      `AlreadyClaimed`, read from the first 4 bytes of the revert data, never more); any other refusal is
    ///      reported. `listedOnly` (a pull): a drop in a currency the outer
    ///      token does not list is left for `claimDrop` (`DropLeft`, only when the door has a share or the share cannot
    ///      be read under the same cap), as is one whose listing cannot be read. Never reverts.
    function _claimDrop(uint256 dropId, bool listedOnly) private {
        IHookrDropBox box = IHookrDropBox(innerDropBox);
        address asset = box.dropAt(dropId).asset;
        bool own = asset == revenueToken;
        if (listedOnly && !own && asset != address(0)) {
            (bool known, uint256 listed) = HookrForward.read(
                revenueToken, abi.encodeCall(IHookrRevenueToken.isAsset, (Currency.wrap(asset))), BALANCE_GAS
            );
            if (!known || listed == 0) {
                (bool read, uint256 owed) = HookrForward.read(
                    address(box), abi.encodeCall(IHookrDropBox.claimable, (dropId, address(this))), DROP_CLAIM_GAS
                );
                if (!read || owed != 0) emit DropLeft(dropId, asset);
                return;
            }
        }
        uint256[] memory ids = new uint256[](1);
        ids[0] = dropId;
        try box.claim{gas: DROP_CLAIM_GAS}(ids, own ? DEAD : address(this)) returns (uint256[] memory amounts) {
            emit DropClaimed(dropId, asset, amounts[0]);
            if (own) emit Retired(amounts[0]);
            else _forward(asset, amounts[0]);
        } catch {
            bytes4 code = bytes4(_revertData(4));
            if (code != IHookrDropBox.NothingToClaim.selector && code != IHookrDropBox.AlreadyClaimed.selector) {
                emit DropClaimFailed(dropId);
            }
        }
    }

    /// @dev The last call's revert data, cut to its first `max` bytes: one bounded copy, whatever the callee returned.
    function _revertData(uint256 max) private pure returns (bytes memory data) {
        assembly ("memory-safe") {
            let size := returndatasize()
            if gt(size, max) { size := max }
            data := mload(0x40)
            mstore(data, size)
            returndatacopy(add(data, 0x20), 0, size)
            mstore(0x40, add(add(data, 0x20), and(add(size, 31), not(31))))
        }
    }

    /// @dev The inner shares are the door's principal; nothing else is its own.
    function _isOwnAsset(address asset) internal view override returns (bool) {
        return asset == inner;
    }

    function _isReleased() internal view override returns (bool) {
        return released;
    }
}
