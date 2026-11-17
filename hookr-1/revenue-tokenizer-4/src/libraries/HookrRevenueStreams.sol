// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrLaunchFee} from "hookr/interfaces/IHookrLaunchFee.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrDropHost} from "../interfaces/IHookrDropHost.sol";
import {IHookrRevenueDoor} from "../interfaces/IHookrRevenueDoor.sol";
import {IHookrFamilyForwarder} from "../interfaces/IHookrFamilyForwarder.sol";
import {IHookrFeebAdapter} from "../interfaces/IHookrFeebAdapter.sol";
import {IHookrFeebAdapterFactory} from "../interfaces/IHookrFeebAdapterFactory.sol";
import {IHookrPositionNftDoor} from "../interfaces/IHookrPositionNftDoor.sol";
import {IHookrRevenueTokenDoor} from "../interfaces/IHookrRevenueTokenDoor.sol";
import {IHookrRevenueTokenDoorFactory} from "../interfaces/IHookrRevenueTokenDoorFactory.sol";
import {EndKind} from "../types/EndKind.sol";
import {HookrForward} from "./HookrForward.sol";
import {HookrRevenueTokenizerStorage} from "./HookrRevenueTokenizerStorage.sol";
import {HookrRevenueTokenDeployer} from "./HookrRevenueTokenDeployer.sol";
import {HookrRevenueStreamEnds} from "./HookrRevenueStreamEnds.sol";
import {HookrRevenueMarketOpener} from "./HookrRevenueMarketOpener.sol";
import {HookrRevenueDoorDeployer} from "./HookrRevenueDoorDeployer.sol";

