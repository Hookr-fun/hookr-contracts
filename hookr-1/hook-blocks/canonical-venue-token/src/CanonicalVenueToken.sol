// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title CanonicalVenueToken
/// @notice A fixed-supply ERC-20 (a HookrToken variant) whose frozen transfer policy
///         lets the token cross the Uniswap v4 PoolManager boundary only as settlement of one operation on one
///         exact PoolId, performed by one immutable settlement contract. There is no owner, mint, pause, tax,
///         allowlist editor or upgrade surface: the policy is fixed in the constructor and can never change.
/// @dev The policy, in full:
///      1. A transfer that neither sends to nor sends from the PoolManager is an ordinary ERC-20 transfer.
///      2. A transfer from the PoolManager to 0xdead is always allowed. It destroys supply and is the path the
///         Hookr root's Auto Burn uses (`poolManager.take(subject, DEAD, burn)`); it is the one listed recovery
///         path that needs no settlement involvement.
///      3. Every other transfer that sends to or from the PoolManager must be covered by a transient permit for
///         that exact (from, to) pair, written in the same transaction by `settlement`. The permit is an amount;
///         each covered transfer consumes it. Permits live in transient storage, so none survives a transaction.
///      Why a permit and not "the PoolManager is allowed": every v4 pool shares the PoolManager's custody, so an
///      address allowlist cannot tell the canonical pool from any other pool that holds this token. The settlement
///      writes a permit only for the deltas of its own single operation on the canonical key, executed in its own
///      unlock, immediately before the one transfer that consumes it (or around one call into the pinned Hookr
///      Launcher, which is itself locked while the permit is live).
///      What the policy cannot do, stated plainly: inside one unlock, v4 nets deltas per currency across pools, so
///      a locker can route canonical-pool output into another pool or into ERC-6909 claims without an ERC-20
///      transfer. Those positions can never be withdrawn as this ERC-20 outside the settlement, but they exist.
///      Wallet-to-wallet (OTC) transfers, other AMMs that receive ordinary transfers, and wrappers are not covered.
contract CanonicalVenueToken is ERC20 {
    using PoolIdLibrary for PoolKey;

    /// @notice Identifies this template and its frozen policy.
    bytes32 public constant TEMPLATE_ID = keccak256("hookr.canonical-venue-token");
    /// @notice Shortest accepted token name, in bytes.
    uint256 public constant MIN_NAME_BYTES = 1;
    /// @notice Longest accepted token name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 64;
    /// @notice Shortest accepted token symbol, in bytes.
    uint256 public constant MIN_SYMBOL_BYTES = 1;
    /// @notice Longest accepted token symbol, in bytes.
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    /// @notice The only destination the PoolManager may pay without a permit.
    address public constant DEAD = address(0xdead);
    bytes32 private constant PERMIT_SEED = keccak256("hookr.canonical-venue-token.permit");

    /// @notice The Uniswap v4 singleton whose boundary the policy guards.
    IPoolManager public immutable poolManager;
    /// @notice The only account that can write transfer permits.
    address public immutable settlement;
    /// @notice The exact pool this token may be settled in.
    PoolId public immutable canonicalPoolId;
    Currency private immutable _currency0;
    Currency private immutable _currency1;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    address private immutable _hooks;

    /// @notice Name or symbol is empty or too long.
    error InvalidMetadata();
    /// @notice Supply is zero.
    error ZeroSupply();
    /// @notice A policy constructor argument is unusable.
    error InvalidPolicy();
    /// @notice Only the settlement can write permits.
    error NotSettlement(address caller);
    /// @notice A permit must name a pair that crosses the PoolManager boundary.
    error InvalidPermit(address from, address to);
    /// @notice The transfer crosses the PoolManager boundary without a sufficient permit.
    /// @param from Sender.
    /// @param to Recipient.
    /// @param value Amount attempted.
    /// @param permitted Remaining permit for this exact pair.
    error VenueOnly(address from, address to, uint256 value, uint256 permitted);

    /// @param name_ Token name, MIN_NAME_BYTES..MAX_NAME_BYTES bytes.
    /// @param symbol_ Token symbol, MIN_SYMBOL_BYTES..MAX_SYMBOL_BYTES bytes.
    /// @param supply Fixed supply, minted once to `recipient`.
    /// @param recipient Receives the whole supply. Cannot be the PoolManager.
    /// @param manager The v4 PoolManager.
    /// @param settlement_ The only permit writer.
    /// @param quote The canonical pool's other currency; address zero is native ETH.
    /// @param fee The canonical key's fee field (a Hookr root requires the dynamic-fee flag).
    /// @param tickSpacing The canonical key's tick spacing.
    /// @param hooks The canonical key's hook (a Hookr root).
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        address recipient,
        IPoolManager manager,
        address settlement_,
        Currency quote,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) ERC20(name_, symbol_) {
        if (supply == 0) revert ZeroSupply();
        if (
            bytes(name_).length < MIN_NAME_BYTES || bytes(name_).length > MAX_NAME_BYTES
                || bytes(symbol_).length < MIN_SYMBOL_BYTES || bytes(symbol_).length > MAX_SYMBOL_BYTES
        ) revert InvalidMetadata();
        if (
            address(manager).code.length == 0 || settlement_ == address(0) || recipient == address(0)
                || recipient == address(manager) || Currency.unwrap(quote) == address(this) || tickSpacing <= 0
        ) revert InvalidPolicy();
        poolManager = manager;
        settlement = settlement_;
        bool selfFirst = uint160(address(this)) < uint160(Currency.unwrap(quote));
        Currency c0 = selfFirst ? Currency.wrap(address(this)) : quote;
        Currency c1 = selfFirst ? quote : Currency.wrap(address(this));
        _currency0 = c0;
        _currency1 = c1;
        _fee = fee;
        _tickSpacing = tickSpacing;
        _hooks = hooks;
        canonicalPoolId = PoolKey(c0, c1, fee, tickSpacing, IHooks(hooks)).toId();
        _mint(recipient, supply);
    }

    /// @notice The exact PoolKey this token may be settled in. Fixed at construction.
    function canonicalPoolKey() public view returns (PoolKey memory) {
        return PoolKey(_currency0, _currency1, _fee, _tickSpacing, IHooks(_hooks));
    }

    /// @notice The canonical pool's other currency.
    function quoteCurrency() external view returns (Currency) {
        return Currency.unwrap(_currency0) == address(this) ? _currency1 : _currency0;
    }

    /// @notice Writes the transient permit for one boundary-crossing pair. Only the settlement can call.
    /// @dev Overwrites, it does not add. The settlement writes a permit immediately before the transfer it covers
    ///      and checks or clears it immediately after.
    /// @param from Sender the permit covers.
    /// @param to Recipient the permit covers.
    /// @param amount Remaining amount the pair may move in this transaction.
    function setVenuePermit(address from, address to, uint256 amount) external {
        if (msg.sender != settlement) revert NotSettlement(msg.sender);
        address pm = address(poolManager);
        if ((from != pm && to != pm) || from == to) revert InvalidPermit(from, to);
        bytes32 slot = _permitSlot(from, to);
        assembly ("memory-safe") { tstore(slot, amount) }
    }

    /// @notice Remaining transient permit for a pair in this transaction.
    function venuePermit(address from, address to) external view returns (uint256 amount) {
        bytes32 slot = _permitSlot(from, to);
        assembly ("memory-safe") { amount := tload(slot) }
    }

    /// @notice Whether a transfer of `value` from `from` to `to` would pass the policy right now.
    function isVenueTransfer(address from, address to, uint256 value) external view returns (bool) {
        address pm = address(poolManager);
        if (from != pm && to != pm) return true;
        if (from == pm && to == DEAD) return true;
        bytes32 slot = _permitSlot(from, to);
        uint256 permitted;
        assembly ("memory-safe") { permitted := tload(slot) }
        return value <= permitted;
    }

    /// @dev Applies the frozen policy, then the standard ERC-20 update.
    function _update(address from, address to, uint256 value) internal override {
        address pm = address(poolManager);
        if ((from == pm || to == pm) && !(from == pm && to == DEAD)) {
            bytes32 slot = _permitSlot(from, to);
            uint256 permitted;
            assembly ("memory-safe") { permitted := tload(slot) }
            if (value > permitted) revert VenueOnly(from, to, value, permitted);
            unchecked {
                permitted -= value;
            }
            assembly ("memory-safe") { tstore(slot, permitted) }
        }
        super._update(from, to, value);
    }

    function _permitSlot(address from, address to) private pure returns (bytes32) {
        return keccak256(abi.encode(PERMIT_SEED, from, to));
    }
}
