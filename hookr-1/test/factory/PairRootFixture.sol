// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrRootFactory.sol";
import {IHookrPairAdvisory} from "../../src/interfaces/IHookrPairAdvisory.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {mineSalt} from "../../script/HookrPairRootSalt.s.sol";

/// @dev Configurable advisory. Modes: 0 returns `value` as a raw word, 1 reverts, 2 burns all gas, 3 returns no data,
///      4 returns two words, 5 returns the direction-dependent surcharge after checking the call arguments, 6 returns 100
///      only when entered with at least `value` gas. `bindPair` acknowledges every binding with `bindReply`.
contract MockPairAdvisory {
    uint256 public mode;
    uint256 public value;
    bytes32 public expectedId;
    bytes4 public bindReply = IHookrPairAdvisory.bindPair.selector;
    bytes public lastBind;

    function setBindReply(bytes4 reply) external {
        bindReply = reply;
    }

    function bindPair(PoolId id, uint24 capPips, uint32 gasLimit, bytes calldata data) external returns (bytes4) {
        lastBind = abi.encode(msg.sender, id, capPips, gasLimit, data);
        return bindReply;
    }

    function set(uint256 mode_, uint256 value_) external {
        mode = mode_;
        value = value_;
    }

    function expect(bytes32 id) external {
        expectedId = id;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        uint256 m = mode;
        if (m == 1) revert("advisory down");
        if (m == 2) {
            while (true) {}
        }
        if (m == 3) return "";
        if (m == 4) return abi.encode(value, value);
        if (m == 6) {
            if (gasleft() < value) revert("starved");
            return abi.encode(uint256(100));
        }
        if (m == 5) {
            (bytes32 id, bool zeroForOne, int256 amount, uint160 limit, bytes memory data, address sender) =
                abi.decode(input[4:], (bytes32, bool, int256, uint160, bytes, address));
            if (id != expectedId || sender == address(0) || amount == 0 || limit == 0) revert("bad args");
            return abi.encode(uint256(zeroForOne ? 1_000 : 2_000) + data.length);
        }
        return abi.encode(value);
    }
}

/// @dev Minimal unlock-callback router: one swap or one liquidity change per call, exact settlement, no extras.
contract PairTestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        delta = abi.decode(
            manager.unlock(
                abi.encode(msg.sender, key, true, abi.encode(SwapParams(zeroForOne, amountSpecified, limit)), hookData)
            ),
            (BalanceDelta)
        );
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function modify(PoolKey calldata key, ModifyLiquidityParams calldata params) external payable {
        manager.unlock(abi.encode(msg.sender, key, false, abi.encode(params), bytes("")));
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, bool isSwap, bytes memory op, bytes memory hookData) =
            abi.decode(raw, (address, PoolKey, bool, bytes, bytes));
        BalanceDelta delta;
        if (isSwap) {
            delta = manager.swap(key, abi.decode(op, (SwapParams)), hookData);
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(op, (ModifyLiquidityParams)), hookData);
        }
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}

