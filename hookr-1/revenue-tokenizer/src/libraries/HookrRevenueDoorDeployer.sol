// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRevenueTokenizer} from "../interfaces/IHookrRevenueTokenizer.sol";
import {IHookrPositionNftDoor} from "../interfaces/IHookrPositionNftDoor.sol";
import {IPositionManagerDoor} from "../interfaces/IPositionManagerDoor.sol";
import {HookrFamilyForwarder} from "../HookrFamilyForwarder.sol";
import {HookrFeebAdapter} from "../HookrFeebAdapter.sol";
import {IHookrPositionNftDoorFactory} from "../interfaces/IHookrPositionNftDoorFactory.sol";

/// @title Hookr revenue door deployer
/// @notice Deploys the tokenizer's family forwarders and FEEB adapters, keeping their creation code out of the
///         tokenizer (see HookrRevenueTokenDeployer); reads a list of position NFTs for way (4) and creates their door
///         through the tokenizer's factory. By delegatecall, so the forwarder names the calling tokenizer, the door's
///         creator is the tokenizer's caller and the factory sees the tokenizer. Kept apart because the tokenizer's
///         runtime passed the 24,576-byte limit with the position scan inside it.
library HookrRevenueDoorDeployer {
    Currency internal constant NATIVE = Currency.wrap(address(0));
    /// @dev The revenue token's asset bound (HookrIncomeLedger.MAX_ASSETS), the tokenizer's own copy of it, checked
    ///      against the token's in test/HookrRevenueTokenizer.bounds.t.sol.
    uint256 internal constant MAX_ASSETS = 4;
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
    ///         both legs must each be the token or zero (zero passes the block's own bind only for a leg that is off,
    ///         or for a recovery recipient with no route), else `AdvisoryRecipientMismatch`. Any other block admitted
    ///         to take quote pays a recipient of its own that the tokenizer cannot read: it binds, and
    ///         `AdvisoryPayeeUnchecked(token, member, advisory)` is emitted by the calling tokenizer so the app reads
    ///         that block's own payee and shows where its cut goes. A block admitted with no quote take can only
    ///         surcharge the LP fee, which the locked position earns for the token. Mirrors the Rules' group read, so
    ///         a block the Rules treat as Tax + Conversion is the one checked here.
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

    /// @notice Deploys a forwarder for `token` on `lock`, registering families only for the calling tokenizer.
    function deployForwarder(address token, address lock) external returns (address) {
        return address(new HookrFamilyForwarder(token, lock, address(this)));
    }

    /// @notice Deploys an adapter for NFT `tokenId` of `vault` paying `token`.
    function deployAdapter(address token, address vault, uint256 tokenId) external returns (address) {
        return address(new HookrFeebAdapter(token, vault, tokenId));
    }

    /// @notice IHookrRevenueTokenizer.previewPositions, computed here: reads every position's pool from
    ///         the calling tokenizer's PositionManager and answers the leg basis points (the tokenizer's outside leg
    ///         unless every pool's hook is its root), the asset list (native ETH, every pool currency, the creator's
    ///         `extra`, each once, at most `MAX_ASSETS`), per NFT whether its pool is on the root and whether its
    ///         hook, not being the root, runs on liquidity removals, so its author could make the door's collection
    ///         of that position fail (HookrPositionNftDoor.hookCanBlockCollection). 1 to the tokenizer's
    ///         `MAX_POSITIONS` ids; an id with no position (its key has no currency1) is refused.
    /// @dev The same parameters as the tokenizer's `previewPositions`, so the tokenizer forwards its calldata as it
    ///      arrived and this function's return data as its own, by staticcall: here `msg.sender` is the tokenizer,
    ///      whose pins are read through its getters, and `address(this)` is this library.
    function previewPositions(uint256[] calldata tokenIds, Currency[] calldata extra)
        external
        view
        returns (uint16 legBps, Currency[] memory assets, bool[] memory hookrPool, bool[] memory canBlock)
    {
        IHookrRevenueTokenizer tokenizer = IHookrRevenueTokenizer(msg.sender);
        address root = tokenizer.root();
        address[] memory hooks;
        bool allHookr;
        (allHookr, assets, hooks, canBlock) =
            _scan(tokenizer.positionManager(), root, tokenIds, extra, tokenizer.MAX_POSITIONS(), MAX_ASSETS);
        legBps = allHookr ? 0 : tokenizer.HOOKR_LEG_BPS_OUTSIDE();
        hookrPool = new bool[](hooks.length);
        for (uint256 i; i < hooks.length; ++i) {
            hookrPool[i] = hooks[i] == root;
        }
    }

    /// @notice `scanPositions`, and one `PositionReported` per NFT, emitted by the calling tokenizer (the delegatecall
    ///         keeps its address), so the creator's call records what the tokenizer read before the door is created.
    function reportPositions(
        address positionManager,
        address root,
        uint256[] calldata tokenIds,
        Currency[] calldata extra,
        uint256 maxPositions,
        uint256 maxAssets
    ) external returns (bool allHookr, Currency[] memory assets) {
        address[] memory hooks;
        bool[] memory canBlock;
        (allHookr, assets, hooks, canBlock) = _scan(positionManager, root, tokenIds, extra, maxPositions, maxAssets);
        for (uint256 i; i < hooks.length; ++i) {
            emit IHookrRevenueTokenizer.PositionReported(tokenIds[i], hooks[i], hooks[i] == root, canBlock[i]);
        }
    }

    function _scan(
        address positionManager,
        address root,
        uint256[] calldata tokenIds,
        Currency[] calldata extra,
        uint256 maxPositions,
        uint256 maxAssets
    ) private view returns (bool allHookr, Currency[] memory assets, address[] memory hooks, bool[] memory canBlock) {
        uint256 n = tokenIds.length;
        if (n == 0 || n > maxPositions) revert IHookrRevenueTokenizer.InvalidTerms();
        Currency[] memory list = new Currency[](1 + 2 * n + extra.length);
        list[0] = NATIVE;
        uint256 count = 1;
        hooks = new address[](n);
        canBlock = new bool[](n);
        allHookr = true;
        for (uint256 i; i < n; ++i) {
            (PoolKey memory key,) = IPositionManagerDoor(positionManager).getPoolAndPositionInfo(tokenIds[i]);
            if (key.currency1.isAddressZero()) revert IHookrRevenueTokenizer.InvalidTerms();
            address h = address(key.hooks);
            hooks[i] = h;
            if (h != root) {
                allHookr = false;
                canBlock[i] = (uint160(h) & REMOVE_LIQUIDITY_FLAGS) != 0;
            }
            count = _add(list, count, key.currency0);
            count = _add(list, count, key.currency1);
        }
        for (uint256 i; i < extra.length; ++i) {
            count = _add(list, count, extra[i]);
        }
        if (count > maxAssets) revert IHookrRevenueTokenizer.TooManyAssets(count);
        assets = new Currency[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = list[i];
        }
    }

    /// @notice Creates the door for `token` through `factory` on behalf of the calling creator (`msg.sender`, which the
    ///         delegatecall keeps), so the factory pulls the NFTs from the creator and the door records the creator as
    ///         each one's depositor; then checks the door is the factory's, names `token` and is active. First every
    ///         permit in `p.permits` is applied on `positionManager` for the factory: `permitForAll` for the creator,
    ///         or `permit` for its position, each in its own try, since a permit a front-runner already applied fails
    ///         on its nonce and has set the same approval. A missing approval fails the move itself.
    /// @dev The PositionManager verifies a permit as Permit2 does: a creator with code is asked through ERC-1271 and its
    ///      key is never tried, so an EIP-7702 creator whose code does not answer ERC-1271 approves the factory
    ///      (`setApprovalForAll`) instead of signing.
    function createDoor(
        address factory,
        address positionManager,
        address token,
        IHookrRevenueTokenizer.PositionTerms calldata p,
        bytes32 salt
    ) external returns (address door) {
        return _createDoor(factory, positionManager, token, p.tokenIds, p.permits, p.unlockAt, salt);
    }

    /// @notice `createDoor` for way (5), whose positions, permits and term arrive apart (StreamParams.positionIds,
    ///         `positionPermits`, `unlockAt`): the same permits, the same `createFor` on the creator's behalf, the
    ///         same checks.
    function createStreamDoor(
        address factory,
        address positionManager,
        address token,
        uint256[] calldata tokenIds,
        IHookrRevenueTokenizer.PositionPermit[] calldata permits,
        uint64 unlockAt,
        bytes32 salt
    ) external returns (address door) {
        return _createDoor(factory, positionManager, token, tokenIds, permits, unlockAt, salt);
    }

    function _createDoor(
        address factory,
        address positionManager,
        address token,
        uint256[] calldata tokenIds,
        IHookrRevenueTokenizer.PositionPermit[] calldata permits,
        uint64 unlockAt,
        bytes32 salt
    ) private returns (address door) {
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
        door = IHookrPositionNftDoorFactory(factory).createFor(msg.sender, token, tokenIds, unlockAt, salt);
        if (
            !IHookrPositionNftDoorFactory(factory).isDoor(door) || IHookrPositionNftDoor(door).revenueToken() != token
                || !IHookrPositionNftDoor(door).active()
        ) revert IHookrRevenueTokenizer.DoorMismatch(door);
    }

    function _add(Currency[] memory list, uint256 count, Currency c) private pure returns (uint256) {
        for (uint256 i; i < count; ++i) {
            if (list[i] == c) return count;
        }
        list[count] = c;
        return count + 1;
    }
}
