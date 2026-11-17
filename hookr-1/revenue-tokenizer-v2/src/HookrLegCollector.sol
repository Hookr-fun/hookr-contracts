// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {IHookrTreasury} from "hookr/interfaces/IHookrTreasury.sol";
import {IHookrLegCollector} from "./interfaces/IHookrLegCollector.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";
import {IHookrDropHost} from "./interfaces/IHookrDropHost.sol";
import {IHookrDropBox} from "./interfaces/IHookrDropBox.sol";
import {HookrForward} from "./libraries/HookrForward.sol";

/// @title Hookr leg collector, part of the HookRevenue Tokenizer
/// @notice Takes Hookr's leg from every revenue token the tokenizer creates (5% of what each door outside the Hookr root
///         delivers, sent in the token's sync) and lets anyone sweep it to the HookrTreasury's current `target()`.
/// @dev No owner and no state. `receive()` is empty, so a revenue token's gas-capped leg payment always lands; ERC-20s
///      arrive by plain transfers. The target is read on every sweep, so only the treasury's own two-step target change
///      moves where the money goes. A sweep sends the whole balance: ETH by a call that must succeed, an ERC-20 by
///      `safeTransfer`, so an asset that charges on the way out still leaves in full and the target gets what it lets
///      through. When the leg is paid in a revenue token of the tokenizer, its shares earn nothing here: every such
///      token leaves its leg collector out of `earns`, so no income accrues to the collector that it could not claim,
///      and the shares start earning for the target once swept. A revenue token of another tokenizer or release (a
///      listed asset of a token here, so its token-side leg pays shares of it in) does not leave this collector out,
///      so its income and drops accrue here: `collectIncome` and `collectDrops`, anyone's call, claim them straight to
///      the target, bounded to eight assets or eight drops, each claim with a gas cap and one copied word, and refused
///      before the attempt when the caller left too little gas. The amounts they return and log are what the source
///      answered; the target's balance is the record.
contract HookrLegCollector is IHookrLegCollector {
    using SafeERC20 for IERC20;

    /// @dev A revenue token lists at most eight assets; one collection visits at most eight drops.
    uint256 private constant MAX_ITEMS = 8;
    /// @dev Gas each read (`assetCount`, `dropBox`, `dropAt`) gets.
    uint256 private constant READ_GAS = 100_000;
    /// @dev Gas each claim gets: a cold transfer of a revenue token listing eight assets, as the drop box allows.
    uint256 private constant CLAIM_GAS = 1_600_000;
    /// @dev What a claim needs left before it starts: its cap with the 1/64 the EVM keeps back, a read and the event.
    uint256 private constant CLAIM_FLOOR = CLAIM_GAS + CLAIM_GAS / 63 + READ_GAS + 30_000;

    /// @inheritdoc IHookrLegCollector
    address public immutable treasury;

    /// @param treasury_ The HookrTreasury; must have code.
    constructor(address treasury_) {
        if (treasury_.code.length == 0) revert InvalidTreasury(treasury_);
        treasury = treasury_;
    }

    /// @notice Takes native ETH from anyone and writes nothing.
    receive() external payable {}

    /// @inheritdoc IHookrLegCollector
    function sweep(Currency currency) external returns (uint256 amount) {
        amount = _sweep(currency, IHookrTreasury(treasury).target());
        if (amount == 0) revert NothingToSweep(currency);
    }

    /// @inheritdoc IHookrLegCollector
    function sweepMany(Currency[] calldata currencies) external returns (uint256[] memory amounts) {
        address target = IHookrTreasury(treasury).target();
        uint256 n = currencies.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amounts[i] = _sweep(currencies[i], target);
        }
    }

    /// @inheritdoc IHookrLegCollector
    function collectIncome(address revenueToken) external returns (uint256[] memory amounts) {
        (bool read, uint256 n) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.assetCount, ()), READ_GAS);
        if (!read || n > MAX_ITEMS) return amounts;
        address target = IHookrTreasury(treasury).target();
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (gasleft() < CLAIM_FLOOR) revert CollectionStarved(i);
            uint256 amount = _claimWord(revenueToken, abi.encodeCall(IHookrRevenueToken.claim, (i, target)));
            if (amount != 0) {
                amounts[i] = amount;
                emit IncomeCollected(revenueToken, i, target, amount);
            }
        }
    }

    /// @inheritdoc IHookrLegCollector
    function collectDrops(address revenueToken, uint256[] calldata dropIds)
        external
        returns (uint256[] memory amounts)
    {
        uint256 n = dropIds.length;
        if (n > MAX_ITEMS) revert TooManyCollectionDrops(n);
        amounts = new uint256[](n);
        (bool read, uint256 word) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrDropHost.dropBox, ()), READ_GAS);
        address box = address(uint160(word));
        if (!read || word >> 160 != 0 || box.code.length == 0) return amounts;
        address target = IHookrTreasury(treasury).target();
        uint256[] memory one = new uint256[](1);
        for (uint256 i; i < n; ++i) {
            if (gasleft() < CLAIM_FLOOR) revert CollectionStarved(i);
            uint256 id = dropIds[i];
            one[0] = id;
            uint256 amount = _claimDrop(box, abi.encodeCall(IHookrDropBox.claim, (one, target)));
            if (amount != 0) {
                amounts[i] = amount;
                emit DropCollected(revenueToken, id, target, amount);
            }
        }
    }

    /// @dev A claim with `CLAIM_GAS` that must answer exactly one word; zero when it fails.
    function _claimWord(address source, bytes memory data) private returns (uint256 amount) {
        assembly ("memory-safe") {
            let ok := call(CLAIM_GAS, source, 0, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            amount := mul(mload(0), ok)
        }
    }

    /// @dev A drop box `claim` of one id with `CLAIM_GAS`: it must answer a one-element array (three words); zero
    ///      when it fails or answers anything else.
    function _claimDrop(address box, bytes memory data) private returns (uint256 amount) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            let ok := call(CLAIM_GAS, box, 0, add(data, 0x20), mload(data), p, 0x60)
            ok := and(ok, eq(returndatasize(), 0x60))
            ok := and(ok, and(eq(mload(p), 0x20), eq(mload(add(p, 0x20)), 1)))
            amount := mul(mload(add(p, 0x40)), ok)
        }
    }

    /// @dev Pays the whole balance of `currency` to `target`; zero when there is none.
    function _sweep(Currency currency, address target) private returns (uint256 amount) {
        amount = HookrSettlement.balance(currency, address(this));
        if (amount == 0) return 0;
        if (currency.isAddressZero()) HookrSettlement.send(currency, target, amount);
        else IERC20(Currency.unwrap(currency)).safeTransfer(target, amount);
        emit Swept(currency, target, amount);
    }
}
