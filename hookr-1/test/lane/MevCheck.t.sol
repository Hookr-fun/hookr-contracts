// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLaneExecutor} from "../../src/interfaces/callback/IHookrLaneExecutor.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @notice A lane executor whose MEV view answers as scripted and whose arb recapture does nothing.
contract MevExecutor {
    enum Answer {
        FALSE,
        TRUE,
        REVERT,
        TWO_WORDS,
        TWO,
        SHORT,
        BURN,
        TRUE_ONE_FOR_ZERO,
        TRUE_IF_ABOVE_197400,
        TRUE_IF_ABOVE_200000
    }

    address public immutable root;
    Answer public answer;

    constructor(address r) {
        root = r;
    }

    function set(Answer a) external {
        answer = a;
    }

    function executeArbitrage(PoolKey calldata, address) external view returns (uint256) {
        require(msg.sender == root, "root");
        return 0;
    }

    function checkV3PoolsMev(address, address, address, bool zeroForOne) external view returns (bool) {
        uint256 g = gasleft();
        Answer a = answer;
        if (a == Answer.TRUE_IF_ABOVE_197400) return g > 197_400;
        if (a == Answer.TRUE_IF_ABOVE_200000) return g > 200_000;
        if (a == Answer.TRUE) return true;
        // True only for a swap of currency1 in and currency0 out: one direction refused, the other let through.
        if (a == Answer.TRUE_ONE_FOR_ZERO) return !zeroForOne;
        if (a == Answer.REVERT) revert("no");
        if (a == Answer.BURN) {
            uint256 i;
            while (true) {
                unchecked {
                    ++i;
                }
            }
        }
        assembly ("memory-safe") {
            switch a
            case 3 {
                mstore(0, 1)
                mstore(32, 1)
                return(0, 64)
            }
            case 4 {
                mstore(0, 2)
                return(0, 32)
            }
            case 5 {
                mstore(0, 0x0100000000000000000000000000000000000000000000000000000000000000)
                return(0, 1)
            }
        }
        return false;
    }
}

/// @notice The same executor with other code, answering true: what a lane whose executor changed would reach.
contract ChangedMevExecutor {
    function executeArbitrage(PoolKey calldata, address) external pure returns (uint256) {
        return 7;
    }

    function checkV3PoolsMev(address, address, address, bool) external pure returns (bool) {
        return true;
    }
}

/// @notice An executor with only the older three-argument view, `checkV3PoolsMev(address,address,address)`,
///         answering true. The root asks the four-argument view, which it does not have.
contract ThreeArgumentMevExecutor {
    function executeArbitrage(PoolKey calldata, address) external pure returns (uint256) {
        return 0;
    }

    function checkV3PoolsMev(address, address, address) external pure returns (bool) {
        return true;
    }
}

