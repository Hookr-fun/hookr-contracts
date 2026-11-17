// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";
import {IPositionManagerDoor} from "../interfaces/IPositionManagerDoor.sol";
import {IHookrRevenueDoor} from "../interfaces/IHookrRevenueDoor.sol";
import {IHookrRevenueSource} from "../interfaces/IHookrRevenueSource.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";
import {IHookrPositionNftDoor} from "../interfaces/IHookrPositionNftDoor.sol";
import {IHookrPositionNftDoorFactory} from "../interfaces/IHookrPositionNftDoorFactory.sol";
import {IHookrV3PositionNftDoorFactory} from "../interfaces/IHookrV3PositionNftDoorFactory.sol";
import {INonfungiblePositionManagerDoor} from "../interfaces/external/INonfungiblePositionManagerDoor.sol";
import {EndKind} from "../types/EndKind.sol";
import {HookrFamilyForwarder} from "../doors/HookrFamilyForwarder.sol";
import {HookrRevenueStreamEnds} from "./HookrRevenueStreamEnds.sol";

/// @title Hookr revenue door deployer
/// @notice The tokenizer's family forwarders (their creation code stays out of the tokenizer and its streams library),
///         the Hook Block check of a launch member or a market, the checks of an outside source, and the position doors:
///         a set of v4 positions sorted into the root's and the rest, and a set of v3 positions.
/// @dev An external library. `deployForwarder`, `checkAdvisory`, `positionDoors` and `v3Door` run by delegatecall, so the
///      forwarder names the calling tokenizer and the events are the tokenizer's; `previewPositions` runs under a
///      staticcall from the tokenizer, whose pins it reads through `msg.sender`.
library HookrRevenueDoorDeployer {
    /// @dev Most positions one call takes (IHookrRevenueTokenizer.MAX_POSITIONS).
    uint256 internal constant MAX_POSITIONS = 64;
    /// @dev Most currencies a source may declare (IHookrRevenueToken.MAX_ASSETS).
    uint256 internal constant MAX_ASSETS = 8;
    /// @dev The token's door stipend bounds (IHookrRevenueToken.MIN_DOOR_GAS, MAX_DOOR_GAS): what a source may declare.
    uint256 internal constant MIN_DOOR_GAS = 100_000;
    uint256 internal constant MAX_DOOR_GAS = 12_000_000;
    /// @dev The tokenizer's minimum terms (IHookrRevenueTokenizer.MIN_TERM_BLOCKS, MIN_TERM_SECONDS).
    uint64 internal constant MIN_TERM_BLOCKS = 50_400;
    uint64 internal constant MIN_TERM_SECONDS = 7 days;
    uint64 internal constant FOREVER = type(uint64).max;
    /// @dev The hook flags that run on a liquidity removal, which is what a fee collection is to the PoolManager: the
    ///      door's own rule for `hookCanBlockCollection`.
    uint160 internal constant REMOVE_LIQUIDITY_FLAGS = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    /// @dev How HookrRules knows Tax + Conversion at bind (HookrRules._taxConversion): the block answers
    ///      `EXCLUSIVE_GROUP()` (selector 0x5ac238e9) with keccak256("DIRECTIONAL_QUOTE_TAX"), read with 10,000 gas; a
    ///      failed, starved or malformed read is no.
    bytes4 internal constant EXCLUSIVE_GROUP_SELECTOR = 0x5ac238e9;
    uint256 internal constant GROUP_READ_GAS = 10_000;
    bytes32 internal constant TAX_CONVERSION_GROUP = keccak256("DIRECTIONAL_QUOTE_TAX");
    /// @dev Tax + Conversion's bind data starts with its Config, two static Legs of five words each (taxPips,
    ///      routeId, assetRecipient, recoveryRecipient, staleRecoveryDelay), in every one of its four shapes (320,
    ///      512, 576 or 768 bytes: with the session tiers, the decay schedule, neither or both appended). The creator
    ///      recipients are words 2 and 3 of the buy leg and 7 and 8 of the sell leg.
    uint256 internal constant TAX_CONFIG_BYTES = 320;

    /// @notice Checks a pool's Hook Block `advisory` for `token` (a launch member, or the market with the empty bind
    ///         data its launch sends, as `member`): every block the registry admits on `root` binds, as on any launch.
    ///         Tax + Conversion's creator payout is pinned to the token: `assetRecipient` and `recoveryRecipient` of
    ///         both legs must each be the token or zero, else `AdvisoryRecipientMismatch`. Any other block admitted to
    ///         take quote pays a recipient of its own that the tokenizer cannot read: it binds, and
    ///         `AdvisoryPayeeUnchecked(token, member, advisory)` is emitted by the calling tokenizer so the app reads
    ///         that block's own payee and shows where its cut goes. A block admitted with no quote take can only
    ///         surcharge the LP fee, which the locked position earns for the token.
    function checkAdvisory(
        address launcher,
        address root,
        address advisory,
        bytes calldata data,
        address token,
        uint256 member
    ) external {
        bytes32 group;
        assembly ("memory-safe") {
            mstore(0, EXCLUSIVE_GROUP_SELECTOR)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
            let ok := staticcall(GROUP_READ_GAS, advisory, 0, 4, 0, 32)
            if and(ok, eq(returndatasize(), 32)) { group := mload(0) }
        }
        if (group == TAX_CONVERSION_GROUP) {
            if (data.length < TAX_CONFIG_BYTES) revert IHookrRevenueTokenizer.AdvisoryRecipientMismatch(advisory);
            uint256[4] memory words = [uint256(2), 3, 7, 8];
            for (uint256 i; i < 4; ++i) {
                uint256 word = uint256(bytes32(data[words[i] * 32:words[i] * 32 + 32]));
                if (word != 0 && word != uint256(uint160(token))) {
                    revert IHookrRevenueTokenizer.AdvisoryRecipientMismatch(advisory);
                }
            }
            return;
        }
        IHookrRegistry registry = IHookrLauncher(launcher).registry();
        if (registry.admission(root, advisory).caps.maxQuoteTakePips != 0) {
            emit IHookrRevenueTokenizer.AdvisoryPayeeUnchecked(token, member, advisory);
        }
    }

    /// @notice Deploys the family forwarder of `token` on `lock`, registering families only for the calling tokenizer.
    function deployForwarder(address token, address lock) external returns (address) {
        return address(new HookrFamilyForwarder(token, lock, address(this)));
    }

    /// @notice Checks source `s` for `token`: code, `revenueToken()` the token, a `pullGas` within the token's stipend
    ///         bounds, `bound()`, no pending revocation, a dated end no sooner than the minimum term, a `sourceKind`,
    ///         and `assets()` of at most `MAX_ASSETS`, none of them the token itself. Every read is a staticcall
    ///         capped at `SOURCE_VIEW_GAS` and checked for shape: a source that does not answer, or answers malformed
    ///         data, is `InvalidSource`.
    /// @dev A source cannot deliver the token itself: the token refuses every transfer to its own doors, and a right
    ///      that pays both its currencies in one call (Doppler's `collectFees`) then fails whole on every pull, or
    ///      leaves the token's side at the right for good (a Pons escrow), where it earns income no one can claim.
    ///      So a source that declares the token is `InvalidSource`.
    /// @return stipend The source's `pullGas`, its door's stipend.
    /// @return id The source's `sourceKind`.
    /// @return assets The currencies the source declares.
    function checkSource(address token, address s)
        external
        view
        returns (uint32 stipend, bytes32 id, Currency[] memory assets)
    {
        if (s.code.length == 0) revert IHookrRevenueTokenizer.InvalidSource(s);
        (bool ok, uint256 w0, uint256 w1) =
            HookrRevenueStreamEnds.read(s, abi.encodeCall(IHookrRevenueDoor.revenueToken, ()), 1);
        if (!ok || w0 != uint256(uint160(token))) revert IHookrRevenueTokenizer.InvalidSource(s);
        (ok, w0,) = HookrRevenueStreamEnds.read(s, abi.encodeCall(IHookrRevenueSource.pullGas, ()), 1);
        if (!ok || w0 < MIN_DOOR_GAS || w0 > MAX_DOOR_GAS) revert IHookrRevenueTokenizer.InvalidSource(s);
        stipend = uint32(w0);
        (ok, w0,) = HookrRevenueStreamEnds.read(s, abi.encodeCall(IHookrRevenueSource.bound, ()), 1);
        if (!ok || w0 > 1) revert IHookrRevenueTokenizer.InvalidSource(s);
        if (w0 == 0) revert IHookrRevenueTokenizer.SourceNotBound(s);
        (ok, w0, w1) = HookrRevenueStreamEnds.read(s, abi.encodeCall(IHookrRevenueDoor.ends, ()), 2);
        if (!ok || w0 > uint256(EndKind.ENDED) || w1 > FOREVER) revert IHookrRevenueTokenizer.InvalidSource(s);
        EndKind kind = EndKind(w0);
        if (kind == EndKind.REVOCABLE) {
            if (w1 != 0) revert IHookrRevenueTokenizer.SourceRevocationPending(s, uint64(w1));
        } else if (kind == EndKind.AT_TIME) {
            _checkTerm(uint64(w1), uint64(block.timestamp) + MIN_TERM_SECONDS);
        } else if (kind == EndKind.AT_BLOCK) {
            _checkTerm(uint64(w1), uint64(block.number) + MIN_TERM_BLOCKS);
        } else if (kind == EndKind.ENDED) {
            revert IHookrRevenueTokenizer.SourceNotBound(s);
        }
        (ok, w0,) = HookrRevenueStreamEnds.read(s, abi.encodeCall(IHookrRevenueSource.sourceKind, ()), 1);
        if (!ok) revert IHookrRevenueTokenizer.InvalidSource(s);
        id = bytes32(w0);
        assets = _sourceAssets(s, token);
    }

    /// @dev A term is forever or at least `minimum`.
    function _checkTerm(uint64 given, uint64 minimum) private pure {
        if (given != FOREVER && given < minimum) revert IHookrRevenueTokenizer.TermTooShort(given, minimum);
    }

    /// @dev `assets()` on `s`, read raw with `SOURCE_VIEW_GAS` and checked for shape: one offset word of 0x20, a
    ///      length of at most `MAX_ASSETS`, then that many address words, none of them `token`. Anything else is
    ///      `InvalidSource`.
    function _sourceAssets(address s, address token) private view returns (Currency[] memory assets) {
        bytes memory data = abi.encodeCall(IHookrRevenueSource.assets, ());
        uint256 cap = HookrRevenueStreamEnds.SOURCE_VIEW_GAS;
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
        assets = new Currency[](n);
        for (uint256 k; k < n; ++k) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(ret, add(0x60, shl(5, k))))
            }
            if (word > type(uint160).max || word == uint256(uint160(token))) {
                revert IHookrRevenueTokenizer.InvalidSource(s);
            }
            assets[k] = Currency.wrap(address(uint160(word)));
        }
    }

    /// @notice IHookrRevenueTokenizer.previewPositions: per position whether its pool is on the root, whether its
    ///         hook, not being the root, runs on liquidity removals, and whether its pool holds `token`; and the
    ///         currencies the positions bring, each once.
    function previewPositions(address token, uint256[] calldata tokenIds)
        external
        view
        returns (
            bool[] memory hookrPool,
            bool[] memory canBlock,
            bool[] memory holdsToken,
            Currency[] memory currencies
        )
    {
        IHookrRevenueTokenizer tokenizer = IHookrRevenueTokenizer(msg.sender);
        address root = tokenizer.root();
        address[] memory hooks;
        (hooks, canBlock, holdsToken, currencies) = _scan(tokenizer.positionManager(), root, token, tokenIds);
        hookrPool = new bool[](hooks.length);
        for (uint256 i; i < hooks.length; ++i) {
            hookrPool[i] = hooks[i] == root;
        }
    }

    /// @notice The caller's v4 positions for `token`: scanned on `positionManager` with one `PositionReported` each
    ///         (emitted as the calling tokenizer), sorted into the ones whose pool's hook is `root` and the rest, the
    ///         permits applied for `factory` (each in its own try: a permit a front-runner applied fails on its nonce
    ///         and has set the same approval), then one door per non-empty set through `factory` on the caller's
    ///         behalf, each checked to be the factory's and the token's, with every position on the root or none.
    /// @dev The PositionManager verifies a permit as Permit2 does: a caller with code is asked through ERC-1271, so an
    ///      EIP-7702 caller whose code does not answer ERC-1271 approves the factory instead of signing.
    /// @return onRoot The door of the positions on the root, or zero.
    /// @return offRoot The door of the others, or zero.
    /// @return currencies The pools' currencies, each once.
    function positionDoors(
        address positionManager,
        address root,
        address factory,
        address token,
        uint256[] calldata tokenIds,
        IHookrRevenueTokenizer.PositionPermit[] calldata permits,
        uint64 unlockAt
    ) external returns (address onRoot, address offRoot, Currency[] memory currencies) {
        uint256[] memory rootIds;
        uint256[] memory otherIds;
        (rootIds, otherIds, currencies) = _report(positionManager, root, token, tokenIds);
        for (uint256 i; i < permits.length; ++i) {
            IHookrRevenueTokenizer.PositionPermit calldata permit = permits[i];
            if (permit.forAll) {
                try IPositionManagerDoor(positionManager)
                    .permitForAll(msg.sender, factory, true, permit.deadline, permit.nonce, permit.signature) {}
                    catch {}
            } else {
                try IPositionManagerDoor(positionManager)
                    .permit(factory, permit.tokenId, permit.deadline, permit.nonce, permit.signature) {}
                    catch {}
            }
        }
        if (rootIds.length != 0) onRoot = _positionDoor(factory, token, rootIds, unlockAt, true);
        if (otherIds.length != 0) offRoot = _positionDoor(factory, token, otherIds, unlockAt, false);
    }

    function _positionDoor(address factory, address token, uint256[] memory ids, uint64 unlockAt, bool onRoot)
        private
        returns (address door)
    {
        bytes32 salt = keccak256(abi.encode(token, IHookrRevenueToken(token).doorCount(), onRoot));
        door = IHookrPositionNftDoorFactory(factory).createFor(msg.sender, token, ids, unlockAt, salt);
        IHookrPositionNftDoor d = IHookrPositionNftDoor(door);
        if (
            !IHookrPositionNftDoorFactory(factory).isDoor(door) || d.revenueToken() != token
                || d.rootCount() != (onRoot ? ids.length : 0)
        ) revert IHookrRevenueTokenizer.DoorMismatch(door);
    }

    /// @notice The caller's v3 positions for `token` in one door: 1 to `MAX_POSITIONS`, their currencies read (the
    ///         manager's wrapper stands for native ETH), none on a pool of `token` itself, the permits applied for
    ///         `factory`, the door created on the caller's behalf and checked to be the factory's and the token's.
    /// @dev A v3 pool of the revenue token holds the token outside the v4 PoolManager, so it is an earning holder that
    ///      never claims: its share of every income and drop would stay in the token for good. A position on such a
    ///      pool is refused (`V3PairIsRevenueToken`), as Pons and Doppler refuse a pair of the token. This is the only
    ///      path to the v3 door factory, which creates doors for the tokenizer alone.
    function v3Door(
        address positionManager,
        address factory,
        address token,
        uint256[] calldata tokenIds,
        IHookrRevenueTokenizer.V3PositionPermit[] calldata permits,
        uint64 unlockAt
    ) external returns (address door, Currency[] memory currencies) {
        uint256 n = tokenIds.length;
        if (n > MAX_POSITIONS) revert IHookrRevenueTokenizer.InvalidTerms();
        INonfungiblePositionManagerDoor manager = INonfungiblePositionManagerDoor(positionManager);
        IHookrV3PositionNftDoorFactory f = IHookrV3PositionNftDoorFactory(factory);
        address wrapper = f.wrappedNative();
        Currency[] memory list = new Currency[](2 * n);
        uint256 count;
        for (uint256 i; i < n; ++i) {
            (,, address token0, address token1,,,,,,,,) = manager.positions(tokenIds[i]);
            if (token0 == token || token1 == token) revert IHookrRevenueTokenizer.V3PairIsRevenueToken(tokenIds[i]);
            count = _add(list, count, token0 == wrapper ? Currency.wrap(address(0)) : Currency.wrap(token0));
            count = _add(list, count, token1 == wrapper ? Currency.wrap(address(0)) : Currency.wrap(token1));
        }
        currencies = _trim(list, count);
        for (uint256 i; i < permits.length; ++i) {
            IHookrRevenueTokenizer.V3PositionPermit calldata permit = permits[i];
            try manager.permit(factory, permit.tokenId, permit.deadline, permit.v, permit.r, permit.s) {} catch {}
        }
        bytes32 salt = keccak256(abi.encode(token, IHookrRevenueToken(token).doorCount()));
        door = f.createFor(msg.sender, token, tokenIds, unlockAt, salt);
        if (!f.isDoor(door) || IHookrRevenueDoor(door).revenueToken() != token) {
            revert IHookrRevenueTokenizer.DoorMismatch(door);
        }
    }

    /// @dev Scans `tokenIds`, emits one `PositionReported` each, and sorts them into the root's and the rest, each in
    ///      the given order.
    function _report(address positionManager, address root, address token, uint256[] calldata tokenIds)
        private
        returns (uint256[] memory onRoot, uint256[] memory offRoot, Currency[] memory currencies)
    {
        address[] memory hooks;
        bool[] memory canBlock;
        (hooks, canBlock,, currencies) = _scan(positionManager, root, token, tokenIds);
        uint256 n = hooks.length;
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (hooks[i] == root) ++k;
            emit IHookrRevenueTokenizer.PositionReported(tokenIds[i], hooks[i], hooks[i] == root, canBlock[i]);
        }
        onRoot = new uint256[](k);
        offRoot = new uint256[](n - k);
        uint256 a;
        uint256 b;
        for (uint256 i; i < n; ++i) {
            if (hooks[i] == root) onRoot[a++] = tokenIds[i];
            else offRoot[b++] = tokenIds[i];
        }
    }

    /// @dev Reads every position's pool: an id with no position (its key has no currency1) is `InvalidTerms`, as is
    ///      an empty list or one past the tokenizer's `MAX_POSITIONS`.
    function _scan(address positionManager, address root, address token, uint256[] calldata tokenIds)
        private
        view
        returns (address[] memory hooks, bool[] memory canBlock, bool[] memory holdsToken, Currency[] memory currencies)
    {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_POSITIONS) revert IHookrRevenueTokenizer.InvalidTerms();
        Currency[] memory list = new Currency[](2 * n);
        uint256 count;
        hooks = new address[](n);
        canBlock = new bool[](n);
        holdsToken = new bool[](n);
        for (uint256 i; i < n; ++i) {
            (PoolKey memory key,) = IPositionManagerDoor(positionManager).getPoolAndPositionInfo(tokenIds[i]);
            if (key.currency1.isAddressZero()) revert IHookrRevenueTokenizer.InvalidTerms();
            address h = address(key.hooks);
            hooks[i] = h;
            if (h != root) canBlock[i] = (uint160(h) & REMOVE_LIQUIDITY_FLAGS) != 0;
            holdsToken[i] = Currency.unwrap(key.currency0) == token || Currency.unwrap(key.currency1) == token;
            count = _add(list, count, key.currency0);
            count = _add(list, count, key.currency1);
        }
        currencies = _trim(list, count);
    }

    function _trim(Currency[] memory list, uint256 count) private pure returns (Currency[] memory out) {
        out = new Currency[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = list[i];
        }
    }

    function _add(Currency[] memory list, uint256 count, Currency c) private pure returns (uint256) {
        for (uint256 i; i < count; ++i) {
            if (list[i] == c) return count;
        }
        list[count] = c;
        return count + 1;
    }
}
