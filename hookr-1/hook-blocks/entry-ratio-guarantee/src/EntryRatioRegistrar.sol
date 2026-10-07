// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrGoverned} from "hookr/base/HookrGoverned.sol";
import {IEntryRatioGuarantee} from "./interfaces/IEntryRatioGuarantee.sol";

/// @title EntryRatioRegistrar
/// @notice The registrar of one Entry Ratio Guarantee hook, held by an owner under Hookr's governed timelock.
///         Allowing a price reference for a currency pair adds power: new pools may name it and deposits are priced
///         against it. So it is queued as `ALLOW_REFERENCE` with its arguments disclosed and runs only after the
///         timelock delay. Disallowing a reference and closing a pool only stop new deposits, so they apply at once.
/// @dev The hook's registrar is immutable and must be a contract, so the role is exercised only through this
///      contract's rules. Ownership moves in two steps through a queued `TRANSFER_OWNER` (HookrGoverned); owner,
///      nominee and guardian are never EIP-7702 delegated accounts. The delay is HookrGoverned's minimum.
///      Powers:
///      - owner, after the delay: `allowReference`, `setGuardian`, `transferOwnership`;
///      - owner, at once: `closePool` (permanent: the hook has no reopen), `removeGuardian`, `cancel`;
///      - owner or guardian, at once: `disallowReference`. It is the reversible brake. It voids every
///        `ALLOW_REFERENCE` for the same pair and reference queued before it, so re-allowing waits a full delay.
///      None of these reach funds, exits, the reserve or any pool's frozen terms.
contract EntryRatioRegistrar is HookrGoverned {
    /// @custom:storage-location erc7201:hookr.erg.registrar
    struct State {
        address guardian;
    }

    /// @dev cast index-erc7201 hookr.erg.registrar
    bytes32 private constant STATE_SLOT = 0xc19e003a9c7681557449028d5fde386fd11f747c8a70a7600f20dbb6f622a900;

    /// @notice Kind for allowing a price reference on one currency pair. Arguments:
    ///         abi.encode(Currency currency0, Currency currency1, address priceReference), currency0 < currency1.
    bytes32 public constant ALLOW_REFERENCE = keccak256("ALLOW_REFERENCE");
    /// @notice Kind for appointing the guardian. Arguments: abi.encode(address guardian), non-zero.
    bytes32 public constant SET_GUARDIAN = keccak256("SET_GUARDIAN");

    /// @notice The hook this contract is the registrar of.
    IEntryRatioGuarantee public immutable hook;

    /// @notice Emitted when the guardian changes. Zero means no guardian.
    /// @param previousGuardian The guardian before the change
    /// @param newGuardian The guardian after the change
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);

    /// @notice Thrown when a brake is called by an account that is neither the owner nor the guardian.
    /// @param caller The caller
    error NotGuardianOrOwner(address caller);

    /// @param owner_ The owner (non-zero, not an EIP-7702 delegated account)
    /// @param hook_ The hook whose registrar this contract is. Under CREATE3 the hook's address is known before it
    ///        is deployed, so this contract deploys first and the hook names it as its registrar.
    constructor(address owner_, IEntryRatioGuarantee hook_) HookrGoverned(owner_, MIN_DELAY) {
        if (address(hook_) == address(0)) revert InvalidAddress(address(hook_));
        hook = hook_;
    }

    /// @notice Allows `priceReference` for the pair, consuming a ready `ALLOW_REFERENCE` with the same arguments.
    /// @dev The hook re-checks the pair order and that the reference is a contract and not a delegated account.
    /// @param currency0 The pair's lower-sorted currency
    /// @param currency1 The pair's higher-sorted currency
    /// @param priceReference The reference to allow
    function allowReference(Currency currency0, Currency currency1, address priceReference) external onlyOwner {
        _consume(ALLOW_REFERENCE, abi.encode(currency0, currency1, priceReference));
        hook.setPriceReference(currency0, currency1, priceReference, true);
    }

    /// @notice Appoints `nextGuardian`, consuming a ready `SET_GUARDIAN` with the same argument.
    /// @param nextGuardian The guardian (non-zero, not an EIP-7702 delegated account)
    function setGuardian(address nextGuardian) external onlyOwner {
        if (nextGuardian == address(0)) revert InvalidAddress(nextGuardian);
        _refuseDelegated(nextGuardian);
        _consume(SET_GUARDIAN, abi.encode(nextGuardian));
        State storage s = _state();
        emit GuardianSet(s.guardian, nextGuardian);
        s.guardian = nextGuardian;
    }

    /// @notice Disallows `priceReference` for the pair at once. Owner or guardian.
    /// @dev Deposits into every pool that names the reference stop. Exits do not re-check the allowance, so positions
    ///      that entered on the reference can still exercise against it while it answers. Every `ALLOW_REFERENCE` for
    ///      the same arguments queued before this call is void, so allowing it again waits a full delay.
    /// @param currency0 The pair's lower-sorted currency
    /// @param currency1 The pair's higher-sorted currency
    /// @param priceReference The reference to disallow
    function disallowReference(Currency currency0, Currency currency1, address priceReference) external {
        State storage s = _state();
        if (msg.sender != _owner() && msg.sender != s.guardian) revert NotGuardianOrOwner(msg.sender);
        _invalidateQueued(_subjectKey(ALLOW_REFERENCE, abi.encode(currency0, currency1, priceReference)));
        hook.setPriceReference(currency0, currency1, priceReference, false);
    }

    /// @notice Permanently stops new deposits into a pool at once. Owner only, because the hook has no reopen.
    /// @param id The pool id
    function closePool(PoolId id) external onlyOwner {
        hook.closePool(id);
    }

    /// @notice Removes the guardian at once and voids any queued `SET_GUARDIAN` naming the removed account.
    /// @dev Does nothing when no guardian is set.
    function removeGuardian() external onlyOwner {
        State storage s = _state();
        address previous = s.guardian;
        if (previous == address(0)) return;
        s.guardian = address(0);
        _invalidateQueued(_subjectKey(SET_GUARDIAN, abi.encode(previous)));
        emit GuardianSet(previous, address(0));
    }

    /// @notice The guardian, or zero.
    /// @return The account that may call `disallowReference` besides the owner
    function guardian() external view returns (address) {
        return _state().guardian;
    }

    /// @dev Queue-time admission: known kinds with canonical arguments only. A reference must already hold
    ///      contract code that is not a delegation designator, and the pair must be sorted as a v4 key sorts it.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        bytes memory canonical;
        if (kind == ALLOW_REFERENCE) {
            (Currency currency0, Currency currency1, address priceReference) =
                abi.decode(arguments, (Currency, Currency, address));
            if (Currency.unwrap(currency0) >= Currency.unwrap(currency1)) {
                revert IEntryRatioGuarantee.InvalidReferencePair();
            }
            _requireDeployedCode(priceReference);
            canonical = abi.encode(currency0, currency1, priceReference);
        } else if (kind == SET_GUARDIAN) {
            address nextGuardian = abi.decode(arguments, (address));
            if (nextGuardian == address(0)) revert InvalidAddress(nextGuardian);
            _refuseDelegated(nextGuardian);
            canonical = abi.encode(nextGuardian);
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
            return;
        } else {
            revert UnknownOperation(kind);
        }
        _requireCanonical(kind, arguments, canonical);
    }

    /// @dev `ALLOW_REFERENCE` and `SET_GUARDIAN` are keyed by subject, so a brake voids only the operation on its
    ///      own pair and reference, or its own guardian.
    function _epochKey(bytes32 kind, bytes memory arguments) internal pure override returns (bytes32) {
        if (kind == ALLOW_REFERENCE || kind == SET_GUARDIAN) return _subjectKey(kind, arguments);
        return kind;
    }

    function _subjectKey(bytes32 kind, bytes memory arguments) private pure returns (bytes32) {
        return keccak256(abi.encode(kind, arguments));
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
