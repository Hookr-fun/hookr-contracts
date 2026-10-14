// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @dev A curated router stand-in whose msgSender() answer the test chooses: the locker, a revert, zero, a word above
///      160 bits, or a short return.
contract CuratedRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;
    uint8 public mode;
    address private _locker;

    constructor(IPoolManager manager_) {
        poolManager = manager_;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function msgSender() external view returns (address) {
        uint8 m = mode;
        if (m == 1) revert("no locker");
        if (m == 2) return address(0);
        if (m == 3) {
            assembly ("memory-safe") {
                mstore(0, shl(160, 1))
                return(0, 32)
            }
        }
        if (m == 4) {
            assembly ("memory-safe") {
                mstore(0, 0)
                return(0, 16)
            }
        }
        return _locker;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount) external {
        _locker = msg.sender;
        poolManager.unlock(abi.encode(key, zeroForOne, amount));
        _locker = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "manager");
        (PoolKey memory key, bool zeroForOne, int256 amount) = abi.decode(data, (PoolKey, bool, int256));
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams(zeroForOne, amount, zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341),
            ""
        );
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).transferFrom(_locker, address(poolManager), uint128(-amount));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(c, _locker, uint128(amount));
        }
    }
}

/// @dev The same stand-in with one more function: the same answers from different runtime code.
contract CuratedRouterTwin is CuratedRouter {
    constructor(IPoolManager manager_) CuratedRouter(manager_) {}

    function twin() external pure returns (bool) {
        return true;
    }
}

/// @notice I-05 (phase-one review, Informational, fixed by the economics lane) and F-026 (09-24 audit, Info: the
///         curated identity path had no tests): if the curated router's msgSender() failed or returned zero, the swap
///         went on as an unauthenticated generic-caller swap.
/// @dev At r31 HookrRoot._identity reverts InvalidHookData when the curated router's code is not the code pinned at
///      construction, or its msgSender() reverts, returns zero, returns a word above 160 bits or returns short; a good
///      answer authenticates the locker. The r31 suites had no test of these refusals; the real Universal Router path
///      is covered by core/FeeOnlyPath.t.sol (test_feeOnlySwapKeepsCuratedRouterIdentity).
contract HookrRootCuratedIdentityTest is PeripheryFixture {
    CuratedRouter private curated;
    HookrRoot private curatedRoot;
    HookrRules private curatedRules;
    PoolKey private key;

    function setUp() public {
        _setUpPeriphery();
        curated = new CuratedRouter(manager);
        bytes memory args = abi.encode(manager, registry, address(router), address(quoter), address(curated));
        bytes32 initHash = keccak256(abi.encodePacked(type(HookrRoot).creationCode, args));
        bytes32 salt;
        for (uint256 i;; ++i) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x2acc) {
                salt = bytes32(i);
                break;
            }
        }
        curatedRoot = new HookrRoot{salt: salt}(manager, registry, address(router), address(quoter), address(curated));
        curatedRules = new HookrRules(manager, registry, protocol, address(curatedRoot), 0);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(curatedRules),
            codeHash: address(curatedRules).codehash,
            schemaHash: curatedRules.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(curatedRoot), address(curatedRoot).codehash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(curatedRoot), address(curatedRoot).codehash);
        registry.queue(registry.ADMIT(), abi.encode(address(curatedRoot), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(curatedRoot), a);

        bool aFirst = address(tokenA) < address(tokenB);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(aFirst ? address(tokenA) : address(tokenB)));
        members[0].config.rules = address(curatedRules);
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(aFirst ? address(tokenB) : address(tokenA), "", "", 0, bytes32(0)),
            address(curatedRoot),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        assertEq(address(key.hooks), address(curatedRoot));
        vm.startPrank(trader);
        tokenA.approve(address(curated), type(uint256).max);
        tokenB.approve(address(curated), type(uint256).max);
        vm.stopPrank();
    }

    function _refused() private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(curatedRoot),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(IHookrRootEvents.InvalidHookData.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function testGoodAnswerAuthenticatesTheLocker() public {
        vm.prank(trader);
        curated.swap(key, true, -1e18);
        // The protocol fee is booked for the authenticated payer: the locker, not the curated router.
        assertGt(curatedRules.protocolFeePaid(trader, key.currency0), 0, "payer is the locker");
        assertEq(curatedRules.protocolFeePaid(address(curated), key.currency0), 0, "not the router");
    }

    function testEveryBadAnswerRevertsInsteadOfDowngrading() public {
        string[4] memory labels = ["revert", "zero", "above 160 bits", "short return"];
        for (uint8 m = 1; m <= 4; ++m) {
            curated.setMode(m);
            vm.prank(trader);
            vm.expectRevert(_refused());
            curated.swap(key, true, -1e18);
            emit log_named_string("refused", labels[m - 1]);
        }
    }

    function testChangedCuratedCodeIsRefused() public {
        // Same answers, different runtime: the root compares the code hash pinned at construction.
        CuratedRouterTwin twin = new CuratedRouterTwin(manager);
        vm.etch(address(curated), address(twin).code);
        assertTrue(address(curated).codehash != curatedRoot.curatedRouterCodeHash());
        vm.prank(trader);
        vm.expectRevert(_refused());
        curated.swap(key, true, -1e18);
    }
}