abstract contract PairRootFixture is Test {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint160 internal constant SQRT_ONE = uint160(1 << 96);

    IPoolManager internal manager;
    HookrRegistry internal registry;
    HookrRootFactory internal factory;
    PairTestRouter internal router;
    MockPairAdvisory internal advisory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal deployer = address(0xD3);
    address internal trader = address(0x7E);
    address internal lp = address(0x1B);

    function _setUpFactory() internal {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        registry = new HookrRegistry(address(this), manager, _registryDelay());
        factory = new HookrRootFactory(manager, IHookrFactoryRegistry(address(registry)));
        _activateFactory(registry, address(factory));
        router = new PairTestRouter(manager);
        advisory = new MockPairAdvisory();
        _admitPairAdvisory(registry, address(factory), address(advisory));
        MockERC20 x = new MockERC20("X", "X", 18);
        MockERC20 y = new MockERC20("Y", "Y", 18);
        (tokenA, tokenB) = address(x) < address(y) ? (x, y) : (y, x);
        address[3] memory users = [trader, lp, deployer];
        for (uint256 i; i < users.length; ++i) {
            vm.deal(users[i], 1_000_000 ether);
            tokenA.mint(users[i], 1e30);
            tokenB.mint(users[i], 1e30);
            vm.startPrank(users[i]);
            tokenA.approve(address(router), type(uint256).max);
            tokenB.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev The registry delay this fixture deploys with. Unit suites keep one day; a gas bench that models the
    ///      release overrides it with the release's 30 minutes.
    function _registryDelay() internal pure virtual returns (uint48) {
        return 1 days;
    }

    /// @dev Activates `factory` through the registry's SET_ROOT_FACTORY timelock, pinned to its runtime codehash.
    function _activateFactory(HookrRegistry reg, address factory_) internal {
        reg.queue(reg.SET_ROOT_FACTORY(), abi.encode(factory_, factory_.codehash, true));
        vm.warp(vm.getBlockTimestamp() + reg.delay());
        reg.setRootFactory(factory_, factory_.codehash, true);
    }

    /// @dev The widest pair advisory admission the registry accepts: kind ADVISORY, pinned to the module's runtime
    ///      codehash, a 600,000-pip cap, a 2,000,000 gas limit, fee-only and fail-open, so the factory deploys
    ///      fail-open and fail-closed roots on it alike.
    function _pairAdmission(address module) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: module,
            codeHash: module.codehash,
            schemaHash: keccak256("hookr.pair.advisory"),
            caps: HookrTypes.Caps(600_000, 0, 0),
            gasLimit: 2_000_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: true
        });
    }

    /// @dev Admits `module` for `factory_` through the registry's ADMIT timelock, then restores the block timestamp so
    ///      time-dependent state set up before the call is unchanged.
    function _admitPairAdvisory(HookrRegistry reg, address factory_, address module) internal {
        uint256 t = vm.getBlockTimestamp();
        IHookrRegistry.Admission memory a = _pairAdmission(module);
        reg.queue(reg.ADMIT(), abi.encode(factory_, a));
        vm.warp(t + reg.delay());
        reg.admit(factory_, a);
        vm.warp(t);
    }

    function _plain(Currency c0, Currency c1, uint24 base) internal pure returns (IHookrPairRoot.Params memory p) {
        p.currency0 = c0;
        p.currency1 = c1;
        p.tickSpacing = 60;
        p.baseLpFeePips = base;
        p.maxLpFeePips = base;
    }

    function _advised(Currency c0, Currency c1, uint24 base, uint24 cap, bool failOpen)
        internal
        view
        returns (IHookrPairRoot.Params memory p)
    {
        p = _plain(c0, c1, base);
        p.maxLpFeePips = base + cap;
        p.advisory = address(advisory);
        p.advisoryCapPips = cap;
        p.advisoryGasLimit = 50_000;
        p.advisoryFailOpen = failOpen;
    }

    function _erc() internal view returns (Currency, Currency) {
        return (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
    }

    function _eth() internal view returns (Currency, Currency) {
        return (Currency.wrap(address(0)), Currency.wrap(address(tokenA)));
    }

    /// @dev Off-chain-style salt mining: the lowest salt whose address carries exactly the pair root flags.
    function _mine(address who, IHookrPairRoot.Params memory p) internal view returns (bytes32) {
        return mineSalt(address(factory), who, factory.initCodeHash(p), 0);
    }

    function _deploy(IHookrPairRoot.Params memory p) internal returns (HookrPairRoot root, PoolKey memory key) {
        return _deploy(p, "");
    }

    /// @dev Admits the advisory for the factory first when it is not admitted yet.
    function _deploy(IHookrPairRoot.Params memory p, bytes memory advisoryData)
        internal
        returns (HookrPairRoot root, PoolKey memory key)
    {
        if (p.advisory != address(0) && registry.admission(address(factory), p.advisory).implementation == address(0)) {
            _admitPairAdvisory(registry, address(factory), p.advisory);
        }
        bytes32 salt = _mine(deployer, p);
        vm.prank(deployer);
        (address r,) = factory.deploy(salt, p, SQRT_ONE, advisoryData);
        root = HookrPairRoot(r);
        key = root.poolKey();
    }

    function _fund(PoolKey memory key) internal {
        vm.prank(lp);
        router.modify{value: key.currency0.isAddressZero() ? 1_000 ether : 0}(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0})
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amount, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        uint256 value = zeroForOne && key.currency0.isAddressZero() ? (amount < 0 ? uint256(-amount) : 100 ether) : 0;
        vm.prank(trader);
        delta = router.swap{value: value}(key, zeroForOne, amount, hookData);
    }

    /// @dev Swaps and returns the LP fee the PoolManager reports in its Swap event.
    function _swapFee(PoolKey memory key, bool zeroForOne, int256 amount, bytes memory hookData)
        internal
        returns (uint24 fee)
    {
        vm.recordLogs();
        _swap(key, zeroForOne, amount, hookData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "no Swap event");
    }
}
