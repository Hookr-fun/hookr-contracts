// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal vendored interface over Uniswap's Continuous Clearing Auction stack, as
///         deployed on Robinhood Chain 4663 and byte-verified against
///         github.com/Uniswap/continuous-clearing-auction @ 6c9e559 on 2026-08-20.
///
///         Hookr deploys NONE of this. The factory at 0x000000001F26a0044BaA66024e7b6599c61963F8
///         is reused as-is: it is permissionless (create() is caller-agnostic and CREATE2-salts
///         by msg.sender, so nobody can frontrun our auction address), audited
///         (Spearbit/OpenZeppelin/ABDK), and carries no owner, proxy, or ACL. Only the calls the
///         launchpad actually makes are declared here; drift against the deployed bytecode is
///         impossible because the deployed bytecode is immutable.

/// @notice Constructor parameters for one auction, ABI-encoded into `create`'s configData.
/// @dev Field order and types mirror src/interfaces/IContinuousClearingAuction.sol upstream.
struct AuctionParameters {
    address currency; // token to raise funds in. address(0) = native ETH
    address tokensRecipient; // receives unsold supply after the auction ends
    address fundsRecipient; // sole address allowed to sweep the raise
    uint64 startBlock; // first block bids are accepted
    uint64 endBlock; // auction is over at this block (bids revert AT endBlock)
    uint64 claimBlock; // filled tokens claimable from this block
    uint256 tickSpacing; // fixed Q96 granularity for bid prices
    address validationHook; // optional per-bid hook; zero for none
    uint256 floorPrice; // starting Q96 clearing price (currency-wei per token-wei)
    uint128 requiredCurrencyRaised; // graduation floor; below it every bid refunds in full
    bytes auctionStepsData; // packed issuance schedule; see StepLib note below
}

/// @notice The clearing outcome the auction reports to its migrating funds recipient.
struct LBPInitializationParams {
    uint256 initialPriceX96; // final clearing price, Q96 currency-wei per token-wei
    uint256 tokensSold;
    uint256 currencyRaised; // gross raise; sweepCurrency transfers this minus protocol fee
}

/// @notice The factory seam (upstream: IDistributorFactory). `create` deploys the auction but
///         does NOT fund it: the caller must transfer exactly `amount` of `token` to the
///         returned address and then call `onTokensReceived()`.
interface IContinuousClearingAuctionFactory {
    function create(address token, uint256 amount, bytes calldata configData, bytes32 salt)
        external
        returns (address auction);
    function getAddress(address token, uint256 amount, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        returns (address auction);
}

/// @notice The auction surface the launchpad drives. Bidding (`submitBid`) and bidder exits and
///         claims are intentionally NOT declared: bidders interact with the auction directly and
///         the launchpad never custodies a bid.
/// @dev StepLib packing, for `auctionStepsData`: a sequence of bytes8 words, each
///      `uint24 mpsPerBlock | uint40 blockDelta` (mps first, in the high 3 bytes). The contract
///      enforces sum(mpsPerBlock * blockDelta) == 1e7 and sum(blockDelta) == endBlock - startBlock.
interface IContinuousClearingAuction {
    function onTokensReceived() external;
    /// @dev The upstream CCA updates clearing and graduation state lazily. Integrators MUST
    ///      checkpoint after the auction window before reading the final `isGraduated()` value.
    ///      The concrete function returns a Checkpoint struct; Hookr intentionally ignores the
    ///      return data, so the minimal interface declares no return value.
    function checkpoint() external;
    function isGraduated() external view returns (bool);
    function endBlock() external view returns (uint64);
    function lbpInitializationParams() external view returns (LBPInitializationParams memory);
    /// @dev Caller must be fundsRecipient, after endBlock. Transfers currencyRaised minus the
    ///      protocol fee the factory's controller quotes at sweep time — which is why the
    ///      launchpad accounts by received balance delta, never by the reported figure.
    function sweepCurrency() external;
    /// @dev Caller must be tokensRecipient, after endBlock. Transfers remainingSupply() when the
    ///      auction graduated, or the entire auction supply when it did not.
    function sweepUnsoldTokens() external;
}
