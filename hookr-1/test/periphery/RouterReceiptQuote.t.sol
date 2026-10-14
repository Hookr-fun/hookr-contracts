// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRootRoute} from "../../src/interfaces/IHookrRootRoute.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrReferralDistributor} from "../../src/engagement/HookrReferralDistributor.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {TemplateAdvisory} from "../kit/TemplateAdvisory.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {GaslessToken, MockRegistry, MockRoot, MockPermit2} from "../gasless/GaslessMocks.sol";

/// @notice The router fills the program receipt's quote from the root's narrow read, `poolRoute(id).quote`, not
///         from the whole `poolConfig`. Both read the one stored quote of the pool record, so the receipt carries the
///         same currency for every pool kind the router serves, and a root without the narrow read still gets
///         `poolConfig`'s. A program scope's quote is checked with the same narrow read at creation, and a referral
///         campaign reads the configuration once for the two fields it checks.
contract RouterReceiptQuoteTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    TemplateAdvisory internal advisory;
    HookrPrograms internal programs;

    function setUp() public {
        _setUpPeriphery();
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        advisory = new TemplateAdvisory();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: advisory.configSchemaHash(),
            caps: HookrTypes.Caps(1000, 0, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev kind 0: every native rule; 1: fee-only (base fee alone, no guard); 2: Hookr dynamic fees with every rule;
    ///      3: fee-only with a fee-only advisory.
    function _kind(Currency quote, uint256 kind) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(quote);
        if (kind == 1 || kind == 3) {
            m.rules.burnBps = 0;
            m.rules.lpBps = 0;
            m.rules.royaltyBps = 0;
            m.rules.royaltyTo = address(0);
        } else if (kind == 2) {
            m.rules.maxFeePips = 50_000;
            m.rules.dynamicFeeSens = 5;
        }
        if (kind == 3) {
            m.config.advisory = address(advisory);
            m.config.advisoryGasLimit = 100_000;
            m.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        }
    }

    function _open(HookrToken subject, Currency quote, uint256 kind) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _kind(quote, kind);
        bool native = Currency.unwrap(quote) == address(0);
        bytes32 family;
        if (kind == 3) {
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encode(uint24(500));
            (family,) = launcher.launchAdvised{value: native ? 1e24 : 0}(
                IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
                address(root),
                members,
                data,
                vm.getBlockTimestamp()
            );
        } else {
            (family,) = launcher.launch{value: native ? 1e24 : 0}(
                IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
                address(root),
                members,
                vm.getBlockTimestamp()
            );
        }
        key = launcher.position(family, 0).key;
    }

    /// @dev An Immediate points program, one point per unit of quote volume.
    function _terms() internal view returns (P.Terms memory t) {
        t.mode = P.Mode.Immediate;
        t.start = uint64(vm.getBlockTimestamp());
        t.end = uint64(vm.getBlockTimestamp() + 1 days);
        t.pointBudget = 1e30;
        t.walletPointCap = 1e30;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("authenticated-router-user-swap");
        t.name = "Receipts";
        t.pointDecimals = 18;
    }

    /// @dev `key`'s pool as the program's one scope, with `quoteAsset` as its quote.
    function _scopes(PoolKey memory key, address quoteAsset) internal view returns (P.Scope[] memory s) {
        s = new P.Scope[](1);
        s[0] = P.Scope(address(root), PoolId.unwrap(key.toId()), root.policyHash(key.toId()), quoteAsset, 1, 1, 0, 0);
    }

    function _campaign(PoolKey memory key, address quoteAsset) internal returns (uint256[] memory ids) {
        P.Terms memory t = _terms();
        P.Scope[] memory s = _scopes(key, quoteAsset);
        ids = new uint256[](1);
        ids[0] = programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
    }

    /// @dev A rewarded router buy by the trader; the program admits only a receipt whose quote asset is `quoteAsset`.
    function _rewardedBuy(PoolKey memory key, address quoteAsset) internal returns (uint256 points) {
        (IHookrRouter.Swap memory p, uint256[] memory ids) = _prepare(key, quoteAsset);
        points = _execute(p, ids, quoteAsset == address(0));
    }

    /// @dev The swap and its program, built before any call is counted.
    function _prepare(PoolKey memory key, address quoteAsset)
        internal
        returns (IHookrRouter.Swap memory p, uint256[] memory ids)
    {
        ids = _campaign(key, quoteAsset);
        p = _swap(key, true, true, 1e21);
    }

    function _execute(IHookrRouter.Swap memory p, uint256[] memory ids, bool native) internal returns (uint256) {
        vm.prank(trader);
        router.swap{value: native ? 1e21 : 0}(p, address(programs), ids);
        return programs.points(ids[0], trader);
    }

    /// Every pool kind, with the quote as currency1, as currency0 and as native ETH: the narrow read's quote is
    /// poolConfig's, and a rewarded swap's receipt, which the program checks against poolConfig's quote, is recorded
    /// with it.
    function testPoolRouteQuoteIsPoolConfigQuoteOnEveryPoolKind() public {
        uint256 opened;
        for (uint256 kind; kind < 4; ++kind) {
            for (uint256 side; side < 3; ++side) {
                Currency quote = side == 2 ? Currency.wrap(address(0)) : Currency.wrap(address(tokenB));
                // side 0: the subject sorts first, so the quote is currency1; side 1: the quote is currency0.
                HookrToken subject = _freshSubject(side == 2 ? 0 : side + 1);
                PoolKey memory key = _open(subject, quote, kind);
                ++opened;
                PoolId id = key.toId();
                (Currency routeQuote, address routeAdvisory) = root.poolRoute(id);
                HookrTypes.PoolConfig memory pc = root.poolConfig(id);
                assertEq(Currency.unwrap(routeQuote), Currency.unwrap(pc.quote), "poolRoute's quote is poolConfig's");
                assertEq(Currency.unwrap(pc.quote), Currency.unwrap(quote), "the launched quote");
                assertEq(routeAdvisory, pc.advisory, "and the advisory");
                assertEq(
                    Currency.unwrap(key.currency0) == Currency.unwrap(quote),
                    side != 0,
                    "the quote on the intended side"
                );
                assertGt(_rewardedBuy(key, Currency.unwrap(pc.quote)), 0, "the receipt carries poolConfig's quote");
            }
        }
        assertEq(opened, 12);
    }

    /// The receipt names the pool's quote, not its subject: a program cannot be scoped to the subject, a receipt that
    /// named the subject (the narrow read mocked to answer it) is refused by a program on the quote, and the real
    /// receipt is credited.
    function testReceiptNamesTheQuoteNotTheSubject() public {
        HookrToken subject = _freshSubject(0);
        PoolKey memory key = _open(subject, Currency.wrap(address(tokenB)), 0);
        P.Terms memory t = _terms();
        P.Scope[] memory s = _scopes(key, address(subject));
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        uint256[] memory ids = _campaign(key, address(tokenB));
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e21);
        vm.mockCall(
            address(root),
            abi.encodeWithSelector(IHookrRootRoute.poolRoute.selector, key.toId()),
            abi.encode(address(subject), address(0))
        );
        vm.prank(trader);
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        router.swap(p, address(programs), ids);
        vm.clearMockedCalls();
        assertGt(_execute(p, ids, false), 0, "the receipt with the quote is credited");
    }

    /// A root without the narrow read (IHookrRootRoute is optional for roots): the router falls back to poolConfig.
    function testRootWithoutPoolRouteFallsBackToPoolConfig() public {
        PoolKey memory key = _open(tokenA, Currency.wrap(address(tokenB)), 0);
        (IHookrRouter.Swap memory p, uint256[] memory ids) = _prepare(key, address(tokenB));
        vm.mockCallRevert(address(root), abi.encodeWithSelector(IHookrRootRoute.poolRoute.selector), "");
        vm.expectCall(address(root), abi.encodeWithSelector(IHookrRootRoute.poolRoute.selector, key.toId()), 1);
        vm.expectCall(address(root), abi.encodeWithSelector(root.poolConfig.selector, key.toId()), 1);
        assertGt(_execute(p, ids, false), 0, "recorded with poolConfig's quote");
    }

    /// With the narrow read the router no longer reads poolConfig for the receipt.
    function testRewardedSwapReadsPoolRouteNotPoolConfig() public {
        PoolKey memory key = _open(tokenA, Currency.wrap(address(tokenB)), 2);
        (IHookrRouter.Swap memory p, uint256[] memory ids) = _prepare(key, address(tokenB));
        vm.expectCall(address(root), abi.encodeWithSelector(IHookrRootRoute.poolRoute.selector, key.toId()), 1);
        vm.expectCall(address(root), abi.encodeWithSelector(root.poolConfig.selector, key.toId()), 0);
        assertGt(_execute(p, ids, false), 0);
    }

    /// A program scope's quote is checked with the narrow read, as the router reads it: the whole poolConfig is not
    /// read.
    function testProgramScopeQuoteReadsPoolRouteNotPoolConfig() public {
        PoolKey memory key = _open(tokenA, Currency.wrap(address(tokenB)), 2);
        P.Terms memory t = _terms();
        P.Scope[] memory s = _scopes(key, address(tokenB));
        vm.expectCall(address(root), abi.encodeWithSelector(IHookrRootRoute.poolRoute.selector, key.toId()), 1);
        vm.expectCall(address(root), abi.encodeWithSelector(root.poolConfig.selector, key.toId()), 0);
        assertEq(programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false)), 1);
    }

    /// A root without the narrow read: the validator falls back to poolConfig's quote and still refuses a scope that
    /// names another asset.
    function testProgramScopeQuoteFallsBackToPoolConfig() public {
        PoolKey memory key = _open(tokenA, Currency.wrap(address(tokenB)), 0);
        P.Terms memory t = _terms();
        vm.mockCallRevert(address(root), abi.encodeWithSelector(IHookrRootRoute.poolRoute.selector), "");
        P.Scope[] memory wrong = _scopes(key, address(tokenA));
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        programs.createProgram(t, wrong, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        P.Scope[] memory s = _scopes(key, address(tokenB));
        vm.expectCall(address(root), abi.encodeWithSelector(root.poolConfig.selector, key.toId()), 1);
        assertEq(programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false)), 1);
    }

    /// @dev A one-day referral campaign on `key`'s pool with this contract as creator and attestor.
    function _campaignTerms(HookrReferralDistributor distributor, PoolKey memory key)
        internal
        view
        returns (IHookrReferralDistributor.Terms memory t)
    {
        t.root = address(root);
        t.rules = address(rules);
        t.poolId = PoolId.unwrap(key.toId());
        t.configHash = root.policyHash(key.toId());
        t.currency = address(tokenB);
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.referrerBps = 2000;
        t.cashbackBps = 1000;
        t.dailyBudget = 1000;
        t.walletFeeCap = 2000;
        t.attestor = distributor.attestor();
        t.reviewer = royalty;
        t.reviewDelay = distributor.MIN_REVIEW_DELAY();
        t.sourcePolicyHash = keccak256("collected protocol cash only");
    }

    /// A referral campaign reads the pool's configuration once for both the Rules and the quote it checks, and still
    /// refuses a campaign naming other Rules or another currency.
    function testReferralCampaignReadsPoolConfigOnce() public {
        PoolKey memory key = _open(tokenA, Currency.wrap(address(tokenB)), 0);
        HookrReferralDistributor distributor =
            new HookrReferralDistributor(address(new HookrReferralRegistry()), address(registry), address(this));
        tokenB.approve(address(distributor), type(uint256).max);
        IHookrReferralDistributor.Terms memory t = _campaignTerms(distributor, key);
        t.rules = address(advisory);
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
        t = _campaignTerms(distributor, key);
        t.currency = address(tokenA);
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
        t = _campaignTerms(distributor, key);
        vm.expectCall(address(root), abi.encodeWithSelector(root.poolConfig.selector, key.toId()), 1);
        assertEq(distributor.createCampaign(t), 1);
    }

    /// @dev A fresh subject approved for the launcher; `order` 1 sorts it below tokenB, 2 above it, 0 either.
    function _freshSubject(uint256 order) internal returns (HookrToken t) {
        while (true) {
            t = new HookrToken("S", "S", 1e30, address(this));
            bool below = address(t) < address(tokenB);
            if (order == 0 || (order == 1) == below) break;
        }
        t.approve(address(launcher), type(uint256).max);
    }
}

