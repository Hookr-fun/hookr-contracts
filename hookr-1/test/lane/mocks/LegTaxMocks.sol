// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrAdvisory} from "../../../src/interfaces/IHookrAdvisory.sol";
import {IHookrEngagementReceiptSink} from "../../../src/interfaces/IHookrEngagementReceiptSink.sol";

/// @notice A stand-in quote tax and surcharge that knows nothing about the lane executor. As the directional tax charges
///         it: buys (either shape) and exact-output sells in the before phase, exact-input sells in the after phase.
///         With `sellsBefore` every sell is charged in the before phase instead (a tax bound for the before phase
///         only); with `doubleSell` an exact-input sell is charged in both. Switches refuse, break, burn gas or answer
///         malformed, some only for one sender.
contract LegTaxAdvisory is IHookrAdvisory {
    uint24 public buyTax;
    uint24 public sellTax;
    uint24 public surcharge;
    bool public sellsBefore;
    bool public doubleSell;
    address public refuseFor;
    address public malformFor;
    bool public broken;
    uint256 public burn;
    address public burnFor;
    address public constant BUY_TO = address(0xB0B1);
    address public constant SELL_TO = address(0x5E11);

    function set(uint24 b, uint24 s) external {
        (buyTax, sellTax) = (b, s);
    }

    function setSurcharge(uint24 pips) external {
        surcharge = pips;
    }

    function setSellsBefore(bool on) external {
        sellsBefore = on;
    }

    function setDoubleSell(bool on) external {
        doubleSell = on;
    }

    /// @dev Refuses every swap sent by `sender` before it runs.
    function setRefuseFor(address sender) external {
        refuseFor = sender;
    }

    /// @dev Answers a swap sent by `sender` after it runs with an LP surcharge, which the root refuses there.
    function setMalformFor(address sender) external {
        malformFor = sender;
    }

    function setBroken(bool on) external {
        broken = on;
    }

    /// @dev Burns `gasToBurn` in each answer to a swap sent by `sender`, to make its answer cost more gas.
    function setBurn(uint256 gasToBurn, address sender) external {
        (burn, burnFor) = (gasToBurn, sender);
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("legtax.advisory");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory a) {
        _work(x.sender);
        a.reject = x.sender == refuseFor;
        a.lpFeeSurchargePips = surcharge;
        if (x.isBuy) {
            (a.quoteTakePips, a.recipient) = (buyTax, BUY_TO);
        } else if (!x.exactInput || sellsBefore || doubleSell) {
            (a.quoteTakePips, a.recipient) = (sellTax, SELL_TO);
        }
        if (a.quoteTakePips == 0) a.recipient = address(0);
    }

    function afterSwap(HookrTypes.SwapContext calldata x, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory a)
    {
        _work(x.sender);
        if (!x.isBuy && x.exactInput && (!sellsBefore || doubleSell) && sellTax != 0) {
            (a.quoteTakePips, a.recipient) = (sellTax, SELL_TO);
        }
        if (x.sender == malformFor) a.lpFeeSurchargePips = 1;
    }

    function _work(address sender) private view {
        require(!broken, "broken");
        if (sender != burnFor) return;
        uint256 g = gasleft();
        while (g - gasleft() < burn) {}
    }
}

/// @notice A stand-in market band: the after phase refuses a swap that ends outside [lower, upper], and the before
///         phase prices a move of at least `priceFrom` at `priced` pips of LP surcharge. It knows nothing about the lane.
contract BandAdvisory is IHookrAdvisory {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    int24 public lower = type(int24).min;
    int24 public upper = type(int24).max;
    uint24 public priced;
    uint256 public priceFrom;

    constructor(IPoolManager m) {
        manager = m;
    }

    function setBand(int24 lo, int24 hi) external {
        (lower, upper) = (lo, hi);
    }

    function setPrice(uint24 pips, uint256 from) external {
        (priced, priceFrom) = (pips, from);
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("legtax.band");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory a) {
        uint256 size = x.amountSpecified < 0 ? uint256(-x.amountSpecified) : uint256(x.amountSpecified);
        if (priced != 0 && size >= priceFrom) a.lpFeeSurchargePips = priced;
    }

    function afterSwap(HookrTypes.SwapContext calldata x, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory a)
    {
        (, int24 tick,,) = manager.getSlot0(x.id);
        a.reject = tick < lower || tick > upper;
    }
}

interface IProtocolPaid {
    function protocolFeePaid(address payer, Currency quote) external view returns (uint256);
}

