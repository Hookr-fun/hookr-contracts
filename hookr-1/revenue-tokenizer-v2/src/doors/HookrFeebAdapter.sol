// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrForwarding} from "../base/HookrForwarding.sol";
import {HookrDoorTerm} from "../base/HookrDoorTerm.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {IHookrFeebAdapter} from "../interfaces/IHookrFeebAdapter.sol";
import {IPositionManagerDoor} from "../interfaces/IPositionManagerDoor.sol";
import {IBeneficiaryVault} from "../interfaces/external/IBeneficiaryVault.sol";
import {IFeeSplitter} from "../interfaces/external/IFeeSplitter.sol";

/// @title Hookr FEEB adapter, part of the HookRevenue Tokenizer
/// @notice Holds one pools.trade Fee Beneficiary NFT for a term and claims its creator fee for a revenue token, after
///         the launch's fee splitter has collected the position. See IHookrFeebAdapter for the rules.
/// @dev Calls nothing on the vault but `claim`, `transferFrom` at release and three reads; approves no one. The vault
///      pays only native ETH (the other side compounds in the pool), so a pull forwards the native balance alone;
///      anything else that reaches the adapter leaves through `dropStray`. Before a claim it reads the position's
///      owner on the PositionManager with `OWNER_READ_GAS` and, when that owner's code hashes to `splitterCodeHash`,
///      calls its `collectFees([tokenId])` with `COLLECT_GAS`, copying no return data.
///
///      Gas: the tokenizer gives this door `PULL_GAS` (1,700,000): the owner read at `OWNER_READ_GAS`, the collect
///      at `COLLECT_GAS`, the vault's reads, the claim at `CLAIM_GAS` and the native forward at `SEND_GAS`.
///      Measured on 4663: a live collect takes at most 299,567 (one native and one token payout with both
///      recipients' callbacks), and a pull that collects, claims and forwards 357,533 cold, measured as the first
///      call of its test (NFT 3,638,200 at block 94,370,000).
contract HookrFeebAdapter is IHookrFeebAdapter, HookrForwarding, HookrDoorTerm {
    /// @inheritdoc IHookrFeebAdapter
    uint256 public constant CLAIM_GAS = 500_000;
    /// @inheritdoc IHookrFeebAdapter
    uint256 public constant OWNER_READ_GAS = 50_000;
    /// @inheritdoc IHookrFeebAdapter
    uint256 public constant COLLECT_GAS = 600_000;
    /// @inheritdoc IHookrFeebAdapter
    uint32 public constant PULL_GAS = 1_700_000;

    /// @inheritdoc IHookrFeebAdapter
    address public immutable vault;
    /// @inheritdoc IHookrFeebAdapter
    uint256 public immutable tokenId;
    /// @inheritdoc IHookrFeebAdapter
    address public immutable positionManager;
    /// @inheritdoc IHookrFeebAdapter
    bytes32 public immutable splitterCodeHash;
    /// @inheritdoc IHookrFeebAdapter
    bool public released;

    /// @param revenueToken_ The revenue token every pull pays.
    /// @param vault_ The pools.trade vault holding the NFT; must have code.
    /// @param tokenId_ The Fee Beneficiary NFT.
    /// @param returnTo_ The account the NFT goes back to.
    /// @param unlockAt_ The unlock timestamp, after now, or FOREVER.
    /// @param positionManager_ The Uniswap v4 PositionManager the splitter's position sits on.
    /// @param splitterCodeHash_ The runtime code hash of a pools.trade fee splitter.
    constructor(
        address revenueToken_,
        address vault_,
        uint256 tokenId_,
        address returnTo_,
        uint64 unlockAt_,
        address positionManager_,
        bytes32 splitterCodeHash_
    ) HookrForwarding(revenueToken_) HookrDoorTerm(returnTo_, unlockAt_) {
        if (vault_.code.length == 0) revert InvalidConfig();
        vault = vault_;
        tokenId = tokenId_;
        positionManager = positionManager_;
        splitterCodeHash = splitterCodeHash_;
    }

    /// @notice Takes the vault's payout; forwarded by the next pull.
    receive() external payable {}

    /// @inheritdoc IHookrFeebAdapter
    function bound() public view returns (bool) {
        return !released && IBeneficiaryVault(vault).ownerOf(tokenId) == address(this);
    }

    /// @inheritdoc IHookrFeebAdapter
    function pending() external view returns (uint256 eth, uint256 other) {
        return IBeneficiaryVault(vault).amounts(tokenId);
    }

    /// @inheritdoc IHookrFeebAdapter
    function splitter() public view returns (address) {
        (bool read, uint256 owner) =
            HookrForward.read(positionManager, abi.encodeCall(IPositionManagerDoor.ownerOf, (tokenId)), OWNER_READ_GAS);
        if (!read || owner >> 160 != 0 || address(uint160(owner)).codehash != splitterCodeHash) return address(0);
        return address(uint160(owner));
    }

    /// @notice Has the splitter collect the position, then claims the NFT's pending fee, while the adapter holds the
    ///         NFT, each on its own attempt (`COLLECT_GAS`, `CLAIM_GAS`), and forwards the adapter's native balance
    ///         to the revenue token. Only the revenue token. After the release it forwards what the final claim left
    ///         here.
    /// @dev The collect and the claim run only while the NFT is here, the claim only when something is pending, each
    ///      on its own attempt, so a splitter or a vault that refuses this block never holds the native forward.
    function pull() external onlyRevenueToken nonReentrant {
        IBeneficiaryVault v = IBeneficiaryVault(vault);
        if (!released && v.ownerOf(tokenId) == address(this)) {
            _collect();
            (uint256 eth, uint256 other) = v.amounts(tokenId);
            if (eth != 0 || other != 0) {
                uint256 before = address(this).balance;
                try v.claim{gas: CLAIM_GAS}(tokenId, 0, 0) {
                    emit Claimed(address(this).balance - before);
                } catch {
                    emit ClaimFailed();
                }
            }
        }
        _forwardHeld(address(0));
    }

    /// @inheritdoc IHookrFeebAdapter
    function release() external nonReentrant {
        if (released) revert AlreadyReleased();
        _requireUnlocked();
        IBeneficiaryVault v = IBeneficiaryVault(vault);
        address owner = v.ownerOf(tokenId);
        if (owner != address(this)) revert NotBound(owner);
        released = true;
        _collect();
        (uint256 eth, uint256 other) = v.amounts(tokenId);
        if (eth != 0 || other != 0) {
            uint256 before = address(this).balance;
            v.claim(tokenId, 0, 0);
            emit Claimed(address(this).balance - before);
        }
        v.transferFrom(address(this), returnTo, tokenId);
        emit Released(returnTo);
    }

    /// @dev The splitter's `collectFees([tokenId])` with `COLLECT_GAS`, when the position sits with a splitter. Copies
    ///      no return data, and its failure is an event, never a revert.
    function _collect() private {
        address s = splitter();
        if (s == address(0)) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        bytes memory data = abi.encodeCall(IFeeSplitter.collectFees, (ids));
        bool ok;
        assembly ("memory-safe") {
            ok := call(COLLECT_GAS, s, 0, add(data, 0x20), mload(data), 0, 0)
        }
        if (ok) emit FeesCollected(s);
        else emit CollectFailed(s);
    }

    /// @dev Native ETH is the adapter's only own currency.
    function _isOwnAsset(address) internal pure override returns (bool) {
        return false;
    }

    function _isReleased() internal view override returns (bool) {
        return released;
    }
}