/// @notice The forwarder reads a relayed pool's quote and advisory with the same narrow read, `poolRoute`, and reads
///         `poolConfig` only for a root without it; a root with neither is refused before any pull.
contract ForwarderRouteReadTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    MockRegistry registry = new MockRegistry();
    MockRoot root = new MockRoot();
    GaslessToken t0 = new GaslessToken();
    GaslessToken t1 = new GaslessToken();
    HookrForwarder fwd;

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        registry.set(address(root));
        fwd = new HookrForwarder(PERMIT2, address(registry), address(0xB0B));
    }

    /// @dev An exact-input intent selling currency0 with a 10-unit relayer fee; the root quotes currency0, so the fee
    ///      is taken from the input and the pull is the input plus the fee.
    function _intent() internal returns (IHookrForwarder.HookrSwapIntent memory i, bytes32 id) {
        (Currency c0, Currency c1) = address(t0) < address(t1)
            ? (Currency.wrap(address(t0)), Currency.wrap(address(t1)))
            : (Currency.wrap(address(t1)), Currency.wrap(address(t0)));
        root.setQuote(c0);
        i.key = PoolKey(c0, c1, 0x800000, 60, IHooks(address(root)));
        i.zeroForOne = true;
        i.amountSpecified = -1000;
        i.amountBound = 1;
        i.recipient = address(0x1002);
        i.relayer = address(0xFEE);
        i.relayerFee = 10;
        i.nonce = 1;
        i.deadline = block.timestamp + 60;
        id = PoolId.unwrap(i.key.toId());
    }

    function test_routeIsTheNarrowRead() public {
        (IHookrForwarder.HookrSwapIntent memory i, bytes32 id) = _intent();
        vm.expectCall(address(root), abi.encodeWithSelector(MockRoot.poolRoute.selector, id), 1);
        vm.expectCall(address(root), abi.encodeWithSelector(MockRoot.poolConfig.selector, id), 0);
        (address token, uint256 amount, bool feeFromInput) = fwd.pullOf(i);
        assertEq(token, Currency.unwrap(i.key.currency0));
        assertEq(amount, 1010);
        assertTrue(feeFromInput);
    }

    function test_routeFallsBackToPoolConfigWithoutTheNarrowRead() public {
        (IHookrForwarder.HookrSwapIntent memory i, bytes32 id) = _intent();
        vm.mockCallRevert(address(root), abi.encodeWithSelector(MockRoot.poolRoute.selector), "");
        vm.expectCall(address(root), abi.encodeWithSelector(MockRoot.poolConfig.selector, id), 1);
        (address token, uint256 amount, bool feeFromInput) = fwd.pullOf(i);
        assertEq(token, Currency.unwrap(i.key.currency0));
        assertEq(amount, 1010);
        assertTrue(feeFromInput);
    }

    function test_rootWithNeitherReadIsRefused() public {
        (IHookrForwarder.HookrSwapIntent memory i,) = _intent();
        vm.mockCallRevert(address(root), abi.encodeWithSelector(MockRoot.poolRoute.selector), "");
        vm.mockCallRevert(address(root), abi.encodeWithSelector(MockRoot.poolConfig.selector), "");
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.UnsupportedPool.selector, address(root)));
        fwd.pullOf(i);
    }
}
