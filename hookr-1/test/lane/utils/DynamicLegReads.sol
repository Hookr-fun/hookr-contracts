// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrToken} from "../../../src/support/HookrToken.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../../src/interfaces/IHookrRouter.sol";
import {HookrRules} from "../../../src/core/HookrRules.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {Actor} from "../mocks/Actors.sol";

/// @notice Reads of a pool's dynamic fee state and the ordinary trades the legs are held against.
abstract contract DynamicLegReads is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @dev HookrRules' storage root (erc7201:hookr.rules); `dynamicFee` is the State struct's fifth mapping.
    uint256 internal constant RULES_SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    /// @dev IHookrLaneRules.carryLeg, by its signature, so this file also compiles against a tree without it.
    bytes4 internal constant CARRY_LEG = bytes4(
        keccak256(
            "carryLeg((bytes32,address,address,address,address,address,bool,bool,bool,bool,int256,uint160,uint24),(uint160,int24,uint160,int24),uint256)"
        )
    );

    struct LegSwap {
        uint160 sqrtPrice;
        int24 tick;
        int128 amount0;
        int128 amount1;
    }

    /// @dev The pool's whole dynamic fee word in the Rules: minimum liquidity, reference, anchor, moved tick, moved and
    ///      reference times and the started flag.
    function _word(PoolKey memory key) internal view returns (bytes32) {
        return vm.load(address(rules), keccak256(abi.encode(key.toId(), RULES_SLOT + 4)));
    }

    function _anchorTick(PoolKey memory key) internal view returns (int24 anchor) {
        (,, anchor,,,) = rules.referenceState(key.toId());
    }

    /// @dev The executor's swaps on `key` in `logs`, in order: each one's end price and tick and its delta.
    function _legSwaps(Vm.Log[] memory logs, PoolKey memory key, address executor)
        internal
        pure
        returns (LegSwap[] memory out)
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (_isLeg(logs[i], key, executor)) ++n;
        }
        out = new LegSwap[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (!_isLeg(logs[i], key, executor)) continue;
            (int128 a0, int128 a1, uint160 p,, int24 t,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            out[n++] = LegSwap(p, t, a0, a1);
        }
    }

    function _isLeg(Vm.Log memory l, PoolKey memory key, address executor) private pure returns (bool) {
        return l.topics.length == 3 && l.topics[0] == SWAP_EVENT && l.topics[1] == PoolId.unwrap(key.toId())
            && l.topics[2] == bytes32(uint256(uint160(executor)));
    }

    /// @dev An ordinary authenticated router swap by a fresh actor that carries `key` to `target` (its price limit),
    ///      paying every rule the pool charges.
    function _ordinaryTo(PoolKey memory key, uint160 target) internal {
        (uint160 now_,,,) = manager.getSlot0(key.toId());
        if (now_ == target) return;
        bool zeroForOne = target < now_;
        Currency quote = _poolQuote(key);
        bool buy = zeroForOne == (quote == key.currency0);
        Actor who = _newActor();
        address sub = Currency.unwrap(_subjectOf(key));
        uint256 held = HookrToken(sub).balanceOf(address(this));
        if (held > 1e26) held = 1e26;
        HookrToken(sub).transfer(address(who), held);
        who.approveAll(sub);
        bool native = (zeroForOne ? key.currency0 : key.currency1).isAddressZero();
        uint256 amount = native ? 1e27 : buy ? 1e26 : held;
        IHookrRouter.Swap memory p = _swapParams(key, quote, buy, true, amount, address(who));
        p.sqrtPriceLimitX96 = target;
        who.routerSwap(p, native ? amount : 0);
        (uint160 reached,,,) = manager.getSlot0(key.toId());
        assertEq(reached, target, "the ordinary trade reached the leg's price");
    }

    /// @dev The Rules' ordinary path for one swap, run as the root: `quoteSimulatedSwap` on `m` (the reference's steps,
    ///      the start of an unstarted state, the lag), then `settleSwap` with `quoteAmount` as the actual quote and no
    ///      charge (the anchor's move). The pool must stand at the swap's end. One call, so the transient lag carries
    ///      from the quote to the settlement as inside a swap.
    function ordinaryModel(HookrTypes.SwapContext calldata x, HookrTypes.SwapSimulation calldata m, uint256 quoteAmount)
        external
    {
        require(msg.sender == address(this), "self");
        vm.prank(address(root));
        rules.quoteSimulatedSwap(x, m);
        HookrTypes.Settlement memory z;
        z.actualQuote = quoteAmount;
        vm.prank(address(root));
        rules.settleSwap(x, z);
    }

    /// @dev The dynamic fee word an ordinary swap from `before` to the leg's end with the leg's quote leaves, from the
    ///      word `start` the leg found. Leaves the Rules' word as it found it.
    function _modelWord(
        PoolKey memory key,
        address executor,
        bytes32 start,
        HookrTypes.SwapSimulation memory m,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 quoteAmount
    ) internal returns (bytes32 modelled) {
        bytes32 slot = keccak256(abi.encode(key.toId(), RULES_SLOT + 4));
        bytes32 legWord = vm.load(address(rules), slot);
        vm.store(address(rules), slot, start);
        Currency quote = _poolQuote(key);
        bool quoteIs0 = quote == key.currency0;
        HookrTypes.SwapContext memory x = HookrTypes.SwapContext({
            id: key.toId(),
            sender: executor,
            payer: executor,
            beneficiary: executor,
            subject: quoteIs0 ? key.currency1 : key.currency0,
            quote: quote,
            authenticated: false,
            isBuy: zeroForOne == quoteIs0,
            exactInput: amountSpecified < 0,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 2 : TickMath.MAX_SQRT_PRICE - 2,
            baseLpFeePips: BASE_FEE
        });
        this.ordinaryModel(x, m, quoteAmount);
        modelled = vm.load(address(rules), slot);
        vm.store(address(rules), slot, legWord);
    }
}