/// @notice An executor that runs the legs it is given in each phase (before: the call naming no trader; after: the
///         call naming the swap's authenticated payer, so every trigger it is used with is an authenticated swap),
///         settles each from its own balances, pushes nothing and returns `reported` (which the root does not read).
///         A refused leg is recorded and ends the call with a zero report, so the frame closes clean. Test code only.
contract LegExecutor {
    using CurrencyLibrary for Currency;

    struct Leg {
        PoolKey key;
        SwapParams params;
        uint256 gas;
    }

    /// @dev `quoteLeg((address,address,uint24,int24,address),(bool,int256,uint160),int128,int128)`.
    bytes4 internal constant QUOTE_LEG = 0xba835629;
    IPoolManager public immutable manager;
    address public root;
    address public rules;
    Leg[] internal _before;
    Leg[] internal _after;
    uint256 public reported;
    uint256 public legs;
    int256 public last0;
    int256 public last1;
    uint256 public legGas;
    uint256 public paidInFrame;
    bytes public lastError;
    /// @dev When `quoting`, each leg is first quoted with the root's `quoteLeg` under staticcall, inside the frame,
    ///      with the after-phase amounts `quote0` and `quote1`; the call's success and return data are kept.
    bool public quoting;
    int128 public quote0;
    int128 public quote1;
    bool public quoteOk;
    bytes public quoteOut;
    /// @dev When `trying`, each leg is first run as a trial inside the frame, after its quote: `trial` swaps and
    ///      reverts, with `Trial` and the executor's delta or with the swap's own error, which `trialOut` keeps.
    ///      Nothing of the trial stays.
    bool public trying;
    bytes public trialOut;
    /// @dev When `badReturn`, the call returns two words after its legs, which fails the frame (LaneBadReturn).
    bool public badReturn;

    error Trial(int128 amount0, int128 amount1);

    constructor(IPoolManager m) {
        manager = m;
    }

    receive() external payable {}

    function setUp(address root_, address rules_) external {
        (root, rules) = (root_, rules_);
    }

    function clear() external {
        delete _before;
        delete _after;
        reported = 0;
        legs = 0;
        delete lastError;
        delete trialOut;
        badReturn = false;
    }

    function add(bool afterPhase, PoolKey calldata key, bool zeroForOne, int256 amount, uint160 limit, uint256 gas)
        external
    {
        (afterPhase ? _after : _before).push(Leg(key, SwapParams(zeroForOne, amount, limit), gas));
    }

    function setQuoting(bool on, int128 amount0, int128 amount1) external {
        (quoting, quote0, quote1) = (on, amount0, amount1);
    }

    function setTrying(bool on) external {
        trying = on;
    }

    function setBadReturn(bool on) external {
        badReturn = on;
    }

    /// @dev The leg, reverted: a trial of it inside the frame. Only this contract calls it.
    function trial(PoolKey calldata key, SwapParams calldata params) external {
        require(msg.sender == address(this), "self");
        BalanceDelta d = manager.swap(key, params, "");
        revert Trial(d.amount0(), d.amount1());
    }

    function report(uint256 profit) external {
        reported = profit;
    }

    function executeArbitrage(PoolKey calldata, address trader) external returns (uint256) {
        require(msg.sender == root, "root");
        Leg[] storage list = trader == address(0) ? _before : _after;
        for (uint256 i; i < list.length; ++i) {
            Leg memory l = list[i];
            if (quoting) {
                (quoteOk, quoteOut) =
                    root.staticcall(abi.encodeWithSelector(QUOTE_LEG, l.key, l.params, quote0, quote1));
            }
            if (trying) {
                try this.trial(l.key, l.params) {}
                catch (bytes memory out) {
                    trialOut = out;
                }
            }
            uint256 g = gasleft();
            BalanceDelta d;
            if (l.gas != 0) {
                try manager.swap{gas: l.gas}(l.key, l.params, "") returns (BalanceDelta out) {
                    d = out;
                } catch (bytes memory err) {
                    lastError = err;
                    return 0;
                }
            } else {
                try manager.swap(l.key, l.params, "") returns (BalanceDelta out) {
                    d = out;
                } catch (bytes memory err) {
                    lastError = err;
                    return 0;
                }
            }
            legGas = g - gasleft();
            legs++;
            (last0, last1) = (d.amount0(), d.amount1());
            paidInFrame = IProtocolPaid(rules).protocolFeePaid(address(this), l.key.currency0)
                + IProtocolPaid(rules).protocolFeePaid(address(this), l.key.currency1);
            _settle(l.key.currency0, d.amount0());
            _settle(l.key.currency1, d.amount1());
        }
        if (badReturn) {
            uint256 r = reported;
            assembly ("memory-safe") {
                mstore(0, r)
                mstore(32, 0)
                return(0, 64)
            }
        }
        return reported;
    }

    function _settle(Currency c, int128 v) internal {
        if (v < 0) {
            uint256 owed = uint256(uint128(-v));
            if (c.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (v > 0) {
            manager.take(c, address(this), uint256(uint128(v)));
        }
    }
}

/// @notice Records the receipt the pinned router hands a receipt sink. Test code only.
contract ReceiptSink is IHookrEngagementReceiptSink {
    address public immutable trustedRouter;
    address public immutable poolManager;
    uint256 public quoteVolume;
    uint256 public records;

    constructor(address router_, address manager_) {
        (trustedRouter, poolManager) = (router_, manager_);
    }

    function recordExecution(EngagementReceipt calldata receipt, uint256[] calldata) external {
        quoteVolume = receipt.quoteVolume;
        records++;
    }
}
