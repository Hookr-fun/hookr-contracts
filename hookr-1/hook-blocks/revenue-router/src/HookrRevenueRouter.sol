// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrLanes} from "hookr/interfaces/IHookrLanes.sol";
import {IHookrRecaptureRules} from "hookr/interfaces/IHookrRecaptureRules.sol";
import {HookrRevenueTypes} from "./interfaces/HookrRevenueTypes.sol";
import {HookrRevenueConfig} from "./libraries/HookrRevenueConfig.sol";
import {HookrRevenueSplit} from "./HookrRevenueSplit.sol";

/// @title Hookr revenue router
/// @notice Permissionless, ownerless CREATE2 factory and directory of `HookrRevenueSplit`s. A split's address is a
///         pure function of this router, the tag and the exact payee list, so a creator can put the predicted
///         address into `RulesConfig.royaltyTo` before the split exists: Rules claims wait at that address and the
///         split, once anyone deploys it, pulls them. Nobody can occupy the address with a different payee list.
/// @dev Why a factory of per-address splits rather than one ledger keyed by market id (the shape of the live
///      release's revenue router): Hookr 1 `HookrRules` credits claims to an address, never to a market id, so the
///      payee identity a pool can commit to is an address. One split per address keeps each pool's (or each tag's)
///      accounting separate without any registrar, configurator or hook change.
///      Creator knobs, fixed per split at creation and bounded by the getters below: the payee list (count within
///      [MIN_RECIPIENTS, MAX_RECIPIENTS]), each payee's weight (within [MIN_RECIPIENT_BPS, MAX_RECIPIENT_BPS],
///      summing to exactly TOTAL_BPS), each payee's role label (STRATEGY makes that payee pull-only) and the tag.
///      `DEFAULT_*` values and `defaultRecipients` are what launch tooling proposes; the router does not enforce them.
///      No owner, no constructor arguments, no timelock: one CREATE3 deploy gives the same router, and so the same
///      split address per (tag, payees), on every chain that has the factory.
contract HookrRevenueRouter is HookrReleased {
    using PoolIdLibrary for PoolKey;

    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.revenue.factory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SLOT = 0xcc5e05fef90c3825cc5063f85b07f0873484e828732f6ed774d2477a87922500;

    /// @custom:storage-location erc7201:hookr.revenue.factory
    struct State {
        mapping(address split => bool) isSplit;
        uint256 count;
    }

    /// @notice Fewest payees one split may name.
    uint256 public constant MIN_RECIPIENTS = HookrRevenueTypes.MIN_RECIPIENTS;
    /// @notice Most payees one split may name.
    uint256 public constant MAX_RECIPIENTS = HookrRevenueTypes.MAX_RECIPIENTS;
    /// @notice Payee count launch tooling proposes (the creator alone).
    uint256 public constant DEFAULT_RECIPIENTS = HookrRevenueTypes.DEFAULT_RECIPIENTS;
    /// @notice Smallest weight one payee may hold, in basis points.
    uint256 public constant MIN_RECIPIENT_BPS = HookrRevenueTypes.MIN_RECIPIENT_BPS;
    /// @notice Largest weight one payee may hold, in basis points.
    uint256 public constant MAX_RECIPIENT_BPS = HookrRevenueTypes.MAX_RECIPIENT_BPS;
    /// @notice Weight launch tooling proposes for the creator's own payee, in basis points.
    uint256 public constant DEFAULT_RECIPIENT_BPS = HookrRevenueTypes.DEFAULT_RECIPIENT_BPS;
    /// @notice The weights of one split sum to exactly this.
    uint256 public constant TOTAL_BPS = HookrRevenueTypes.BPS;

    /// @notice Smallest `RulesConfig.royaltyBps` launch tooling offers with a split as `royaltyTo` (zero means no
    ///         royalty). Whether a royalty pays anything also depends on the pool's LP Rewards and protocol share: the
    ///         Rules take it in whole pips of each buy, so a small royalty of a small net slice rounds to nothing (this
    ///         one on lpBps 100 at the 2,000 floor, for example); `checkRoyaltyTerms` refuses such terms.
    uint256 public constant MIN_ROYALTY_BPS = 1;
    /// @notice Largest `RulesConfig.royaltyBps`: the bound HookrRules enforces at bind (10% of the net LP-reward slice).
    uint256 public constant MAX_ROYALTY_BPS = 1_000;
    /// @notice `RulesConfig.royaltyBps` launch tooling proposes with a split. A proposal, not enforced; the Rules
    ///         enforce only MAX_ROYALTY_BPS and the configured protocol share floor. The royalty comes out of the
    ///         LP-reward slice net of the protocol share, which the Rules take in pips rounded up, so the pool never
    ///         pays the protocol less than its configured share; `checkRoyaltyTerms` is a stricter tooling check. This
    ///         royalty is a tenth of the net slice, a whole number of pips wherever the share is whole bps, so the
    ///         check accepts it on every LP Rewards slice whose share it accepts.
    uint256 public constant DEFAULT_ROYALTY_BPS = 1_000;

    /// @notice Most currencies `payoutCurrencies` returns, equal to the split's `MAX_BATCH_CURRENCIES`.
    uint256 public constant MAX_PAYOUT_CURRENCIES = 16;

    /// @notice A split was deployed at its committed address.
    event SplitCreated(address indexed split, bytes32 indexed splitId, bytes32 indexed tag, address caller);

    /// @notice Thrown if CREATE2 did not land on the predicted address. Unreachable.
    error AddressMismatch(address predicted, address deployed);

    /// @notice Thrown by `checkRoyaltyTerms` when the protocol's share of the LP Rewards or Auto Burn slice is not a
    ///         whole number of basis points.
    error ProtocolShareRoundsDown(uint256 lpBps, uint256 burnBps, uint256 protocolShareBps);

    /// @notice Thrown by `checkRoyaltyTerms` when the royalty is not a whole, non-zero number of pips of each buy.
    error RoyaltyRoundsDown(uint256 lpBps, uint256 protocolShareBps, uint256 royaltyBps);

    /// @notice The commitment `keccak256(abi.encode(tag, recipients))` used as the CREATE2 salt.
    function splitIdOf(bytes32 tag, HookrRevenueTypes.Recipient[] calldata recipients) public pure returns (bytes32) {
        return HookrRevenueConfig.id(tag, recipients);
    }

    /// @notice Hash of the split's init code for this payee list (creation code plus constructor arguments).
    function initCodeHash(bytes32 tag, HookrRevenueTypes.Recipient[] calldata recipients)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(type(HookrRevenueSplit).creationCode, abi.encode(tag, recipients)));
    }

    /// @notice The address the split for (tag, recipients) has or will have. Reverts for an invalid payee list,
    ///         so a creator can never commit a pool's royalty to an address no split can ever occupy.
    function predict(bytes32 tag, HookrRevenueTypes.Recipient[] calldata recipients)
        public
        view
        returns (address split)
    {
        bytes32 salt = splitIdOf(tag, recipients);
        split = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash(tag, recipients))))
            )
        );
        HookrRevenueConfig.validate(recipients, split, address(this));
    }

    /// @notice Deploys the split for (tag, recipients), or returns it if it already exists. Anyone may call.
    /// @dev Idempotent: a front-run of this call deploys exactly the same split, so it cannot grief the creator.
    function create(bytes32 tag, HookrRevenueTypes.Recipient[] calldata recipients) external returns (address split) {
        split = predict(tag, recipients);
        if (split.code.length != 0) return split;
        address deployed = address(new HookrRevenueSplit{salt: splitIdOf(tag, recipients)}(tag, recipients));
        if (deployed != split) revert AddressMismatch(split, deployed);
        State storage s = _state();
        s.isSplit[split] = true;
        s.count += 1;
        emit SplitCreated(split, HookrRevenueConfig.id(tag, recipients), tag, msg.sender);
    }

    /// @notice Reverts unless the protocol's share of the LP Rewards slice (`lpBps`) and of the Auto Burn slice
    ///         (`burnBps`) at `protocolShareBps` is a whole number of basis points, and the royalty, `royaltyBps` of the
    ///         LP Rewards slice net of that share, a whole and non-zero number of pips of each buy. Launch tooling may
    ///         call it before committing a split as `royaltyTo`; it is a stricter tooling check, not a safety
    ///         requirement, and it does not repeat the Rules' bind bounds.
    /// @dev HookrRules takes the protocol share of each slice in pips of the gross spend, rounded up
    ///      (`ceil(bps * protocolShareBps / 100)`), so the protocol is never paid less than its configured share and
    ///      at most one pip more per slice. Terms this accepts (both `bps * protocolShareBps` divide by 10,000) are
    ///      paid exactly the configured share in whole bps, the same under any rounding of the share; terms it
    ///      refuses, such as lpBps 4 at the 2,000 floor, bind and pay at least the share. A zero Auto Burn slice is
    ///      accepted. The Rules take the royalty in whole pips, rounded down (`lpNet * royaltyBps / 10,000`, `lpNet`
    ///      the net slice in pips), and the rest stays in the LP Rewards: a split is paid exactly its configured
    ///      royalty only when that divides, and nothing at all below one pip. This accepts only royalties that divide
    ///      and pay something, so it refuses royaltyBps 20 on lpBps 5 (400 pips net at the 2,000 floor: 0.8 pip, paid
    ///      0), `MIN_ROYALTY_BPS` on lpBps 100 (8,000 pips net: 0.8 pip, paid 0), and any royalty without LP Rewards.
    ///      The check is per slice. A royalty needs LP Rewards, so a pool that pays one earns Hookr its LP Rewards
    ///      share at any nonzero protocol share and binds no Hookr minimum: on terms this accepts the share is
    ///      Hookr's whole take. Only a Hookr token's pool without arb recapture at a zero share (Rules and treasury
    ///      floors both zero, not the release's) binds the minimum beside a royalty; it tops up Hookr's part alone
    ///      and leaves the royalty unchanged. The inputs are RulesConfig values; a `protocolShareBps` above 10,000
    ///      can revert with an arithmetic panic.
    function checkRoyaltyTerms(uint256 lpBps, uint256 burnBps, uint256 protocolShareBps, uint256 royaltyBps)
        external
        pure
    {
        if (lpBps * protocolShareBps % TOTAL_BPS != 0 || burnBps * protocolShareBps % TOTAL_BPS != 0) {
            revert ProtocolShareRoundsDown(lpBps, burnBps, protocolShareBps);
        }
        // The net LP Rewards slice in pips, as HookrRules `_buyParts` computes it.
        uint256 lpNetPips = lpBps * 100 - (lpBps * protocolShareBps + 99) / 100;
        if (lpNetPips * royaltyBps == 0 || lpNetPips * royaltyBps % TOTAL_BPS != 0) {
            revert RoyaltyRoundsDown(lpBps, protocolShareBps, royaltyBps);
        }
    }

    /// @notice The payee list launch tooling proposes before the creator edits it: `creator` alone, as CREATOR, at
    ///         DEFAULT_RECIPIENT_BPS. Not enforced; any list within the bounds above is accepted.
    function defaultRecipients(address creator) external pure returns (HookrRevenueTypes.Recipient[] memory list) {
        list = new HookrRevenueTypes.Recipient[](HookrRevenueTypes.DEFAULT_RECIPIENTS);
        list[0] = HookrRevenueTypes.Recipient(
            creator, HookrRevenueTypes.DEFAULT_RECIPIENT_BPS, HookrRevenueTypes.Role.CREATOR
        );
    }

    /// @notice Every currency in which a Hookr 1 pool's royalty or claims can reach a split, for
    ///         `HookrRevenueSplit.collectMany` and `claimMany`: the pool's two currencies (the royalty is paid in the
    ///         quote), then each member of `registry`'s recapture settlement set that is not one of them (native ETH,
    ///         WETH and USDG at genesis; an arb recapture's protocol share and the liquidity owner's accrual are paid
    ///         in the currency the executor pushed), then each currency the pool's recapture accrual in `rules` has
    ///         held that is not yet listed (a member since removed from the set). No duplicates, at most
    ///         MAX_PAYOUT_CURRENCIES.
    /// @dev A view for tooling and keepers; nothing on-chain depends on it and a split accepts any currency. The
    ///      registry and Rules are the caller's to choose: pass the release's. An address without code, or a read that
    ///      reverts, adds nothing, so the list is never shorter than the pool's two currencies. A contract that
    ///      answers with malformed data makes this view revert.
    function payoutCurrencies(address registry, address rules, PoolKey calldata key)
        external
        view
        returns (Currency[] memory list)
    {
        list = new Currency[](MAX_PAYOUT_CURRENCIES);
        list[0] = key.currency0;
        list[1] = key.currency1;
        uint256 n = 2;
        if (registry.code.length != 0) {
            try IHookrLanes(registry).settlementCurrencies() returns (address[] memory set) {
                for (uint256 i; i < set.length; ++i) {
                    n = _append(list, n, Currency.wrap(set[i]));
                }
            } catch {}
        }
        if (rules.code.length != 0) {
            try IHookrRecaptureRules(rules).poolAccruedCurrencies(key.toId()) returns (Currency[] memory held) {
                for (uint256 i; i < held.length; ++i) {
                    n = _append(list, n, held[i]);
                }
            } catch {}
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }

    /// @notice True when `account` is a split this router deployed. A UI should require this before showing a
    ///         pool's royalty recipient as a revenue split.
    function isSplit(address account) external view returns (bool) {
        return _state().isSplit[account];
    }

    /// @notice Number of splits this router has deployed.
    function splitCount() external view returns (uint256) {
        return _state().count;
    }

    /// @dev Appends `c` to the first `n` entries of `list` unless it is already there or the list is full.
    function _append(Currency[] memory list, uint256 n, Currency c) private pure returns (uint256) {
        if (n == list.length) return n;
        for (uint256 i; i < n; ++i) {
            if (list[i] == c) return n;
        }
        list[n] = c;
        return n + 1;
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }
}
