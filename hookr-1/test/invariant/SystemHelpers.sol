// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";

/// @notice PoolManager locker for the system campaign. Pinned into both HookrRoots as the curated router (its
///         msgSender() reports the caller), and deployed a second time unpinned as a generic PoolManager caller.
///         Runs 1..n swaps and liquidity changes across pools in ONE unlock, then settles every net delta for the
///         calling user (sync, transferFrom, settle; native from msg.value) and takes every credit to the user.
/// @dev Inside the unlock, right after every action, it counts actions that left the pool's hook with an open
///      PoolManager delta: a root must settle whatever it takes or returns within the same callback.
contract SysLocker is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    struct Act {
        uint8 kind; // 0 swap, 1 modifyLiquidity
        PoolKey key;
        bool zeroForOne;
        int256 amount; // swap amountSpecified, or liquidityDelta
        uint160 limit;
        int24 lower;
        int24 upper;
        bytes32 salt;
    }

    IPoolManager public immutable pm;
    address public admin;
    address private _user;
    /// @notice Actions that left their hook with an open delta.
    uint256 public hookDeltas;

    constructor(IPoolManager m, address admin_) {
        pm = m;
        admin = admin_;
    }

    function setAdmin(address a) external {
        require(msg.sender == admin, "admin");
        admin = a;
    }

    function msgSender() external view returns (address) {
        return _user;
    }

    function poolManager() external view returns (IPoolManager) {
        return pm;
    }

    function run(Act[] calldata acts) external payable returns (int256[] memory out) {
        require(_user == address(0), "reentered");
        _user = msg.sender;
        out = abi.decode(pm.unlock(abi.encode(msg.sender, acts)), (int256[]));
        _user = address(0);
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            require(ok, "refund");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (address user, Act[] memory acts) = abi.decode(data, (address, Act[]));
        int256[] memory out = new int256[](acts.length * 2);
        for (uint256 i; i < acts.length; ++i) {
            Act memory a = acts[i];
            BalanceDelta d;
            if (a.kind == 0) {
                d = pm.swap(a.key, SwapParams(a.zeroForOne, a.amount, a.limit), "");
            } else {
                (d,) = pm.modifyLiquidity(a.key, ModifyLiquidityParams(a.lower, a.upper, a.amount, a.salt), "");
            }
            address hook = address(a.key.hooks);
            if (pm.currencyDelta(hook, a.key.currency0) != 0 || pm.currencyDelta(hook, a.key.currency1) != 0) {
                ++hookDeltas;
            }
            out[2 * i] = d.amount0();
            out[2 * i + 1] = d.amount1();
        }
        for (uint256 i; i < acts.length; ++i) {
            _resolve(user, acts[i].key.currency0);
            _resolve(user, acts[i].key.currency1);
        }
        return abi.encode(out);
    }

    function _resolve(address user, Currency c) private {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            uint256 owed = uint256(-d);
            pm.sync(c);
            if (c.isAddressZero()) {
                pm.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(c)).transferFrom(user, address(pm), owed);
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(c, user, uint256(d));
        }
    }

    /// @notice Lets the admin spend this locker's own Rules claims (refunds credited to the locker as payer).
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == admin, "admin");
        (bool ok, bytes memory r) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        return r;
    }

    receive() external payable {}
}

/// @notice Sequential multicall: every step runs in the SAME transaction with this contract as msg.sender.
contract SysMulticall {
    address public admin;

    constructor(address admin_) {
        admin = admin_;
    }

    function exec(address[] calldata t, uint256[] calldata v, bytes[] calldata d)
        external
        payable
        returns (bytes[] memory out)
    {
        require(msg.sender == admin, "admin");
        out = new bytes[](t.length);
        for (uint256 i; i < t.length; ++i) {
            (bool ok, bytes memory r) = t[i].call{value: v[i]}(d[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(r, 32), mload(r))
                }
            }
            out[i] = r;
        }
    }

    receive() external payable {}
}

interface ISysRulesView {
    function protocolFeePaid(address payer, address quote) external view returns (uint256);
    function claimable(address currency, address beneficiary) external view returns (uint256);
}

/// @notice Called between multicall steps inside one transaction: snapshots the Rules transient PROTOCOL_PAID ledger for
///         one payer next to the protocol recipient's claim, so the handler can compare deltas step by step.
contract SysProbe {
    struct Snap {
        uint256 paid;
        uint256 protocolClaim;
    }

    Snap[] internal _snaps;

    function snap(address rules, address payer, address quote, address recipient) external {
        _snaps.push(
            Snap(ISysRulesView(rules).protocolFeePaid(payer, quote), ISysRulesView(rules).claimable(quote, recipient))
        );
    }

    function clear() external {
        delete _snaps;
    }

    function count() external view returns (uint256) {
        return _snaps.length;
    }

    function snapAt(uint256 i) external view returns (Snap memory) {
        return _snaps[i];
    }
}

/// @notice A v4 PoolManager protocolFeeController modelled on the V4FeeAdapter live on 4663: the fee setter stores a
///         value, and ANYONE may push it to an initialized pool at any time with triggerFeeUpdate.
contract SysFeeAdapter {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable pm;
    address public immutable feeSetter;
    mapping(PoolId => uint24) public stored;

    constructor(IPoolManager m, address setter) {
        pm = m;
        feeSetter = setter;
    }

    function setPoolOverride(PoolId id, uint24 fee) external {
        require(msg.sender == feeSetter, "setter");
        stored[id] = fee;
    }

    function triggerFeeUpdate(PoolKey calldata key) external {
        pm.setProtocolFee(key, stored[key.toId()]);
    }
}

/// @notice Minimal ERC-4337 v0.7 account (no signature check), SimpleAccount execute / executeBatch selectors.
contract SysAccount {
    address public immutable entryPoint;
    address public immutable admin;

    constructor(address ep, address admin_) {
        entryPoint = ep;
        admin = admin_;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missingAccountFunds)
        external
        returns (uint256)
    {
        require(msg.sender == entryPoint, "ep");
        if (missingAccountFunds != 0) {
            (bool ok,) = payable(entryPoint).call{value: missingAccountFunds}("");
            ok;
        }
        return 0;
    }

    function execute(address dest, uint256 value, bytes calldata func) external {
        require(msg.sender == entryPoint || msg.sender == admin, "ep");
        _call(dest, value, func);
    }

    function executeBatch(address[] calldata dest, uint256[] calldata value, bytes[] calldata func) external {
        require(msg.sender == entryPoint || msg.sender == admin, "ep");
        for (uint256 i; i < dest.length; ++i) {
            _call(dest[i], value.length == 0 ? 0 : value[i], func[i]);
        }
    }

    function _call(address dest, uint256 value, bytes calldata func) private {
        (bool ok, bytes memory r) = dest.call{value: value}(func);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    receive() external payable {}
}

interface ISysEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface ISysPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
