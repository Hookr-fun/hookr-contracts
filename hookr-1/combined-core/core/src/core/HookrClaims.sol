// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookrRulesStorage as S} from "../libraries/HookrRulesStorage.sol";
import {HookrCoreState} from "../libraries/HookrCoreState.sol";

/// @notice Root-agnostic claim code reached by the combined core's exact-selector fallback.
/// @dev The core appends its trusted root as the final calldata word. Modules declare no state or transient fields.
contract HookrClaims is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable poolManager;
    address public immutable protocolRecipient;
    address private immutable SELF = address(this);
    error Unauthorized();
    error InvalidConfig();
    error ReentrantClaim();
    error NothingToClaim();
    error ClaimFailed();
    error PoolManagerUnlocked();
    event Claimed(Currency indexed quote, address indexed beneficiary, address indexed to, uint256 amount);

    constructor(IPoolManager manager, address protocol) {
        if (address(manager).code.length == 0 || protocol == address(0) || protocol == address(manager)) revert InvalidConfig();
        poolManager = manager;
        protocolRecipient = protocol;
    }
    modifier delegated() {
        if (address(this) == SELF) revert Unauthorized();
        _;
    }
    function claim(Currency currency) external delegated returns (uint256) { return _claim(currency, msg.sender); }
    function claimTo(Currency currency, address to) external delegated returns (uint256) { return _claim(currency, to); }

    /// @notice Transfers the full available uint256 balance as ERC-6909 claims, preserving the release's exit.
    function claimAsClaims(Currency currency, address to) external delegated returns (uint256 amount) {
        amount = _debit(currency, to, false);
        _setClaiming(true);
        poolManager.transfer(to, currency.toId(), amount);
        _setClaiming(false);
        emit Claimed(currency, msg.sender, to, amount);
    }
    function _claim(Currency currency, address to) private returns (uint256 amount) {
        amount = _debit(currency, to, true);
        _setClaiming(true);
        poolManager.unlock(abi.encode(currency, to, amount));
        _setClaiming(false);
        emit Claimed(currency, msg.sender, to, amount);
    }
    function _debit(Currency currency, address to, bool chunk) private returns (uint256 amount) {
        if (_claiming()) revert ReentrantClaim();
        if (to == address(0) || to == address(poolManager) || to == address(this) || to == _root()) revert InvalidConfig();
        S.State storage s = S.rules();
        uint256 explicit = s.claims[currency][msg.sender];
        amount = explicit;
        if (msg.sender == protocolRecipient) {
            // During a swap the root can have recorded liabilities but not yet minted their ERC-6909 backing.
            // Neither a residual nor an explicit+residual combined debit can be priced in that intermediate state.
            if (poolManager.isUnlocked()) revert PoolManagerUnlocked();
            amount += HookrCoreState.residual(poolManager.balanceOf(address(this), currency.toId()), s.liabilities[currency]);
        }
        if (amount == 0) revert NothingToClaim();
        if (chunk && amount > uint256(uint128(type(int128).max))) amount = uint256(uint128(type(int128).max));
        uint256 fromExplicit = explicit < amount ? explicit : amount;
        if (fromExplicit != 0) {
            s.claims[currency][msg.sender] = explicit - fromExplicit;
            s.liabilities[currency] -= fromExplicit;
        }
    }
    function unlockCallback(bytes calldata data) external delegated returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_claiming()) revert Unauthorized();
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        uint256 beforeBalance = currency.isAddressZero() ? 0 : currency.balanceOf(to);
        uint256 managerBefore = currency.isAddressZero() ? 0 : currency.balanceOf(address(poolManager));
        poolManager.take(currency, to, amount);
        if (!currency.isAddressZero()) {
            uint256 afterBalance = currency.balanceOf(to);
            uint256 managerAfter = currency.balanceOf(address(poolManager));
            if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount || managerAfter > managerBefore ||
                managerBefore - managerAfter != amount) revert ClaimFailed();
        }
        return bytes("");
    }
    function _root() private pure returns (address root) {
        if (msg.data.length < 36) revert Unauthorized();
        assembly ("memory-safe") { root := calldataload(sub(calldatasize(), 32)) }
    }
    function _claiming() private view returns (bool claiming) {
        bytes32 slot = S.CLAIMING_SLOT;
        assembly ("memory-safe") { claiming := tload(slot) }
    }
    function _setClaiming(bool claiming) private {
        bytes32 slot = S.CLAIMING_SLOT;
        assembly ("memory-safe") { tstore(slot, claiming) }
    }
}
