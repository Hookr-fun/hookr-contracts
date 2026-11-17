// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrIncomeLedger} from "./base/HookrIncomeLedger.sol";
import {HookrIncomeSync} from "./base/HookrIncomeSync.sol";
import {IHookrBalanceHistory} from "./interfaces/IHookrBalanceHistory.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";

/// @title Hookr revenue token
/// @notice The revenue token itself: the ledger (HookrIncomeLedger) and the sync (HookrIncomeSync) under one fixed-supply
///         ERC-20 with a balance history and its own drop box (HookrDropHost, deployed at construction). The tokenizer
///         adds its first doors, mints the supply once with `initialize`, and adds doors after that for as long as the
///         token has a stream manager (or for anyone, for its own door kinds, when the token has `openStreams`). Income
///         from the doors is shared through the token; drops of any asset by anyone are claimed from the box by the
///         balance at the block before the drop; strays reach the holders through the box. Every holder
///         action but approving an operator can be signed and relayed; a holder approves the operators that claim
///         for it in a transaction of its own.
/// @dev Streams and listed assets only grow: nothing removes or changes a door, an asset, the supply, the terms, the
///      release period, the tip or the bridge. No owner, no pause, no upgrade, no sweep, no second mint. The tokenizer
///      is the only caller of `initialize` and `addDoor`, and it locks each fee right in its door before it adds the
///      door. The stream manager may list assets and hand its role on in two steps, or give it up for good.
///
///      Shares the leg collector or the tokenizer hold earn nothing, like the PoolManager's, 0xdead's, the drop
///      box's and the token's own: neither has a call that claims a revenue token's income, so their shares (Hookr's
///      leg in this token before a sweep, shares anyone sends the tokenizer) would earn income no one can take.
contract HookrRevenueToken is HookrIncomeSync, IERC165 {
    /// @inheritdoc IHookrRevenueToken
    address public immutable tokenizer;
    /// @inheritdoc IHookrRevenueToken
    bytes32 public immutable termsHash;
    /// @inheritdoc IHookrRevenueToken
    uint256 public immutable shareSupply;
    /// @inheritdoc IHookrRevenueToken
    bool public immutable openStreams;

    /// @inheritdoc IHookrRevenueToken
    address public streamManager;
    /// @inheritdoc IHookrRevenueToken
    address public pendingStreamManager;

    /// @param tokenizer_ The tokenizer, the only caller of `initialize` and `addDoor`.
    /// @param legCollector_ Where Hookr's leg goes; nonzero.
    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param supply The fixed supply, `MIN_SUPPLY` to `MAX_SUPPLY`, minted once by `initialize`.
    /// @param assets The listed assets at birth, native ETH first, 1 to `MAX_ASSETS`.
    /// @param streamSeconds_ Zero for immediate income, or a positive release period up to `MAX_STREAM_SECONDS`.
    /// @param tipBps_ The sync caller's tip, at most `MAX_TIP_BPS`.
    /// @param termsHash_ Commitment to the published terms; nonzero.
    /// @param poolManager_ The PoolManager whose shares earn nothing.
    /// @param streamManager_ Who may add streams and listed assets; zero closes the list at birth.
    /// @param openStreams_ Whether anyone may add the tokenizer's own door kinds (the tokenizer reads and enforces it).
    constructor(
        address tokenizer_,
        address legCollector_,
        string memory name_,
        string memory symbol_,
        uint256 supply,
        Currency[] memory assets,
        uint32 streamSeconds_,
        uint16 tipBps_,
        bytes32 termsHash_,
        address poolManager_,
        address streamManager_,
        bool openStreams_
    ) HookrIncomeLedger(name_, symbol_, assets, streamSeconds_, poolManager_) HookrIncomeSync(tipBps_, legCollector_) {
        if (tokenizer_ == address(0) || supply < MIN_SUPPLY || supply > MAX_SUPPLY || termsHash_ == bytes32(0)) {
            revert InvalidConfig();
        }
        tokenizer = tokenizer_;
        termsHash = termsHash_;
        shareSupply = supply;
        openStreams = openStreams_;
        if (streamManager_ != address(0)) {
            streamManager = streamManager_;
            emit StreamManagerTransferred(address(0), streamManager_);
        }
    }

    // ------------------------------------------------------------------ tokenizer

    /// @inheritdoc IHookrRevenueToken
    /// @dev Only the tokenizer, once. The recipients' amounts must sum to `shareSupply` exactly; a zero amount, the
    ///      zero address, this token or one of its doors is refused. The mints are checkpointed at this block, so the
    ///      first drop can land in the next block at the earliest (a drop in this block reads an empty snapshot and
    ///      is refused).
    function initialize(Mint calldata m) external {
        if (msg.sender != tokenizer) revert Unauthorized(msg.sender);
        if (live) revert AlreadyLive();
        live = true;
        _setBridge(m.bridge, m.bridgeBps);
        uint256 n = m.recipients.length;
        if (n == 0 || n != m.amounts.length) revert InvalidConfig();
        uint256 minted;
        for (uint256 i; i < n; ++i) {
            address to = m.recipients[i];
            uint256 amount = m.amounts[i];
            if (to == address(0)) revert InvalidRecipient(to);
            if (amount == 0) revert InvalidAmount(amount);
            minted += amount;
            _mint(to, amount);
        }
        if (minted != shareSupply) revert InvalidAmount(minted);
        emit Initialized(minted, m.bridge, m.bridgeBps);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev Only the tokenizer, before or after `initialize`. The tokenizer itself is never a door.
    function addDoor(Door calldata door) external nonReentrant returns (uint256 id) {
        address tokenizer_ = tokenizer;
        if (msg.sender != tokenizer_) revert Unauthorized(msg.sender);
        if (door.target == tokenizer_) revert InvalidTarget(door.target);
        return _addDoor(door);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev The tokenizer or the stream manager. Not inside a sync or a claim (the reentrancy lock), so a listing never
    ///      lands between a sync's reads.
    function addAsset(Currency currency) external nonReentrant returns (uint256 asset) {
        if (msg.sender != tokenizer && msg.sender != streamManager) revert Unauthorized(msg.sender);
        return _addAsset(currency);
    }

    // ------------------------------------------------------------------ stream manager

    /// @inheritdoc IHookrRevenueToken
    /// @dev Zero cancels a pending transfer.
    function transferStreamManager(address newManager) external {
        address manager = streamManager;
        if (msg.sender != manager || manager == address(0)) revert Unauthorized(msg.sender);
        pendingStreamManager = newManager;
        emit StreamManagerTransferStarted(manager, newManager);
    }

    /// @inheritdoc IHookrRevenueToken
    function acceptStreamManager() external {
        address pending = pendingStreamManager;
        if (msg.sender != pending || pending == address(0)) revert Unauthorized(msg.sender);
        address manager = streamManager;
        streamManager = pending;
        pendingStreamManager = address(0);
        emit StreamManagerTransferred(manager, pending);
    }

    /// @inheritdoc IHookrRevenueToken
    /// @dev Clears a pending transfer too, so nobody can take the role afterwards.
    function renounceStreamManager() external {
        address manager = streamManager;
        if (msg.sender != manager || manager == address(0)) revert Unauthorized(msg.sender);
        streamManager = address(0);
        pendingStreamManager = address(0);
        emit StreamManagerTransferred(manager, address(0));
    }

    // ------------------------------------------------------------------ earning rule

    /// @inheritdoc IHookrBalanceHistory
    /// @dev The ledger's rule plus the leg collector and the tokenizer, both immutables, as the history requires. A
    ///      transfer into the collector therefore settles and records only the sending side, which keeps Hookr's leg
    ///      in this token inside the sync's `LEG_GAS`.
    function earns(address account) public view override returns (bool) {
        return super.earns(account) && account != legCollector && account != tokenizer;
    }

    // ------------------------------------------------------------------ introspection

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC20).interfaceId
            || interfaceId == type(IHookrRevenueToken).interfaceId;
    }
}
