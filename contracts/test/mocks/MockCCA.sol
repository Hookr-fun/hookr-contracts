// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IContinuousClearingAuctionFactory,
    IContinuousClearingAuction,
    AuctionParameters,
    LBPInitializationParams
} from "../../src/interfaces/IContinuousClearingAuction.sol";

/// @notice A minimal stand-in for Uniswap's deployed CCA, faithful to the surface `HookrLaunchpadV5`
///         drives: it captures the fund/token recipients and end block from the config, lets a test
///         set the clearing outcome, and enforces the same recipient gates on the sweeps. Bidding is
///         out of scope — the launchpad never touches it — so the mock never models bids.
contract MockAuction is IContinuousClearingAuction {
    address public immutable token;
    uint256 public immutable amount;
    /// @notice The auction's quote currency: address(0) = native ETH, else an ERC20 (HOOKR).
    address public currency;
    address public fundsRecipient;
    address public tokensRecipient;
    uint64 public endBlockValue;
    uint256 public floorPriceQ96;
    uint256 public requiredCurrencyRaised;

    bool public graduated;
    bool public checkpointed;
    uint256 public clearingPriceX96;
    uint256 public raiseWei;
    uint256 public unsoldTokens;
    bool public armed;

    error OnlyRecipient();
    error TickPriceNotAtBoundary();
    error TickSpacingTooSmall();
    error FloorPriceIsZero();

    constructor(address token_, uint256 amount_, AuctionParameters memory p) {
        // Mirror the deployed CCA's TickStorage construction gates: the floor initializes the
        // first tick and MUST sit on an exact tick boundary (the live canary caught a launchpad
        // that truncated the spacing and missed the boundary by 51 wei — this mock now refuses
        // the same config the real auction refuses).
        if (p.tickSpacing < 2) revert TickSpacingTooSmall();
        if (p.floorPrice == 0) revert FloorPriceIsZero();
        if (p.floorPrice % p.tickSpacing != 0) revert TickPriceNotAtBoundary();
        token = token_;
        amount = amount_;
        currency = p.currency;
        fundsRecipient = p.fundsRecipient;
        tokensRecipient = p.tokensRecipient;
        endBlockValue = p.endBlock;
        floorPriceQ96 = p.floorPrice;
        requiredCurrencyRaised = p.requiredCurrencyRaised;
    }

    /// @notice Test hook: set the clearing outcome the launchpad will read at migration. Fund this
    ///         contract with `raiseWei` of ETH separately (the real auction holds the raised bids).
    function setOutcome(bool graduated_, uint256 clearingPriceX96_, uint256 raiseWei_, uint256 unsoldTokens_) external {
        graduated = graduated_;
        checkpointed = false;
        clearingPriceX96 = clearingPriceX96_;
        raiseWei = raiseWei_;
        unsoldTokens = unsoldTokens_;
    }

    function onTokensReceived() external override {
        require(IERC20(token).balanceOf(address(this)) == amount, "not funded");
        armed = true;
    }

    /// @notice Mirror the deployed CCA's lazy finalization: settlement must checkpoint before the
    ///         final graduation result becomes visible.
    function checkpoint() external override {
        checkpointed = true;
    }

    function isGraduated() external view override returns (bool) {
        return checkpointed && graduated;
    }

    function endBlock() external view override returns (uint64) {
        return endBlockValue;
    }

    function lbpInitializationParams() external view override returns (LBPInitializationParams memory) {
        return LBPInitializationParams({
            initialPriceX96: clearingPriceX96, tokensSold: amount - unsoldTokens, currencyRaised: raiseWei
        });
    }

    function sweepCurrency() external override {
        if (msg.sender != fundsRecipient) revert OnlyRecipient();
        if (graduated && raiseWei > 0) {
            if (currency == address(0)) {
                (bool ok,) = fundsRecipient.call{value: raiseWei}("");
                require(ok, "eth");
            } else {
                require(IERC20(currency).transfer(fundsRecipient, raiseWei), "erc20");
            }
        }
    }

    function sweepUnsoldTokens() external override {
        if (msg.sender != tokensRecipient) revert OnlyRecipient();
        uint256 back = graduated ? unsoldTokens : amount;
        if (back > 0) IERC20(token).transfer(tokensRecipient, back);
    }

    receive() external payable {}
}

/// @notice Stand-in for the deployed CCA factory. `create` deploys a `MockAuction`; it is
///         caller-agnostic and unfunded, exactly like the real permissionless factory.
contract MockAuctionFactory is IContinuousClearingAuctionFactory {
    function create(address token, uint256 amount, bytes calldata configData, bytes32)
        external
        override
        returns (address auction)
    {
        AuctionParameters memory p = abi.decode(configData, (AuctionParameters));
        return address(new MockAuction(token, amount, p));
    }

    function getAddress(address, uint256, bytes calldata, bytes32, address) external pure override returns (address) {
        return address(0);
    }
}
