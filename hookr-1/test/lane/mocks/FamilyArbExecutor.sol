// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IHookrLaneRoot} from "../../../src/interfaces/IHookrLaneRoot.sol";

/// @notice Test-only family-aware executor. The triggering pool is a native-quote member A (ETH / S) of a family whose
///         sibling B (Q / S) and a hookless connector C (ETH / Q) close the cycle. While a cycle is profitable it runs one
///         fixed ETH chunk around it, entirely inside the unlock with flash accounting: ETH -> Q on C, Q -> S on B,
///         S -> ETH on A when S is cheaper on B; ETH -> S on A, S -> Q on B, Q -> ETH on C when S is cheaper on A. A
///         chunk that does not return more ETH than it spent is unwound on its own. Chunks halve on the first loss.
///         It keeps its partner share of the ETH profit and pushes the rest to the root.
contract FamilyArbExecutor {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    IPoolManager public immutable manager;
    address public immutable root;
    address public immutable partner;
    uint16 public immutable partnerBps;
    PoolKey internal _sibling;
    PoolKey internal _connector;
    Currency internal _subject;
    uint256 public firstChunk;
    uint256 public minChunk;
    uint256 public cycles;

    error NoOpportunity();
    error NotProfitable(uint256 spent, uint256 got);

    constructor(IPoolManager _manager, address _root, address _partner, uint16 _partnerBps) {
        manager = _manager;
        root = _root;
        partner = _partner;
        partnerBps = _partnerBps;
    }

    function configure(
        PoolKey calldata sibling,
        PoolKey calldata connector,
        Currency subject,
        uint256 first,
        uint256 min
    ) external {
        _sibling = sibling;
        _connector = connector;
        _subject = subject;
        firstChunk = first;
        minChunk = min;
    }

    function executeArbitrage(PoolKey calldata key, address) external returns (uint256 profit) {
        require(msg.sender == root, "root");
        uint256 before = uint256(manager.currencyDelta(address(this), Currency.wrap(address(0))));
        uint256 chunk = firstChunk;
        uint8 direction;
        for (uint256 i; i < 32 && chunk >= minChunk; ++i) {
            bool ok;
            if (direction != 2) {
                try this.cycle(key, true, chunk) {
                    ok = true;
                    direction = 1;
                } catch {}
            }
            if (!ok && direction != 1) {
                try this.cycle(key, false, chunk) {
                    ok = true;
                    direction = 2;
                } catch {}
            }
            if (ok) cycles++;
            else chunk /= 2;
        }
        int256 credit = manager.currencyDelta(address(this), Currency.wrap(address(0)));
        profit = uint256(credit) - before;
        if (profit == 0) revert NoOpportunity();
        uint256 share = profit * partnerBps / 10_000;
        uint256 pushed = profit - share;
        if (share != 0) manager.take(Currency.wrap(address(0)), partner, share);
        manager.mint(root, Currency.wrap(address(0)).toId(), pushed);
        IHookrLaneRoot(root).settleRecapture(key, Currency.wrap(address(0)), pushed);
    }

    /// @notice One chunk around the cycle, reverting unless it returns more ETH than it spent. Only this contract.
    function cycle(PoolKey calldata trigger, bool buyOnSibling, uint256 eth) external {
        require(msg.sender == address(this), "self");
        uint256 got;
        if (buyOnSibling) {
            uint256 q = _swapIn(_connector, Currency.wrap(address(0)), eth);
            uint256 s = _swapIn(_sibling, _other(_sibling, _subject), q);
            got = _swapIn(trigger, _subject, s);
        } else {
            uint256 s = _swapIn(trigger, Currency.wrap(address(0)), eth);
            uint256 q = _swapIn(_sibling, _subject, s);
            got = _swapIn(_connector, _other(_connector, Currency.wrap(address(0))), q);
        }
        if (got <= eth) revert NotProfitable(eth, got);
    }

    /// @dev Exact input `amount` of `input` on `key` at no price limit; returns the output. Deltas stay open.
    function _swapIn(PoolKey memory key, Currency input, uint256 amount) internal returns (uint256) {
        bool zeroForOne = input == key.currency0;
        BalanceDelta d =
            manager.swap(key, SwapParams(zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1), "");
        int128 out = zeroForOne ? d.amount1() : d.amount0();
        return uint256(uint128(out));
    }

    function _other(PoolKey memory key, Currency c) internal pure returns (Currency) {
        return key.currency0 == c ? key.currency1 : key.currency0;
    }
}
