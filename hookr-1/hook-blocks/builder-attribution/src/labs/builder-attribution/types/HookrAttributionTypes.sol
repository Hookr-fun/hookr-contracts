// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Builder attribution types
/// @notice Shared structs and constants for builder attribution.
library HookrAttributionTypes {
    /// @notice Directional tax ceiling, in pips of the taxed quote amount (10%).
    uint24 internal constant MAX_TAX_PIPS = 100_000;
    /// @notice Inclusive bounds of a registered partner's share of every harvested amount, in basis points.
    uint16 internal constant MIN_PARTNER_SHARE_BPS = 2_000;
    uint16 internal constant MAX_PARTNER_SHARE_BPS = 2_500;
    /// @notice The partner share the onboarding flow pre-fills: the bottom of the range, so the treasury keeps 1,000.
    uint16 internal constant DEFAULT_PARTNER_SHARE_BPS = 2_000;
    /// @notice Fixed creator share of every harvested amount.
    uint16 internal constant CREATOR_SHARE_BPS = 6_000;
    /// @notice Fixed HOOKR buy/burn allocation of every harvested amount. An allocation, not an executed burn.
    uint16 internal constant BUY_BURN_SHARE_BPS = 1_000;
    /// @notice What creator and buy/burn leave for partner plus treasury.
    uint16 internal constant PARTNER_AND_TREASURY_BPS = 3_000;
    /// @notice Basis-point denominator.
    uint16 internal constant BPS = 10_000;

    /// @notice One-time authorization that binds a registered partner, or none, to one fresh PoolId.
    /// @dev Signed with EIP-712 by the partner's registered signer, unless `partnerId` is zero: a direct market,
    ///      which carries no signature and no partner share. `stackHash` commits the Rules module, base fee,
    ///      caps, policy id and exact Rules config the pool freezes, and the opening price, range, liquidity and
    ///      funding ceilings of the launch (`HookrAttributionLauncher.stackHash`).
    /// @param partnerId Registered partner, or zero for a direct market
    /// @param launcher The only launcher that may consume the voucher
    /// @param root The Hookr root the pool is initialized on
    /// @param caller The only account that may launch with the voucher
    /// @param poolId The fresh PoolId the voucher attributes
    /// @param stackHash Commitment to the pool's frozen Rules stack and the launch market
    /// @param creatorBeneficiary Initial payee of the creator's 60%
    /// @param buyTaxPips Tax on every buy, pips of the gross buyer spend
    /// @param sellTaxPips Tax on exact-input sells, pips of the quote the sale releases
    /// @param partnerShareBps Must equal the partner's registered share; zero for a direct market
    /// @param nonce Per-signer replay nonce
    /// @param deadline Last block.timestamp at which the voucher can be consumed
    struct Voucher {
        bytes32 partnerId;
        address launcher;
        address root;
        address caller;
        bytes32 poolId;
        bytes32 stackHash;
        address creatorBeneficiary;
        uint24 buyTaxPips;
        uint24 sellTaxPips;
        uint16 partnerShareBps;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice The permanent attribution record of one pool. Written once and never rewritten.
    /// @param recorded True once the pool is attributed
    /// @param partnerId Registered partner, or zero for a direct market
    /// @param root The root the pool lives on
    /// @param caller The account that launched the pool
    /// @param signer The partner signer that authorized the voucher, or zero for a direct market
    /// @param vault The per-pool revenue vault that receives the pool's directional tax
    /// @param creatorBeneficiary Initial creator payee
    /// @param partnerBeneficiary Initial partner payee (the partner's registered beneficiary), or zero
    /// @param buyTaxPips Frozen buy tax
    /// @param sellTaxPips Frozen sell tax
    /// @param partnerShareBps Frozen partner share
    /// @param createdAtBlock block.number at attribution (the parent-chain height on Robinhood Chain)
    /// @param stackHash The committed Rules stack
    /// @param termsHash Commitment to the pool, split, taxes and initial payees
    struct Attribution {
        bool recorded;
        bytes32 partnerId;
        address root;
        address caller;
        address signer;
        address vault;
        address creatorBeneficiary;
        address partnerBeneficiary;
        uint24 buyTaxPips;
        uint24 sellTaxPips;
        uint16 partnerShareBps;
        uint64 createdAtBlock;
        bytes32 stackHash;
        bytes32 termsHash;
    }

    /// @notice A registered partner.
    /// @param signer Authorizes vouchers (EOA, EIP-7702 account or ERC-1271 contract)
    /// @param beneficiary Initial partner payee written into every vault the partner is attributed to
    /// @param shareBps The partner's share, inside [MIN_PARTNER_SHARE_BPS, MAX_PARTNER_SHARE_BPS]
    /// @param readyAt Earliest block.timestamp at which the owner can activate the proposal
    /// @param active True while the partner can authorize new vouchers
    /// @param retired True once retired; a retired partner id can never be reactivated
    struct Partner {
        address signer;
        address beneficiary;
        uint16 shareBps;
        uint48 readyAt;
        bool active;
        bool retired;
    }

    /// @notice Per-pool advisory configuration: the directional tax and the vault that receives it.
    struct TaxConfig {
        uint24 buyTaxPips;
        uint24 sellTaxPips;
        address vault;
    }
}
