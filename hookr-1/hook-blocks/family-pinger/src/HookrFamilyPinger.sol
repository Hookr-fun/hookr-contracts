// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {IHookrZapAccrual} from "zap-relay/interfaces/IHookrZapAccrual.sol";
import {IHookrZapMeshAccrual} from "zap-mesh/interfaces/IHookrZapMeshAccrual.sol";
import {IHookrFeeBridgeFactory} from "fee-bridge/interfaces/IHookrFeeBridge.sol";
import {IHookrFamilyPinger, IHookrFamilyPingerFactory} from "./interfaces/IHookrFamilyPinger.sol";

/// @notice The calls a pinger makes. What a zap, drip or payout returns is read word by word (at most REASON_BYTES of
///         it) to tell real work from a call that moved nothing: a vault's or mesh's ZapResult, a bridge's
///         (donated, tip) and a payout's amount.
interface IPingable {
    function ready() external view returns (bool);
    function zap(address rewardTo) external;
    function drip(address tipTo) external returns (uint256 donated, uint256 tip);
    function record() external;
    function protocolOwed() external view returns (uint256);
    function payProtocol() external returns (uint256 amount);
    function maxPerDrip() external view returns (uint128);
}

/// @title Hookr family pinger
/// @notice One contract per family that runs every action that is due in one call: a zap vault or zap mesh that is
///         ready, a fee bridge drip (or the liquidity record a later drip needs), Hookr's set-aside protocol share.
///         The vaults' and bridges' own caller rewards go to the caller's `rewardTo`, and when an action did real work
///         (a zap that deployed quote, a drip that donated at least 1% of its bridge's maxPerDrip, a protocol payout
///         that paid something) the pinger adds its own tip from a native budget, at most once every minBlocks.
/// @dev No owner, no admin: the action list, tip, spacing and gas are immutable. The factory admits only vaults the
///      Zap Relay accrual made, meshes the Zap Mesh accrual made and bridges the fee bridge factory made, so every
///      action is Hookr code, and the pinger reads what each returns to decide whether it worked. Each action runs on
///      its own: it gets exactly gasPerAction or does not run (the pinger stops before an action it cannot give that
///      much, after its readiness read too), at most REASON_BYTES of what it returns or reverts with is copied back,
///      and a failing action is skipped, never blocking the rest. Funded by plain sends or as a royalty payee
///      (collect).
contract HookrFamilyPinger is HookrReleased, IHookrFamilyPinger {
    uint8 internal constant KIND_ZAP = 0;
    uint8 internal constant KIND_DRIP = 1;
    uint8 internal constant KIND_PROTOCOL = 2;
    /// @dev Gas held back for the pinger's own bookkeeping after the last action.
    uint256 private constant RESERVE = 60_000;
    /// @dev Gas a readiness read gets.
    uint256 private constant READ_GAS = 300_000;
    /// @dev Gas kept on top of an action's own: the call itself, reading what it returned (with the drip floor) and
    ///      logging a failure.
    uint256 private constant RUN_MARGIN = 20_000;
    /// @dev Most bytes of an action's return or revert data the pinger copies (and logs in ActionFailed).
    uint256 private constant REASON_BYTES = 256;
    /// @dev Gas the drip floor's maxPerDrip() read gets.
    uint256 private constant FLOOR_READ_GAS = 10_000;
    /// @dev A drip earns the tip when it donates at least 1 / DRIP_FLOOR_DIVISOR of its bridge's maxPerDrip.
    uint256 private constant DRIP_FLOOR_DIVISOR = 100;
    /// @dev Words of the ZapResults: a vault's spent and addedQuote, a mesh's deployed.
    uint256 private constant VAULT_SPENT = 2;
    uint256 private constant VAULT_ADDED_QUOTE = 5;
    uint256 private constant MESH_DEPLOYED = 3;
    uint8 private constant IDLE = 1;
    uint8 private constant BUSY = 2;

    /// @inheritdoc IHookrFamilyPinger
    address public immutable factory;
    /// @inheritdoc IHookrFamilyPinger
    uint128 public immutable tip;
    /// @inheritdoc IHookrFamilyPinger
    uint32 public immutable minBlocks;
    /// @inheritdoc IHookrFamilyPinger
    uint32 public immutable gasPerAction;
    /// @dev Bit i set when action i is a ZAP on a mesh, whose ZapResult has its own shape.
    uint256 private immutable _meshes;

    uint8 private _lock = IDLE;
    /// @inheritdoc IHookrFamilyPinger
    uint64 public lastTipBlock;
    Action[] private _actions;

    /// @dev Made only by HookrFamilyPingerFactory, which checks every action. Which ZAP targets are meshes is asked of
    ///      the factory's mesh accrual here rather than passed in, so the init code (and the factory's predict) never
    ///      depends on whether the targets exist yet; a deployer without one marks none.
    constructor(Action[] memory list, uint128 tip_, uint32 minBlocks_, uint32 gasPerAction_) {
        factory = msg.sender;
        tip = tip_;
        minBlocks = minBlocks_;
        gasPerAction = gasPerAction_;
        (bool known, uint256 accrual) =
            _word(msg.sender, abi.encodeCall(IHookrFamilyPingerFactory.meshAccrual, ()), READ_GAS);
        known = known && accrual != 0 && accrual >> 160 == 0;
        uint256 meshes;
        for (uint256 i; i < list.length; ++i) {
            _actions.push(list[i]);
            if (!known || list[i].kind != KIND_ZAP) continue;
            (bool ok, uint256 isMesh) = _word(
                // accrual >> 160 == 0, checked above.
                // forge-lint: disable-next-line(unsafe-typecast)
                address(uint160(accrual)),
                abi.encodeCall(IHookrZapMeshAccrual.meshRecord, (list[i].target)),
                READ_GAS
            );
            if (ok && isMesh == 1) meshes |= _bit(i);
        }
        _meshes = meshes;
    }

    /// @inheritdoc IHookrFamilyPinger
    function actions() external view returns (Action[] memory) {
        return _actions;
    }

    /// @inheritdoc IHookrFamilyPinger
    function due() external view returns (uint256 mask) {
        uint256 n = _actions.length;
        for (uint256 i; i < n; ++i) {
            Action memory a = _actions[i];
            if (a.kind == KIND_PROTOCOL ? _owed(a.target) : _ready(a.target)) mask |= _bit(i);
        }
    }

    /// @inheritdoc IHookrFamilyPinger
    function ping(address rewardTo) external returns (uint256 ran) {
        if (_lock != IDLE) revert Reentered();
        _lock = BUSY;
        if (rewardTo == address(0) || rewardTo == address(this)) revert InvalidRewardRecipient(rewardTo);
        bool paid;
        uint256 n = _actions.length;
        // What an action needs when it is about to run: its whole gasPerAction past the 63/64 rule, the margin for
        // the call and reading its result, and the bookkeeping after the last action.
        uint256 runGas = uint256(gasPerAction) * 64 / 63 + RUN_MARGIN + RESERVE;
        for (uint256 i; i < n; ++i) {
            if (gasleft() < uint256(gasPerAction) + READ_GAS + RESERVE) break;
            Action memory a = _actions[i];
            bytes memory call;
            // A record (a bridge not ready yet) keeps the family moving but is no work to tip.
            bool tippable = true;
            if (a.kind == KIND_PROTOCOL) {
                if (!_owed(a.target)) continue;
                call = abi.encodeCall(IPingable.payProtocol, ());
            } else if (_ready(a.target)) {
                call = a.kind == KIND_ZAP
                    ? abi.encodeCall(IPingable.zap, (rewardTo))
                    : abi.encodeCall(IPingable.drip, (rewardTo));
            } else if (a.kind == KIND_DRIP) {
                // Not ready: the record a drip in a later block needs (once per block; it returns false otherwise).
                call = abi.encodeCall(IPingable.record, ());
                tippable = false;
            } else {
                continue;
            }
            // A costly readiness read can leave less than the action's whole budget: stop rather than run it short.
            if (gasleft() < runGas) break;
            (bool ok, bytes memory out) = _run(a.target, call);
            if (ok) {
                ran |= _bit(i);
                if (tippable && !paid) paid = _worked(a, i, out);
            } else {
                // i < MAX_ACTIONS (8).
                // forge-lint: disable-next-line(unsafe-typecast)
                emit ActionFailed(uint8(i), out);
            }
        }
        uint256 paidTip;
        if (
            paid && tip != 0 && address(this).balance >= tip
                && (lastTipBlock == 0 || block.number >= uint256(lastTipBlock) + minBlocks)
        ) {
            // block.number fits uint64 for the life of any chain.
            // forge-lint: disable-next-line(unsafe-typecast)
            lastTipBlock = uint64(block.number);
            paidTip = tip;
            (bool sent,) = rewardTo.call{value: paidTip}("");
            if (!sent) revert InvalidRewardRecipient(rewardTo);
        }
        emit Pinged(msg.sender, rewardTo, ran, paidTip);
        _lock = IDLE;
    }

    /// @inheritdoc IHookrFamilyPinger
    function collect(address rules) external returns (uint256 amount) {
        if (_lock != IDLE) revert Reentered();
        Currency native = Currency.wrap(address(0));
        if (IHookrRules(rules).claimable(native, address(this)) == 0) return 0;
        _lock = BUSY;
        uint256 before = address(this).balance;
        IHookrRules(rules).claim(native);
        amount = address(this).balance - before;
        _lock = IDLE;
    }

    /// @notice The tip budget: native from anyone, writing nothing, so a royalty or tax pays in full.
    receive() external payable {}

    /// @dev Calls `target` with exactly gasPerAction and copies back at most REASON_BYTES of what it returned or
    ///      reverted with, so neither a returndata bomb nor a large honest revert costs the pinger more than that.
    function _run(address target, bytes memory data) private returns (bool ok, bytes memory out) {
        uint256 gasLimit = gasPerAction;
        uint256 most = REASON_BYTES;
        assembly ("memory-safe") {
            ok := call(gasLimit, target, 0, add(data, 0x20), mload(data), 0, 0)
            let size := returndatasize()
            if gt(size, most) { size := most }
            out := mload(0x40)
            mstore(out, size)
            returndatacopy(add(out, 0x20), 0, size)
            mstore(0x40, add(add(out, 0x20), and(add(size, 0x1f), not(0x1f))))
        }
    }

    /// @dev Whether an action that returned did real work, from what it returned. A target that returns less than the
    ///      words read did none as far as the pinger can tell. A drip must donate at least 1 / DRIP_FLOOR_DIVISOR of
    ///      its bridge's own maxPerDrip, which funding a bridge with dust cannot meet.
    function _worked(Action memory a, uint256 i, bytes memory out) private view returns (bool) {
        if (a.kind == KIND_PROTOCOL) return _at(out, 0) != 0;
        if (a.kind == KIND_DRIP) {
            uint256 donated = _at(out, 0);
            if (donated == 0 || out.length < 64) return false;
            (bool ok, uint256 cap) = _word(a.target, abi.encodeCall(IPingable.maxPerDrip, ()), FLOOR_READ_GAS);
            return ok && donated >= cap / DRIP_FLOOR_DIVISOR;
        }
        if (_meshes & _bit(i) != 0) return _at(out, MESH_DEPLOYED) != 0;
        return _at(out, VAULT_SPENT) != 0 || _at(out, VAULT_ADDED_QUOTE) != 0;
    }

    /// @dev Word `k` of `out`, or zero when `out` is shorter.
    function _at(bytes memory out, uint256 k) private pure returns (uint256 value) {
        if (out.length < (k + 1) * 32) return 0;
        assembly ("memory-safe") {
            value := mload(add(add(out, 0x20), mul(k, 0x20)))
        }
    }

    /// @dev A static call that reads one word back: ok only when it succeeded and returned at least 32 bytes. Only that
    ///      word is copied, whatever the target returns.
    function _word(address target, bytes memory data, uint256 gasLimit) private view returns (bool ok, uint256 value) {
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(data, 0x20), mload(data), 0, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            value := mload(0)
        }
    }

    function _ready(address target) private view returns (bool) {
        (bool ok, uint256 value) = _word(target, abi.encodeCall(IPingable.ready, ()), READ_GAS);
        return ok && value == 1;
    }

    function _owed(address target) private view returns (bool) {
        (bool ok, uint256 value) = _word(target, abi.encodeCall(IPingable.protocolOwed, ()), READ_GAS);
        return ok && value != 0;
    }

    function _bit(uint256 i) private pure returns (uint256) {
        return 2 ** i;
    }
}

