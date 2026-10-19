// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrLaunchFee} from "hookr/interfaces/IHookrLaunchFee.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueSource} from "../interfaces/IHookrRevenueSource.sol";
import {IHookrFamilyForwarder} from "../interfaces/IHookrFamilyForwarder.sol";
import {IHookrFeebAdapter} from "../interfaces/IHookrFeebAdapter.sol";
import {IHookrPositionNftDoor} from "../interfaces/IHookrPositionNftDoor.sol";
import {IHookrV3PositionNftDoor} from "../interfaces/IHookrV3PositionNftDoor.sol";
import {IHookrV3PositionNftDoorFactory} from "../interfaces/IHookrV3PositionNftDoorFactory.sol";
import {IPositionManagerDoor} from "../interfaces/IPositionManagerDoor.sol";
import {INonfungiblePositionManagerDoor} from "../interfaces/external/INonfungiblePositionManagerDoor.sol";
import {IBeneficiaryVault} from "../interfaces/external/IBeneficiaryVault.sol";
import {HookrRevenueTokenDeployer} from "./HookrRevenueTokenDeployer.sol";
import {HookrRevenueDoorDeployer} from "./HookrRevenueDoorDeployer.sol";
import {HookrRevenueMarketOpener} from "./HookrRevenueMarketOpener.sol";

