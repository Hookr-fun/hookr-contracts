// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {ReleaseWiring} from "./ReleaseWiring.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
    function msgSender() external view returns (address);
}

interface IPermit2Bench {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Fixture on the real 4663 PoolManager, Universal Router 2.1.1 and Permit2 runtimes, etched at their chain
///         addresses. Two standing ERC-20-quote pools: a fee-only pool (base LP fee, no per-swap add-on) and a full
///         pool (Hookr dynamic fees, Auto Burn, LP Rewards and royalty).
abstract contract GasBenchFixture is Test {
    using PoolIdLibrary for PoolKey;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    uint160 internal constant SQRT_ONE = uint160(1 << 96);
    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    address internal constant RELAYER = address(0xE1A);

    IPoolManager internal manager;
    address internal ur;
    address internal permit2;
    HookrRegistry internal registry;
    HookrRules internal rules;
    HookrRoot internal root;
    HookrRouter internal router;
    HookrQuoter internal quoter;
    HookrLauncher internal launcher;
    HookrForwarder internal fwd;
    HookrToken internal subject;
    HookrToken internal quoteFee;
    HookrToken internal quoteFull;
    HookrToken[8] internal quotes;
    address internal trader = address(0x1002);
    address internal royaltyTo = address(0x1003);
    address internal protocol = address(0x1001);
    uint256 internal ownerPk = 0xA11CE;
    address internal owner;

    bytes32 internal feeFamily;
    bytes32 internal fullFamily;
    PoolKey internal feeKey;
    PoolKey internal fullKey;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.etch(Chain4663Code.POOL_MANAGER_ADDRESS, Chain4663Code.POOL_MANAGER);
        vm.etch(Chain4663Code.UNIVERSAL_ROUTER_ADDRESS, Chain4663Code.UNIVERSAL_ROUTER);
        vm.etch(Chain4663Code.PERMIT2_ADDRESS, Chain4663Code.PERMIT2);
        manager = IPoolManager(Chain4663Code.POOL_MANAGER_ADDRESS);
        ur = Chain4663Code.UNIVERSAL_ROUTER_ADDRESS;
        permit2 = Chain4663Code.PERMIT2_ADDRESS;
        owner = vm.addr(ownerPk);
        registry = new HookrRegistry(address(this), manager, 30 minutes);
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        fwd = new HookrForwarder(permit2, address(registry), predictedRouter);
        router = new HookrRouter(manager, registry, address(fwd));
        require(address(router) == predictedRouter, "router prediction");
        quoter = new HookrQuoter(manager, registry);
        launcher = new HookrLauncher(manager, registry);
        root = ReleaseWiring.deployRoot(manager, registry, address(router), address(quoter), ur);
        rules = new HookrRules(manager, registry, protocol, address(root), 0);
        ReleaseWiring.registerRootAndLauncher(registry, address(root), address(launcher));
        ReleaseWiring.admitAfterDelay(registry, address(root), ReleaseWiring.rulesAdmission(rules, 200_000));

        subject = new HookrToken("Subject", "SUB", 1e30, address(this));
        quoteFee = new HookrToken("Quote F", "QF", 1e30, address(this));
        quoteFull = new HookrToken("Quote X", "QX", 1e30, address(this));
        HookrToken[3] memory standing = [subject, quoteFee, quoteFull];
        for (uint256 i; i < 3; ++i) {
            HookrToken t = standing[i];
            t.approve(address(launcher), type(uint256).max);
            t.transfer(trader, 1e27);
            t.transfer(owner, 1e27);
            vm.startPrank(trader);
            t.approve(address(router), type(uint256).max);
            t.approve(permit2, type(uint256).max);
            IPermit2Bench(permit2).approve(address(t), ur, type(uint160).max, type(uint48).max);
            vm.stopPrank();
            vm.prank(owner);
            t.approve(permit2, type(uint256).max);
        }
        // Each spare quote is queued right after its creation: under --isolate every top-level call is a transaction
        // that spends a nonce of this contract, so the order of creations and calls fixes the spares' addresses.
        for (uint256 i; i < 8; ++i) {
            quotes[i] = new HookrToken("Q", "Q", 1e30, address(this));
            quotes[i].approve(address(launcher), type(uint256).max);
            ReleaseWiring.queueQuote(registry, address(quotes[i]));
        }
        // The Root opens pools only on catalog quotes: the two standing quotes, then the eight spares.
        ReleaseWiring.queueQuote(registry, address(quoteFee));
        ReleaseWiring.queueQuote(registry, address(quoteFull));
        ReleaseWiring.waitDelay(registry);
        ReleaseWiring.addQuote(registry, address(quoteFee));
        ReleaseWiring.addQuote(registry, address(quoteFull));
        for (uint256 i; i < 8; ++i) {
            ReleaseWiring.addQuote(registry, address(quotes[i]));
        }
        vm.deal(address(this), 1e30);
        vm.deal(trader, 1e28);

        feeFamily = _launchOne(Currency.wrap(address(quoteFee)), 60, false);
        feeKey = launcher.position(feeFamily, 0).key;
        fullFamily = _launchOne(Currency.wrap(address(quoteFull)), 60, true);
        fullKey = launcher.position(fullFamily, 0).key;
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev full: dynamic fees (sensitivity 5, 5% ceiling), Auto Burn 1%, LP Rewards 2%, royalty 5% and a 25% protocol share.
    ///      Otherwise fee-only: the 0.3% base LP fee and nothing per swap.
    function _member(Currency quote, int24 spacing, bool full) internal view returns (IHookrLauncher.Member memory m) {
        m.quote = quote;
        m.tickSpacing = spacing;
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
        m.config.policyId = keccak256("gas-bench");
        m.rules.maxFeePips = full ? 50_000 : 3000;
        m.rules.protocolShareBps = 2500;
        if (full) {
            m.rules.dynamicFeeSens = 5;
            m.rules.burnBps = 100;
            m.rules.lpBps = 200;
            m.rules.royaltyBps = 500;
            m.rules.royaltyTo = royaltyTo;
        }
    }

    function _launchOne(Currency quote, int24 spacing, bool full) internal returns (bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote, spacing, full);
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
    }