/// @title Hookr family pinger factory
/// @notice Makes pingers at CREATE2 addresses keyed by (creator, salt), admitting only Hookr's own actions.
contract HookrFamilyPingerFactory is HookrReleased, IHookrFamilyPingerFactory {
    uint8 internal constant KIND_ZAP = 0;
    uint8 internal constant KIND_DRIP = 1;
    uint8 internal constant KIND_PROTOCOL = 2;
    /// @notice Most actions one pinger runs.
    uint256 public constant MAX_ACTIONS = 8;
    /// @notice Least and most gas an action may get.
    uint32 public constant MIN_GAS_PER_ACTION = 150_000;
    uint32 public constant MAX_GAS_PER_ACTION = 5_000_000;
    /// @notice Most blocks a pinger may require between tipped pings.
    uint32 public constant MAX_MIN_BLOCKS = 100_000;

    /// @inheritdoc IHookrFamilyPingerFactory
    address public immutable zapAccrual;
    /// @inheritdoc IHookrFamilyPingerFactory
    address public immutable meshAccrual;
    /// @inheritdoc IHookrFamilyPingerFactory
    address public immutable bridgeFactory;
    /// @inheritdoc IHookrFamilyPingerFactory
    mapping(address pinger => bool) public isPinger;

    constructor(address zapAccrual_, address meshAccrual_, address bridgeFactory_) {
        zapAccrual = zapAccrual_;
        meshAccrual = meshAccrual_;
        bridgeFactory = bridgeFactory_;
    }

    /// @inheritdoc IHookrFamilyPingerFactory
    /// @dev Codes: 1 action count; 2 gas per action; 3 minBlocks.
    function create(
        IHookrFamilyPinger.Action[] calldata list,
        uint128 tip,
        uint32 minBlocks,
        uint32 gasPerAction,
        bytes32 salt
    ) external returns (address pinger) {
        _check(list, minBlocks, gasPerAction);
        pinger = address(new HookrFamilyPinger{salt: _salt(msg.sender, salt)}(list, tip, minBlocks, gasPerAction));
        isPinger[pinger] = true;
        emit PingerCreated(pinger, msg.sender, list.length, tip);
    }

    /// @inheritdoc IHookrFamilyPingerFactory
    function predict(
        address creator,
        IHookrFamilyPinger.Action[] calldata list,
        uint128 tip,
        uint32 minBlocks,
        uint32 gasPerAction,
        bytes32 salt
    ) external view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(HookrFamilyPinger).creationCode, abi.encode(list, tip, minBlocks, gasPerAction))
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(creator, salt), initHash))))
        );
    }

    function _check(IHookrFamilyPinger.Action[] calldata list, uint32 minBlocks, uint32 gasPerAction) private view {
        if (list.length == 0 || list.length > MAX_ACTIONS) revert InvalidPinger(1);
        if (gasPerAction < MIN_GAS_PER_ACTION || gasPerAction > MAX_GAS_PER_ACTION) revert InvalidPinger(2);
        if (minBlocks > MAX_MIN_BLOCKS) revert InvalidPinger(3);
        for (uint256 i; i < list.length; ++i) {
            address t = list[i].target;
            uint8 kind = list[i].kind;
            bool known;
            if (kind == KIND_ZAP || kind == KIND_PROTOCOL) {
                known = _isVault(t) || _isMesh(t);
            } else if (kind == KIND_DRIP) {
                known = bridgeFactory != address(0) && IHookrFeeBridgeFactory(bridgeFactory).isBridge(t);
            }
            if (!known) revert InvalidAction(i);
            for (uint256 j; j < i; ++j) {
                if (list[j].target == t && list[j].kind == kind) revert InvalidAction(i);
            }
        }
    }

    function _isVault(address t) private view returns (bool exists) {
        if (zapAccrual == address(0)) return false;
        (exists,,) = IHookrZapAccrual(zapAccrual).vaultRecord(t);
    }

    function _isMesh(address t) private view returns (bool) {
        return meshAccrual != address(0) && IHookrZapMeshAccrual(meshAccrual).meshRecord(t);
    }

    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
