// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLaneExecutor} from "../../src/interfaces/callback/IHookrLaneExecutor.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {Actor} from "./mocks/Actors.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice Records every lane call: the rebate recipient, the calldata length and the selector. Pushes nothing.
contract RecordingExecutor {
    struct Call {
        address trader;
        uint256 dataLength;
        bytes4 selector;
    }

    address public immutable root;
    Call[] internal _calls;

    constructor(address root_) {
        root = root_;
    }

    function executeArbitrage(PoolKey calldata, address trader) external returns (uint256) {
        require(msg.sender == root, "root");
        _calls.push(Call(trader, msg.data.length, msg.sig));
        return 0;
    }

    function count() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 i) external view returns (Call memory) {
        return _calls[i];
    }

    function clear() external {
        delete _calls;
    }
}

/// @notice Runs HookrLane's frame in its own context the way the root's self-call does: a self-call carrying the frame
///         input, with a swap active and a frame snapshot of two currencies recorded, so the frame's own input check
///         is what answers.
contract FrameHarness {
    address public immutable lane;

    constructor(address lane_) {
        lane = lane_;
    }

    function probe(bytes calldata input) external returns (bool ok, bytes memory ret) {
        bytes32 active = keccak256("hookr.root.transient.active");
        bytes32 nonceSlot = keccak256("hookr.root.transient.lane.nonce");
        bytes32 list = keccak256(abi.encode(keccak256("hookr.root.transient.lane.accepted"), uint256(1)));
        assembly ("memory-safe") {
            tstore(active, 1)
            tstore(nonceSlot, 1)
            tstore(list, 2)
        }
        (ok, ret) = address(this).call(input);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        address target = lane;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), target, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }
}

/// @notice The root calls `executeArbitrage(PoolKey,address)`, selector 0x488301cd, twice on every swap of a lane pool:
///         before the swap is quoted, naming no trader, and after it settles, naming the authenticated payer (zero for
///         an unauthenticated swap). The frame input is `abi.encode(PoolKey, address)`, 192 bytes.
contract ExecutorAbiTest is LaneFixture {
    using CurrencyLibrary for Currency;

    uint8 internal constant BEFORE = 0;
    uint8 internal constant AFTER = 1;

    RecordingExecutor internal rec;

    function setUp() public {
        _setUpLane();
        rec = new RecordingExecutor(address(root));
        _openLane(address(rec));
    }

    function _check(address trader, string memory label) internal view {
        assertEq(rec.count(), 2, "both lane calls ran");
        RecordingExecutor.Call memory b = rec.callAt(BEFORE);
        RecordingExecutor.Call memory a = rec.callAt(AFTER);
        assertEq(b.trader, address(0), "the before-phase names no trader");
        assertEq(a.trader, trader, label);
        for (uint256 i; i < 2; ++i) {
            RecordingExecutor.Call memory c = i == 0 ? b : a;
            assertEq(c.selector, bytes4(0x488301cd), "executeArbitrage(PoolKey,address)");
            assertEq(c.dataLength, 196, "4 + 6 words");
        }
    }

    /// Authenticated buys and sells, exact input and exact output, on a native ETH quote and a token quote.
    function test_executorAbi_twoArgumentsInBothPhases() public {
        assertEq(IHookrLaneExecutor.executeArbitrage.selector, bytes4(0x488301cd));
        Currency[2] memory quotes = [ETH, Currency.wrap(address(tokenA))];
        for (uint256 i; i < 2; ++i) {
            Currency quote = quotes[i];
            PoolKey memory k = _openRecapture(quote);
            _nextBlock();
            for (uint256 shape; shape < 4; ++shape) {
                bool buy = shape < 2;
                bool exactInput = shape % 2 == 0;
                uint256 amount = 2e18;
                IHookrRouter.Swap memory p = _swapParams(k, quote, buy, exactInput, amount, whale);
                if (buy && quote.isAddressZero() && !exactInput) p.amountBound = uint128(amount * 2);
                uint256 value = quote.isAddressZero() && buy ? (exactInput ? amount : amount * 2) : 0;
                rec.clear();
                vm.prank(whale);
                router.swap{value: value}(p, address(0), new uint256[](0));
                _check(whale, "the after-phase names the authenticated payer");
                _nextBlock();
            }
        }
    }

    /// An unauthenticated swap: both calls, neither names a trader.
    function test_executorAbi_unauthenticatedSwapNamesNoTrader() public {
        PoolKey memory k = _openRecapture(ETH);
        _nextBlock();
        Actor t = _newActor(k);
        rec.clear();
        t.directSwap(k, true, -int256(1e18), MIN_PRICE);
        _check(address(0), "no authenticated payer");
    }

    /// The frame's own check takes exactly 192 bytes: it refuses 160 and the 224 of a three-argument frame, and 192
    /// passes it and reaches the executor call (here none, so LaneBadReturn). From outside, every length is refused.
    function test_executorAbi_frameTakesOnly192Bytes() public {
        (address module,) = IHookrLaneRoot(address(root)).laneModule();
        FrameHarness h = new FrameHarness(module);
        PoolKey memory k;
        bytes[3] memory inputs = [abi.encode(k), abi.encode(k, address(0), uint256(1)), abi.encode(k, address(0))];
        for (uint256 i; i < 3; ++i) {
            (bool ok, bytes memory ret) = h.probe(inputs[i]);
            assertFalse(ok);
            bytes4 expected = i < 2 ? IHookrRootEvents.Unauthorized.selector : IHookrLaneEvents.LaneBadReturn.selector;
            assertEq(bytes4(ret), expected, i < 2 ? "wrong length refused" : "192 bytes pass the length check");
            (ok,) = address(root).call(inputs[i]);
            assertFalse(ok, "never from outside");
        }
    }
}