    function _zeroForOne(PoolKey memory key, bool buy) internal view returns (bool) {
        bool subjectIs0 = Currency.unwrap(key.currency0) == address(subject);
        return buy ? !subjectIs0 : subjectIs0;
    }

    function _params(PoolKey memory key, bool buy, uint128 amount) internal view returns (IHookrRouter.Swap memory p) {
        bool zeroForOne = _zeroForOne(key, buy);
        p = IHookrRouter.Swap(
            key,
            zeroForOne,
            -int128(amount),
            1,
            zeroForOne ? MIN_PRICE : MAX_PRICE,
            trader,
            vm.getBlockTimestamp() + 1000
        );
    }

    function _routerSwap(PoolKey memory key, bool buy, uint128 amount) internal {
        IHookrRouter.Swap memory p = _params(key, buy, amount);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    function _urSwap(PoolKey memory key, bool buy, uint128 amount) internal {
        bool zeroForOne = _zeroForOne(key, buy);
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amount, 1, 0, ""));
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, uint256(amount));
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(trader, trader);
        IUniversalRouter(ur).execute(hex"10", inputs, vm.getBlockTimestamp() + 1000);
    }

    function _intent(PoolKey memory key, bool buy, uint128 amount, uint256 nonce)
        internal
        view
        returns (IHookrForwarder.HookrSwapIntent memory i)
    {
        IHookrRouter.Swap memory p = _params(key, buy, amount);
        i.key = key;
        i.zeroForOne = p.zeroForOne;
        i.amountSpecified = p.amountSpecified;
        i.amountBound = 1;
        i.sqrtPriceLimitX96 = p.sqrtPriceLimitX96;
        i.recipient = owner;
        i.relayer = RELAYER;
        i.relayerFee = 1e15;
        i.campaigns = new uint256[](0);
        i.nonce = nonce;
        i.deadline = vm.getBlockTimestamp() + 1000;
    }

    function _sign(IHookrForwarder.HookrSwapIntent memory i) internal view returns (bytes memory) {
        (address token, uint256 amount,) = fwd.pullOf(i);
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                fwd.WITNESS_TYPE_STRING()
            )
        );
        bytes32 tp = keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 structHash =
            keccak256(abi.encode(typeHash, tp, address(fwd), fwd.permit2Nonce(i.nonce), i.deadline, fwd.hashIntent(i)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2Bench(permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _relayed(PoolKey memory key, bool buy, uint128 amount, uint256 nonce)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        IHookrForwarder.HookrSwapIntent memory i = _intent(key, buy, amount, nonce);
        bytes memory sig = _sign(i);
        vm.prank(RELAYER);
        (amountIn, amountOut) = fwd.execute(i, owner, sig);
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    /// @dev Steady state: claims, liabilities, balances, flow words and the relayer's nonce word are nonzero.
    function _warm(PoolKey memory key) internal {
        _routerSwap(key, true, 1e21);
        _nextBlock();
        _routerSwap(key, false, 5e20);
        _nextBlock();
        _relayed(key, true, 1e20, 1);
        _nextBlock();
    }

    receive() external payable {}
}
