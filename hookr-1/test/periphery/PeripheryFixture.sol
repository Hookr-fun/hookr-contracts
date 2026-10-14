// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";

abstract contract PeripheryFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    IPoolManager internal manager;
    HookrRegistry internal registry;
    HookrRules internal rules;
    HookrRoot internal root;
    HookrRouter internal router;
    HookrQuoter internal quoter;
    HookrLauncher internal launcher;
    HookrToken internal tokenA;
    HookrToken internal tokenB;
    address internal protocol = address(0x1001);
    address internal trader = address(0x1002);
    address internal royalty = address(0x1003);
    uint160 internal constant SQRT_ONE = uint160(1 << 96);
    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;

    /// @dev HookrRules' global minProtocolShareBps in this fixture. Zero admits any share; production deploys 2,000.
    function _minProtocolShareBps() internal view virtual returns (uint16) {
        return 0;
    }

    function _setUpPeriphery() internal {
        _deployPeriphery(IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)))));
    }

    function _deployPeriphery(IPoolManager manager_) internal {
        manager = manager_;
        registry = new HookrRegistry(address(this), manager, _registryDelay());
        router = new HookrRouter(manager, registry, address(0));
        quoter = new HookrQuoter(manager, registry);
        launcher = new HookrLauncher(manager, registry);
        // The release no longer has HookrEngagement; its deploy's nonce is still spent so every later fixture
        // address, and the digests pinned to them, stay as they were.
        vm.setNonce(address(this), vm.getNonce(address(this)) + 1);
        root = ReleaseWiring.deployRoot(manager, registry, address(router), address(quoter), address(0));
        rules = new HookrRules(manager, registry, protocol, address(root), _minProtocolShareBps());
        ReleaseWiring.registerRootAndLauncher(registry, address(root), address(launcher));
        ReleaseWiring.admitAfterDelay(registry, address(root), ReleaseWiring.rulesAdmission(rules, 200_000));
        tokenA = new HookrToken("Token A", "TA", 1e30, address(this));
        tokenB = new HookrToken("Token B", "TB", 1e30, address(this));
        // Both fixture tokens serve as quotes; the Root only opens pools on catalog quotes.
        address[] memory quotes = new address[](2);
        (quotes[0], quotes[1]) = (address(tokenA), address(tokenB));
        ReleaseWiring.catalogQuotes(registry, quotes);
        tokenA.approve(address(launcher), type(uint256).max);
        tokenB.approve(address(launcher), type(uint256).max);
        tokenA.transfer(trader, 1e27);
        tokenB.transfer(trader, 1e27);
        vm.startPrank(trader);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.deal(address(this), 1e30);
        vm.deal(trader, 1e28);
    }

    /// @dev The registry delay this fixture deploys with. Unit suites keep one day; a fork test that models the
    ///      release overrides it with the release's 30 minutes.
    function _registryDelay() internal pure virtual returns (uint48) {
        return 1 days;
    }

    /// @dev Adds `asset` to the registry's quote catalog through the timelock.
    function _catalogQuote(address asset) internal {
        ReleaseWiring.catalogQuote(registry, asset);
    }

    function _member(Currency quote) internal view returns (IHookrLauncher.Member memory m) {
        m.quote = quote;
        m.tickSpacing = 60;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000;
        m.tickUpper = 60_000;
        m.liquidity = 1e24;
        m.amount0Max = 1e24;
        m.amount1Max = 1e24;
        m.config.rules = address(rules);
        m.config.baseLpFeePips = 3000;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("phase-one-test");
        m.rules.maxFeePips = 3000;
        m.rules.burnBps = 100;
        m.rules.lpBps = 200;
        m.rules.potBps = 0;
        m.rules.royaltyBps = 500;
        m.rules.protocolShareBps = 2500;
        m.rules.potEveryNBuys = 0;
        m.rules.potMinBuyQuote = 0;
        m.rules.royaltyTo = royalty;
    }

    function _launch(bool subjectFirst, bool nativeQuote)
        internal
        returns (bytes32 family, PoolKey memory key, HookrToken subject, Currency quote)
    {
        if (nativeQuote) {
            subject = tokenA;
            quote = Currency.wrap(address(0));
        } else {
            bool aFirst = address(tokenA) < address(tokenB);
            subject = aFirst == subjectFirst ? tokenA : tokenB;
            quote = Currency.wrap(aFirst == subjectFirst ? address(tokenB) : address(tokenA));
        }
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote);
        (family,) = launcher.launch{value: nativeQuote ? 1e24 : 0}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _swap(PoolKey memory key, bool buy, bool exactInput, uint128 amount)
        internal
        view
        returns (IHookrRouter.Swap memory p)
    {
        Currency subject = root.poolConfig(key.toId()).subject;
        bool inputIs0 = buy
            ? Currency.unwrap(key.currency0) != Currency.unwrap(subject)
            : Currency.unwrap(key.currency0) == Currency.unwrap(subject);
        p = IHookrRouter.Swap(
            key,
            inputIs0,
            exactInput ? -int128(amount) : int128(amount),
            exactInput ? 1 : uint128(1e25),
            inputIs0 ? MIN_PRICE : MAX_PRICE,
            trader,
            vm.getBlockTimestamp()
        );
    }

    receive() external payable {}
}
