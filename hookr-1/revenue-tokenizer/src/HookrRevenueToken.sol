// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrIncomeLedger} from "./base/HookrIncomeLedger.sol";
import {HookrIncomeSync} from "./base/HookrIncomeSync.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";

/// @title Hookr revenue token
/// @notice The revenue token itself: the ledger (HookrIncomeLedger) and the sync (HookrIncomeSync) under one fixed-supply
///         ERC-20 with a balance history and its own drop box (HookrDropHost, deployed at construction), born pending
///         from the tokenizer and sealed once the fee rights are locked. Income from the rights streams through the
///         token; drops of any asset by anyone are claimed from the box by the balance at the block before the drop;
///         anything else sent straight to the token or the box becomes a drop too (`dropStray`, on either).
///         Every holder action can be signed and relayed (HookrERC20Permit, HookrERC20Authorizations, the claims by
///         signature), so holding and being paid never needs gas.
/// @dev Immutable after `seal`: fixed doors, fixed supply, fixed assets, fixed release period and tip; no owner, no
///      pause, no sweep, no second mint. The tokenizer is the only caller of `seal`, and it seals in the same
///      transaction that locks the rights, so no share exists before its income is locked behind it.
contract HookrRevenueToken is HookrIncomeSync {
    /// @inheritdoc IHookrRevenueToken
    address public immutable tokenizer;
    /// @inheritdoc IHookrRevenueToken
    bytes32 public immutable termsHash;
    /// @inheritdoc IHookrRevenueToken
    uint256 public immutable shareSupply;

    /// @param tokenizer_ The tokenizer, the only caller of `seal`.
    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param supply The fixed supply, `MIN_SUPPLY` to `MAX_SUPPLY`, minted once at seal.
    /// @param assets The assets, native ETH first, at most `MAX_ASSETS`.
    /// @param streamSeconds_ The release period, `MIN_STREAM_SECONDS` to `MAX_STREAM_SECONDS`.
    /// @param tipBps_ The sync caller's tip, at most `MAX_TIP_BPS`.
    /// @param termsHash_ Commitment to the published terms; nonzero.
    /// @param poolManager_ The PoolManager whose shares earn nothing.
    constructor(
        address tokenizer_,
        string memory name_,
        string memory symbol_,
        uint256 supply,
        Currency[] memory assets,
        uint32 streamSeconds_,
        uint16 tipBps_,
        bytes32 termsHash_,
        address poolManager_
    ) HookrIncomeLedger(name_, symbol_, assets, streamSeconds_, poolManager_) HookrIncomeSync(tipBps_) {
        if (tokenizer_ == address(0) || supply < MIN_SUPPLY || supply > MAX_SUPPLY || termsHash_ == bytes32(0)) {
            revert InvalidConfig();
        }
        tokenizer = tokenizer_;
        termsHash = termsHash_;
        shareSupply = supply;
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev Only the tokenizer, once. The recipients' amounts must sum to `shareSupply` exactly; a zero recipient,
    ///      this token or a zero amount is refused. The mints are checkpointed at this block, so the first drop can
    ///      land in the next block at the earliest (a drop in the seal block reads an empty snapshot and is refused).
    function seal(Seal calldata s) external {
        if (msg.sender != tokenizer) revert Unauthorized(msg.sender);
        if (live) revert AlreadyLive();
        live = true;
        _setDoors(s.doors);
        _setBridge(s.bridge, s.bridgeBps);
        uint256 n = s.recipients.length;
        if (n == 0 || n != s.amounts.length) revert InvalidConfig();
        uint256 minted;
        for (uint256 i; i < n; ++i) {
            address to = s.recipients[i];
            uint256 amount = s.amounts[i];
            if (to == address(0)) revert InvalidRecipient(to);
            if (amount == 0) revert InvalidAmount(amount);
            minted += amount;
            _mint(to, amount);
        }
        if (minted != shareSupply) revert InvalidAmount(minted);
        emit Sealed(s.doors.length, minted, s.bridge, s.bridgeBps);
    }
}