/// @notice On every outer swap of a lane pool the root asks the pool's frozen executor, right after the
///         before-phase call, whether the swap is closing an arbitrage inside a v3 pool's callback
///         (`checkV3PoolsMev(subject, quote, swapper, zeroForOne)`, 0x9e97c424, staticcall, at most 200,000 gas;
///         `zeroForOne` the swap's direction on the pool in its key's order). A clean single true word
///         refuses the swap (MevCallbackRefused); anything else, an executor without the four-argument view
///         included, lets it go on. A braked or changed executor, the executor's own legs and a pool's creation
///         transaction are never asked.
contract MevCheckTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes4 internal constant MEV_CHECK = 0x9e97c424;
    MevExecutor internal ex;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        ex = new MevExecutor(address(root));
        _openLane(address(ex));
        key = _openKoth(ETH);
        _nextBlock();
    }

    function buyExt(PoolKey memory k, uint256 amount) external returns (uint256) {
        require(msg.sender == address(this));
        return _buy(k, ETH, whale, amount);
    }

    function sellExt(PoolKey memory k, uint256 amount) external returns (uint256) {
        require(msg.sender == address(this));
        return _sell(k, ETH, whale, amount);
    }

    function _contains(bytes memory data, bytes memory needle) internal pure returns (bool) {
        if (data.length < needle.length) return false;
        for (uint256 i; i + needle.length <= data.length; ++i) {
            bool hit = true;
            for (uint256 j; j < needle.length; ++j) {
                if (data[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    function _refusal(PoolKey memory k) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRootState.MevCallbackRefused.selector, k.currency1, k.currency0);
    }

    function test_theSelectorIsCheckV3PoolsMevWithTheDirection() public pure {
        assertEq(MEV_CHECK, bytes4(keccak256("checkV3PoolsMev(address,address,address,bool)")));
        assertEq(MEV_CHECK, IHookrLaneExecutor.checkV3PoolsMev.selector, "the root's interface");
        assertTrue(MEV_CHECK != bytes4(keccak256("checkV3PoolsMev(address,address,address)")), "three-argument view");
    }

    /// A clean true refuses the swap, a buy and a sell alike: it reverts with MevCallbackRefused(subject, quote),
    /// wrapped by the PoolManager.
    function test_aCleanTrueRefusesTheSwap() public {
        ex.set(MevExecutor.Answer.TRUE);
        uint256 before = whale.balance;
        try this.buyExt(key, 1e18) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, _refusal(key)), "buy: MevCallbackRefused(subject, quote)");
        }
        assertEq(whale.balance, before, "nothing moved");
        try this.sellExt(key, 1e18) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, _refusal(key)), "sell: MevCallbackRefused(subject, quote)");
        }
        assertEq(whale.balance, before, "nothing moved");
    }

    /// A buy on an ETH pool (ETH, the key's currency0, in): the root asks once, with the subject, the quote, the caller
    /// of PoolManager.swap (the router here) and zeroForOne true, and the swap goes on when the answer is false.
    function test_aBuyIsAskedOnceWithSubjectQuoteSwapperAndZeroForOne() public {
        assertTrue(key.currency0.isAddressZero(), "ETH is currency0");
        vm.expectCall(
            address(ex), abi.encodeWithSelector(MEV_CHECK, key.currency1, key.currency0, address(router), true), 1
        );
        vm.expectCall(
            address(ex), abi.encodeWithSelector(MEV_CHECK, key.currency1, key.currency0, address(router), false), 0
        );
        assertGt(_buy(key, ETH, whale, 1e18), 0, "the swap went on");
    }

    /// A sell on an ETH pool (the subject, currency1, in): the root asks once with zeroForOne false.
    function test_aSellIsAskedOnceWithZeroForOneFalse() public {
        vm.expectCall(
            address(ex), abi.encodeWithSelector(MEV_CHECK, key.currency1, key.currency0, address(router), false), 1
        );
        vm.expectCall(
            address(ex), abi.encodeWithSelector(MEV_CHECK, key.currency1, key.currency0, address(router), true), 0
        );
        assertGt(_sell(key, ETH, whale, 1e18), 0, "the swap went on");
    }

    /// zeroForOne is the swap's direction in the pool key's order, not "a buy": on a pool whose quote is currency1 a buy
    /// is asked with false and a sell with true, with the subject and the quote in their own places.
    function test_theDirectionIsInTheKeysOrder() public {
        Currency tb = Currency.wrap(address(tokenB));
        PoolKey memory k;
        for (uint256 i; i < 16; ++i) {
            k = _openKoth(tb);
            if (k.currency1 == tb) break;
        }
        assertTrue(k.currency1 == tb, "a pool whose quote is currency1");
        _nextBlock();
        vm.expectCall(address(ex), abi.encodeWithSelector(MEV_CHECK, k.currency0, tb, address(router), false), 1);
        assertGt(_buy(k, tb, whale, 1e18), 0, "the buy went on");
        _nextBlock();
        vm.expectCall(address(ex), abi.encodeWithSelector(MEV_CHECK, k.currency0, tb, address(router), true), 1);
        assertGt(_sell(k, tb, whale, 1e18), 0, "the sell went on");
    }

    /// A view that refuses only one direction: on an ETH pool its sells are refused and its buys go on, so a
    /// same-direction split the executor reads as harmless is not refused.
    function test_aViewMayRefuseOneDirectionOnly() public {
        ex.set(MevExecutor.Answer.TRUE_ONE_FOR_ZERO);
        assertGt(_buy(key, ETH, whale, 1e18), 0, "the buy went on");
        _nextBlock();
        try this.sellExt(key, 1e18) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, _refusal(key)), "the sell was refused");
        }
    }

    /// The one-direction view on a pool whose quote is currency1: it refuses zeroForOne == false, which there is a
    /// buy, and lets the sell (zeroForOne true) go on, so the refusal follows the key's order and not a buy flag.
    function test_aOneDirectionViewOnAQuoteIsCurrency1Pool() public {
        Currency tb = Currency.wrap(address(tokenB));
        PoolKey memory k;
        for (uint256 i; i < 16; ++i) {
            k = _openKoth(tb);
            if (k.currency1 == tb) break;
        }
        assertTrue(k.currency1 == tb, "a pool whose quote is currency1");
        _nextBlock();
        assertGt(_buy(k, tb, whale, 1e18), 0, "the buy went on while the view answered false");
        ex.set(MevExecutor.Answer.TRUE_ONE_FOR_ZERO);
        _nextBlock();
        assertGt(_sell(k, tb, whale, 1e17), 0, "the sell (zeroForOne true) went on");
        _nextBlock();
        try this.buyQuoteExt(k, tb, 1e18) {
            fail();
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, abi.encodeWithSelector(IHookrRootState.MevCallbackRefused.selector, k.currency0, tb)),
                "the buy (zeroForOne false) was refused"
            );
        }
    }

    function buyQuoteExt(PoolKey memory k, Currency quote, uint256 amount) external returns (uint256) {
        require(msg.sender == address(this));
        return _buy(k, quote, whale, amount);
    }

    /// A revert, a two-word answer, a 2, a one-byte answer or a view that runs out of its gas all let the swap go on.
    function test_anythingButACleanTrueLetsTheSwapGoOn() public {
        MevExecutor.Answer[5] memory answers = [
            MevExecutor.Answer.REVERT,
            MevExecutor.Answer.TWO_WORDS,
            MevExecutor.Answer.TWO,
            MevExecutor.Answer.SHORT,
            MevExecutor.Answer.BURN
        ];
        for (uint256 i; i < answers.length; ++i) {
            ex.set(answers[i]);
            _nextBlock();
            assertGt(_buy(key, ETH, whale, 1e18), 0, "the buy went on");
            _nextBlock();
            assertGt(_sell(key, ETH, whale, 1e17), 0, "the sell went on");
        }
    }

    /// The four-argument view is reached and gets at most 200,000 gas: a view that burns all of it costs the swap
    /// 200,000 less what the answering view spends, on the same state.
    function test_aBurningViewSpendsAtMostItsGas() public {
        uint256 snap = vm.snapshotState();
        _buy(key, ETH, whale, 1e18);
        uint256 idle = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
        ex.set(MevExecutor.Answer.BURN);
        _buy(key, ETH, whale, 1e18);
        uint256 burning = vm.lastCallGas().gasTotalUsed;
        console2.log("buy gas: view answering false, view burning its gas", idle, burning);
        assertGt(burning, idle + 190_000, "the view ran and burned its grant");
        assertLe(burning, idle + 200_000, "at most 200,000");
    }

    /// The view receives its whole 200,000 grant to within 2,600 gas: a cap of 194,000 makes the first swap go on, a
    /// cap of 202,000 makes the second one refuse.
    function test_theViewGetsItsGrantAtEntryToWithin2600() public {
        ex.set(MevExecutor.Answer.TRUE_IF_ABOVE_197400);
        try this.buyExt(key, 1e18) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, _refusal(key)), "the view got more than 197,400 gas");
        }
        _nextBlock();
        ex.set(MevExecutor.Answer.TRUE_IF_ABOVE_200000);
        assertGt(_buy(key, ETH, whale, 1e18), 0, "the view never got more than 200,000 gas");
    }

    /// An executor without the view: the swap goes on.
    function test_anExecutorWithoutTheViewNeverRefuses() public {
        /// @dev Has no checkV3PoolsMev().
        MockIdleExecutor v = new MockIdleExecutor();
        _openLane(address(v));
        PoolKey memory k = _openKoth(ETH);
        _nextBlock();
        assertGt(_buy(k, ETH, whale, 1e18), 0);
    }

    /// An executor with only the older three-argument view, answering true, never refuses: the root asks the
    /// four-argument selector, which it has not, and never the three-argument one.
    function test_aThreeArgumentViewNeverRefuses() public {
        ThreeArgumentMevExecutor old = new ThreeArgumentMevExecutor();
        _openLane(address(old));
        PoolKey memory k = _openKoth(ETH);
        _nextBlock();
        vm.expectCall(address(old), abi.encodeWithSelector(MEV_CHECK), 2);
        vm.expectCall(address(old), abi.encodePacked(bytes4(keccak256("checkV3PoolsMev(address,address,address)"))), 0);
        assertGt(_buy(k, ETH, whale, 1e18), 0, "the buy went on");
        _nextBlock();
        assertGt(_sell(k, ETH, whale, 1e18), 0, "the sell went on");
    }

    /// A braked executor is never asked: the brake also takes away its say over swaps.
    function test_aBrakedExecutorIsNeverAsked() public {
        ex.set(MevExecutor.Answer.TRUE);
        registry.stopExecutorLane(address(root), address(ex));
        vm.expectCall(address(ex), abi.encodeWithSelector(MEV_CHECK), 0);
        assertGt(_buy(key, ETH, whale, 1e18), 0, "the swap went on with the lane braked");
    }

    /// An executor whose code changed is never asked (the root skips the lane with LaneCodeChanged).
    function test_aChangedExecutorIsNeverAsked() public {
        vm.etch(address(ex), address(new ChangedMevExecutor()).code);
        vm.expectCall(address(ex), abi.encodeWithSelector(MEV_CHECK), 0);
        assertGt(_buy(key, ETH, whale, 1e18), 0);
    }

    /// The executor's own legs inside a frame are never asked: one question per outer swap, however many legs.
    function test_legsAreNeverAsked() public {
        ScriptedExecutor s = new ScriptedExecutor(manager);
        vm.deal(address(s), 1e28);
        s.setRoot(address(root));
        _openLane(address(s));
        PoolKey memory k = _openKoth(ETH);
        _nextBlock();
        s.set(ScriptedExecutor.Mode.LEG_SAME_POOL, 1e17);
        vm.expectCall(address(s), abi.encodeWithSelector(MEV_CHECK), 1);
        _buy(k, ETH, whale, 1e18);
        assertGt(s.calls(), 0, "the frames ran and legged");
    }

    /// A pool launched without recapture has no lane, so its swaps are never asked.
    function test_aPoolWithoutALaneIsNeverAsked() public {
        ex.set(MevExecutor.Answer.TRUE);
        PoolKey memory k = _openStd(ETH);
        _nextBlock();
        vm.expectCall(address(ex), abi.encodeWithSelector(MEV_CHECK), 0);
        vm.expectCall(address(0), abi.encodeWithSelector(MEV_CHECK), 0);
        assertGt(_buy(k, ETH, whale, 1e18), 0, "the swap went on");
        _nextBlock();
        assertGt(_sell(k, ETH, whale, 1e17), 0, "the sell went on");
    }

    /// No lane call runs in a pool's creation transaction, so its launch buy is never asked.
    function test_theLaunchTransactionIsNeverAsked() public {
        ex.set(MevExecutor.Answer.TRUE);
        vm.expectCall(address(ex), abi.encodeWithSelector(MEV_CHECK), 0);
        PoolKey memory k = _openKoth(ETH);
        assertTrue(Currency.unwrap(k.currency0) == address(0));
    }
}
