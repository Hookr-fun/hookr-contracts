// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @notice Adds or removes a third-party liquidity band directly on the PoolManager.
contract BandLp is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable _manager;

    constructor(IPoolManager manager_) {
        _manager = manager_;
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 delta) external {
        _manager.unlock(abi.encode(key, lower, upper, delta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 lower, int24 upper, int256 delta) = abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta d,) = _manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, delta, bytes32(0)), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            _manager.sync(c);
            if (c.isAddressZero()) {
                _manager.settle{value: uint128(-amount)}();
            } else {
                IERC20(Currency.unwrap(c)).transfer(address(_manager), uint128(-amount));
                _manager.settle();
            }
        } else if (amount > 0) {
            _manager.take(c, address(this), uint128(amount));
        }
    }

    receive() external payable {}
}

/// @notice Shared launch helpers for the economics regression tests.
abstract contract EconomicsSecurityBase is PeripheryFixture {
    function setUp() public virtual {
        _setUpPeriphery();
    }

    /// @dev A pure dynamic fee pool: base 3,000, maxFee 100,000, sens 5, no LP Rewards, burn or royalty.
    function _dynamicFeeMember(Currency quote) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(quote);
        m.rules.maxFeePips = 100_000;
        m.rules.dynamicFeeSens = 5;
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        m.rules.protocolShareBps = 2500;
    }

    function _dynamicFeeWindow() internal view returns (uint256 window) {
        (window,,,) = rules.dynamicFeeParameters();
    }

    function _dynamicFeeReset() internal view returns (uint256 reset) {
        (, reset,,) = rules.dynamicFeeParameters();
    }

    function _pair(bool subjectFirst) internal view returns (HookrToken subject, Currency quote) {
        bool aFirst = address(tokenA) < address(tokenB);
        subject = aFirst == subjectFirst ? tokenA : tokenB;
        quote = Currency.wrap(aFirst == subjectFirst ? address(tokenB) : address(tokenA));
    }

    function _launchMember(IHookrLauncher.Member memory m, bool subjectFirst)
        internal
        returns (PoolKey memory key, HookrToken subject, Currency quote)
    {
        (subject, quote) = _pair(subjectFirst);
        m.quote = quote;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _expectLaunchRefused(IHookrLauncher.Member memory m) internal {
        (HookrToken subject, Currency quote) = _pair(true);
        m.quote = quote;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        vm.expectRevert();
        launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
    }

    function _buyAs(address who, PoolKey memory key, uint128 amount) internal returns (uint256 input, uint256 output) {
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        p.recipient = who;
        vm.prank(who);
        (input, output) = router.swap(p, address(0), new uint256[](0));
    }

    function _quoteBuy(PoolKey memory key, uint128 amount) internal returns (HookrTypes.ExecutionReceipt memory) {
        return quoter.quote(_swap(key, true, true, amount), trader);
    }
}
