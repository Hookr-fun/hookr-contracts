// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrTokenTransfer, IHookrUtilityToken} from "./libraries/HookrTokenTransfer.sol";

/// @notice The claim surface of `HookrNativeMechanicsBlockV2` this forwarder consumes.
interface IHookrNativeMechanicsBlockV2Claims {
    function protocolRecipient() external view returns (address recipient);
    function poolManager() external view returns (address manager);
    function claimable(address quote, address account) external view returns (uint256 amount);
    function claimTo(address quote, address to) external;
}

/// @title Hookr Treasury Forwarder V1
/// @notice Rotatable payout indirection for the one treasury address a V2 market pins forever.
/// @dev `HookrNativeMechanicsBlockV2.protocolRecipient` is immutable and
///      `HookrNativeMechanicsCoordinatorLibV2` admits a market only while it equals the
///      coordinator's `treasuryBeneficiary()`. Pinning an EOA there makes rotating the treasury
///      de-admit every new market.
///      This contract is pinned instead: it owns nothing, holds no protocol authority, and only
///      forwards whatever it is owed or holds to one owner-settable `target`. Rotating `target`
///      never touches the pinned address, so admission is unaffected. Both payout paths are
///      permissionless - only the destination is governed.
contract HookrTreasuryForwarderV1 {
    using HookrTokenTransfer for IHookrUtilityToken;

    /// @dev Bounded read of a candidate block's immutable getters while validating wiring.
    uint256 private constant BLOCK_QUERY_GAS = 50_000;

    /// @notice Uniswap v4 PoolManager every bindable block settles through.
    /// @dev Held immutably so `target` can be rejected as the PoolManager even before a block is
    ///      bound. Paying the PoolManager would donate the protocol fee to whoever `take`s next.
    address public immutable poolManager;

    /// @notice Account authorized to rotate the payout target and to point at the native block.
    address public owner;
    /// @notice Account eligible to accept the pending ownership transfer.
    address public pendingOwner;
    /// @notice Sole payout destination. May legitimately be the deployer EOA at launch and a
    ///         multisig later; rotation is exactly what this contract exists to make safe.
    address public target;
    /// @notice The `HookrNativeMechanicsBlockV2` whose protocol-share accruals this forwarder pushes.
    address public nativeBlock;

    event OwnerProposed(address indexed pendingOwner);
    event OwnerProposalCleared();
    event OwnerSet(address indexed owner);
    event TargetSet(address indexed target);
    event NativeBlockSet(address indexed nativeBlock);
    event Collected(address indexed quote, address indexed target, uint256 paid);
    /// @notice Emitted when an accrual was pulled out of the block but the target rejected it.
    event ForwardDeferred(address indexed quote, address indexed target, uint256 amount);
    event Swept(address indexed token, address indexed target, uint256 amount);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error TargetUnchanged();
    error InvalidTarget();
    error InvalidPoolManager();
    error InvalidNativeBlock();
    error NativeBlockUnchanged();
    error NotBound();
    error NativeTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param owner_ Initial owner.
    /// @param target_ Initial payout destination.
    /// @param poolManager_ Uniswap v4 PoolManager the bindable block settles claims through.
    constructor(address owner_, address target_, address poolManager_) {
        if (owner_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        if (poolManager_.code.length == 0) revert InvalidPoolManager();
        poolManager = poolManager_;
        _requireSafeTarget(target_, address(0));
        owner = owner_;
        target = target_;
        emit OwnerSet(owner_);
        emit TargetSet(target_);
    }

    /// @notice Accepts the native leg of `collect`, which claims into this contract before
    ///         forwarding, and any raw value sent to it directly.
    receive() external payable {}

    /// @notice Returns the release identity used by deployment and integration tooling.
    function contractName() external pure returns (string memory) {
        return "HookrTreasuryForwarderV1";
    }

    /// @notice Returns the forwarder interface version.
    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    /// @notice Proposes a new owner, or clears a pending proposal when `nextOwner` is zero.
    /// @param nextOwner Account that may accept ownership; `address(0)` cancels the standing offer.
    function proposeOwner(address nextOwner) external onlyOwner {
        if (nextOwner == owner) revert ZeroAddress();
        pendingOwner = nextOwner;
        if (nextOwner == address(0)) {
            emit OwnerProposalCleared();
        } else {
            emit OwnerProposed(nextOwner);
        }
    }

    /// @notice Accepts ownership as the pending owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    /// @notice Rotates the payout destination. The pinned forwarder address never changes, so no
    ///         live market is touched and no future admission is affected.
    /// @param target_ New payout destination.
    function setTarget(address target_) external onlyOwner {
        _setTarget(target_);
    }

    /// @notice Rotates the payout destination and immediately drains the listed quotes to it.
    /// @dev Rotation and collection in one transaction: a compromised old target cannot be
    ///      front-run into receiving the claims that are pending at rotation time, because no
    ///      third party gets a block boundary between the two. Broadcast this through a private
    ///      relay or an atomic bundle whenever the old target is believed compromised - a public
    ///      mempool still exposes the rotation intent itself, just not a claimable window.
    /// @param newTarget New payout destination.
    /// @param quotes Quote currencies to collect after rotating; `address(0)` is native.
    /// @return collected Amount pulled out of the block for each quote, in the same order.
    function setTargetAndCollect(address newTarget, address[] calldata quotes)
        external
        onlyOwner
        returns (uint256[] memory collected)
    {
        _setTarget(newTarget);
        collected = new uint256[](quotes.length);
        for (uint256 i; i < quotes.length; ++i) {
            collected[i] = _collect(quotes[i], newTarget);
        }
    }

    /// @notice Points this forwarder at the native block that pins it as its protocol recipient.
    /// @dev Owner-mutable rather than one-shot, and deliberately so. Every accrual lives in its own
    ///      block's `claimable[quote][forwarder]` mapping and `claimTo` always pays whatever path
    ///      this forwarder holds at call time, so re-pointing strands nothing: the old block's
    ///      balance stays claimable the moment it is pointed at again. A one-shot bind has the
    ///      opposite failure mode - binding the wrong block once would strand every market's
    ///      protocol fee forever, because the real block's `protocolRecipient` is immutable and
    ///      cannot be moved to a second forwarder. The candidate must still prove it pins this
    ///      contract, so the owner can only ever point at blocks that already pay here.
    /// @param nativeBlock_ Candidate `HookrNativeMechanicsBlockV2`.
    function setNativeBlock(address nativeBlock_) external onlyOwner {
        if (nativeBlock_ == address(0)) revert ZeroAddress();
        if (nativeBlock_ == nativeBlock) revert NativeBlockUnchanged();
        if (nativeBlock_.code.length == 0) revert InvalidNativeBlock();
        if (nativeBlock_ == target) revert InvalidNativeBlock();
        (bool ok, uint256 recipient) =
            _boundedWord(nativeBlock_, abi.encodeCall(IHookrNativeMechanicsBlockV2Claims.protocolRecipient, ()));
        if (!ok || recipient != uint256(uint160(address(this)))) revert InvalidNativeBlock();
        // The standing target must still be a legal destination under the new block's PoolManager.
        _requireSafeTarget(target, nativeBlock_);
        nativeBlock = nativeBlock_;
        emit NativeBlockSet(nativeBlock_);
    }

    /// @notice Permissionlessly claims this forwarder's accrued protocol fees and pushes them on.
    /// @dev The block pays `claimable[quote][forwarder]` into this contract and the same call
    ///      forwards the received amount to `target`. Claiming here first is what keeps a bad
    ///      target non-blocking: if the forward fails the accrual is already out of the block and
    ///      simply rests here, `ForwardDeferred` is emitted, and `sweep` delivers it after the
    ///      owner rotates. Nothing owed is not a failure: `collect` returns zero instead of
    ///      reverting.
    /// @param quote Quote currency of the accrual; `address(0)` is native.
    /// @return collected Amount pulled out of the block, zero when nothing was claimable. It sits
    ///         on this contract only when the forward to `target` failed.
    function collect(address quote) external returns (uint256 collected) {
        collected = _collect(quote, target);
    }

    /// @notice Permissionlessly forwards any balance this forwarder itself holds to `target`.
    /// @dev Serves any accrual `collect` had to defer, and any balance sent here directly. Unlike
    ///      `collect` this reverts when the target rejects the payment, because there is nothing
    ///      left to rescue by continuing.
    /// @param token Token to forward; `address(0)` is native.
    function sweep(address token) external {
        address to = target;
        uint256 amount = _selfBalance(token);
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IHookrUtilityToken(token).safeTransfer(to, amount);
        }
        emit Swept(token, to, amount);
    }

    function _setTarget(address target_) private {
        _requireSafeTarget(target_, nativeBlock);
        if (target_ == target) revert TargetUnchanged();
        target = target_;
        emit TargetSet(target_);
    }

    function _collect(address quote, address to) private returns (uint256 collected) {
        address block_ = nativeBlock;
        if (block_ == address(0)) revert NotBound();
        if (IHookrNativeMechanicsBlockV2Claims(block_).claimable(quote, address(this)) == 0) return 0;

        uint256 balanceBefore = _selfBalance(quote);
        IHookrNativeMechanicsBlockV2Claims(block_).claimTo(quote, address(this));
        collected = _selfBalance(quote) - balanceBefore;
        if (collected == 0) return 0;

        if (_forward(quote, to, collected)) {
            emit Collected(quote, to, collected);
        } else {
            emit ForwardDeferred(quote, to, collected);
        }
    }

    /// @dev A destination that cannot be paid must not be settable, and neither may a destination
    ///      that would burn the payout: this contract itself (a no-op that re-queues forever), the
    ///      block (which would credit nobody), or the PoolManager (whose loose balance is takeable
    ///      by anyone). The block's own `poolManager()` is read alongside the immutable one so a
    ///      block wired to a different manager is covered too; a candidate whose read fails is
    ///      still covered by the immutable check.
    function _requireSafeTarget(address target_, address block_) private view {
        if (target_ == address(0)) revert ZeroAddress();
        if (target_ == address(this) || target_ == poolManager) revert InvalidTarget();
        if (block_ == address(0)) return;
        if (target_ == block_) revert InvalidTarget();
        (bool ok, uint256 manager) =
            _boundedWord(block_, abi.encodeCall(IHookrNativeMechanicsBlockV2Claims.poolManager, ()));
        if (ok && manager == uint256(uint160(target_))) revert InvalidTarget();
    }

    function _selfBalance(address token) private view returns (uint256 balance) {
        if (token == address(0)) return address(this).balance;
        balance = IHookrUtilityToken(token).safeBalanceOf(address(this));
    }

    /// @dev Non-reverting counterpart to `HookrTokenTransfer.safeTransfer`, so a hostile or merely
    ///      blocklisting target cannot trap an accrual inside the block.
    function _forward(address token, address to, uint256 amount) private returns (bool delivered) {
        if (token == address(0)) {
            (delivered,) = payable(to).call{value: amount}("");
            return delivered;
        }
        bytes memory input = abi.encodeCall(IHookrUtilityToken.transfer, (to, amount));
        bool ok;
        uint256 returnSize;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(gas(), token, 0, add(input, 0x20), mload(input), 0, 0x20)
            returnSize := returndatasize()
            word := mload(0)
        }
        delivered = ok && (returnSize == 0 || (returnSize == 32 && word == 1));
    }

    function _boundedWord(address target_, bytes memory input) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(BLOCK_QUERY_GAS, target_, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }
}
