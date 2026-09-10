// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Hookr Partner Registry V1
/// @notice Interface for deterministic revenue vaults, market vouchers, and pool attribution.
interface IHookrPartnerRegistryV1 {
    /// @notice One-time initialization terms for a deterministic, initially dormant per-pool
    ///         revenue vault.
    /// @dev Source strategy addresses and the stack hash are intentionally absent so the vault can
    ///      be deployed before the strategies without a CREATE2 dependency cycle. `marketKind`
    ///      permits a new-token vault to bind the coordinator's counterfactual token address while
    ///      preserving deployed-code validation for existing-token markets.
    struct VaultTerms {
        /// @notice Raw Uniswap v4 PoolId for the attributed market.
        bytes32 poolId;
        /// @notice Registered partner identifier, or zero for a direct creator launch.
        bytes32 partnerId;
        /// @notice Version of the partner integration terms.
        uint32 integrationVersion;
        /// @notice Market kind: 1 for a new token and 2 for an existing token.
        uint8 marketKind;
        /// @notice Coordinator authorized to consume the market voucher.
        address coordinator;
        /// @notice Root hook implementation bound to the market.
        address kernel;
        /// @notice Market creator whose authorization applies to a direct launch.
        address creator;
        /// @notice Subject token paired by the market.
        address subject;
        /// @notice Quote token, or address(0) for native currency.
        address quote;
        /// @notice Voucher-declared buy-side directional tax in basis points.
        uint16 buyTaxBps;
        /// @notice Voucher-declared sell-side directional tax in basis points.
        uint16 sellTaxBps;
        /// @notice Initial recipient of the creator share.
        address creatorBeneficiary;
        /// @notice Initial recipient of the partner share, or the treasury for a direct launch.
        address partnerBeneficiary;
        /// @notice Initial recipient of the treasury share.
        address treasuryBeneficiary;
        /// @notice Initial recipient of the buy/burn allocation.
        address buyBurnBeneficiary;
        /// @notice Commitment to the immutable fee allocation terms.
        bytes32 feeTermsHash;
        /// @notice Partner share of credited tax proceeds in basis points, or zero for no partner.
        uint16 partnerShareBps;
    }

    /// @notice Coordinator-derived values committed by the signed market voucher.
    struct MarketContext {
        /// @notice Market kind: 1 for a new token and 2 for an existing token.
        uint8 marketKind;
        /// @notice Account calling the coordinator's market-opening function.
        address caller;
        /// @notice Creator attributed to the market.
        address creator;
        /// @notice Subject token paired by the market.
        address subject;
        /// @notice Quote token, or address(0) for native currency.
        address quote;
        /// @notice Kernel address encoded in the complete PoolKey.
        address kernel;
        /// @notice Raw Uniswap v4 PoolId for the market.
        bytes32 poolId;
        /// @notice Commitment to every PoolKey field.
        bytes32 poolKeyHash;
        /// @notice Commitment to the kernel, modules, and stack limits.
        bytes32 hookStackHash;
        /// @notice Commitment to market-specific creation intent.
        bytes32 marketIntentHash;
        /// @notice Commitment to the caller, assets, and funding amounts.
        bytes32 fundingHash;
    }

    /// @notice EIP-712 authorization binding a signer to one market and revenue configuration.
    struct MarketVoucher {
        /// @notice Registered partner identifier, or zero for a direct creator launch.
        bytes32 partnerId;
        /// @notice Version of the partner integration terms.
        uint32 integrationVersion;
        /// @notice Market kind: 1 for a new token and 2 for an existing token.
        uint8 marketKind;
        /// @notice Coordinator authorized to consume the voucher.
        address coordinator;
        /// @notice Account authorized to call the coordinator for this market.
        address caller;
        /// @notice Creator attributed to the market.
        address creator;
        /// @notice Subject token paired by the market.
        address subject;
        /// @notice Quote token, or address(0) for native currency.
        address quote;
        /// @notice Raw Uniswap v4 PoolId for the market.
        bytes32 poolId;
        /// @notice Commitment to every PoolKey field.
        bytes32 poolKeyHash;
        /// @notice Commitment to the kernel, modules, and stack limits.
        bytes32 hookStackHash;
        /// @notice Commitment to market-specific creation intent.
        bytes32 marketIntentHash;
        /// @notice Commitment to the caller, assets, and funding amounts.
        bytes32 fundingHash;
        /// @notice Root hook implementation bound to the market.
        address kernel;
        /// @notice Buy-side directional-tax strategy, or zero when buyTaxBps is zero.
        address buyStrategy;
        /// @notice Sell-side directional-tax strategy, or zero when sellTaxBps is zero.
        address sellStrategy;
        /// @notice Declared buy-side tax signed with the complete hook-stack commitment.
        uint16 buyTaxBps;
        /// @notice Declared sell-side tax signed with the complete hook-stack commitment.
        uint16 sellTaxBps;
        /// @notice Initial recipient of the creator share.
        address creatorBeneficiary;
        /// @notice Initial recipient of the partner share, or the treasury for a direct launch.
        address partnerBeneficiary;
        /// @notice Initial recipient of the treasury share.
        address treasuryBeneficiary;
        /// @notice Initial recipient of the buy/burn allocation.
        address buyBurnBeneficiary;
        /// @notice Deterministic revenue-vault address derived from the voucher terms.
        address revenueVault;
        /// @notice Commitment to the immutable fee allocation terms.
        bytes32 feeTermsHash;
        /// @notice Partner share of credited tax proceeds in basis points, or zero for no partner.
        uint16 partnerShareBps;
        /// @notice Signer-scoped nonce consumed with the voucher.
        uint256 nonce;
        /// @notice Last block timestamp at which the voucher may be consumed.
        uint256 deadline;
    }