/// @title Hookr revenue streams
/// @notice Way (5) of the tokenizer, `tokenizeStreams`, in full: the checks, the launch, the FEEB adapters, the v4
///         and v3 doors, the sources, the seal, the market and the refunds; plus `predictStreamToken` and
///         `streamsOf`. The tokenizer only dispatches: it forwards each call's calldata as it arrived (by
///         delegatecall for the tokenization, by staticcall for the views), so it decodes none of the stream terms
///         and the whole way costs it a few hundred bytes of runtime.
/// @dev By delegatecall, so the library acts as the tokenizer: `msg.sender` is the creator, `msg.value` the
///      creator's ETH, `address(this)` the tokenizer (the token's `tokenizer`, the forwarder's registrar, the door
///      factories' caller, the launch's owner). It reads the tokenizer's pins and admitted sets through the
///      tokenizer's own getters (`IHookrRevenueTokenizer(address(this))`), reaches the other libraries as the
///      tokenizer does (HookrRevenueTokenDeployer, HookrRevenueDoorDeployer, HookrRevenueMarketOpener; a library
///      called from a delegatecall is itself delegatecalled) and touches the tokenizer's storage only through the
///      two references `record` is handed. The views run under a staticcall, where `msg.sender` is the tokenizer
///      and `address(this)` this library: they read the pins through `msg.sender` and never through `address(this)`.
///      The bounds and stipends below are the tokenizer's own, copied (its are internal); the streams suite holds
///      the public ones together. `docs/multi-stream.md` has the order of operations and every check.
library HookrRevenueStreams {
    /// @notice The least gas stipend a source may declare for its pull (IHookrRevenueSource.pullGas): 100,000.
    uint32 internal constant MIN_SOURCE_GAS = 100_000;
    /// @notice The most gas stipend a source may declare for its pull: 3,000,000, what a v4 door of one position
    ///         gets; a sync must have each door's stipend to spare, so a source cannot ask for more.
    uint32 internal constant MAX_SOURCE_GAS = 3_000_000;
    /// @dev The tokenizer's bounds (HookrRevenueTokenizer): the token's asset and door counts, a family's members,
    ///      the bridge and tip caps, the release window, both minimum terms and the two legs.
    uint256 internal constant MAX_ASSETS = 4;
    uint256 internal constant MAX_DOORS = 8;
    uint256 internal constant MAX_MEMBERS = 8;
    uint256 internal constant MAX_POSITIONS = 64;
    uint16 internal constant MAX_BRIDGE_BPS = 2_000;
    uint16 internal constant MAX_TIP_BPS = 100;
    uint32 internal constant DEFAULT_STREAM_SECONDS = 7 days;
    uint32 internal constant MIN_STREAM_SECONDS = 1 days;
    uint32 internal constant MAX_STREAM_SECONDS = 14 days;
    uint64 internal constant MIN_TERM_BLOCKS = 50_400;
    uint64 internal constant MIN_TERM_SECONDS = 7 days;
    uint64 internal constant FOREVER = type(uint64).max;
    uint16 internal constant HOOKR_LEG_BPS_OUTSIDE = 500;
    uint16 internal constant HOOKR_LEG_BPS_HOOKR = 0;
    uint8 internal constant WAY_STREAMS = 5;
    /// @dev The token's sync budget (HookrIncomeSync): one reserve per door, and the most the stipends plus the
    ///      reserves may sum to, so a sync fits one transaction under Robinhood Chain's 32,000,000 cap.
    uint256 internal constant SYNC_RESERVE_GAS = 300_000;
    uint256 internal constant MAX_SYNC_GAS = 28_000_000;
    /// @dev Gas each read of a source's views gets, at the mint and in `streamsOf`: a Pons adapter's `ends` reads the
    ///      Pons factory twice in about 60,000; a source that burns more, or answers malformed data, fails only itself.
    uint256 internal constant SOURCE_VIEW_GAS = 200_000;
    /// @dev The door stipends the tokenizer seals in, the same figures for the same kinds.
    uint32 internal constant RULES_DOOR_GAS = 250_000;
    uint32 internal constant FORWARDER_DOOR_BASE_GAS = 200_000;
    uint32 internal constant FORWARDER_DOOR_MEMBER_GAS = 400_000;
    uint32 internal constant FEEB_DOOR_GAS = 300_000;
    uint32 internal constant POSITIONS_DOOR_BASE_GAS = 2_900_000;
    uint32 internal constant POSITIONS_DOOR_POSITION_GAS = 160_000;
    Currency internal constant NATIVE = Currency.wrap(address(0));

    /// @dev One tokenization's working state.
    struct Build {
        address creator;
        address token;
        address forwarder;
        address adapter;
        address door;
        address v3Door;
        bytes32 familyId;
        bytes32 marketFamilyId;
        uint64 unlockBlock;
        uint32 streamSeconds;
        uint16 legBps;
        uint256 leg;
        uint256 seed;
        uint256 fee;
        address bridge;
        uint16 bridgeBps;
        bool hasLaunch;
        bool forwarded;
        address subject;
        uint256 members;
        Currency[] assets;
        Currency[] currencies;
        address[] rulesList;
        uint256 rulesCount;
        IHookrRevenueToken.Door[] doors;
        uint256 doorCount;
        uint32[] sourceGas;
    }

    /// @notice IHookrRevenueTokenizer.tokenizeStreams, run as the tokenizer. The same parameters in the same order,
    ///         so the tokenizer forwards its calldata unchanged, and the return data `record` takes as is.
    /// @return token The revenue token.
    /// @return r The token's record, as the tokenizer stores it (`way` is `WAY_STREAMS`).
    /// @return supply The supply minted, for the `Tokenized` event.
    function tokenize(
        IHookrRevenueTokenizer.StreamParams calldata p,
        IHookrRevenueTokenizer.TokenTerms calldata t,
        IHookrRevenueTokenizer.LockTerms calldata l,
        IHookrRevenueTokenizer.MarketTerms calldata m
    ) external returns (address, IHookrRevenueTokenizer.Tokenization memory, uint256) {
        IHookrRevenueTokenizer tokenizer = IHookrRevenueTokenizer(address(this));
        Build memory b;
        b.creator = msg.sender;
        b.hasLaunch = p.launchParams.length != 0;
        if (
            !b.hasLaunch && p.feebs.length == 0 && p.positionIds.length == 0 && p.v3PositionIds.length == 0
                && p.sources.length == 0
        ) revert IHookrRevenueTokenizer.NothingToTokenize();

        // The terms, the market, the asset list, then the leg: nothing when every stream is on our hook.
        _checkTerms(tokenizer, t, m, b);
        bool allHookr = true;
        if (p.positionIds.length != 0) allHookr = _checkV4(tokenizer, p, t, b);
        bool outside = p.feebs.length != 0 || p.v3PositionIds.length != 0 || p.sources.length != 0 || !allHookr;
        b.legBps = outside ? HOOKR_LEG_BPS_OUTSIDE : HOOKR_LEG_BPS_HOOKR;
        b.leg = t.supply * b.legBps / 10_000;
        _checkMint(t, b);
        bool locksFamily = b.hasLaunch || m.open;
        if (locksFamily) _checkTerm(l.unlockBlock, uint64(block.number) + MIN_TERM_BLOCKS);
        b.unlockBlock = locksFamily ? l.unlockBlock : 0;
        if (p.positionIds.length != 0 || p.v3PositionIds.length != 0) {
            _checkTerm(p.unlockAt, uint64(block.timestamp) + MIN_TERM_SECONDS);
        }
        (b.fee,,,,) = IHookrLaunchFee(tokenizer.launcher()).launchFee();
        if (!b.hasLaunch && msg.value != (m.open ? b.fee : 0)) revert IHookrRevenueTokenizer.InvalidFunding();

        // The token's address, known before anything is made.
        HookrRevenueTokenDeployer.TokenArgs memory a = _tokenArgs(t, b.assets, b.streamSeconds);
        bytes32 salt = _salt(msg.sender, t.termsHash);
        b.token = HookrRevenueTokenDeployer.predict(a, salt, tokenizer.poolManager());

        // The sources, the launch's members (checked as ways 1 and 3 check them), the door count and the sync
        // budget, all before anything is spent.
        b.sourceGas = new uint32[](p.sources.length);
        for (uint256 i; i < p.sources.length; ++i) {
            b.sourceGas[i] = _checkSource(p.sources, i, b);
        }
        b.rulesList = new address[](MAX_MEMBERS + 1);
        if (b.hasLaunch) _checkLaunch(tokenizer, _launchParams(p.launchParams), b);
        if (m.open) b.rulesList[b.rulesCount++] = m.config.rules;
        b.forwarded = b.hasLaunch || m.open;
        b.members = (b.hasLaunch ? _launchParams(p.launchParams).members.length : 0) + (m.open ? 1 : 0);
        _countDoors(p, b);

        // The launch, the token at its predicted address, the forwarder, the lock.
        if (b.hasLaunch) {
            address launched;
            (b.familyId, launched,, b.currencies) = HookrRevenueMarketOpener.launch(
                tokenizer.launcher(), _launchBytes(p.launchParams), b.subject, b.token, b.fee, m.open
            );
            if (launched != b.subject) revert IHookrRevenueTokenizer.InvalidConfig();
        } else {
            b.currencies = new Currency[](2);
            b.currencies[1] = Currency.wrap(b.token);
        }
        if (HookrRevenueTokenDeployer.deploy(a, salt, tokenizer.poolManager()) != b.token) {
            revert IHookrRevenueTokenizer.InvalidConfig();
        }
        if (b.forwarded) b.forwarder = HookrRevenueDoorDeployer.deployForwarder(b.token, tokenizer.lock());
        if (b.hasLaunch) _lockFamily(tokenizer, b, b.familyId);

        // The doors: FEEB adapters, the v4 door, the v3 door, the sources, the Rules, the forwarder.
        _addFeebs(tokenizer, p, b);
        if (p.positionIds.length != 0) {
            b.door = HookrRevenueDoorDeployer.createStreamDoor(
                tokenizer.doorFactory(),
                tokenizer.positionManager(),
                b.token,
                p.positionIds,
                p.positionPermits,
                p.unlockAt,
                t.termsHash
            );
            _addDoor(
                b,
                IHookrRevenueToken.DoorKind.POSITIONS,
                b.door,
                POSITIONS_DOOR_BASE_GAS + POSITIONS_DOOR_POSITION_GAS * uint32(p.positionIds.length)
            );
        }
        if (p.v3PositionIds.length != 0) {
            b.v3Door = _createV3Door(tokenizer, p, t.termsHash, b);
            _addDoor(
                b,
                IHookrRevenueToken.DoorKind.POSITIONS_V3,
                b.v3Door,
                POSITIONS_DOOR_BASE_GAS + POSITIONS_DOOR_POSITION_GAS * uint32(p.v3PositionIds.length)
            );
        }
        for (uint256 i; i < p.sources.length; ++i) {
            _addDoor(b, IHookrRevenueToken.DoorKind.SOURCE, p.sources[i], b.sourceGas[i]);
        }
        _addRulesDoors(b);
        if (b.forwarded) {
            _addDoor(
                b,
                IHookrRevenueToken.DoorKind.FORWARDER,
                b.forwarder,
                FORWARDER_DOOR_BASE_GAS + FORWARDER_DOOR_MEMBER_GAS * uint32(b.members)
            );
        }

        // The bridge, the seal, the market, the refunds, the streams.
        _seal(tokenizer, t, m, b);
        if (m.open) _openMarket(tokenizer, m, b);
        _refund(b);
        _emitStreams(b.token, b.familyId);
        return (
            b.token,
            IHookrRevenueTokenizer.Tokenization(
                b.creator,
                WAY_STREAMS,
                b.forwarder,
                b.adapter,
                b.door,
                b.familyId,
                b.marketFamilyId,
                b.unlockBlock,
                b.legBps
            ),
            t.supply
        );
    }

    /// @notice Writes what `tokenize` returned (`ret`, its return data as is) into the tokenizer's record and token
    ///         list, handed in as storage references, and emits `Tokenized` as the tokenizer: what the tokenizer's
    ///         own `_finish` does for the other ways. Run as the tokenizer, right after `tokenize`.
    /// @return token The revenue token, the tokenizer's own return.
    function record(
        mapping(address => IHookrRevenueTokenizer.Tokenization) storage tokenizations,
        address[] storage tokens,
        bytes memory ret
    ) external returns (address token) {
        IHookrRevenueTokenizer.Tokenization memory r;
        uint256 supply;
        (token, r, supply) = abi.decode(ret, (address, IHookrRevenueTokenizer.Tokenization, uint256));
        tokenizations[token] = r;
        tokens.push(token);
        emit IHookrRevenueTokenizer.Tokenized(
            token,
            r.creator,
            r.way,
            r.forwarder,
            r.adapter,
            r.door,
            r.familyId,
            r.marketFamilyId,
            supply,
            r.unlockBlock,
            r.legBps
        );
    }

    /// @notice IHookrRevenueTokenizer.predictStreamToken, computed as the tokenizer: the token deployer's init code
    ///         over native ETH and `t.extraAssets`, created from the tokenizer (`msg.sender` under the staticcall)
    ///         with the salt of `creator` and `t.termsHash`. Reverts as `tokenize` does on the asset list.
    function predict(address creator, IHookrRevenueTokenizer.TokenTerms calldata t) external view returns (address) {
        uint32 stream = t.streamSeconds == 0 ? DEFAULT_STREAM_SECONDS : t.streamSeconds;
        HookrRevenueTokenDeployer.TokenArgs memory a = _tokenArgs(t, _assetList(t.extraAssets), stream);
        address poolManager = IHookrRevenueTokenizer(msg.sender).poolManager();
        return Create2.computeAddress(
            _salt(creator, t.termsHash), HookrRevenueTokenDeployer.initCodeHash(msg.sender, a, poolManager), msg.sender
        );
    }

    /// @notice IHookrRevenueTokenizer.streamsOf, computed as the tokenizer from the token's doors and the record:
    ///         one record per door, and one per family of the forwarder door; empty for a token the tokenizer did
    ///         not create.
    function streamsOf(address token) external view returns (IHookrRevenueTokenizer.StreamRecord[] memory) {
        IHookrRevenueTokenizer.Tokenization memory r = IHookrRevenueTokenizer(msg.sender).tokenizations(token);
        if (r.way == 0) return new IHookrRevenueTokenizer.StreamRecord[](0);
        return _records(token, r.familyId);
    }

    // ------------------------------------------------------------------ checks

    /// @dev The terms every way shares (the tokenizer's `_begin`, less the leg and the mint sum, which wait on the
    ///      streams): the supply, the window, the tip, the terms hash, the recipients; the market when it opens;
    ///      the asset list.
    function _checkTerms(
        IHookrRevenueTokenizer tokenizer,
        IHookrRevenueTokenizer.TokenTerms calldata t,
        IHookrRevenueTokenizer.MarketTerms calldata m,
        Build memory b
    ) private view {
        uint32 stream = t.streamSeconds == 0 ? DEFAULT_STREAM_SECONDS : t.streamSeconds;
        if (
            t.supply == 0 || t.supply > type(uint128).max || stream < MIN_STREAM_SECONDS || stream > MAX_STREAM_SECONDS
                || t.tipBps > MAX_TIP_BPS || t.termsHash == bytes32(0)
        ) revert IHookrRevenueTokenizer.InvalidTerms();
        uint256 n = t.recipients.length;
        if (n == 0 || n != t.amounts.length) revert IHookrRevenueTokenizer.InvalidTerms();
        for (uint256 i; i < n; ++i) {
            if (t.recipients[i] == address(0) || t.amounts[i] == 0) revert IHookrRevenueTokenizer.InvalidTerms();
        }
        if (m.open) {
            if (!tokenizer.isAdmittedRules(m.config.rules)) {
                revert IHookrRevenueTokenizer.RulesNotAdmitted(m.config.rules);
            }
            if (m.seed == 0) revert IHookrRevenueTokenizer.InvalidMarket();
            if (m.bridgeBps != 0 && (tokenizer.bridgeFactory() == address(0) || m.bridgeBps > MAX_BRIDGE_BPS)) {
                revert IHookrRevenueTokenizer.InvalidMarket();
            }
            b.seed = m.seed;
        }
        b.streamSeconds = stream;
        b.assets = _assetList(t.extraAssets);
    }

    /// @dev The recipients' amounts must sum to the supply less the leg and the seed, exactly.
    function _checkMint(IHookrRevenueTokenizer.TokenTerms calldata t, Build memory b) private pure {
        uint256 sum;
        for (uint256 i; i < t.amounts.length; ++i) {
            sum += t.amounts[i];
        }
        uint256 expected = t.supply > b.leg + b.seed ? t.supply - b.leg - b.seed : 0;
        if (expected == 0 || sum != expected) revert IHookrRevenueTokenizer.MintMismatch(sum, expected);
    }

    /// @dev A term is forever or at least `minimum`; anything shorter is `TermTooShort(given, minimum)`.
    function _checkTerm(uint64 given, uint64 minimum) private pure {
        if (given != FOREVER && given < minimum) revert IHookrRevenueTokenizer.TermTooShort(given, minimum);
    }

    /// @dev The v4 positions: 1 to `MAX_POSITIONS`, every pool currency listed (native ETH is), then the scan with
    ///      its `PositionReported` events, which also says whether every pool is on the root.
    function _checkV4(
        IHookrRevenueTokenizer tokenizer,
        IHookrRevenueTokenizer.StreamParams calldata p,
        IHookrRevenueTokenizer.TokenTerms calldata t,
        Build memory b
    ) private returns (bool allHookr) {
        uint256 n = p.positionIds.length;
        if (n > MAX_POSITIONS) revert IHookrRevenueTokenizer.InvalidTerms();
        address positionManager = tokenizer.positionManager();
        for (uint256 i; i < n; ++i) {
            (PoolKey memory key,) = IPositionManagerDoor(positionManager).getPoolAndPositionInfo(p.positionIds[i]);
            if (key.currency1.isAddressZero()) revert IHookrRevenueTokenizer.InvalidTerms();
            _requireListed(b.assets, key.currency0);
            _requireListed(b.assets, key.currency1);
        }
        (allHookr,) = HookrRevenueDoorDeployer.reportPositions(
            positionManager, tokenizer.root(), p.positionIds, t.extraAssets, MAX_POSITIONS, MAX_ASSETS
        );
    }

    /// @dev The launch's members as ways 1 and 3 check them: 1 to `MAX_MEMBERS`, one advisory config each, admitted
    ///      Rules, `royaltyTo` the token (or zero with no royalty), the Hook Block check; every quote and the subject
    ///      (an existing token, or the new one at the address the launcher will give it) listed. Collects the
    ///      members' Rules for the doors.
    function _checkLaunch(IHookrRevenueTokenizer tokenizer, IHookrLauncher.LaunchParams calldata lp, Build memory b)
        private
    {
        uint256 n = lp.members.length;
        if (n == 0 || n > MAX_MEMBERS || lp.advisoryConfigs.length != n) revert IHookrRevenueTokenizer.InvalidTerms();
        address launcher = tokenizer.launcher();
        b.subject = lp.token.existing == address(0)
            ? IHookrLauncher(launcher).predictToken(address(this), lp.token)
            : lp.token.existing;
        _requireListed(b.assets, Currency.wrap(b.subject));
        address root = tokenizer.root();
        for (uint256 i; i < n; ++i) {
            IHookrLauncher.Member calldata member = lp.members[i];
            if (!tokenizer.isAdmittedRules(member.config.rules)) {
                revert IHookrRevenueTokenizer.RulesNotAdmitted(member.config.rules);
            }
            if (member.rules.royaltyTo != (member.rules.royaltyBps != 0 ? b.token : address(0))) {
                revert IHookrRevenueTokenizer.InvalidTerms();
            }
            _requireListed(b.assets, member.quote);
            if (member.config.advisory != address(0)) {
                HookrRevenueDoorDeployer.checkAdvisory(
                    launcher, root, member.config.advisory, lp.advisoryConfigs[i], b.token, i
                );
            }
            b.rulesList[b.rulesCount++] = member.config.rules;
        }
    }

    /// @dev How many doors the streams make: one per FEEB NFT, one for the v4 positions, one for the v3 positions,
    ///      one per source, one per distinct Rules, one forwarder; `TooManyDoors` above `MAX_DOORS`. And the sync
    ///      budget those doors seal in: every stipend plus one `SYNC_RESERVE_GAS` per door, `SyncTooExpensive`
    ///      above `MAX_SYNC_GAS`, the token's own rule, refused here before anything moves.
    function _countDoors(IHookrRevenueTokenizer.StreamParams calldata p, Build memory b) private pure {
        uint256 feebs = p.feebs.length;
        uint256 v4 = p.positionIds.length;
        uint256 v3 = p.v3PositionIds.length;
        uint256 rules = _distinctRules(b);
        uint256 count = feebs + (v4 != 0 ? 1 : 0) + (v3 != 0 ? 1 : 0) + p.sources.length + rules + (b.forwarded ? 1 : 0);
        if (count > MAX_DOORS) revert IHookrRevenueTokenizer.TooManyDoors(count);
        uint256 total = feebs * FEEB_DOOR_GAS + rules * RULES_DOOR_GAS + count * SYNC_RESERVE_GAS;
        if (v4 != 0) total += POSITIONS_DOOR_BASE_GAS + POSITIONS_DOOR_POSITION_GAS * v4;
        if (v3 != 0) total += POSITIONS_DOOR_BASE_GAS + POSITIONS_DOOR_POSITION_GAS * v3;
        if (b.forwarded) total += FORWARDER_DOOR_BASE_GAS + FORWARDER_DOOR_MEMBER_GAS * b.members;
        for (uint256 i; i < b.sourceGas.length; ++i) {
            total += b.sourceGas[i];
        }
        if (total > MAX_SYNC_GAS) revert IHookrRevenueTokenizer.SyncTooExpensive(total);
        b.doors = new IHookrRevenueToken.Door[](count);
    }

    /// @dev Source `i` of `sources`: code, no repeat, `revenueToken()` the token, `pullGas()` within bounds,
    ///      `bound()`, `ends()` not a pending revocation and not a term under the minimum, every `assets()` currency
    ///      listed. Every read is a staticcall with `SOURCE_VIEW_GAS` whose answer is checked for shape: a source
    ///      that does not answer, or answers malformed data, is `InvalidSource`, never a raw decoder revert.
    /// @return stipend The source's `pullGas`, the door's stipend.
    function _checkSource(address[] calldata sources, uint256 i, Build memory b) private view returns (uint32 stipend) {
        address s = sources[i];
        if (s.code.length == 0) revert IHookrRevenueTokenizer.InvalidSource(s);
        for (uint256 j; j < i; ++j) {
            if (sources[j] == s) revert IHookrRevenueTokenizer.InvalidSource(s);
        }
        (bool ok, uint256 w0, uint256 w1) = _read(s, abi.encodeCall(IHookrRevenueSource.revenueToken, ()), 1);
        if (!ok || w0 != uint256(uint160(b.token))) revert IHookrRevenueTokenizer.InvalidSource(s);
        (ok, w0,) = _read(s, abi.encodeCall(IHookrRevenueSource.pullGas, ()), 1);
        if (!ok || w0 < MIN_SOURCE_GAS || w0 > MAX_SOURCE_GAS) revert IHookrRevenueTokenizer.InvalidSource(s);
        stipend = uint32(w0);
        (ok, w0,) = _read(s, abi.encodeCall(IHookrRevenueSource.bound, ()), 1);
        if (!ok || w0 > 1) revert IHookrRevenueTokenizer.InvalidSource(s);
        if (w0 == 0) revert IHookrRevenueTokenizer.SourceNotBound(s);
        (ok, w0, w1) = _read(s, abi.encodeCall(IHookrRevenueSource.ends, ()), 2);
        if (!ok || w0 > uint256(IHookrRevenueSource.EndKind.ENDED) || w1 > type(uint64).max) {
            revert IHookrRevenueTokenizer.InvalidSource(s);
        }
        IHookrRevenueSource.EndKind kind = IHookrRevenueSource.EndKind(w0);
        if (kind == IHookrRevenueSource.EndKind.REVOCABLE) {
            if (w1 != 0) revert IHookrRevenueTokenizer.SourceRevocationPending(s, uint64(w1));
        } else if (kind == IHookrRevenueSource.EndKind.AT_TIME) {
            _checkTerm(uint64(w1), uint64(block.timestamp) + MIN_TERM_SECONDS);
        } else if (kind == IHookrRevenueSource.EndKind.AT_BLOCK) {
            _checkTerm(uint64(w1), uint64(block.number) + MIN_TERM_BLOCKS);
        } else if (kind == IHookrRevenueSource.EndKind.ENDED) {
            revert IHookrRevenueTokenizer.SourceNotBound(s);
        }
        _checkAssets(s, b.assets);
    }

    /// @dev `assets()` on `s`, read raw with `SOURCE_VIEW_GAS` and checked for shape: one offset word of 0x20, a
    ///      length of at most `MAX_ASSETS`, then that many address words, each a listed currency. Anything else is
    ///      `InvalidSource`.
    function _checkAssets(address s, Currency[] memory assets) private view {
        bytes memory data = abi.encodeCall(IHookrRevenueSource.assets, ());
        uint256 cap = SOURCE_VIEW_GAS;
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(cap, s, add(data, 0x20), mload(data), 0, 0)
            size := returndatasize()
        }
        if (!ok || size < 0x40 || size > 0x40 + 0x20 * MAX_ASSETS) revert IHookrRevenueTokenizer.InvalidSource(s);
        bytes memory ret = new bytes(size);
        uint256 offset;
        uint256 n;
        assembly ("memory-safe") {
            returndatacopy(add(ret, 0x20), 0, size)
            offset := mload(add(ret, 0x20))
            n := mload(add(ret, 0x40))
        }
        if (offset != 0x20 || size != 0x40 + 0x20 * n) revert IHookrRevenueTokenizer.InvalidSource(s);
        for (uint256 k; k < n; ++k) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(ret, add(0x60, shl(5, k))))
            }
            if (word > type(uint160).max) revert IHookrRevenueTokenizer.InvalidSource(s);
            _requireListed(assets, Currency.wrap(address(uint160(word))));
        }
    }

    /// @dev A staticcall of `data` on `source` with `SOURCE_VIEW_GAS` that must answer exactly `words` words (one or
    ///      two), read into scratch memory past the free pointer. A revert, a burn past the cap, no code or an answer
    ///      of another size is `ok` false with zero words.
    function _read(address source, bytes memory data, uint256 words)
        private
        view
        returns (bool ok, uint256 w0, uint256 w1)
    {
        uint256 cap = SOURCE_VIEW_GAS;
        assembly ("memory-safe") {
            let p := mload(0x40)
            ok := staticcall(cap, source, add(data, 0x20), mload(data), p, 0x40)
            ok := and(ok, eq(returndatasize(), shl(5, words)))
            w0 := mul(mload(p), ok)
            w1 := mul(mload(add(p, 0x20)), and(ok, eq(words, 2)))
        }
    }

    /// @dev `c` must be one of the token's assets.
    function _requireListed(Currency[] memory assets, Currency c) private pure {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == c) return;
        }
        revert IHookrRevenueTokenizer.AssetNotListed(c);
    }

    // ------------------------------------------------------------------ the launch

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

    /// @dev The struct's own encoding, what the opener forwards to the launcher.
    function _launchBytes(bytes calldata raw) private pure returns (bytes calldata) {
        return raw[uint256(bytes32(raw[0:32])):];
    }

    /// @dev Hands family `familyId` to the lock for the forwarder until the unlock block and registers it there,
    ///      returning to the creator.
    function _lockFamily(IHookrRevenueTokenizer tokenizer, Build memory b, bytes32 familyId) private {
        IHookrLauncher(tokenizer.launcher()).transferFamily(familyId, tokenizer.lock(), 0);
        IHookrFamilyLock(tokenizer.lock()).lock(familyId, b.forwarder, b.unlockBlock);
        IHookrFamilyForwarder(b.forwarder).register(familyId, b.creator);
    }

    // ------------------------------------------------------------------ the doors

    /// @dev Each FEEB NFT into its own one-way adapter: an admitted vault, the adapter, the transfer from the
    ///      creator, the adapter checked to hold it. The first adapter is the record's.
    function _addFeebs(IHookrRevenueTokenizer tokenizer, IHookrRevenueTokenizer.StreamParams calldata p, Build memory b)
        private
    {
        for (uint256 i; i < p.feebs.length; ++i) {
            address vault = p.feebs[i].vault;
            uint256 tokenId = p.feebs[i].tokenId;
            if (!tokenizer.isAdmittedVault(vault)) revert IHookrRevenueTokenizer.VaultNotAdmitted(vault);
            address adapter = HookrRevenueDoorDeployer.deployAdapter(b.token, vault, tokenId);
            IBeneficiaryVault(vault).transferFrom(msg.sender, adapter, tokenId);
            address owner = IBeneficiaryVault(vault).ownerOf(tokenId);
            if (owner != adapter) revert IHookrRevenueTokenizer.NotNftOwner(vault, tokenId, owner);
            if (b.adapter == address(0)) b.adapter = adapter;
            _addDoor(b, IHookrRevenueToken.DoorKind.FEEB, adapter, FEEB_DOOR_GAS);
        }
    }

    /// @dev The v3 door: 1 to `MAX_POSITIONS` positions, each one's pool currencies listed with native ETH standing
    ///      for the manager's wrapper, the permits applied first (each in its own try, as the v4 permits), then the
    ///      pinned factory's `createFor` on the creator's behalf, locked until `p.unlockAt`, and the door checked to
    ///      be the factory's, the token's and active.
    function _createV3Door(
        IHookrRevenueTokenizer tokenizer,
        IHookrRevenueTokenizer.StreamParams calldata p,
        bytes32 salt,
        Build memory b
    ) private returns (address door) {
        uint256 n = p.v3PositionIds.length;
        if (n > MAX_POSITIONS) revert IHookrRevenueTokenizer.InvalidTerms();
        INonfungiblePositionManagerDoor manager = INonfungiblePositionManagerDoor(tokenizer.positionManagerV3());
        IHookrV3PositionNftDoorFactory factory = IHookrV3PositionNftDoorFactory(tokenizer.v3DoorFactory());
        address wrapper = factory.wrappedNative();
        for (uint256 i; i < n; ++i) {
            (,, address token0, address token1,,,,,,,,) = manager.positions(p.v3PositionIds[i]);
            _requireListed(b.assets, token0 == wrapper ? NATIVE : Currency.wrap(token0));
            _requireListed(b.assets, token1 == wrapper ? NATIVE : Currency.wrap(token1));
        }
        for (uint256 i; i < p.v3Permits.length; ++i) {
            IHookrRevenueTokenizer.V3PositionPermit calldata permit = p.v3Permits[i];
            try manager.permit(address(factory), permit.tokenId, permit.deadline, permit.v, permit.r, permit.s) {}
                catch {}
        }
        door = factory.createFor(msg.sender, b.token, p.v3PositionIds, p.unlockAt, salt);
        if (
            !factory.isDoor(door) || IHookrV3PositionNftDoor(door).revenueToken() != b.token
                || !IHookrV3PositionNftDoor(door).active()
        ) revert IHookrRevenueTokenizer.DoorMismatch(door);
    }

    /// @dev One RULES door per distinct Rules among the members' and the market's.
    function _addRulesDoors(Build memory b) private pure {
        for (uint256 i; i < b.rulesCount; ++i) {
            address r = b.rulesList[i];
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (b.rulesList[j] == r) seen = true;
            }
            if (!seen) _addDoor(b, IHookrRevenueToken.DoorKind.RULES, r, RULES_DOOR_GAS);
        }
    }

    /// @dev How many distinct Rules the members and the market bind.
    function _distinctRules(Build memory b) private pure returns (uint256 k) {
        for (uint256 i; i < b.rulesCount; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (b.rulesList[j] == b.rulesList[i]) seen = true;
            }
            if (!seen) ++k;
        }
    }

    function _addDoor(Build memory b, IHookrRevenueToken.DoorKind kind, address target, uint32 stipend) private pure {
        b.doors[b.doorCount++] = IHookrRevenueToken.Door(kind, target, stipend);
    }

    // ------------------------------------------------------------------ the seal, the market, the refunds

    /// @dev Makes the bridge when the market asks for one, then seals: the doors, the creator's recipients, the
    ///      Hookr leg to the collector when there is one, the market seed to the tokenizer.
    function _seal(
        IHookrRevenueTokenizer tokenizer,
        IHookrRevenueTokenizer.TokenTerms calldata t,
        IHookrRevenueTokenizer.MarketTerms calldata m,
        Build memory b
    ) private {
        if (m.open && m.bridgeBps != 0) {
            b.bridge = HookrRevenueMarketOpener.makeBridge(
                tokenizer.launcher(), tokenizer.root(), tokenizer.bridgeFactory(), b.token, m
            );
            b.bridgeBps = m.bridgeBps;
        }
        uint256 n = t.recipients.length;
        uint256 extra = (b.leg != 0 ? 1 : 0) + (b.seed != 0 ? 1 : 0);
        address[] memory recipients = new address[](n + extra);
        uint256[] memory amounts = new uint256[](n + extra);
        for (uint256 i; i < n; ++i) {
            recipients[i] = t.recipients[i];
            amounts[i] = t.amounts[i];
        }
        if (b.leg != 0) {
            recipients[n] = tokenizer.collector();
            amounts[n] = b.leg;
            ++n;
        }
        if (b.seed != 0) {
            recipients[n] = address(this);
            amounts[n] = b.seed;
        }
        IHookrRevenueToken(b.token).seal(IHookrRevenueToken.Seal(b.doors, recipients, amounts, b.bridge, b.bridgeBps));
    }

    /// @dev Opens the revenue token's own market as the other ways do (HookrRevenueMarketOpener.open), registers
    ///      its family on the forwarder returning to the creator, and emits `MarketOpened` as the tokenizer.
    function _openMarket(
        IHookrRevenueTokenizer tokenizer,
        IHookrRevenueTokenizer.MarketTerms calldata m,
        Build memory b
    ) private {
        (bytes32 familyId, PoolId poolId, uint256 placed) = HookrRevenueMarketOpener.open(
            HookrRevenueMarketOpener.Market(
                tokenizer.launcher(), tokenizer.lock(), tokenizer.root(), b.token, b.forwarder, b.unlockBlock, b.fee
            ),
            m
        );
        b.marketFamilyId = familyId;
        IHookrFamilyForwarder(b.forwarder).register(familyId, b.creator);
        emit IHookrRevenueTokenizer.MarketOpened(b.token, familyId, poolId, placed, b.bridge, b.bridgeBps);
    }

    /// @dev Everything left here goes back to the creator (the launcher's refunds, dev-bought subject, the lock's
    ///      acceptance payout, unspent seed); the native balance must be zero.
    function _refund(Build memory b) private {
        Currency[] memory cs = b.currencies;
        for (uint256 i; i < cs.length; ++i) {
            uint256 held = HookrSettlement.balance(cs[i], address(this));
            if (held != 0) HookrSettlement.send(cs[i], b.creator, held);
        }
        if (address(this).balance != 0) revert IHookrRevenueTokenizer.InvalidFunding();
    }

    /// @dev One `StreamAdded` per stream, in the order `streamsOf` answers them, as of the mint.
    function _emitStreams(address token, bytes32 familyId) private {
        IHookrRevenueTokenizer.StreamRecord[] memory list = _records(token, familyId);
        for (uint256 i; i < list.length; ++i) {
            IHookrRevenueTokenizer.StreamRecord memory s = list[i];
            emit IHookrRevenueTokenizer.StreamAdded(token, i, s.kind, s.target, s.id, s.endKind, s.end);
        }
    }

    // ------------------------------------------------------------------ the streams

    /// @dev Every stream of `token`, read live from its doors: one per door, and one per family of a FORWARDER door
    ///      (the launched family `familyId` as `FAMILY`, any other as `MARKET`).
    function _records(address token, bytes32 familyId)
        private
        view
        returns (IHookrRevenueTokenizer.StreamRecord[] memory list)
    {
        IHookrRevenueToken tk = IHookrRevenueToken(token);
        uint256 n = tk.doorCount();
        uint256 count;
        for (uint256 i; i < n; ++i) {
            IHookrRevenueToken.Door memory d = tk.doorAt(i);
            count += d.kind == IHookrRevenueToken.DoorKind.FORWARDER ? IHookrFamilyForwarder(d.target).familyCount() : 1;
        }
        list = new IHookrRevenueTokenizer.StreamRecord[](count);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            IHookrRevenueToken.Door memory d = tk.doorAt(i);
            if (d.kind == IHookrRevenueToken.DoorKind.FORWARDER) {
                IHookrFamilyForwarder forwarder = IHookrFamilyForwarder(d.target);
                uint256 families = forwarder.familyCount();
                for (uint256 j; j < families; ++j) {
                    list[k++] = _familyRecord(d.target, forwarder.familyAt(j), familyId);
                }
            } else {
                list[k++] = _doorRecord(d);
            }
        }
    }

    /// @dev A locked family: released is `ENDED`, forever is `FOREVER`, else `AT_BLOCK` its unlock block.
    function _familyRecord(address forwarder, IHookrFamilyForwarder.Family memory f, bytes32 familyId)
        private
        pure
        returns (IHookrRevenueTokenizer.StreamRecord memory s)
    {
        s.kind = f.id == familyId ? IHookrRevenueTokenizer.StreamKind.FAMILY : IHookrRevenueTokenizer.StreamKind.MARKET;
        s.target = forwarder;
        s.id = f.id;
        if (f.released) {
            s.endKind = IHookrRevenueSource.EndKind.ENDED;
        } else if (f.unlockBlock == FOREVER) {
            s.endKind = IHookrRevenueSource.EndKind.FOREVER;
        } else {
            s.endKind = IHookrRevenueSource.EndKind.AT_BLOCK;
            s.end = f.unlockBlock;
        }
    }

    /// @dev A door that is not the forwarder: a Rules ledger and a FEEB adapter end never; a position door at its
    ///      unlock time, or never, or `ENDED` once every NFT went back; a source as it answers `ends()` now, with
    ///      its `sourceKind` as the id. Both source reads are capped at `SOURCE_VIEW_GAS` and checked for shape: a
    ///      source that does not answer, or answers malformed data, is `ENDED` with a zero id, and never takes the
    ///      view down with it.
    function _doorRecord(IHookrRevenueToken.Door memory d)
        private
        view
        returns (IHookrRevenueTokenizer.StreamRecord memory s)
    {
        s.target = d.target;
        if (d.kind == IHookrRevenueToken.DoorKind.RULES) {
            s.kind = IHookrRevenueTokenizer.StreamKind.RULES;
        } else if (d.kind == IHookrRevenueToken.DoorKind.FEEB) {
            s.kind = IHookrRevenueTokenizer.StreamKind.FEEB;
            s.id = bytes32(IHookrFeebAdapter(d.target).tokenId());
        } else if (d.kind == IHookrRevenueToken.DoorKind.POSITIONS) {
            s.kind = IHookrRevenueTokenizer.StreamKind.POSITIONS;
            IHookrPositionNftDoor door = IHookrPositionNftDoor(d.target);
            _positionsEnd(s, door.released(), door.unlockAt());
        } else if (d.kind == IHookrRevenueToken.DoorKind.POSITIONS_V3) {
            s.kind = IHookrRevenueTokenizer.StreamKind.POSITIONS_V3;
            IHookrV3PositionNftDoor door = IHookrV3PositionNftDoor(d.target);
            _positionsEnd(s, door.released(), door.unlockAt());
        } else {
            s.kind = IHookrRevenueTokenizer.StreamKind.SOURCE;
            (bool ok, uint256 w0, uint256 w1) = _read(d.target, abi.encodeCall(IHookrRevenueSource.sourceKind, ()), 1);
            if (ok) s.id = bytes32(w0);
            (ok, w0, w1) = _read(d.target, abi.encodeCall(IHookrRevenueSource.ends, ()), 2);
            if (ok && w0 <= uint256(IHookrRevenueSource.EndKind.ENDED) && w1 <= type(uint64).max) {
                s.endKind = IHookrRevenueSource.EndKind(w0);
                s.end = uint64(w1);
            } else {
                s.endKind = IHookrRevenueSource.EndKind.ENDED;
            }
        }
    }

    function _positionsEnd(IHookrRevenueTokenizer.StreamRecord memory s, bool released, uint64 unlockAt) private pure {
        if (released) {
            s.endKind = IHookrRevenueSource.EndKind.ENDED;
        } else if (unlockAt == FOREVER) {
            s.endKind = IHookrRevenueSource.EndKind.FOREVER;
        } else {
            s.endKind = IHookrRevenueSource.EndKind.AT_TIME;
            s.end = unlockAt;
        }
    }

    // ------------------------------------------------------------------ assets and the token

    /// @dev Native ETH then `extra`, as given: each once and not native ETH again (`InvalidTerms`), at most
    ///      `MAX_ASSETS` (`TooManyAssets`). The list is the creator's, so the token's address is known before any
    ///      stream exists.
    function _assetList(Currency[] calldata extra) private pure returns (Currency[] memory assets) {
        uint256 count = 1 + extra.length;
        if (count > MAX_ASSETS) revert IHookrRevenueTokenizer.TooManyAssets(count);
        assets = new Currency[](count);
        for (uint256 i; i < extra.length; ++i) {
            Currency c = extra[i];
            if (c.isAddressZero()) revert IHookrRevenueTokenizer.InvalidTerms();
            for (uint256 j; j < i; ++j) {
                if (extra[j] == c) revert IHookrRevenueTokenizer.InvalidTerms();
            }
            assets[i + 1] = c;
        }
    }

    function _tokenArgs(IHookrRevenueTokenizer.TokenTerms calldata t, Currency[] memory assets, uint32 stream)
        private
        pure
        returns (HookrRevenueTokenDeployer.TokenArgs memory a)
    {
        a.name = t.name;
        a.symbol = t.symbol;
        a.supply = t.supply;
        a.assets = assets;
        a.streamSeconds = stream;
        a.tipBps = t.tipBps;
        a.termsHash = t.termsHash;
    }

    /// @dev The tokenizer's salt for a revenue token: the creator and the terms hash.
    function _salt(address creator, bytes32 termsHash) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, termsHash));
    }
}
