// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRulesStorage as S} from "./HookrRulesStorage.sol";

interface IHookrExtsload { function extsload(bytes32 slot) external view returns (bytes32); }
interface IHookrClaimsBalance { function balanceOf(address owner, uint256 currencyId) external view returns (uint256); }

/// @notice Release-prefix mapping recipes and residual accounting over a pinned core's extsload surface.
library HookrCoreState {
    function mappingSlot(bytes32 root, uint256 offset, bytes32 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, bytes32(uint256(root) + offset)));
    }
    function currencyKey(Currency currency) internal pure returns (bytes32) { return bytes32(uint256(uint160(Currency.unwrap(currency)))); }
    function addressKey(address account) internal pure returns (bytes32) { return bytes32(uint256(uint160(account))); }
    function poolSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 0, PoolId.unwrap(id)); }
    function claimSlot(Currency currency, address payee) internal pure returns (bytes32) { return mappingSlot(mappingSlot(S.RULES_SLOT, 1, currencyKey(currency)), 0, addressKey(payee)); }
    function liabilitiesSlot(Currency currency) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 2, currencyKey(currency)); }
    function dynamicFeeSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 4, PoolId.unwrap(id)); }
    function recaptureSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 5, PoolId.unwrap(id)); }
    function hillSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 6, PoolId.unwrap(id)); }
    function poolAccruedSlot(PoolId id, Currency currency) internal pure returns (bytes32) { return mappingSlot(mappingSlot(S.RULES_SLOT, 7, PoolId.unwrap(id)), 0, currencyKey(currency)); }
    function pendingSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 9, PoolId.unwrap(id)); }
    function integrationSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 10, PoolId.unwrap(id)); }
    function knobsSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.RULES_SLOT, 12, PoolId.unwrap(id)); }
    function walletBoughtSlot(Currency subject, uint32 launch, address wallet) internal pure returns (bytes32) {
        return mappingSlot(mappingSlot(mappingSlot(S.WALLET_CAP_SLOT, 0, currencyKey(subject)), 0, bytes32(uint256(launch))), 0, addressKey(wallet));
    }
    function podiumSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.CROWN_SLOT, 0, PoolId.unwrap(id)); }
    function prizeCapSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.CROWN_SLOT, 1, PoolId.unwrap(id)); }
    function crownGateSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.CROWN_SLOT, 2, PoolId.unwrap(id)); }
    function exitSlot(PoolId id, address wallet) internal pure returns (bytes32) { return mappingSlot(mappingSlot(S.EXIT_CLOCK_SLOT, 0, PoolId.unwrap(id)), 0, addressKey(wallet)); }
    function sandwichSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.SANDWICH_SLOT, 0, PoolId.unwrap(id)); }
    function stormSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.STORM_SLOT, 0, PoolId.unwrap(id)); }
    function holderPotSlot(PoolId id) internal pure returns (bytes32) { return mappingSlot(S.HOLDER_POT_SLOT, 0, PoolId.unwrap(id)); }
    function holderPositionSlot(PoolId id, address wallet) internal pure returns (bytes32) { return mappingSlot(mappingSlot(S.HOLDER_POT_SLOT, 1, PoolId.unwrap(id)), 0, addressKey(wallet)); }
    /// @dev W1-derived checkpoint/band tables: buckets2, pages3, sumA4, sumB5, cpEpochs6.
    function holderTableSlot(PoolId id, uint8 field, uint256 index) internal pure returns (bytes32) {
        require(field >= 2 && field <= 6, "invalid holder table");
        return mappingSlot(mappingSlot(S.HOLDER_POT_SLOT, field, PoolId.unwrap(id)), 0, bytes32(index));
    }
    function holderHeldSlot(Currency subject, address wallet) internal pure returns (bytes32) { return mappingSlot(mappingSlot(S.HOLDER_POT_SLOT, 7, currencyKey(subject)), 0, addressKey(wallet)); }
    function claims(IHookrExtsload core, Currency currency, address payee) internal view returns (uint256) { return uint256(core.extsload(claimSlot(currency, payee))); }
    function liabilities(IHookrExtsload core, Currency currency) internal view returns (uint256) { return uint256(core.extsload(liabilitiesSlot(currency))); }
    function hot(IHookrExtsload core, PoolId id) internal view returns (uint32) { return uint32(uint256(core.extsload(bytes32(uint256(poolSlot(id)) + 1))) >> 224); }
    function cold(IHookrExtsload core, PoolId id) internal view returns (uint128) { return uint128(uint256(core.extsload(bytes32(uint256(poolSlot(id)) + 2))) >> 128); }
    function residual(uint256 balance, uint256 liabilities_) internal pure returns (uint256) { return balance > liabilities_ ? balance - liabilities_ : 0; }
    function residual(IHookrExtsload core, IHookrClaimsBalance manager, Currency currency) internal view returns (uint256) {
        return residual(manager.balanceOf(address(core), uint160(Currency.unwrap(currency))), liabilities(core, currency));
    }
    function accountingInvariant(IHookrExtsload core, IHookrClaimsBalance manager, Currency currency) internal view returns (bool) {
        return manager.balanceOf(address(core), uint160(Currency.unwrap(currency))) >= liabilities(core, currency);
    }
}