    /// @notice Permanent market attribution recorded when a voucher is consumed.
    struct PoolAttribution {
        /// @notice True after attribution has been recorded for the pool.
        bool recorded;
        /// @notice Registered partner identifier, or zero for a direct creator launch.
        bytes32 partnerId;
        /// @notice Version of the partner integration terms.
        uint32 integrationVersion;
        /// @notice Account that called the coordinator for this market.
        address caller;
        /// @notice Creator attributed to the market.
        address creator;
        /// @notice Address whose signature authorized the voucher.
        address authorizationSigner;
        /// @notice Initial partner beneficiary committed by the voucher.
        /// @dev The vault may later rotate the current beneficiary without changing this snapshot.
        address partnerBeneficiary;
        /// @notice Initial creator beneficiary committed by the voucher.
        /// @dev The vault may later rotate the current beneficiary without changing this snapshot.
        address creatorBeneficiary;
        /// @notice Deterministic vault accounting for credited directional-tax proceeds.
        address revenueVault;
        /// @notice Commitment to the immutable fee allocation terms.
        bytes32 feeTermsHash;
        /// @notice Partner share of credited tax proceeds in basis points, or zero for no partner.
        uint16 partnerShareBps;
        /// @notice Root hook implementation bound to the market.
        address kernel;
        /// @notice Buy-side directional-tax strategy, or zero when disabled.
        address buyStrategy;
        /// @notice Sell-side directional-tax strategy, or zero when disabled.
        address sellStrategy;
        /// @notice Voucher-declared buy-side directional tax in basis points.
        uint16 buyTaxBps;
        /// @notice Voucher-declared sell-side directional tax in basis points.
        uint16 sellTaxBps;
        /// @notice Commitment to the immutable hook stack.
        bytes32 hookStackHash;
        /// @notice Block number at which the attribution was recorded.
        uint256 createdAtBlock;
    }

    /// @notice Returns the coordinator authorized to consume vouchers.
    /// @return Coordinator address, or address(0) before it is set.
    function coordinator() external view returns (address);

    /// @notice Consumes a signed voucher and records permanent attribution for one market.
    /// @dev Callable only by the bound coordinator. The authorization signer and nonce pair may be
    ///      consumed only once.
    /// @param encodedAuthorization ABI encoding of a MarketVoucher and its signature.
    /// @param contextCommitment Commitment independently derived by the coordinator.
    /// @return revenueVault Activated deterministic vault bound to the market.
    function consumeMarketVoucher(bytes calldata encodedAuthorization, bytes32 contextCommitment)
        external
        returns (address revenueVault);

    /// @notice Deploys and initializes the deterministic revenue vault for the supplied terms.
    /// @dev The vault remains unable to accept credits until voucher consumption activates its
    ///      strategy sources.
    /// @param terms Immutable initialization terms for the vault.
    /// @return revenueVault Deployed deterministic vault address.
    function deployRevenueVault(VaultTerms calldata terms) external returns (address revenueVault);

    /// @notice Returns the coordinator-context commitment encoded by a voucher.
    /// @param voucher Voucher whose context fields are hashed.
    /// @return commitment Context commitment expected from the coordinator.
    function voucherContextCommitment(MarketVoucher calldata voucher) external pure returns (bytes32 commitment);

    /// @notice Predicts the deterministic revenue-vault address for the supplied terms.
    /// @param terms Immutable initialization terms for the vault.
    /// @return predicted Predicted vault address.
    function predictRevenueVault(VaultTerms calldata terms) external view returns (address predicted);

    /// @notice Returns the EIP-712 digest signed for a market voucher.
    /// @param voucher Voucher to hash.
    /// @return digest Domain-separated voucher digest.
    function voucherDigest(MarketVoucher calldata voucher) external view returns (bytes32 digest);

    /// @notice Returns the permanent attribution recorded for a pool.
    /// @param poolId Raw Uniswap v4 PoolId.
    /// @return attribution Recorded attribution, or a zero-valued struct when absent.
    function poolAttribution(bytes32 poolId) external view returns (PoolAttribution memory attribution);
}
