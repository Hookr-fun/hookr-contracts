// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";

/// @notice Configurable Rules stand-in for Root-side regression tests. Settles by crediting exactly what Root owes.
contract MockRules {
    IPoolManager public immutable poolManager;
    address public trustedRoot;
    HookrTypes.FeeQuote public buyQuote;
    HookrTypes.FeeQuote public sellQuote;
    uint256 public lockUntil;
    bool public lockReverts;
    int256 public creditSkew;

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    function setRoot(address root_) external {
        trustedRoot = root_;
    }

    function setQuotes(HookrTypes.FeeQuote memory buy, HookrTypes.FeeQuote memory sell) external {
        buyQuote = buy;
        sellQuote = sell;
    }

    function setLock(uint256 until, bool reverts) external {
        lockUntil = until;
        lockReverts = reverts;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.mock.rules");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure {}

    function removalLockedUntil(PoolId) external view returns (uint256) {
        if (lockReverts) revert();
        return lockUntil;
    }

    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.FeeQuote memory) {
        return x.isBuy ? buyQuote : sellQuote;
    }

    HookrTypes.Settlement public lastSettlement;

    function setCreditSkew(int256 skew) external {
        creditSkew = skew;
    }

    /// @dev Credits what the root took, plus `creditSkew` (zero unless a test sets it: a Rules that credits more or
    ///      less than the root minted to it).
    function settleSwap(HookrTypes.SwapContext calldata, HookrTypes.Settlement calldata z) external returns (uint256) {
        lastSettlement = z;
        return uint256(int256(z.rulesFee + z.advisoryFee + z.refund) + creditSkew);
    }
}

/// @notice Shared setup: this contract is an admitted launcher and opens pools directly on the fixture Root.
abstract contract RootSecurityBase is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    PoolModifyLiquidityTest internal lp;
    PoolSwapTest internal generic;
    MockRules internal mock;

    function _setUpRootSecurity() internal {
        _setUpPeriphery();
        lp = new PoolModifyLiquidityTest(manager);
        generic = new PoolSwapTest(manager);
        tokenA.approve(address(lp), type(uint256).max);
        tokenB.approve(address(lp), type(uint256).max);
        tokenA.approve(address(generic), type(uint256).max);
        tokenB.approve(address(generic), type(uint256).max);
        mock = new MockRules(manager);
        mock.setRoot(address(root));
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(mock),
            codeHash: address(mock).codehash,
            schemaHash: mock.configSchemaHash(),
            caps: HookrTypes.Caps(100_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        registry.setLauncher(address(this), true);
    }

    function _key(int24 spacing) internal view returns (PoolKey memory) {
        bool aFirst = address(tokenA) < address(tokenB);
        return PoolKey(
            Currency.wrap(aFirst ? address(tokenA) : address(tokenB)),
            Currency.wrap(aFirst ? address(tokenB) : address(tokenA)),
            0x800000,
            spacing,
            IHooks(address(root))
        );
    }

    /// @dev Subject tokenA, quote tokenB, liquidity owner = the modify-liquidity helper.
    function _config(address rulesModule) internal view returns (HookrTypes.PoolConfig memory pc) {
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(tokenB)));
        pc = m.config;
        pc.subject = Currency.wrap(address(tokenA));
        pc.quote = Currency.wrap(address(tokenB));
        pc.rules = rulesModule;
        pc.liquidityOwner = address(lp);
    }

    function _rulesConfig() internal view returns (HookrTypes.RulesConfig memory c) {
        c = _member(Currency.wrap(address(tokenB))).rules;
    }

    function _open(HookrTypes.PoolConfig memory pc, bytes memory rulesData, int24 spacing)
        internal
        returns (PoolKey memory key)
    {
        key = _key(spacing);
        root.initializePool(key, pc, rulesData, bytes(""), SQRT_ONE);
    }

    function _addLiquidity(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) internal {
        lp.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), bytes(""));
    }

    function _isBuyZeroForOne(PoolKey memory key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(tokenB);
    }

    function _genericSwap(PoolKey memory key, bool buy, int256 amountSpecified, uint160 limit) internal {
        bool zeroForOne = buy == _isBuyZeroForOne(key);
        if (limit == 0) limit = zeroForOne ? MIN_PRICE : MAX_PRICE;
        generic.swap(key, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), "");
    }
}