/// @title Hookr revenue streams
/// @notice `tokenize` and `addStreams` of the tokenizer in full: the terms, the token, every stream kind locked and its
///         door added through one path for both, the market, the mint, the listing and the refunds.
/// @dev By delegatecall with the tokenizer's calldata as it arrived, so the library acts as the tokenizer: `msg.sender`
///      is the caller, `msg.value` the caller's ETH, `address(this)` the tokenizer. It reads the pins and writes the
///      records at the tokenizer's storage slot (HookrRevenueTokenizerStorage).
///
///      Every stream follows one order: the right is locked in its door first, then the door is added to the token,
///      then the stream is recorded. The mint (`initialize`) comes after the streams of `tokenize`, so no share
///      exists before them; the market opens after the mint, because its seed is minted to the tokenizer.
library HookrRevenueStreams {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_ASSETS = 8;
    uint256 internal constant MAX_MEMBERS = 8;
    uint256 internal constant MAX_SUPPLY = type(uint128).max;
    uint16 internal constant MAX_TIP_BPS = 100;
    uint16 internal constant MAX_BRIDGE_BPS = 2_000;
    uint32 internal constant MAX_STREAM_SECONDS = 14 days;
    uint64 internal constant MIN_TERM_BLOCKS = 50_400;
    uint64 internal constant MIN_TERM_SECONDS = 7 days;
    uint64 internal constant FOREVER = type(uint64).max;
    uint16 internal constant LEG_HOOKR = 0;
    uint16 internal constant LEG_OUTSIDE = 500;
    /// @dev A RULES door's stipend: each `claimable` read and each `claim` gets it.
    uint32 internal constant RULES_DOOR_GAS = 250_000;
    /// @dev The most assets a revenue token may list and still be a currency the tokenizer lists or quotes: one,
    ///      native ETH. A Rules `claim` of a revenue token moves it out of the PoolManager, which releases its streams
    ///      and settles the receiver in every one of its assets. Measured cold on the real HookrRules while each of
    ///      its assets has its first income streaming, into a receiver that never held it: 196,791 at one asset
    ///      (202,611 into one that held it while the income landed), 278,275 at two, 441,244 at four and 767,910 at
    ///      eight. RULES_DOOR_GAS fits only the first, and a failed claim leaves the receiver as it was, so it would
    ///      fail on every sync. Raising the stipend instead would multiply every RULES door's figure in the sync plan.
    uint256 internal constant MAX_CURRENCY_ASSETS = 1;
    /// @dev The cap on each read `_fits` makes.
    uint256 internal constant READ_GAS = 50_000;
    Currency internal constant NATIVE = Currency.wrap(address(0));

    /// @dev One call's working state.
    /// @param token The revenue token.
    /// @param forwarder The token's forwarder, or zero until a family is locked.
    /// @param lister Whether the call may list currencies: the creator in `tokenize`, the stream manager in
    ///        `addStreams`.
    /// @param needed The native value the call needs: launch budgets and fees.
    /// @param fee The launch fee, read once.
    /// @param feeRead Whether `fee` has been read.
    /// @param touched Currencies the tokenizer may hold mid-call, returned to the caller at the end.
    /// @param touchedCount How many entries of `touched` are in use.
    /// @param brought Currencies the streams bring, which `listAssets` lists.
    /// @param broughtCount How many entries of `brought` are in use.
    struct Build {
        address token;
        address forwarder;
        bool lister;
        uint256 needed;
        uint256 fee;
        bool feeRead;
        Currency[] touched;
        uint256 touchedCount;
        Currency[] brought;
        uint256 broughtCount;
    }

    /// @notice IHookrRevenueTokenizer.tokenize, run as the tokenizer.
    function tokenize(
        IHookrRevenueTokenizer.TokenTerms calldata t,
        IHookrRevenueTokenizer.StreamParams calldata s,
        IHookrRevenueTokenizer.MarketTerms calldata m
    ) external returns (address token) {
        HookrRevenueTokenizerStorage.Layout storage l = HookrRevenueTokenizerStorage.getLayout();
        if (!_hasStream(s)) revert IHookrRevenueTokenizer.NothingToAdd();
        _checkTerms(l, t, m);
        if (l.termsUsed[msg.sender][t.termsHash]) {
            revert IHookrRevenueTokenizer.TermsHashUsed(msg.sender, t.termsHash);
        }
        l.termsUsed[msg.sender][t.termsHash] = true;
        HookrRevenueTokenizerStorage.Pins storage p = l.pins;
        token = HookrRevenueTokenDeployer.deploy(
            HookrRevenueTokenDeployer.initCode(
                p.tokenCode0, p.tokenCode1, address(this), p.collector, t, p.poolManager
            ),
            HookrRevenueTokenDeployer.salt(msg.sender, t.termsHash)
        );
        l.tokenizations[token] = IHookrRevenueTokenizer.Tokenization(msg.sender, address(0), 0, uint64(block.timestamp));
        l.tokens.push(token);
        Build memory b = _begin(token, address(0));
        b.lister = true;
        // A market quoted in an ERC-20 lists its quote first, so the streams' listing cannot take its slot.
        if (m.open && !m.quote.isAddressZero() && !IHookrRevenueToken(token).isAsset(m.quote)) {
            IHookrRevenueToken(token).addAsset(m.quote);
        }
        _add(l, b, s);
        if (m.open) _market(l, b, t, m, s.unlockBlock);
        else _mint(t, token, 0, address(0), 0);
        _finish(b);
        emit IHookrRevenueTokenizer.Tokenized(token, msg.sender, t.supply, t.streamManager, t.openStreams);
    }

    /// @notice IHookrRevenueTokenizer.addStreams, run as the tokenizer.
    function addStreams(address token, IHookrRevenueTokenizer.StreamParams calldata s)
        external
        returns (uint256 first)
    {
        HookrRevenueTokenizerStorage.Layout storage l = HookrRevenueTokenizerStorage.getLayout();
        address forwarder = l.tokenizations[token].forwarder;
        if (l.tokenizations[token].creator == address(0)) revert IHookrRevenueTokenizer.UnknownToken(token);
        if (!_hasStream(s)) revert IHookrRevenueTokenizer.NothingToAdd();
        IHookrRevenueToken tk = IHookrRevenueToken(token);
        bool manager = msg.sender == tk.streamManager();
        if (!manager && (!tk.openStreams() || s.sources.length != 0 || s.listAssets)) {
            revert IHookrRevenueTokenizer.NotStreamManager(msg.sender);
        }
        Build memory b = _begin(token, forwarder);
        b.lister = manager;
        first = l.streams[token].length;
        _add(l, b, s);
        _finish(b);
    }

    /// @dev The token terms and, when it opens, the market's: the supply, the release period (zero for immediate),
    ///      the tip, the terms hash, the listed assets (ERC-20s with code, distinct, eight with ETH at most, and room
    ///      for an ERC-20 quote; a revenue token among them, or as the quote, lists at most MAX_CURRENCY_ASSETS), the
    ///      recipients (who take exactly the supply less the seed), the market's Rules, seed and bridge.
    function _checkTerms(
        HookrRevenueTokenizerStorage.Layout storage l,
        IHookrRevenueTokenizer.TokenTerms calldata t,
        IHookrRevenueTokenizer.MarketTerms calldata m
    ) private view {
        if (
            t.supply == 0 || t.supply > MAX_SUPPLY || t.streamSeconds > MAX_STREAM_SECONDS || t.tipBps > MAX_TIP_BPS
                || t.termsHash == bytes32(0) || t.assets.length >= MAX_ASSETS
        ) revert IHookrRevenueTokenizer.InvalidTerms();
        bool quoteListed = !m.open || m.quote.isAddressZero();
        for (uint256 i; i < t.assets.length; ++i) {
            Currency c = t.assets[i];
            if (c.isAddressZero() || Currency.unwrap(c).code.length == 0 || !_fits(c)) {
                revert IHookrRevenueTokenizer.InvalidTerms();
            }
            for (uint256 j; j < i; ++j) {
                if (t.assets[j] == c) revert IHookrRevenueTokenizer.InvalidTerms();
            }
            if (c == m.quote) quoteListed = true;
        }
        uint256 n = t.recipients.length;
        if (n == 0 || n != t.amounts.length) revert IHookrRevenueTokenizer.InvalidTerms();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address r = t.recipients[i];
            if (r == address(0) || r == address(this) || r == l.pins.collector || t.amounts[i] == 0) {
                revert IHookrRevenueTokenizer.InvalidTerms();
            }
            sum += t.amounts[i];
        }
        uint256 seed;
        if (m.open) {
            if (!_admitted(m.config.rules)) revert IHookrRevenueTokenizer.RulesNotAdmitted(m.config.rules);
            if (
                m.seed == 0 || (!quoteListed && t.assets.length + 2 > MAX_ASSETS)
                    || (!m.quote.isAddressZero() && Currency.unwrap(m.quote).code.length == 0) || !_fits(m.quote)
                    || (m.bridgeBps != 0
                        && (l.pins.bridgeFactory == address(0)
                            || m.bridgeBps > MAX_BRIDGE_BPS
                            || !m.quote.isAddressZero()))
            ) revert IHookrRevenueTokenizer.InvalidMarket();
            seed = m.seed;
        }
        uint256 expected = t.supply > seed ? t.supply - seed : 0;
        if (expected == 0 || sum != expected) revert IHookrRevenueTokenizer.MintMismatch(sum, expected);
    }

    /// @dev A family term: forever, or at least `MIN_TERM_BLOCKS` parent blocks ahead.
    function _checkBlocks(uint64 unlockBlock) private view {
        uint64 minimum = uint64(block.number) + MIN_TERM_BLOCKS;
        if (unlockBlock != FOREVER && unlockBlock < minimum) {
            revert IHookrRevenueTokenizer.TermTooShort(unlockBlock, minimum);
        }
    }

    /// @dev A door term: forever, or at least `MIN_TERM_SECONDS` ahead.
    function _checkSeconds(uint64 unlockAt) private view {
        uint64 minimum = uint64(block.timestamp) + MIN_TERM_SECONDS;
        if (unlockAt != FOREVER && unlockAt < minimum) revert IHookrRevenueTokenizer.TermTooShort(unlockAt, minimum);
    }

    /// @dev Whether `rules` may be used now, as the tokenizer itself answers it: a live RULES admission on the root
    ///      (IHookrRevenueTokenizer.isAdmittedRules). Asked of the tokenizer, this library's `address(this)`, so the
    ///      rule is written once.
    function _admitted(address rules) private view returns (bool) {
        return IHookrRevenueTokenizer(address(this)).isAdmittedRules(rules);
    }

    function _hasStream(IHookrRevenueTokenizer.StreamParams calldata s) private pure returns (bool) {
        return s.launchParams.length != 0 || s.families.length != 0 || s.rules.length != 0 || s.feebs.length != 0
            || s.positionIds.length != 0 || s.v3PositionIds.length != 0 || s.revenueTokens.length != 0
            || s.sources.length != 0;
    }

    /// @dev Every stream in `s`, kind by kind, each locked, added and recorded; then the listing when asked.
    function _add(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        IHookrRevenueTokenizer.StreamParams calldata s
    ) private {
        if (s.launchParams.length != 0) _launch(l, b, s.launchParams, s.unlockBlock);
        for (uint256 i; i < s.families.length; ++i) {
            _family(l, b, s.families[i], s.unlockBlock);
        }
        for (uint256 i; i < s.rules.length; ++i) {
            address r = s.rules[i];
            if (!_admitted(r)) revert IHookrRevenueTokenizer.RulesNotAdmitted(r);
            _rules(l, b, r);
        }
        for (uint256 i; i < s.feebs.length; ++i) {
            _feeb(l, b, s.feebs[i], s.unlockAt);
        }
        if (s.positionIds.length != 0) _positions(l, b, s.positionIds, s.positionPermits, s.unlockAt);
        if (s.v3PositionIds.length != 0) _positionsV3(l, b, s.v3PositionIds, s.v3Permits, s.unlockAt);
        for (uint256 i; i < s.revenueTokens.length; ++i) {
            _revenueToken(l, b, s.revenueTokens[i], s.unlockAt);
        }
        for (uint256 i; i < s.sources.length; ++i) {
            _source(l, b, s.sources[i]);
        }
        if (s.listAssets) _list(b);
    }

    /// @dev A new Hookr launch for the token: 1 to `MAX_MEMBERS` members with one advisory config each, admitted
    ///      Rules, every royalty paid to the token (or none), every Hook Block checked; funded, launched, locked in the
    ///      forwarder as a FAMILY, then one RULES door per distinct Rules the token does not have yet.
    function _launch(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        bytes calldata raw,
        uint64 unlockBlock
    ) private {
        _checkBlocks(unlockBlock);
        IHookrLauncher.LaunchParams calldata lp = _launchParams(raw);
        uint256 n = lp.members.length;
        if (n == 0 || n > MAX_MEMBERS || lp.advisoryConfigs.length != n) revert IHookrRevenueTokenizer.InvalidTerms();
        if (lp.root != l.pins.root) revert IHookrRevenueTokenizer.InvalidTerms();
        address launcher = l.pins.launcher;
        address subject = lp.token.existing;
        if (subject == address(0)) {
            // Every launch here has the tokenizer as the launcher's creator, so the launcher's per-creator salt
            // namespace is shared by every caller: the salt is bound to the caller instead, and a subject address
            // someone else took is refused before the launcher's creation would burn the call's gas.
            if (bytes20(lp.token.salt) != bytes20(msg.sender)) {
                revert IHookrRevenueTokenizer.LaunchSaltNotCaller(lp.token.salt);
            }
            subject = IHookrLauncher(launcher).predictToken(address(this), lp.token);
            if (subject.code.length != 0) revert IHookrRevenueTokenizer.SubjectTaken(subject);
        }
        for (uint256 i; i < n; ++i) {
            IHookrLauncher.Member calldata member = lp.members[i];
            address r = member.config.rules;
            if (!_admitted(r)) revert IHookrRevenueTokenizer.RulesNotAdmitted(r);
            if (member.rules.royaltyTo != (member.rules.royaltyBps != 0 ? b.token : address(0))) {
                revert IHookrRevenueTokenizer.InvalidTerms();
            }
            // The royalty and a Hook Block take naming the token are Rules credit in the member's quote, which the
            // RULES door claims only in a listed currency: a member with either has its quote listed now.
            if (member.rules.royaltyBps != 0 || member.config.advisory != address(0)) _listQuote(b, member.quote);
            if (member.config.advisory != address(0)) {
                HookrRevenueDoorDeployer.checkAdvisory(
                    launcher, l.pins.root, member.config.advisory, lp.advisoryConfigs[i], b.token, i
                );
            }
        }
        (bytes32 familyId, address launched, uint256 value, Currency[] memory cs) =
            HookrRevenueMarketOpener.launch(launcher, raw[uint256(bytes32(raw[0:32])):], subject, _fee(l, b));
        if (launched != subject) revert IHookrRevenueTokenizer.InvalidConfig();
        b.needed += value;
        for (uint256 i; i < cs.length; ++i) {
            _touch(b, cs[i]);
            _bring(b, cs[i]);
        }
        _lockFamily(l, b, familyId, unlockBlock, false);
        for (uint256 i; i < n; ++i) {
            _rules(l, b, lp.members[i].config.rules);
        }
    }

    /// @dev An existing family its owner, the caller, made this tokenizer the pending owner of, every pool on the
    ///      pinned root: accepted (its fees so far go to the caller, as the launcher pays a previous owner), each
    ///      member's arb recapture accrual so far moved to the caller's claims in its Rules (it would otherwise follow
    ///      the family to the forwarder; a member whose Rules answers nothing is skipped), then locked in the forwarder
    ///      as a FAMILY.
    function _family(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        bytes32 familyId,
        uint64 unlockBlock
    ) private {
        _checkBlocks(unlockBlock);
        IHookrLauncher launcher = IHookrLauncher(l.pins.launcher);
        (address pending,) = launcher.pendingFamilyOwner(familyId);
        if (pending != address(this) || launcher.familyOwner(familyId) != msg.sender) {
            revert IHookrRevenueTokenizer.FamilyNotHanded(familyId);
        }
        uint8 n = launcher.memberCount(familyId);
        address root = l.pins.root;
        for (uint8 i; i < n; ++i) {
            PoolKey memory key = launcher.position(familyId, i).key;
            if (address(key.hooks) != root) revert IHookrRevenueTokenizer.FamilyOffRoot(familyId);
            _touch(b, key.currency0);
            _touch(b, key.currency1);
            _bring(b, key.currency0);
            _bring(b, key.currency1);
        }
        launcher.acceptFamily(familyId);
        for (uint8 i; i < n; ++i) {
            try launcher.claimRecapture(familyId, i, msg.sender) {} catch {}
        }
        _lockFamily(l, b, familyId, unlockBlock, false);
    }

    /// @dev Hands `familyId`, which the tokenizer owns, to the lock for the forwarder until `unlockBlock`, registers it
    ///      there returning to the caller, adds the forwarder as a door on the first family, and records the stream.
    ///      The lock's acceptance pays the tokenizer the fees the family earned so far; they go back with the refunds.
    function _lockFamily(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        bytes32 familyId,
        uint64 unlockBlock,
        bool market
    ) private {
        address lock = l.pins.lock;
        bool first = b.forwarder == address(0);
        if (first) {
            b.forwarder = HookrRevenueDoorDeployer.deployForwarder(b.token, lock);
            l.tokenizations[b.token].forwarder = b.forwarder;
        }
        IHookrLauncher(l.pins.launcher).transferFamily(familyId, lock, 0);
        IHookrFamilyLock(lock).lock(familyId, b.forwarder, unlockBlock);
        uint256 index = IHookrFamilyForwarder(b.forwarder).register(familyId, msg.sender, market);
        if (first) {
            _door(
                b,
                IHookrRevenueToken.DoorKind.FORWARDER,
                b.forwarder,
                IHookrFamilyForwarder(b.forwarder).PULL_GAS(),
                LEG_HOOKR
            );
        }
        _record(
            l,
            b,
            market ? IHookrRevenueTokenizer.StreamKind.MARKET : IHookrRevenueTokenizer.StreamKind.FAMILY,
            b.forwarder,
            familyId,
            LEG_HOOKR,
            index
        );
    }

    /// @dev An admitted Rules ledger as a RULES door, unless the token has it already.
    function _rules(HookrRevenueTokenizerStorage.Layout storage l, Build memory b, address rules) private {
        if (IHookrRevenueToken(b.token).isDoor(rules)) return;
        _door(b, IHookrRevenueToken.DoorKind.RULES, rules, RULES_DOOR_GAS, LEG_HOOKR);
        _record(l, b, IHookrRevenueTokenizer.StreamKind.RULES, rules, bytes32(0), LEG_HOOKR, 0);
    }

    /// @dev A pools.trade FEEB NFT in its own adapter: an admitted vault, the term, the factory's `createFor` for the
    ///      caller (who approved the factory), the adapter checked to be the factory's and the token's.
    function _feeb(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        IHookrRevenueTokenizer.FeebSource calldata f,
        uint64 unlockAt
    ) private {
        if (!l.admittedVaults[f.vault]) revert IHookrRevenueTokenizer.VaultNotAdmitted(f.vault);
        _checkSeconds(unlockAt);
        IHookrFeebAdapterFactory factory = IHookrFeebAdapterFactory(l.pins.feebAdapterFactory);
        address adapter = factory.createFor(msg.sender, b.token, f.vault, f.tokenId, unlockAt, _salt(b));
        if (!factory.isAdapter(adapter) || IHookrRevenueDoor(adapter).revenueToken() != b.token) {
            revert IHookrRevenueTokenizer.DoorMismatch(adapter);
        }
        _door(b, IHookrRevenueToken.DoorKind.FEEB, adapter, IHookrFeebAdapter(adapter).PULL_GAS(), LEG_OUTSIDE);
        _record(l, b, IHookrRevenueTokenizer.StreamKind.FEEB, adapter, bytes32(f.tokenId), LEG_OUTSIDE, 0);
    }

    /// @dev The caller's v4 positions, sorted into the root's and the rest by HookrRevenueDoorDeployer.positionDoors,
    ///      which applies the permits and creates one door per non-empty set: the root's with no leg, the rest with the
    ///      outside leg.
    function _positions(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        uint256[] calldata ids,
        IHookrRevenueTokenizer.PositionPermit[] calldata permits,
        uint64 unlockAt
    ) private {
        _checkSeconds(unlockAt);
        HookrRevenueTokenizerStorage.Pins storage p = l.pins;
        (address onRoot, address offRoot, Currency[] memory cs) = HookrRevenueDoorDeployer.positionDoors(
            p.positionManager, p.root, p.positionDoorFactory, b.token, ids, permits, unlockAt
        );
        for (uint256 i; i < cs.length; ++i) {
            _bring(b, cs[i]);
        }
        if (onRoot != address(0)) _positionDoor(l, b, IHookrRevenueToken.DoorKind.POSITIONS, onRoot, LEG_HOOKR);
        if (offRoot != address(0)) _positionDoor(l, b, IHookrRevenueToken.DoorKind.POSITIONS, offRoot, LEG_OUTSIDE);
    }

    /// @dev The caller's v3 positions in one door with the outside leg (HookrRevenueDoorDeployer.v3Door).
    function _positionsV3(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        uint256[] calldata ids,
        IHookrRevenueTokenizer.V3PositionPermit[] calldata permits,
        uint64 unlockAt
    ) private {
        _checkSeconds(unlockAt);
        HookrRevenueTokenizerStorage.Pins storage p = l.pins;
        (address door, Currency[] memory cs) = HookrRevenueDoorDeployer.v3Door(
            p.positionManagerV3, p.v3PositionDoorFactory, b.token, ids, permits, unlockAt
        );
        for (uint256 i; i < cs.length; ++i) {
            _bring(b, cs[i]);
        }
        _positionDoor(l, b, IHookrRevenueToken.DoorKind.POSITIONS_V3, door, LEG_OUTSIDE);
    }

    /// @dev Adds and records a position door with its own `pullGas` as the stipend.
    function _positionDoor(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        IHookrRevenueToken.DoorKind kind,
        address door,
        uint16 leg
    ) private {
        _door(b, kind, door, IHookrPositionNftDoor(door).pullGas(), leg);
        _record(
            l,
            b,
            kind == IHookrRevenueToken.DoorKind.POSITIONS
                ? IHookrRevenueTokenizer.StreamKind.POSITIONS
                : IHookrRevenueTokenizer.StreamKind.POSITIONS_V3,
            door,
            bytes32(0),
            leg,
            0
        );
    }

    /// @dev Shares of another revenue token from this tokenizer in a door that claims their income into this one:
    ///      the door is created returning to the caller, then the tokenizer moves the shares from the caller (who
    ///      approved the tokenizer on the inner token) into it.
    function _revenueToken(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        IHookrRevenueTokenizer.RevenueTokenShares calldata r,
        uint64 unlockAt
    ) private {
        address inner = r.token;
        if (inner == b.token || l.tokenizations[inner].creator == address(0)) {
            revert IHookrRevenueTokenizer.InvalidInnerToken(inner);
        }
        if (r.amount == 0) revert IHookrRevenueTokenizer.InvalidTerms();
        _checkSeconds(unlockAt);
        IHookrRevenueTokenDoorFactory factory = IHookrRevenueTokenDoorFactory(l.pins.revenueTokenDoorFactory);
        address door = factory.createFor(msg.sender, b.token, inner, unlockAt, _salt(b));
        if (!factory.isDoor(door) || IHookrRevenueDoor(door).revenueToken() != b.token) {
            revert IHookrRevenueTokenizer.DoorMismatch(door);
        }
        IERC20(inner).safeTransferFrom(msg.sender, door, r.amount);
        IHookrRevenueToken it = IHookrRevenueToken(inner);
        uint256 n = it.assetCount();
        for (uint256 i; i < n; ++i) {
            _bring(b, it.assetAt(i).currency);
        }
        _door(b, IHookrRevenueToken.DoorKind.REVENUE_TOKEN, door, IHookrRevenueTokenDoor(door).PULL_GAS(), LEG_HOOKR);
        _record(
            l, b, IHookrRevenueTokenizer.StreamKind.REVENUE_TOKEN, door, bytes32(uint256(uint160(inner))), LEG_HOOKR, 0
        );
    }

    /// @dev An `IHookrRevenueSource` with the outside leg, checked by HookrRevenueDoorDeployer.checkSource, unless
    ///      the token has it as a door already (`InvalidSource`).
    function _source(HookrRevenueTokenizerStorage.Layout storage l, Build memory b, address s) private {
        if (IHookrRevenueToken(b.token).isDoor(s)) revert IHookrRevenueTokenizer.InvalidSource(s);
        (uint32 stipend, bytes32 id, Currency[] memory cs) = HookrRevenueDoorDeployer.checkSource(b.token, s);
        for (uint256 i; i < cs.length; ++i) {
            _bring(b, cs[i]);
        }
        _door(b, IHookrRevenueToken.DoorKind.SOURCE, s, stipend, LEG_OUTSIDE);
        _record(l, b, IHookrRevenueTokenizer.StreamKind.SOURCE, s, id, LEG_OUTSIDE, 0);
    }

    /// @dev Lists every currency the streams brought that the token does not list yet, while there is room: an ERC-20
    ///      with code that is not the token itself, nor a revenue token listing more than MAX_CURRENCY_ASSETS (left
    ///      unlisted, so the doors deliver it into the box).
    function _list(Build memory b) private {
        IHookrRevenueToken tk = IHookrRevenueToken(b.token);
        for (uint256 i; i < b.broughtCount; ++i) {
            Currency c = b.brought[i];
            address erc20 = Currency.unwrap(c);
            if (erc20 == address(0) || erc20 == b.token || erc20.code.length == 0 || tk.isAsset(c) || !_fits(c)) {
                continue;
            }
            if (tk.assetCount() >= MAX_ASSETS) return;
            tk.addAsset(c);
        }
    }

    /// @dev Lists `quote`, a launch member's quote that carries the token's Rules credit, unless it is native ETH or
    ///      listed already. Only a call that may list adds it (`NotStreamManager` for an outsider on an open token,
    ///      who launches on ETH or a listed currency instead); a full list is the token's `TooManyAssets`. A revenue
    ///      token listing more than MAX_CURRENCY_ASSETS is refused (`InvalidTerms`), listed or not: the RULES door
    ///      could never claim the credit in it.
    function _listQuote(Build memory b, Currency quote) private {
        IHookrRevenueToken tk = IHookrRevenueToken(b.token);
        if (!_fits(quote)) revert IHookrRevenueTokenizer.InvalidTerms();
        if (quote.isAddressZero() || tk.isAsset(quote)) return;
        if (!b.lister) revert IHookrRevenueTokenizer.NotStreamManager(msg.sender);
        tk.addAsset(quote);
    }

    /// @dev Whether `c` may be a currency the tokenizer lists or quotes: native ETH, an ERC-20 that is not a revenue
    ///      token (it answers neither `tokenizer()` nor `dropBox()` in one word), or a revenue token that lists at most
    ///      MAX_CURRENCY_ASSETS assets. A revenue token whose asset count cannot be read does not fit.
    function _fits(Currency c) private view returns (bool) {
        address a = Currency.unwrap(c);
        if (a == address(0)) return true;
        (bool hasTokenizer,) = HookrForward.read(a, abi.encodeCall(IHookrRevenueToken.tokenizer, ()), READ_GAS);
        (bool hasBox,) = HookrForward.read(a, abi.encodeCall(IHookrDropHost.dropBox, ()), READ_GAS);
        if (!hasTokenizer && !hasBox) return true;
        (bool read, uint256 n) = HookrForward.read(a, abi.encodeCall(IHookrRevenueToken.assetCount, ()), READ_GAS);
        return read && n <= MAX_CURRENCY_ASSETS;
    }

    /// @dev The market: its Fee Bridge first when asked (the mint records it), the mint with the seed to the tokenizer,
    ///      the launch, the family locked in the forwarder as the MARKET, and its Rules as a door.
    function _market(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        IHookrRevenueTokenizer.TokenTerms calldata t,
        IHookrRevenueTokenizer.MarketTerms calldata m,
        uint64 unlockBlock
    ) private {
        _checkBlocks(unlockBlock);
        HookrRevenueTokenizerStorage.Pins storage p = l.pins;
        address bridge;
        if (m.bridgeBps != 0) {
            bridge = HookrRevenueMarketOpener.makeBridge(p.launcher, p.root, p.bridgeFactory, b.token, m);
        }
        _mint(t, b.token, m.seed, bridge, m.bridgeBps);
        uint256 fee = _fee(l, b);
        b.needed += fee;
        _touch(b, Currency.wrap(b.token));
        _touch(b, m.quote);
        (bytes32 familyId, PoolId poolId, uint256 placed) =
            HookrRevenueMarketOpener.open(p.launcher, p.root, b.token, fee, m);
        l.tokenizations[b.token].marketFamilyId = familyId;
        _lockFamily(l, b, familyId, unlockBlock, true);
        _rules(l, b, m.config.rules);
        emit IHookrRevenueTokenizer.MarketOpened(b.token, familyId, poolId, placed, bridge, m.bridgeBps);
    }

    /// @dev Mints the supply: the creator's recipients, and the seed to the tokenizer when a market opens.
    function _mint(
        IHookrRevenueTokenizer.TokenTerms calldata t,
        address token,
        uint256 seed,
        address bridge,
        uint16 bridgeBps
    ) private {
        uint256 n = t.recipients.length;
        uint256 total = seed != 0 ? n + 1 : n;
        address[] memory recipients = new address[](total);
        uint256[] memory amounts = new uint256[](total);
        for (uint256 i; i < n; ++i) {
            recipients[i] = t.recipients[i];
            amounts[i] = t.amounts[i];
        }
        if (seed != 0) {
            recipients[n] = address(this);
            amounts[n] = seed;
        }
        IHookrRevenueToken(token).initialize(IHookrRevenueToken.Mint(recipients, amounts, bridge, bridgeBps));
    }

    function _begin(address token, address forwarder) private pure returns (Build memory b) {
        b.token = token;
        b.forwarder = forwarder;
        b.touched = new Currency[](4);
        b.brought = new Currency[](4);
        _touch(b, NATIVE);
    }

    /// @dev Adds door `target` to the token, after its right was locked.
    function _door(Build memory b, IHookrRevenueToken.DoorKind kind, address target, uint32 stipend, uint16 legBps)
        private
    {
        IHookrRevenueToken(b.token).addDoor(IHookrRevenueToken.Door(kind, target, stipend, legBps));
    }

    /// @dev Appends a stream to the token's records and emits `StreamAdded` with its end as of now. `family` is a
    ///      family's index in the forwarder, zero for every other kind.
    function _record(
        HookrRevenueTokenizerStorage.Layout storage l,
        Build memory b,
        IHookrRevenueTokenizer.StreamKind kind,
        address door,
        bytes32 id,
        uint16 legBps,
        uint256 family
    ) private {
        HookrRevenueTokenizerStorage.Stream[] storage list = l.streams[b.token];
        uint256 index = list.length;
        list.push(HookrRevenueTokenizerStorage.Stream(kind, legBps, uint40(block.timestamp), door, uint32(family), id));
        (EndKind endKind, uint64 end) = HookrRevenueStreamEnds.ends(kind, door, family);
        emit IHookrRevenueTokenizer.StreamAdded(b.token, index, kind, door, id, legBps, endKind, end, msg.sender);
    }

    /// @dev A factory salt no other door of the token uses: the token and its door count.
    function _salt(Build memory b) private view returns (bytes32) {
        return keccak256(abi.encode(b.token, IHookrRevenueToken(b.token).doorCount()));
    }

    function _fee(HookrRevenueTokenizerStorage.Layout storage l, Build memory b) private view returns (uint256) {
        if (!b.feeRead) {
            (b.fee,,,,) = IHookrLaunchFee(l.pins.launcher).launchFee();
            b.feeRead = true;
        }
        return b.fee;
    }

    /// @dev Everything left here goes back to the caller (the launcher's refunds, dev-bought subject, a lock's
    ///      acceptance payout, unspent seed); `msg.value` must be what the call needed and no native balance may stay.
    function _finish(Build memory b) private {
        if (msg.value != b.needed) revert IHookrRevenueTokenizer.InvalidFunding();
        for (uint256 i; i < b.touchedCount; ++i) {
            Currency c = b.touched[i];
            uint256 held = HookrSettlement.balance(c, address(this));
            if (held != 0) HookrSettlement.send(c, msg.sender, held);
        }
        if (address(this).balance != 0) revert IHookrRevenueTokenizer.InvalidFunding();
    }

    function _touch(Build memory b, Currency c) private pure {
        (b.touched, b.touchedCount) = _push(b.touched, b.touchedCount, c);
    }

    function _bring(Build memory b, Currency c) private pure {
        (b.brought, b.broughtCount) = _push(b.brought, b.broughtCount, c);
    }

    /// @dev Appends `c` to `list[0..count)` unless it is there, growing the list when full.
    function _push(Currency[] memory list, uint256 count, Currency c)
        private
        pure
        returns (Currency[] memory, uint256)
    {
        for (uint256 i; i < count; ++i) {
            if (list[i] == c) return (list, count);
        }
        if (count == list.length) {
            Currency[] memory grown = new Currency[](count * 2);
            for (uint256 i; i < count; ++i) {
                grown[i] = list[i];
            }
            list = grown;
        }
        list[count] = c;
        return (list, count + 1);
    }

    /// @dev `raw` as a `LaunchParams` in calldata: `abi.encode(LaunchParams)` is one head word, the offset of the
    ///      struct's own encoding, then that encoding; the pointer is to the encoding, so every field reads from
    ///      calldata with no copy. A `raw` too short to hold the head is `InvalidTerms`; one that is not a
    ///      `LaunchParams` fails where the launcher decodes it.
    function _launchParams(bytes calldata raw) private pure returns (IHookrLauncher.LaunchParams calldata lp) {
        if (raw.length < 64) revert IHookrRevenueTokenizer.InvalidTerms();
        uint256 head = uint256(bytes32(raw[0:32]));
        if (head >= raw.length) revert IHookrRevenueTokenizer.InvalidTerms();
        assembly ("memory-safe") {
            lp := add(raw.offset, head)
        }
    }
}
