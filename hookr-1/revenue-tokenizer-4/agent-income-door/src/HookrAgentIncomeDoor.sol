// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrForwarding} from "hookrevenue/base/HookrForwarding.sol";
import {HookrForward} from "hookrevenue/libraries/HookrForward.sol";
import {IHookrRevenueDoor} from "hookrevenue/interfaces/IHookrRevenueDoor.sol";
import {IHookrRevenueSource} from "hookrevenue/interfaces/IHookrRevenueSource.sol";
import {IHookrRevenueToken} from "hookrevenue/interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueTokenizer} from "hookrevenue/interfaces/IHookrRevenueTokenizer.sol";
import {EndKind} from "hookrevenue/types/EndKind.sol";
import {IHookrAgentIncomeDoor} from "./interfaces/IHookrAgentIncomeDoor.sol";

/// @title Hookr agent income door
/// @notice The address an ERC-8004 agent is paid at. Native ETH and the ERC-20s the door names arrive by plain
///         transfer and wait here; every sync of the revenue token forwards all of it to the token, which counts it
///         as this door's income and takes Hookr's leg of it. See IHookrAgentIncomeDoor.
/// @dev All state is immutable. The forward of each currency is HookrForwarding's, the one every door of the
///      tokenizer uses: native ETH and a currency the token lists go to the token whole (the token's sync measures
///      the leg around the pull); a named ERC-20 the token does not list goes into the token's drop box less the leg.
///      Any other ERC-20 sent here by mistake is moved the same way by `dropStray`, which anyone may call.
///
///      `pull` takes calls from the revenue token alone and only from a token the pinned tokenizer minted, and
///      `dropStray` moves nothing before that mint, so a door never pays a contract that merely answers like a
///      revenue token, nor that contract's "drop box".
///
///      Known limits, as for every door of the tokenizer (IHookrForwarding): a named ERC-20 that is itself a revenue
///      token earns income while it waits here, and no door has a call that claims it; and Hookr's leg on a named
///      ERC-20 the token does not list is paid by a capped transfer, so a currency that refuses the leg collector
///      pays no leg and the amount goes on to the holders with later pulls.
contract HookrAgentIncomeDoor is IHookrAgentIncomeDoor, HookrForwarding {
    /// @inheritdoc IHookrAgentIncomeDoor
    bytes32 public constant SOURCE_KIND = keccak256("hookr.agent.income");
    /// @inheritdoc IHookrAgentIncomeDoor
    uint256 public constant MAX_TOKENS = 2;
    /// @dev The most gas the native forward takes: the send's `SEND_GAS` with the 64/63 that makes it available,
    ///      and the door's work around it.
    uint256 private constant NATIVE_ITEM_GAS = 100_000;
    /// @dev The pull's own work outside the forwards: the admission read with its `BALANCE_GAS` cap, the lock and
    ///      the loop.
    uint256 private constant PULL_BASE_GAS = 150_000;

    /// @inheritdoc IHookrAgentIncomeDoor
    address public immutable factory;
    /// @inheritdoc IHookrAgentIncomeDoor
    address public immutable tokenizer;
    /// @inheritdoc IHookrAgentIncomeDoor
    address public immutable agentRegistry;
    /// @inheritdoc IHookrAgentIncomeDoor
    uint256 public immutable agentId;
    uint256 private immutable _tokenCount;
    address private immutable _token0;
    address private immutable _token1;
    uint32 private immutable _pullGas;

    /// @param tokenizer_ The HookRevenue Tokenizer whose tokens this door pays; must have code.
    /// @param agentRegistry_ The ERC-8004 identity registry; must have code.
    /// @param revenueToken_ The revenue token every pull pays; nonzero. It may not exist yet.
    /// @param agentId_ The agent whose income this is.
    /// @param tokens The ERC-20s forwarded beside native ETH: at most `MAX_TOKENS`, each with code, each once, none
    ///        the revenue token.
    constructor(
        address tokenizer_,
        address agentRegistry_,
        address revenueToken_,
        uint256 agentId_,
        address[] memory tokens
    ) HookrForwarding(revenueToken_) {
        uint256 n = tokens.length;
        if (tokenizer_.code.length == 0 || agentRegistry_.code.length == 0 || n > MAX_TOKENS) revert InvalidConfig();
        for (uint256 i; i < n; ++i) {
            address token = tokens[i];
            if (token == revenueToken_ || token.code.length == 0 || (i == 1 && token == tokens[0])) {
                revert InvalidConfig();
            }
        }
        factory = msg.sender;
        tokenizer = tokenizer_;
        agentRegistry = agentRegistry_;
        agentId = agentId_;
        _tokenCount = n;
        _token0 = n > 0 ? tokens[0] : address(0);
        _token1 = n > 1 ? tokens[1] : address(0);
        _pullGas = uint32(PULL_BASE_GAS + NATIVE_ITEM_GAS + n * FORWARD_ITEM_GAS);
    }

    /// @notice Takes native ETH from anyone; it waits here for the next sync.
    receive() external payable {}

    /// @inheritdoc IHookrRevenueSource
    function sourceKind() external pure returns (bytes32) {
        return SOURCE_KIND;
    }

    /// @inheritdoc IHookrRevenueSource
    function label() external pure returns (string memory) {
        return "Agent income";
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev Whether the pinned tokenizer minted `revenueToken`. The tokenizer records a token before it checks the
    ///      token's sources, so the pinned tokenizer reads true while it adds the door, at the mint or later, and a
    ///      token of any other tokenizer cannot add the door at all (`SourceNotBound` there). It says nothing about
    ///      where the agent's payments go, which is not readable on chain; `ends()` says that.
    function bound() external view returns (bool) {
        return _minted();
    }

    /// @inheritdoc IHookrRevenueDoor
    /// @dev `REVOCABLE` with no date, for good: the agent can point its payments elsewhere at any time, with no
    ///      notice and no trace here.
    function ends() external pure returns (EndKind, uint64) {
        return (EndKind.REVOCABLE, 0);
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev The whole of one pull: the pull's own work, the native forward and `FORWARD_ITEM_GAS` for each ERC-20.
    function pullGas() external view returns (uint32) {
        return _pullGas;
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev Native ETH first, then the door's ERC-20s.
    function assets() external view returns (Currency[] memory list) {
        uint256 n = _tokenCount;
        list = new Currency[](n + 1);
        if (n > 0) list[1] = Currency.wrap(_token0);
        if (n > 1) list[2] = Currency.wrap(_token1);
    }

    /// @inheritdoc IHookrRevenueSource
    /// @dev What the door holds of native ETH and of each of its ERC-20s the token lists now.
    function pendingIncome() external view returns (Currency[] memory, uint256[] memory) {
        uint256[3] memory none;
        return _income([address(0), _token0, _token1], none, _tokenCount + 1);
    }

    /// @inheritdoc IHookrAgentIncomeDoor
    function admitted() external view returns (bool) {
        if (!_minted()) return false;
        (bool read, uint256 isDoor) =
            HookrForward.read(revenueToken, abi.encodeCall(IHookrRevenueToken.isDoor, (address(this))), BALANCE_GAS);
        return read && isDoor == 1;
    }

    /// @inheritdoc IHookrRevenueDoor
    /// @dev Forwards everything the door holds, native ETH first. Each currency is its own capped attempt and none
    ///      reverts the pull; a currency there is too little gas left for waits for the next pull.
    function pull() external onlyRevenueToken nonReentrant {
        if (!_minted()) revert NotAdmitted();
        if (gasleft() < NATIVE_ITEM_GAS) return;
        _forwardHeld(address(0));
        uint256 n = _tokenCount;
        for (uint256 i; i < n; ++i) {
            if (gasleft() < FORWARD_ITEM_GAS) return;
            _forwardHeld(i == 0 ? _token0 : _token1);
        }
    }

    /// @dev Whether the pinned tokenizer minted `revenueToken`: its record of the token names a creator. Read with
    ///      `BALANCE_GAS` and required to answer the record's four words.
    function _minted() private view returns (bool ok) {
        bytes memory data = abi.encodeCall(IHookrRevenueTokenizer.tokenizations, (revenueToken));
        address pinned = tokenizer;
        uint256 cap = BALANCE_GAS;
        uint256 creator;
        assembly ("memory-safe") {
            let p := mload(0x40)
            ok := staticcall(cap, pinned, add(data, 0x20), mload(data), p, 0x80)
            ok := and(ok, eq(returndatasize(), 0x80))
            creator := mul(mload(p), ok)
        }
        return ok && creator != 0 && creator >> 160 == 0;
    }

    /// @dev The door's own currencies, which only the token's pull moves: its ERC-20s (native ETH is refused by
    ///      `dropStray` itself). `dropStray` asks this before it moves anything, and it is the base's one seam, so
    ///      the admission rule of `pull` is applied here too: nothing leaves a door, by either way out, until the
    ///      pinned tokenizer has minted its token (`NotAdmitted`).
    function _isOwnAsset(address asset) internal view override returns (bool) {
        if (!_minted()) revert NotAdmitted();
        return _tokenCount != 0 && (asset == _token0 || (_tokenCount > 1 && asset == _token1));
    }
}
