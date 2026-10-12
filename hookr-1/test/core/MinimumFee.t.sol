// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";
import {RulesData} from "../utils/RulesData.sol";
import {MockGroupAdvisory, MockBadGroupAdvisory} from "../mocks/MockGroupAdvisory.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @notice The Hookr minimum: Hookr takes at least a pool's frozen minimum of every trader swap only on a Hookr token's
///         pool with no arb recapture and no rule that earns Hookr a share of its fees (LP Rewards, Auto Burn, dynamic
///         fees or the Anti-Snipe tax that can pay Hookr at least a pip of a swap at the pool's protocolShareBps).
///         There the quote take is the minimum, in the pool's quote and on top of the untouched base LP fee. Every
///         other pool binds none: a pool with such a rule pays Hookr its rule shares alone, a pool with arb recapture
///         its arb recapture cut, another token's market nothing. A dynamic fee or Snipe whose share rounds to zero on
///         every swap earns Hookr nothing and keeps the minimum (`test_minFee_onePipThresholds`). Governed on the
///         treasury for new pools behind the 30-minute timelock: a rate for pools without arb recapture, one for pools
///         with it (which these Rules never bind), and a per-integrator override that reaches only the pools whose ids
///         the integrator approved. An advisory's charge is its own, except Tax + Conversion's, whose queues pay
///         Hookr the pool's share of each tax: a pool with that advisory binds none
///         (`test_minFee_taxConversionEarnsHookrAShare`).
contract MinimumFeeTest is GovernanceSecurityBase {
    using PoolIdLibrary for PoolKey;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    address internal constant TARGET = address(0x7A7);
    address internal constant INTEGRATOR = address(0x1A7E);
    address internal constant OTHER = address(0x2B8F);
    uint16 internal constant RELEASE_FLOOR = 2_000;
    uint16 internal constant NONE = type(uint16).max;
    uint256 internal constant PIPS = 1_000_000;
    PoolId internal constant POOL = PoolId.wrap(bytes32(uint256(0xB00)));
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    /// @dev The exclusive group Tax + Conversion's advisory declares, and the account standing in for its tax queue.
    bytes32 internal constant TAX_GROUP = keccak256("DIRECTIONAL_QUOTE_TAX");
    address internal constant TAX_QUEUE = address(0x7A5);

    HookrTreasury internal treasury;
    HookrRules internal r2;
    /// @dev Rules paying the same treasury with an immutable floor of zero, so a pool can bind at a zero share.
    HookrRules internal r0;
    uint256 internal salt;

    struct Paid {
        uint256 protocol;
        uint256 integrator;
        uint256 royalty;
        uint256 earned;
        uint256 quote;
        uint256 allocations;
        uint24 lpFee;
        uint256 advisoryFee;
    }

    function setUp() public {
        _setUpPeriphery();
        treasury = new HookrTreasury(address(this), TARGET, manager);
        r2 = new HookrRules(manager, registry, address(treasury), address(root), RELEASE_FLOOR);
        r0 = new HookrRules(manager, registry, address(treasury), address(root), 0);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(r2), address(r2).codehash, r2.configSchemaHash());
        a.caps = HookrTypes.Caps(600_000, 400_000, 1000);
        IHookrRegistry.Admission memory z = _rulesAdmission(address(r0), address(r0).codehash, r0.configSchemaHash());
        z.caps = a.caps;
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        registry.queue(registry.ADMIT(), abi.encode(address(root), z));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        registry.admit(address(root), z);
        treasury.admitSource(address(r2));
        treasury.admitSource(address(r0));
        vm.deal(trader, 1e30);
    }

    // ------------------------------------------------------------------ helpers

    function _setMin(bool recapture, uint16 pips) internal {
        treasury.proposeMinFee(recapture, pips);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptMinFee(recapture);
    }

    function _setOverride(address account, uint16 pips) internal {
        treasury.proposeIntegratorMinFee(account, pips);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegratorMinFee(account);
    }

    /// @dev `account` approves pool `key` binding its override.
    function _approve(address account, PoolKey memory key) internal {
        vm.prank(account);
        treasury.approveMinFeePool(key.toId(), true);
    }

    /// @dev The key `_launch` gives the first member of `members` on `subject`.
    function _keyOf(address subject, IHookrLauncher.Member[] memory members) internal view returns (PoolKey memory) {
        return PoolKey(
            NATIVE, Currency.wrap(subject), LPFeeLibrary.DYNAMIC_FEE_FLAG, members[0].tickSpacing, IHooks(address(root))
        );
    }

    function _list(address account, uint16 bps) internal {
        treasury.proposeIntegrator(account, bps);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegrator(account);
    }

    /// @dev A one-member native-quoted family on r2 without rules: no dynamic fee, Snipe, LP Rewards, Auto Burn or
    ///      royalty, an 80/20 share.
    function _members(uint16 lp, uint16 burn, address integrator)
        internal
        view
        returns (IHookrLauncher.Member[] memory members)
    {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(NATIVE);
        members[0].config.rules = address(r2);
        members[0].config.caps = HookrTypes.Caps(600_000, 400_000, 1000);
        members[0].rules.lpBps = lp;
        members[0].rules.burnBps = burn;
        members[0].rules.protocolShareBps = 2_000;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.integrator = integrator;
    }

    /// @dev A fresh RulesConfig with no rule at the 2,000 share.
    function _plainRules() internal view returns (HookrTypes.RulesConfig memory) {
        return _members(0, 0, address(0))[0].rules;
    }

    function _hookrToken() internal returns (address s) {
        HookrToken t = new HookrToken{salt: bytes32(++salt)}("S", "S", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        t.transfer(trader, 1e27);
        vm.prank(trader);
        t.approve(address(router), type(uint256).max);
        s = address(t);
    }

    function _otherToken() internal returns (address s) {
        MockERC20 t = new MockERC20("E", "E", 18);
        t.mint(address(this), 1e30);
        t.mint(trader, 1e27);
        t.approve(address(launcher), type(uint256).max);
        vm.prank(trader);
        t.approve(address(router), type(uint256).max);
        s = address(t);
    }

    function _launch(address subject, IHookrLauncher.Member[] memory members) internal returns (PoolKey memory) {
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(subject, "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    function _minimumOf(PoolKey memory key) internal view returns (uint16) {
        return IHookrRecaptureRules(address(r2)).minimumFee(key.toId());
    }

    function _minimumOn(HookrRules r, PoolKey memory key) internal view returns (uint16) {
        return IHookrRecaptureRules(address(r)).minimumFee(key.toId());
    }

    /// @dev Binds a pool of `subject` on `r` directly, as the root does during initialization: `c`, with its dynamic
    ///      fee liquidity word when it has dynamic fees and with arb recapture data when `lane`, and `advisory` in the
    ///      pool's config.
    function _bindOn(HookrRules r, address subject, HookrTypes.RulesConfig memory c, bool lane, address advisory)
        internal
        returns (PoolKey memory key)
    {
        key = PoolKey(NATIVE, Currency.wrap(subject), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        HookrTypes.PoolConfig memory pc = _pc(subject);
        pc.rules = address(r);
        pc.advisory = advisory;
        uint96 minLiquidity = c.dynamicFeeSens == 0 ? 0 : 1e18;
        bytes memory data = RulesData.encode(c, minLiquidity);
        if (lane) {
            HookrTypes.RecaptureConfig memory rc;
            rc.on = true;
            rc.traderBps = 2_500;
            rc.lpBps = 7_500;
            rc.releaseBlocks = 36_000;
            data = RulesData.lane(c, minLiquidity, rc);
        }
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(key.toId()));
        vm.prank(address(root));
        r.bind(key, pc, data);
    }

    /// @dev Binds a pool of a fresh Hookr token on r2 without rules: with arb recapture data when `lane`, naming
    ///      `integrator`, its id approved by `integrator` first when `approved`.
    function _bind(bool lane, address integrator, bool approved) internal returns (PoolKey memory key) {
        address s = _hookrToken();
        if (approved) _approve(integrator, _keyOf(s, _members(0, 0, integrator)));
        HookrTypes.RulesConfig memory c = _plainRules();
        c.integrator = integrator;
        key = _bindOn(r2, s, c, lane, address(0));
    }

    function _pc(address s) internal view returns (HookrTypes.PoolConfig memory pc) {
        pc.subject = Currency.wrap(s);
        pc.quote = NATIVE;
        pc.rules = address(r2);
        pc.liquidityOwner = address(this);
        pc.baseLpFeePips = 3000;
        pc.caps = HookrTypes.Caps(600_000, 400_000, 1000);
    }

    /// @dev Admits `advisory` on the root as a strict advisory of both phases, with a quote take of up to `quoteCap`
    ///      pips and a 10,000-pip surcharge cap.
    function _admitAdvisory(address advisory, uint24 quoteCap) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: advisory,
            codeHash: advisory.codehash,
            schemaHash: FixedAdvice(advisory).configSchemaHash(),
            caps: HookrTypes.Caps(10_000, quoteCap, 0),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev `_launch` of a one-member family without rules on `subject`, with `advisory` asked before each swap.
    function _launchAdvised(address subject, address advisory) internal returns (PoolKey memory) {
        IHookrLauncher.Member[] memory members = _members(0, 0, address(0));
        members[0].config.advisory = advisory;
        members[0].config.advisoryGasLimit = 2_000_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(subject, "", "", 0, bytes32(0)),
            address(root),
            members,
            new bytes[](1),
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    /// @dev A trader's swap of 1e18 on a native-quoted pool bound by `_bindOn`, as the root hands it to the Rules.
    function _context(PoolKey memory key, bool buy, bool exactInput)
        internal
        view
        returns (HookrTypes.SwapContext memory x)
    {
        x.id = key.toId();
        x.sender = trader;
        x.payer = trader;
        x.beneficiary = trader;
        x.subject = key.currency1;
        x.quote = NATIVE;
        x.isBuy = buy;
        x.exactInput = exactInput;
        x.zeroForOne = buy;
        x.amountSpecified = exactInput ? -1e18 : int256(1e18);
        x.baseLpFeePips = 3000;
    }

    /// @dev One swap through the router as the trader; what the Rules credited, the root's HookFee and the quote that
    ///      went through the pool, from that swap's events.
    function _swapAs(PoolKey memory key, bool buy, bool exactInput, uint128 amount) internal returns (Paid memory p) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        IHookrRouter.Swap memory s = _swap(key, buy, exactInput, amount);
        // A native exact-output buy sends exactly its maximum input.
        if (buy && !exactInput) s.amountBound = uint128(amount) * 2;
        vm.recordLogs();
        vm.prank(trader);
        router.swap{value: buy ? (exactInput ? amount : uint256(amount) * 2) : 0}(s, address(0), new uint256[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Each event's data is static words, read by index: FeesAllocated (protocol, royalty, refund, advisory
        // recipient, advisory fee), IntegratorPaid (amount), HookFee (earned, refund, burned) and the PoolManager's
        // Swap (amount0, amount1, sqrtPriceX96, liquidity, tick, fee).
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            bytes memory data = logs[i].data;
            if (logs[i].emitter == address(r2) && t0 == IHookrRulesEvents.FeesAllocated.selector) {
                (p.protocol, p.royalty, p.advisoryFee) = (_word(data, 0), _word(data, 1), _word(data, 4));
                ++p.allocations;
            } else if (logs[i].emitter == address(r2) && t0 == IHookrRulesState.IntegratorPaid.selector) {
                p.integrator = _word(data, 0);
            } else if (logs[i].emitter == address(root) && t0 == IHookrRootState.HookFee.selector) {
                p.earned = _word(data, 0);
            } else if (logs[i].emitter == address(manager) && t0 == SWAP_TOPIC) {
                int256 a0 = int256(_word(data, 0));
                p.quote = uint256(a0 < 0 ? -a0 : a0);
                p.lpFee = uint24(_word(data, 5));
            }
        }
    }

    /// @dev Word `index` of an event's static ABI data.
    function _word(bytes memory data, uint256 index) internal pure returns (uint256 w) {
        require(data.length >= (index + 1) * 32, "short event data");
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), mul(index, 32)))
        }
    }

    function _backed() internal view {
        assertEq(manager.balanceOf(address(r2), NATIVE.toId()), r2.totalLiability(NATIVE), "backed to the wei");
    }

    /// @dev The Rules' take on one swap of a native-quoted pool whose whole quote take is `rate` pips, as the root
    ///      prices it: pips of the gross buyer spend, of the quote out on an exact-input sell, and reserved on top of
    ///      the requested output on an exact-output sell.
    function _take(bool buy, bool exactInput, uint256 requested, uint256 quote, uint256 rate)
        internal
        pure
        returns (uint256)
    {
        if (buy) {
            uint256 basis = quote * PIPS / (PIPS - rate);
            if (exactInput && basis > requested) basis = requested;
            return basis * rate / PIPS;
        }
        if (exactInput) return quote * rate / PIPS;
        return (requested * rate + (PIPS - rate) - 1) / (PIPS - rate);
    }

    // ------------------------------------------------------------------ treasury terms: bounds and timelock

    function test_minFee_constantsAndStart() public view {
        assertEq(treasury.MAX_MIN_FEE_PIPS(), 10_000);
        assertEq(treasury.DEFAULT_MIN_FEE_PIPS(), 1_000);
        assertEq(treasury.NO_MIN_FEE_OVERRIDE(), NONE);
        assertEq(treasury.minFeePips(false), 1_000);
        assertEq(treasury.minFeePips(true), 1_000);
        (uint16 floor, uint16 rate, uint16 minimum) = treasury.feeTerms(address(0), false, POOL);
        assertEq(floor, 0);
        assertEq(rate, 0);
        assertEq(minimum, 1_000);
        (,, minimum) = treasury.feeTerms(INTEGRATOR, true, POOL);
        assertEq(minimum, 1_000);
        (uint16 pips, uint16 pending, uint256 readyAt) = treasury.integratorMinFee(INTEGRATOR);
        assertEq(pips, NONE);
        assertEq(pending, NONE);
        assertEq(readyAt, 0);
    }

    /// Both rates: owner only, 0 to 10,000, 30 minutes to accept, lapsing 14 days after, cancellable; a new proposal
    /// replaces the pending one.
    function test_minFee_timelockBoundsAndOwner() public {
        for (uint256 k; k < 2; ++k) {
            bool recapture = k == 1;
            vm.prank(OTHER);
            vm.expectRevert(IHookrTreasury.NotOwner.selector);
            treasury.proposeMinFee(recapture, 0);
            vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
            treasury.proposeMinFee(recapture, 10_001);
            vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
            treasury.proposeMinFee(recapture, 1_000); // already current
            vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
            treasury.acceptMinFee(recapture);

            treasury.proposeMinFee(recapture, 5_000);
            treasury.proposeMinFee(recapture, 0); // replaces it
            (uint16 pending, uint256 readyAt) = treasury.pendingMinFee(recapture);
            assertEq(pending, 0);
            assertEq(readyAt, vm.getBlockTimestamp() + 30 minutes);
            vm.warp(readyAt - 1);
            vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsNotReady.selector, readyAt));
            treasury.acceptMinFee(recapture);
            vm.warp(readyAt);
            vm.prank(OTHER);
            vm.expectRevert(IHookrTreasury.NotOwner.selector);
            treasury.acceptMinFee(recapture);
            treasury.acceptMinFee(recapture);
            assertEq(treasury.minFeePips(recapture), 0, "down to zero");
            assertEq(treasury.minFeePips(!recapture), recapture ? 10_000 : 1_000, "the other rate is its own");
            (, readyAt) = treasury.pendingMinFee(recapture);
            assertEq(readyAt, 0);

            // The ceiling is accepted; a proposal lapses 14 days after it matures and can be cancelled.
            _setMin(recapture, 10_000);
            assertEq(treasury.minFeePips(recapture), 10_000);
            treasury.proposeMinFee(recapture, 1_000);
            (, readyAt) = treasury.pendingMinFee(recapture);
            vm.warp(readyAt + 14 days + 1);
            vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsExpired.selector, readyAt + 14 days));
            treasury.acceptMinFee(recapture);
            vm.prank(OTHER);
            vm.expectRevert(IHookrTreasury.NotOwner.selector);
            treasury.cancelMinFee(recapture);
            treasury.cancelMinFee(recapture);
            vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
            treasury.cancelMinFee(recapture);
            assertEq(treasury.minFeePips(recapture), 10_000);
        }
    }

    /// An integrator override: owner only, 0 to 10,000 or NO_MIN_FEE_OVERRIDE, the addresses the list refuses refused,
    /// the same timelock; it wins over both rates for its integrator only, and removing the integrator removes it.
    function test_minFee_integratorOverride() public {
        vm.prank(OTHER);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.proposeIntegratorMinFee(INTEGRATOR, 0);
        address[4] memory refused = [address(0), address(treasury), address(manager), address(r2)];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
            treasury.proposeIntegratorMinFee(refused[i], 0);
        }
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeIntegratorMinFee(INTEGRATOR, 10_001);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeIntegratorMinFee(INTEGRATOR, NONE); // none already

        treasury.proposeIntegratorMinFee(INTEGRATOR, 0);
        (uint16 pips, uint16 pending, uint256 readyAt) = treasury.integratorMinFee(INTEGRATOR);
        assertEq(pips, NONE);
        assertEq(pending, 0);
        assertEq(readyAt, vm.getBlockTimestamp() + 30 minutes);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TermsNotReady.selector, readyAt));
        treasury.acceptIntegratorMinFee(INTEGRATOR);
        vm.warp(readyAt);
        treasury.acceptIntegratorMinFee(INTEGRATOR);
        (pips, pending, readyAt) = treasury.integratorMinFee(INTEGRATOR);
        assertEq(pips, 0);
        assertEq(pending, NONE);
        assertEq(readyAt, 0);
        vm.expectRevert(IHookrTreasury.InvalidTerms.selector);
        treasury.proposeIntegratorMinFee(INTEGRATOR, 0); // already 0

        (,, uint16 minimum) = treasury.feeTerms(INTEGRATOR, false, POOL);
        assertEq(minimum, 1_000, "not for a pool the integrator has not approved");
        vm.prank(OTHER);
        treasury.approveMinFeePool(POOL, true);
        (,, minimum) = treasury.feeTerms(INTEGRATOR, false, POOL);
        assertEq(minimum, 1_000, "nor for one another account approved");
        vm.prank(INTEGRATOR);
        treasury.approveMinFeePool(POOL, true);
        (,, minimum) = treasury.feeTerms(INTEGRATOR, false, POOL);
        assertEq(minimum, 0, "the override over the plain rate");
        (,, minimum) = treasury.feeTerms(INTEGRATOR, true, POOL);
        assertEq(minimum, 0, "the override over the arb recapture rate");
        (,, minimum) = treasury.feeTerms(INTEGRATOR, false, PoolId.wrap(bytes32(uint256(0xB01))));
        assertEq(minimum, 1_000, "other pools keep the rate");
        (,, minimum) = treasury.feeTerms(OTHER, false, POOL);
        assertEq(minimum, 1_000, "other integrators keep the rate");
        (,, minimum) = treasury.feeTerms(address(0), true, POOL);
        assertEq(minimum, 1_000);

        // Cancel and replace; removing the override restores the rates.
        treasury.proposeIntegratorMinFee(INTEGRATOR, 7_000);
        treasury.cancelIntegratorMinFee(INTEGRATOR);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.cancelIntegratorMinFee(INTEGRATOR);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptIntegratorMinFee(INTEGRATOR);
        _setOverride(INTEGRATOR, NONE);
        (,, minimum) = treasury.feeTerms(INTEGRATOR, false, POOL);
        assertEq(minimum, 1_000);

        // Taking the integrator off the list removes its override and voids a pending one, at once.
        _list(INTEGRATOR, 5_000);
        _setOverride(INTEGRATOR, 2_500);
        treasury.proposeIntegratorMinFee(INTEGRATOR, 0);
        treasury.removeIntegrator(INTEGRATOR);
        (pips, pending, readyAt) = treasury.integratorMinFee(INTEGRATOR);
        assertEq(pips, NONE);
        assertEq(pending, NONE);
        assertEq(readyAt, 0);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptIntegratorMinFee(INTEGRATOR);
    }

    /// Naming an integrator is any creator's free choice, so its override reaches only the pools it approved: a creator
    /// naming an integrator whose override is zero binds the plain rate (the integrator still frozen at its rate), and
    /// so does one naming it on a key another account approved; the integrator approving a key first, including a new
    /// token's key from predictToken, gives that pool the override, and withdrawing the approval stops the next bind.
    function test_minFee_overrideOnlyReachesApprovedPools() public {
        _list(INTEGRATOR, 5_000);
        _list(OTHER, 5_000);
        _setOverride(INTEGRATOR, 0);

        // A creator naming the integrator without its approval pays the plain rate.
        address s = _hookrToken();
        IHookrLauncher.Member[] memory members = _members(0, 0, INTEGRATOR);
        PoolKey memory named = _launch(s, members);
        assertEq(_minimumOf(named), 1_000, "no approval, no override");
        assertEq(root.feeOnlyFrom(named.toId()), 0);
        (address frozen, uint16 rate) = r2.integration(named.toId());
        assertEq(frozen, INTEGRATOR);
        assertEq(rate, 5_000);
        Paid memory p = _swapAs(named, true, true, 1 ether);
        assertEq(p.protocol, 5e14, "the minimum, split with the integrator");
        assertEq(p.integrator, 5e14);

        // Another account's approval of the key does not count for the integrator.
        s = _hookrToken();
        PoolKey memory key = _keyOf(s, members);
        _approve(OTHER, key);
        assertEq(_minimumOf(_launch(s, members)), 1_000, "only the named integrator's approval");

        // The integrator's own approval does; the same approval does nothing for a pool naming another integrator.
        s = _hookrToken();
        key = _keyOf(s, members);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit IHookrTreasury.MinFeePoolApproved(INTEGRATOR, key.toId(), true);
        _approve(INTEGRATOR, key);
        assertTrue(treasury.minFeePoolApproved(INTEGRATOR, key.toId()));
        assertFalse(treasury.minFeePoolApproved(OTHER, key.toId()));
        PoolKey memory chosen = _launch(s, members);
        assertEq(_minimumOf(chosen), 0, "the approved pool binds the override");
        assertEq(root.feeOnlyFrom(chosen.toId()), 1);
        s = _hookrToken();
        key = _keyOf(s, members);
        _approve(INTEGRATOR, key);
        assertEq(_minimumOf(_launch(s, _members(0, 0, OTHER))), 1_000, "a pool naming another integrator");

        // Withdrawn before the bind: the plain rate.
        s = _hookrToken();
        key = _keyOf(s, members);
        _approve(INTEGRATOR, key);
        vm.prank(INTEGRATOR);
        treasury.approveMinFeePool(key.toId(), false);
        assertEq(_minimumOf(_launch(s, members)), 1_000, "a withdrawn approval");

        // A new token: the integrator approves the key its creator's predicted token gives, before the launch.
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "N", "N", 1e27, bytes32(uint256(8)));
        address predicted = launcher.predictToken(trader, token);
        _approve(INTEGRATOR, _keyOf(predicted, members));
        vm.prank(trader);
        (bytes32 family,) = launcher.launch{value: 1e24}(token, address(root), members, vm.getBlockTimestamp());
        PoolKey memory fresh = launcher.position(family, 0).key;
        assertEq(Currency.unwrap(fresh.currency1), predicted);
        assertEq(_minimumOf(fresh), 0, "a new token's approved pool");
        _backed();
    }

    function test_minFee_ownerChangeVoidsEveryPendingProposal() public {
        treasury.proposeMinFee(false, 0);
        treasury.proposeMinFee(true, 0);
        treasury.proposeIntegratorMinFee(INTEGRATOR, 0);
        treasury.proposeOwner(OTHER);
        vm.prank(OTHER);
        treasury.acceptOwnership();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.startPrank(OTHER);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptMinFee(false);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptMinFee(true);
        vm.expectRevert(IHookrTreasury.NoPendingTerms.selector);
        treasury.acceptIntegratorMinFee(INTEGRATOR);
        vm.stopPrank();
        (, uint256 readyAt) = treasury.pendingMinFee(false);
        assertEq(readyAt, 0);
        assertEq(treasury.minFeePips(false), 1_000);
        assertEq(treasury.minFeePips(true), 1_000);
    }

    // ------------------------------------------------------------------ bind: which pools freeze it

    /// Which pools bind the minimum, at the plain rate of 1,000. A Hookr token's pool with no rule that earns Hookr a
    /// share binds it: no rule at all, the launch guard alone, the guard and its buy cap (block-only), an integrator,
    /// an advisory, and a dynamic fee or Anti-Snipe tax too small to pay Hookr a pip at the 2,000 share (a 4-pip span
    /// or Snipe: 4 x 2,000 / 10,000 rounds to zero on every swap). LP Rewards, Auto Burn, dynamic fees and the
    /// Anti-Snipe tax (flat or decaying) that pay Hookr a pip, each alone or all together, bind none. A royalty is a
    /// cut of LP Rewards: alone it is refused at bind, and with LP Rewards the pool binds none. A pool with arb
    /// recapture binds none, with rules or without, and so does another token's pool. An advisory other than Tax +
    /// Conversion earns Hookr nothing, so a pool whose only other charge is such an advisory's binds the minimum
    /// (Tax + Conversion: `test_minFee_taxConversionEarnsHookrAShare`).
    function test_minFee_whichPoolsBindIt() public {
        _list(INTEGRATOR, 5_000);
        HookrTypes.RulesConfig memory c = _plainRules();
        PoolKey memory key = _bindOn(r2, _hookrToken(), c, false, address(0));
        assertEq(_minimumOf(key), 1_000, "no rule");
        assertEq(r2.feeOnlyFrom(key.toId()), 0, "a pool with a minimum is never fee-only");

        c = _plainRules();
        c.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, false, address(0))), 1_000, "the launch guard alone");
        c.maxBuyQuoteAmount = 1e21;
        key = _bindOn(r2, _hookrToken(), c, false, address(0));
        assertEq(_minimumOf(key), 1_000, "the guard and its buy cap: block-only");
        assertEq(r2.feeOnlyFrom(key.toId()), 0, "nor after its guard");

        c = _plainRules();
        c.integrator = INTEGRATOR;
        key = _bindOn(r2, _hookrToken(), c, false, address(0));
        assertEq(_minimumOf(key), 1_000, "an integrator is not a rule");
        (address named, uint16 rate) = r2.integration(key.toId());
        assertEq(named, INTEGRATOR);
        assertEq(rate, 5_000);
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), false, address(0xAD))), 1_000, "an advisory");

        c = _plainRules();
        c.lpBps = 1;
        key = _bindOn(r2, _hookrToken(), c, false, address(0));
        assertEq(_minimumOf(key), 0, "LP Rewards");
        assertEq(r2.feeOnlyFrom(key.toId()), 0);
        c = _plainRules();
        c.burnBps = 1;
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, false, address(0))), 0, "Auto Burn");
        c = _plainRules();
        c.dynamicFeeSens = 1;
        c.maxFeePips = 3_005;
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, false, address(0))), 0, "dynamic fees");
        c.maxFeePips = 3_004;
        key = _bindOn(r2, _hookrToken(), c, false, address(0));
        assertEq(_minimumOf(key), 1_000, "a dynamic fee whose whole span pays Hookr no pip");
        assertEq(r2.feeOnlyFrom(key.toId()), 0);
        c = _plainRules();
        c.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        c.snipeTaxPips = 5;
        key = _bindOn(r2, _hookrToken(), c, false, address(0));
        assertEq(_minimumOf(key), 0, "a flat Anti-Snipe tax");
        assertEq(r2.feeOnlyFrom(key.toId()), c.guardEndBlock, "fee-only once its guard ends");
        c.snipeTaxPips = 1;
        key = _bindOn(r2, _hookrToken(), c, false, address(0));
        assertEq(_minimumOf(key), 1_000, "a Snipe that pays Hookr no pip");
        assertEq(r2.feeOnlyFrom(key.toId()), 0, "never fee-only, after its guard either");
        c.snipeTaxPips = 4;
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, false, address(0))), 1_000, "4 x 2,000 / 10,000 is 0");
        c.snipeTaxPips = 300_000;
        c.snipeFloorPips = 20_000;
        c.snipeDecaySeconds = 600;
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, false, address(0))), 0, "a decaying Anti-Snipe tax");

        c = _plainRules();
        c.royaltyBps = 500;
        c.royaltyTo = address(0xB0B);
        address s = _hookrToken();
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        this.bindExternal(r2, s, c, false);
        c.lpBps = 200;
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, false, address(0))), 0, "a royalty rides on LP Rewards");

        c = _plainRules();
        c.lpBps = 200;
        c.burnBps = 100;
        c.royaltyBps = 500;
        c.royaltyTo = address(0xB0B);
        c.dynamicFeeSens = 3;
        c.maxFeePips = 50_000;
        c.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        c.snipeTaxPips = 20_000;
        c.maxBuyQuoteAmount = 1e21;
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, false, address(0))), 0, "every rule");

        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), true, address(0))), 0, "arb recapture, no rule");
        c = _plainRules();
        c.lpBps = 200;
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), c, true, address(0))), 0, "arb recapture with LP Rewards");
        key = _bindOn(r2, _otherToken(), _plainRules(), false, address(0));
        assertEq(_minimumOf(key), 0, "another token's pool");
        assertEq(r2.feeOnlyFrom(key.toId()), 1, "fee-only from the start");
    }

    /// @dev `_bindOn` as an external call of this contract, so a revert can be expected on it alone.
    function bindExternal(HookrRules r, address subject, HookrTypes.RulesConfig memory c, bool lane)
        external
        returns (PoolKey memory)
    {
        return _bindOn(r, subject, c, lane, address(0));
    }

    /// Every combination of the four Hookr-earning rules (each set here to pay Hookr more than a pip), the guard and
    /// buy cap, a royalty on LP Rewards, arb recapture and the subject, at any plain rate: a pool binds the rate
    /// exactly when it is a Hookr token's pool without arb recapture and none of LP Rewards, Auto Burn, dynamic fees
    /// and the Anti-Snipe tax is on; every other pool binds zero, and a pool without arb recapture is fee-only exactly
    /// as it would be without a minimum.
    function testFuzz_minFee_bindsExactlyWithoutAHookrEarningRule(uint8 mask, bool lane, bool hookr, uint16 minimum)
        public
    {
        minimum = uint16(bound(minimum, 0, 10_000));
        if (minimum != 1_000) _setMin(false, minimum);
        HookrTypes.RulesConfig memory c = _plainRules();
        if (mask & 1 != 0) c.lpBps = 200;
        if (mask & 2 != 0) c.burnBps = 100;
        if (mask & 4 != 0) {
            c.dynamicFeeSens = 3;
            c.maxFeePips = 50_000;
        }
        if (mask & 8 != 0) c.snipeTaxPips = 20_000;
        if (mask & 16 != 0) c.maxBuyQuoteAmount = 1e21;
        if (mask & 24 != 0 || mask & 64 != 0) c.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        if (mask & 32 != 0 && c.lpBps != 0) {
            c.royaltyBps = 500;
            c.royaltyTo = address(0xB0B);
        }
        PoolKey memory key = _bindOn(r2, hookr ? _hookrToken() : _otherToken(), c, lane, address(0));
        bool earns = mask & 15 != 0;
        uint256 expected = !lane && hookr && !earns ? minimum : 0;
        assertEq(_minimumOf(key), expected, "the minimum binds only without a Hookr-earning rule");
        if (lane) return;
        uint256 feeOnly = r2.feeOnlyFrom(key.toId());
        if (expected != 0 || mask & 7 != 0) assertEq(feeOnly, 0, "the Rules run on every swap");
        else assertEq(feeOnly, c.guardEndBlock == 0 ? 1 : c.guardEndBlock, "fee-only as without a minimum");
    }

    /// A pool with arb recapture binds no minimum whatever the treasury answers: at the recapture rate's default
    /// 1,000 or its 10,000 ceiling, with an integrator's approved override or without, its integrator still frozen at
    /// its rate. The plain rate and an approved override reach a plain pool, frozen at bind.
    function test_minFee_recapturePoolsBindNone() public {
        _list(INTEGRATOR, 5_000);
        _setOverride(INTEGRATOR, 300);
        assertEq(treasury.minFeePips(true), 1_000);
        assertEq(_minimumOf(_bind(true, address(0), false)), 0, "the default recapture rate");
        assertEq(_minimumOf(_bind(true, INTEGRATOR, false)), 0);
        PoolKey memory lane = _bind(true, INTEGRATOR, true);
        assertEq(_minimumOf(lane), 0, "an approved override");
        (address named, uint16 rate) = r2.integration(lane.toId());
        assertEq(named, INTEGRATOR);
        assertEq(rate, 5_000);
        _setMin(true, 10_000);
        assertEq(_minimumOf(_bind(true, address(0), false)), 0, "the recapture rate's ceiling");
        assertEq(_minimumOf(_bind(false, address(0), false)), 1_000, "a plain pool binds the plain rate");
        assertEq(_minimumOf(_bind(false, INTEGRATOR, false)), 1_000, "the override only on a pool it approved");
        PoolKey memory chosen = _bind(false, INTEGRATOR, true);
        assertEq(_minimumOf(chosen), 300, "the override over the plain rate");
        _setOverride(INTEGRATOR, NONE);
        assertEq(_minimumOf(chosen), 300, "frozen");
        vm.prank(INTEGRATOR);
        treasury.approveMinFeePool(chosen.toId(), false);
        assertEq(_minimumOf(chosen), 300, "a withdrawn approval never reaches a bound pool");
    }

    /// A rule earns Hookr a share only at a nonzero protocolShareBps. On Rules whose immutable floor is zero (the
    /// treasury's governed floor is zero too), a Hookr token's pool whose LP Rewards (with a royalty), Auto Burn,
    /// dynamic fees or Anti-Snipe tax run at a zero share binds the minimum, and a buy's quote take is the royalty
    /// plus the whole minimum; the same rules at a one basis point share bind none.
    function test_minFee_zeroShareRulesEarnHookrNothing() public {
        for (uint256 k; k < 4; ++k) {
            HookrTypes.RulesConfig memory c = _plainRules();
            c.protocolShareBps = 0;
            if (k == 0) {
                c.lpBps = 200;
                c.royaltyBps = 500;
                c.royaltyTo = address(0xB0B);
            } else if (k == 1) {
                c.burnBps = 100;
            } else if (k == 2) {
                c.dynamicFeeSens = 3;
                c.maxFeePips = 50_000;
            } else {
                c.guardEndBlock = uint40(vm.getBlockNumber() + 10);
                c.snipeTaxPips = 20_000;
            }
            PoolKey memory zero = _bindOn(r0, _hookrToken(), c, false, address(0));
            assertEq(_minimumOn(r0, zero), 1_000, "a zero share earns Hookr nothing");
            c.protocolShareBps = 1;
            assertEq(_minimumOn(r0, _bindOn(r0, _hookrToken(), c, false, address(0))), 0, "a one basis point share");
            // A dynamic fee pool is quoted through quoteSimulatedSwap, below.
            if (k == 2) continue;
            vm.prank(address(root));
            HookrTypes.FeeQuote memory q = r0.beforeSwap(_context(zero, true, true));
            // The royalty is a cut of the LP Rewards' net: 200 bps x 100 pips x 500 / 10,000.
            assertEq(q.quoteTakePips, (k == 0 ? 1_000 : 0) + 1_000, "the royalty and the whole minimum");
        }
    }

    /// A dynamic fee or Anti-Snipe tax earns Hookr a share only from the size at which Hookr's part of it is a whole
    /// pip: `_quote` rounds both shares down, so the least such span or Snipe is ceil(10,000 / share) pips, 5 at the
    /// release's 2,000 floor, 4 from 2,500 to 3,333, 3 from 3,334 to 4,999 and 2 at 5,000. One pip less binds the
    /// minimum and keeps the pool off the fee-only path; the least earning size binds none. On Rules with a zero
    /// floor a 1 bps share needs 10,000 pips.
    function test_minFee_onePipThresholds() public {
        uint16[8] memory shares = [uint16(1), 2_000, 2_500, 3_000, 3_333, 3_334, 4_999, 5_000];
        uint256[8] memory least = [uint256(10_000), 5, 4, 4, 4, 3, 3, 2];
        for (uint256 i; i < shares.length; ++i) {
            HookrRules r = shares[i] < RELEASE_FLOOR ? r0 : r2;
            assertEq(least[i], (10_000 + uint256(shares[i]) - 1) / shares[i]);
            for (uint256 k; k < 4; ++k) {
                bool snipe = k < 2;
                uint256 pips = k % 2 == 0 ? least[i] - 1 : least[i];
                HookrTypes.RulesConfig memory c = _plainRules();
                c.protocolShareBps = shares[i];
                if (snipe) {
                    c.guardEndBlock = uint40(vm.getBlockNumber() + 10);
                    c.snipeTaxPips = uint24(pips);
                } else {
                    c.dynamicFeeSens = 5;
                    c.maxFeePips = uint24(3000 + pips);
                }
                PoolKey memory key = _bindOn(r, _hookrToken(), c, false, address(0));
                bool earns = pips == least[i];
                assertEq(_minimumOn(r, key), earns ? 0 : 1_000, snipe ? "Snipe" : "dynamic fee span");
                if (!earns) assertEq(r.feeOnlyFrom(key.toId()), 0, "never fee-only");
            }
        }
    }

    /// @dev `span`, or the widest span the reach bound admits at sensitivity 5 and `share` where that is smaller.
    function _withinReach(uint24 span, uint16 share) internal pure returns (uint24) {
        uint256 widest = RulesData.maxDynamicFeeSpan(5, share, 3000);
        return span > widest ? uint24(widest) : span;
    }

    /// Any share, span and Snipe, a few pips or large: a Hookr token's pool binds the minimum exactly when neither its
    /// dynamic fee span nor its Snipe times the share reaches 10,000, and is then never fee-only.
    function testFuzz_minFee_dynamicFeeAndSnipeEarnFromAPip(uint16 share, uint24 span, uint24 snipe, uint8 mode)
        public
    {
        share = uint16(bound(share, 0, 5_000));
        span = uint24(mode & 1 != 0 ? bound(span, 0, 12) : bound(span, 0, 597_000));
        span = _withinReach(span, share);
        snipe = uint24(mode & 2 != 0 ? bound(snipe, 0, 12) : bound(snipe, 0, 597_000));
        HookrTypes.RulesConfig memory c = _plainRules();
        c.protocolShareBps = share;
        if (span != 0) {
            c.dynamicFeeSens = 5;
            c.maxFeePips = uint24(3000 + span);
        }
        if (snipe != 0) {
            c.guardEndBlock = uint40(vm.getBlockNumber() + 10);
            c.snipeTaxPips = snipe;
        }
        PoolKey memory key = _bindOn(r0, _hookrToken(), c, false, address(0));
        bool earns = uint256(span) * share >= 10_000 || uint256(snipe) * share >= 10_000;
        assertEq(_minimumOn(r0, key), earns ? 0 : 1_000);
        if (!earns) assertEq(r0.feeOnlyFrom(key.toId()), 0);
    }

    /// Tax + Conversion is the one advisory whose charge earns Hookr a share: its queues split each tax at the pool's
    /// protocolShareBps. The Rules know it by the exclusive group it declares (`EXCLUSIVE_GROUP()` returning the
    /// keccak256 of "DIRECTIONAL_QUOTE_TAX") and by an admission on the root that lets it take the quote, and a Hookr
    /// token's pool bound with it binds no minimum. Every other advisory keeps the minimum, and the bind goes through:
    /// another group, none, the group without a quote-take admission or without any admission, and a group read that
    /// reverts, runs out of its gas or returns more than one word. So does Tax + Conversion at a zero share, while a
    /// one basis point share binds none; with arb recapture or on another token's pool there is no minimum anyway.
    function test_minFee_taxConversionEarnsHookrAShare() public {
        HookrTypes.Advice memory tax = HookrTypes.Advice(0, 30_000, TAX_QUEUE, false);
        MockGroupAdvisory taxed = new MockGroupAdvisory(TAX_GROUP, tax);
        _admitAdvisory(address(taxed), 100_000);
        PoolKey memory key = _bindOn(r2, _hookrToken(), _plainRules(), false, address(taxed));
        assertEq(_minimumOf(key), 0, "Tax + Conversion earns Hookr its share of the tax");
        assertEq(r2.feeOnlyFrom(key.toId()), 1, "the Rules' own answer; the root keeps a quote-taking pool off it");

        MockGroupAdvisory other = new MockGroupAdvisory(keccak256("BUY_SELL_BLOCK"), tax);
        _admitAdvisory(address(other), 100_000);
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), false, address(other))), 1_000, "another group");
        FixedAdvice plain = new FixedAdvice(tax, HookrTypes.Advice(0, 0, address(0), false), false, false);
        _admitAdvisory(address(plain), 100_000);
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), false, address(plain))), 1_000, "no group");
        MockGroupAdvisory noTake = new MockGroupAdvisory(TAX_GROUP, HookrTypes.Advice(0, 0, address(0), false));
        _admitAdvisory(address(noTake), 0);
        assertEq(
            _minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), false, address(noTake))),
            1_000,
            "admitted without a quote take"
        );
        MockGroupAdvisory unadmitted = new MockGroupAdvisory(TAX_GROUP, tax);
        assertEq(
            _minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), false, address(unadmitted))),
            1_000,
            "never admitted on the root"
        );
        for (uint8 mode; mode < 3; ++mode) {
            MockBadGroupAdvisory bad = new MockBadGroupAdvisory(mode);
            _admitAdvisory(address(bad), 100_000);
            assertEq(
                _minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), false, address(bad))),
                1_000,
                "a reverting, starved or two-word group read"
            );
        }

        HookrTypes.RulesConfig memory c = _plainRules();
        c.protocolShareBps = 0;
        assertEq(_minimumOn(r0, _bindOn(r0, _hookrToken(), c, false, address(taxed))), 1_000, "a zero share");
        c.protocolShareBps = 1;
        assertEq(_minimumOn(r0, _bindOn(r0, _hookrToken(), c, false, address(taxed))), 0, "a 1 bps share");
        assertEq(_minimumOf(_bindOn(r2, _hookrToken(), _plainRules(), true, address(taxed))), 0, "arb recapture");
        assertEq(_minimumOf(_bindOn(r2, _otherToken(), _plainRules(), false, address(taxed))), 0, "another token");
    }

    // ------------------------------------------------------------------ what swaps pay

    /// A pool without rules pays exactly the minimum on every swap shape, in its quote, and nothing else changes: the
    /// base LP fee is the pool's as before.
    function testFuzz_minFee_noRulesPoolPaysExactlyTheMinimum(uint128 amount, uint8 shape) public {
        amount = uint128(bound(amount, 1e9, 1e21));
        bool buy = shape & 1 == 0;
        bool exactInput = shape & 2 == 0;
        PoolKey memory key = _launch(_hookrToken(), _members(0, 0, address(0)));
        Paid memory p = _swapAs(key, buy, exactInput, amount);
        uint256 expected = _take(buy, exactInput, amount, p.quote, 1_000);
        assertEq(p.allocations, 1);
        assertEq(p.protocol, expected, "exactly the minimum");
        assertEq(p.earned, expected, "the root's take is the Rules' own");
        assertEq(p.royalty, 0);
        assertGt(p.protocol, 0);
        _backed();
    }

    /// A block-only pool (the launch guard and its buy cap, no rule that earns Hookr a share) binds the minimum and
    /// pays exactly it, inside the guard and after it.
    function test_minFee_blockOnlyPoolPaysTheMinimum() public {
        IHookrLauncher.Member[] memory members = _members(0, 0, address(0));
        members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 5);
        members[0].rules.maxBuyQuoteAmount = 1e21;
        PoolKey memory key = _launch(_hookrToken(), members);
        assertEq(_minimumOf(key), 1_000);
        assertEq(root.feeOnlyFrom(key.toId()), 0, "never fee-only");
        Paid memory p = _swapAs(key, true, true, 1 ether);
        assertEq(p.protocol, _take(true, true, 1 ether, p.quote, 1_000), "a buy inside the guard");
        p = _swapAs(key, false, true, 1 ether);
        assertEq(p.protocol, _take(false, true, 1 ether, p.quote, 1_000), "a sell inside the guard");
        vm.roll(vm.getBlockNumber() + 10);
        p = _swapAs(key, true, false, 1 ether);
        assertEq(p.protocol, _take(true, false, 1 ether, p.quote, 1_000), "an exact-output buy after it");
        _backed();
    }

    /// A Hookr token's market whose only rule is a 1-pip Anti-Snipe tax under a one-parent-block guard: Hookr's share
    /// of the Snipe (1 x 2,000 / 10,000) is zero, so the pool binds the minimum and is never fee-only. Every swap after
    /// its guard runs the Rules and pays exactly the minimum, as its no-rules twin does.
    function test_minFee_onePipSnipePoolPaysTheMinimum() public {
        PoolKey memory plain = _launch(_hookrToken(), _members(0, 0, address(0)));
        IHookrLauncher.Member[] memory m = _members(0, 0, address(0));
        m[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 1);
        m[0].rules.snipeTaxPips = 1;
        PoolKey memory snipe = _launch(_hookrToken(), m);
        assertEq(_minimumOf(snipe), 1_000, "a Snipe that pays Hookr no pip earns no share");
        assertEq(root.feeOnlyFrom(snipe.toId()), 0, "never fee-only");
        for (uint256 i; i < 6; ++i) {
            bool buy = i % 2 == 0;
            Paid memory a = _swapAs(plain, buy, true, 1 ether);
            Paid memory b = _swapAs(snipe, buy, true, 1 ether);
            assertEq(b.allocations, 1, "the Rules run on every swap");
            assertEq(b.protocol, _take(buy, true, 1 ether, b.quote, 1_000), "exactly the minimum");
            assertEq(b.protocol, a.protocol, "as the no-rules twin pays");
            assertGt(b.protocol, 0);
        }
        _backed();
    }

    /// Inside its guard a 4-pip Snipe at the 2,000 share pays Hookr no pip of a buy and goes to the LPs whole, so the
    /// pool binds the minimum and every guarded buy pays exactly it.
    function test_minFee_subPipSnipeBuysPayTheMinimumInsideTheGuard() public {
        IHookrLauncher.Member[] memory m = _members(0, 0, address(0));
        m[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 50);
        m[0].rules.snipeTaxPips = 4;
        PoolKey memory key = _launch(_hookrToken(), m);
        assertEq(_minimumOf(key), 1_000);
        for (uint256 i; i < 4; ++i) {
            Paid memory p = _swapAs(key, true, true, 1 ether);
            assertEq(p.allocations, 1, "the Rules run inside the guard");
            assertEq(p.protocol, _take(true, true, 1 ether, p.quote, 1_000), "exactly the minimum");
            assertEq(p.lpFee, 3_000 + 4, "the whole Snipe is LP fee");
        }
        _backed();
    }

    /// A dynamic fee pool whose whole span is 4 pips (maxFeePips 3,004 over the 3,000 base) pays Hookr no pip of any
    /// swap at the 2,000 share, so it binds the minimum and every swap, buy or sell, pays exactly it; the dynamic fee
    /// is LP fee.
    function test_minFee_subPipDynamicSpanPaysTheMinimum() public {
        IHookrLauncher.Member[] memory m = _members(0, 0, address(0));
        m[0].rules.dynamicFeeSens = 10;
        m[0].rules.maxFeePips = 3_004;
        PoolKey memory key = _launch(_hookrToken(), m);
        assertEq(_minimumOf(key), 1_000);
        assertEq(root.feeOnlyFrom(key.toId()), 0);
        for (uint256 i; i < 8; ++i) {
            bool buy = i % 4 != 3;
            Paid memory p = _swapAs(key, buy, true, 200 ether);
            assertEq(p.allocations, 1, "the Rules run on every swap");
            assertEq(p.protocol, _take(buy, true, 200 ether, p.quote, 1_000), "exactly the minimum");
            assertLe(p.lpFee, 3_004, "at most the base fee and the whole span");
        }
        _backed();
    }

    /// The cheapest dev-buy launch (launchWithBuy needs a Snipe above zero): a new token whose dev-buy member's only
    /// rule is a 1-pip Snipe under a one-parent-block guard. The Snipe pays Hookr no pip, so the member binds the
    /// minimum: the 1 ETH dev buy pays Hookr 0.1% of it, and every swap after the guard pays the minimum too.
    function test_minFee_devBuyWithASubPipSnipePaysTheMinimum() public {
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Dev", "DEV", 1e24, bytes32(uint256(4242)));
        address subject = launcher.predictToken(address(this), t);
        IHookrLauncher.Member[] memory m = _members(0, 0, address(0));
        m[0].sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        m[0].tickLower = -60_000;
        m[0].tickUpper = 0;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(-60_000), TickMath.getSqrtPriceAtTick(0), 1e24
        );
        m[0].liquidity = liquidity / 1000 * 999;
        m[0].amount0Max = 0;
        m[0].amount1Max = 1e24;
        m[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 1);
        m[0].rules.snipeTaxPips = 1;
        m[0].rules.maxBuyQuoteAmount = 1e21;
        vm.recordLogs();
        (bytes32 family, address s,) = launcher.launchWithBuy{value: 1 ether}(
            t, address(root), m, new bytes[](1), IHookrLauncher.DevBuy(0, 1 ether, 1, 0), vm.getBlockTimestamp()
        );
        assertEq(s, subject);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 devBuyProtocol;
        uint256 devBuyAllocations;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(r2) && logs[i].topics[0] == IHookrRulesEvents.FeesAllocated.selector) {
                (uint256 protocol,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, address, uint256));
                devBuyProtocol += protocol;
                ++devBuyAllocations;
            }
        }
        assertEq(devBuyAllocations, 1);
        assertEq(devBuyProtocol, 1e15, "the dev buy pays the minimum: 0.1% of its 1 ETH");
        PoolKey memory key = launcher.position(family, 0).key;
        assertEq(Currency.unwrap(key.currency1), subject);
        assertEq(_minimumOf(key), 1_000, "the dev-buy member binds the minimum");
        assertEq(root.feeOnlyFrom(key.toId()), 0, "never fee-only");
        vm.prank(trader);
        HookrToken(subject).approve(address(router), type(uint256).max);
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            uint128 amount = buy ? 1 ether : 1e17;
            Paid memory p = _swapAs(key, buy, true, amount);
            assertEq(p.allocations, 1, "the Rules run after the guard");
            assertEq(p.protocol, _take(buy, true, amount, p.quote, 1_000), "exactly the minimum");
            assertGt(p.protocol, 0);
        }
        _backed();
    }

    /// From the threshold the Snipe earns: a 5-pip Snipe at the 2,000 share pays Hookr exactly one pip of each guarded
    /// buy (and the LPs the other four), so the pool binds no minimum and is fee-only once its guard ends.
    function test_minFee_onePipSnipeShareEarnsAndBindsNone() public {
        IHookrLauncher.Member[] memory m = _members(0, 0, address(0));
        m[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 3);
        m[0].rules.snipeTaxPips = 5;
        PoolKey memory key = _launch(_hookrToken(), m);
        assertEq(_minimumOf(key), 0);
        assertEq(root.feeOnlyFrom(key.toId()), m[0].rules.guardEndBlock);
        Paid memory p = _swapAs(key, true, true, 1 ether);
        assertEq(p.protocol, _take(true, true, 1 ether, p.quote, 1), "one pip");
        assertEq(p.protocol, 1e12);
        assertEq(p.lpFee, 3_000 + 4, "the other four pips are LP fee");
        vm.roll(m[0].rules.guardEndBlock);
        assertEq(_swapAs(key, true, true, 1 ether).allocations, 0, "fee-only after the guard: no Rules call");
        _backed();
    }

    /// Through the launcher: a Hookr token's pool whose only charge is Tax + Conversion (a stand-in taking 3% of each
    /// buy for its queue) binds no minimum and stays off the fee-only path; a 1 ETH buy pays the 3% to the queue,
    /// where the real advisory splits Hookr's share off, and nothing more to Hookr. Its twin with an advisory of no
    /// group pays the same 3% and the 0.1% minimum besides.
    function test_minFee_taxConversionPoolPaysTheTaxAlone() public {
        HookrTypes.Advice memory tax = HookrTypes.Advice(0, 30_000, TAX_QUEUE, false);
        MockGroupAdvisory taxed = new MockGroupAdvisory(TAX_GROUP, tax);
        FixedAdvice plain = new FixedAdvice(tax, HookrTypes.Advice(0, 0, address(0), false), false, false);
        _admitAdvisory(address(taxed), 100_000);
        _admitAdvisory(address(plain), 100_000);
        PoolKey memory taxedKey = _launchAdvised(_hookrToken(), address(taxed));
        PoolKey memory plainKey = _launchAdvised(_hookrToken(), address(plain));
        assertEq(_minimumOf(taxedKey), 0);
        assertEq(_minimumOf(plainKey), 1_000);
        assertEq(root.feeOnlyFrom(taxedKey.toId()), 0, "a quote-taking advisory keeps the Rules on every swap");
        Paid memory a = _swapAs(taxedKey, true, true, 1 ether);
        assertEq(a.allocations, 1);
        assertEq(a.advisoryFee, 3e16, "the tax, 3% of the 1 ETH spend");
        assertEq(a.protocol, 0, "no minimum on top");
        assertEq(a.earned, 3e16, "the root's take is the tax alone");
        Paid memory b = _swapAs(plainKey, true, true, 1 ether);
        assertEq(b.advisoryFee, 3e16, "the same advisory take");
        assertEq(b.protocol, 1e15, "and the minimum besides");
        _backed();
    }

    /// Per 1 ETH of spend: no rules pays Hookr 0.001 ETH, a sell 0.1% of its quote out; LP Rewards 2% at 80/20 pays
    /// Hookr its 0.004 ETH share and binds no minimum, so a sell on that pool (LP Rewards charge buys only) pays Hookr
    /// nothing; an integrator at 5,000 takes half of each.
    function test_minFee_workedExamples() public {
        PoolKey memory plain = _launch(_hookrToken(), _members(0, 0, address(0)));
        assertEq(_swapAs(plain, true, true, 1 ether).protocol, 1e15, "no rules: 0.1%");
        Paid memory p = _swapAs(plain, false, true, 1 ether);
        assertEq(p.protocol, p.quote * 1_000 / PIPS, "and of a sell's quote out");
        PoolKey memory rewards = _launch(_hookrToken(), _members(200, 0, address(0)));
        assertEq(_minimumOf(rewards), 0, "LP Rewards earn Hookr a share: no minimum");
        p = _swapAs(rewards, true, true, 1 ether);
        assertEq(p.protocol, 4e15, "LP Rewards 2% at 80/20: Hookr's 0.4% and nothing extra");
        // The LPs' 1.6% is LP fee on what reaches the pool, 0.996 ETH after the 0.004 ETH quote take: 0.015936 ETH of
        // LP Rewards beside the 0.3% base fee.
        assertEq(p.quote, 996e15, "the pool's input");
        assertEq(p.lpFee, 3_000 + 16_000, "base + LP Rewards, pips of the pool's input");
        p = _swapAs(rewards, false, true, 1 ether);
        assertEq(p.allocations, 1, "the sell settles through the Rules");
        assertEq(p.protocol, 0, "and pays Hookr nothing");

        _list(INTEGRATOR, 5_000);
        PoolKey memory shared = _launch(_hookrToken(), _members(0, 0, INTEGRATOR));
        p = _swapAs(shared, true, true, 1 ether);
        assertEq(p.protocol, 5e14);
        assertEq(p.integrator, 5e14, "the integrator's half of the minimum");
        PoolKey memory sharedRewards = _launch(_hookrToken(), _members(200, 0, INTEGRATOR));
        p = _swapAs(sharedRewards, true, true, 1 ether);
        assertEq(p.protocol, 2e15);
        assertEq(p.integrator, 2e15);

        // An integrator whose override is zero: the pools without rules it approved pay Hookr nothing and are fee-only.
        _setOverride(INTEGRATOR, 0);
        address s = _hookrToken();
        IHookrLauncher.Member[] memory members = _members(0, 0, INTEGRATOR);
        _approve(INTEGRATOR, _keyOf(s, members));
        PoolKey memory free = _launch(s, members);
        assertEq(_minimumOf(free), 0);
        assertEq(root.feeOnlyFrom(free.toId()), 1);
        assertEq(_swapAs(free, true, true, 1 ether).allocations, 0);
        _backed();
    }

    /// A pool whose rules earn Hookr a share binds no minimum at any rate and pays Hookr its rule shares alone, also
    /// where they come to less than the minimum: twins bound at the plain rate's 10,000 ceiling and at zero pay Hookr
    /// the same on the same buy and the trader receives the same, and Hookr's part is its share of LP Rewards and Auto
    /// Burn, in pips of the gross spend.
    function testFuzz_minFee_earningPoolsPayTheirSharesAlone(uint16 lp, uint16 burn, uint128 amount) public {
        lp = uint16(bound(lp, 0, 1_000));
        burn = uint16(bound(burn, lp == 0 ? 1 : 0, 1_000 - lp));
        amount = uint128(bound(amount, 1e9, 1e21));
        _setMin(false, 10_000);
        PoolKey memory high = _launch(_hookrToken(), _members(lp, burn, address(0)));
        _setMin(false, 0);
        PoolKey memory zero = _launch(_hookrToken(), _members(lp, burn, address(0)));
        assertEq(_minimumOf(high), 0, "no minimum at the ceiling");
        assertEq(_minimumOf(zero), 0);
        uint256 before = HookrToken(Currency.unwrap(high.currency1)).balanceOf(trader);
        Paid memory a = _swapAs(high, true, true, amount);
        uint256 outA = HookrToken(Currency.unwrap(high.currency1)).balanceOf(trader) - before;
        before = HookrToken(Currency.unwrap(zero.currency1)).balanceOf(trader);
        Paid memory b = _swapAs(zero, true, true, amount);
        uint256 outB = HookrToken(Currency.unwrap(zero.currency1)).balanceOf(trader) - before;
        assertEq(a.protocol, b.protocol, "nothing extra");
        assertEq(a.earned, b.earned);
        assertEq(outA, outB, "the trader receives the same");
        uint256 share = (uint256(lp) * 2_000 + 99) / 100 + (uint256(burn) * 2_000 + 99) / 100;
        assertEq(a.protocol, _take(true, true, amount, a.quote, share), "Hookr's share of the rules alone");
    }

    /// Pips: the Rules' quote take is the royalty plus Hookr's rule share on a pool whose rules earn Hookr a share, and
    /// the minimum on a pool without (where Hookr's rule share and the royalty are zero, a Snipe too small to pay
    /// Hookr a pip included), on every buy and sell, the LP fee surcharge exactly as without a minimum, across LP
    /// Rewards, Auto Burn, royalty, share, the Snipe, the plain rate and the swap shape.
    function testFuzz_minFee_quoteTake(
        uint16 lp,
        uint16 burn,
        uint16 royalty,
        uint16 share,
        uint24 snipe,
        uint16 minimum,
        uint8 shape
    ) public {
        lp = uint16(bound(lp, 0, 1_000));
        burn = uint16(bound(burn, 0, 1_000 - lp));
        royalty = lp == 0 ? 0 : uint16(bound(royalty, 0, 1_000));
        share = uint16(bound(share, RELEASE_FLOOR, 5_000));
        // Half the runs take a Snipe of a few pips, where Hookr's share of it can round to zero.
        snipe = uint24(shape & 4 != 0 ? bound(snipe, 0, 6) : bound(snipe, 0, 597_000));
        minimum = uint16(bound(minimum, 0, 10_000));
        bool buy = shape & 1 == 0;
        bool exactInput = shape & 2 == 0 || snipe != 0; // a guarded buy is exact input
        if (minimum != 1_000) _setMin(false, minimum);

        HookrTypes.RulesConfig memory c = _members(lp, burn, address(0))[0].rules;
        c.protocolShareBps = share;
        c.royaltyBps = royalty;
        c.royaltyTo = royalty == 0 ? address(0) : address(0xB0B);
        if (snipe != 0) {
            c.guardEndBlock = uint40(vm.getBlockNumber() + 10);
            c.snipeTaxPips = snipe;
        }
        PoolKey memory key = _bindOn(r2, _hookrToken(), c, false, address(0));
        // A Snipe earns Hookr a share only from a whole pip of it: snipe x share / 10,000 rounds down.
        bool earns = lp != 0 || burn != 0 || uint256(snipe) * share >= 10_000;
        assertEq(_minimumOf(key), earns ? 0 : minimum);

        vm.prank(address(root));
        HookrTypes.FeeQuote memory q = r2.beforeSwap(_context(key, buy, exactInput));

        uint256 lpSlice = (uint256(lp) * share + 99) / 100;
        uint256 burnSlice = (uint256(burn) * share + 99) / 100;
        uint256 lpNet = uint256(lp) * 100 - lpSlice;
        uint256 royaltyPips = lpNet * royalty / 10_000;
        uint256 lpReward = lpNet - royaltyPips;
        uint256 hookr;
        uint256 surcharge;
        if (buy) {
            uint256 room = 600_000 - 3000 - lpReward;
            uint256 charged = snipe > room ? room : snipe;
            hookr = lpSlice + burnSlice + charged * share / 10_000;
            surcharge = lpReward + charged - charged * share / 10_000;
        } else {
            royaltyPips = 0;
        }
        if (!earns) assertEq(hookr + royaltyPips, 0, "nothing else earns Hookr a share on a pool with the minimum");
        assertEq(q.quoteTakePips, royaltyPips + (earns ? hookr : minimum), "royalty + rule share, or the minimum");
        assertEq(q.lpFeeSurchargePips, surcharge, "the LP fee is untouched");
    }

    /// A dynamic fee pool earns Hookr its dynamic fee share and binds no minimum: its exact-input sell pays Hookr the
    /// same on twins bound at the plain rate's 10,000 ceiling and at zero, with nothing added where that share is below
    /// the minimum.
    function testFuzz_minFee_dynamicFeePoolsPayTheirShareAlone(uint128 amount) public {
        amount = uint128(bound(amount, 1e12, 5e22));
        IHookrLauncher.Member[] memory members = _members(0, 0, address(0));
        // The widest span the reach bound admits at sensitivity 5 and a 50% share.
        members[0].rules.maxFeePips = uint24(3000 + RulesData.maxDynamicFeeSpan(5, 5_000, 3000));
        members[0].rules.dynamicFeeSens = 5;
        members[0].rules.protocolShareBps = 5_000;
        _setMin(false, 10_000);
        PoolKey memory high = _launch(_hookrToken(), members);
        _setMin(false, 0);
        PoolKey memory zero = _launch(_hookrToken(), members);
        assertEq(_minimumOf(high), 0);
        Paid memory a = _swapAs(high, false, true, amount);
        Paid memory b = _swapAs(zero, false, true, amount);
        assertEq(a.quote, b.quote, "the same fill");
        assertEq(a.lpFee, b.lpFee, "the same dynamic fee");
        assertEq(a.protocol, b.protocol, "the dynamic fee share alone");
    }

    /// Caps: the bind bound is the r23 bound on a pool whose rules earn Hookr a share and the minimum on a pool with
    /// none (no royalty is possible there), exact: a pool whose caps do not admit it does not bind, so small caps
    /// cannot drop the minimum.
    function testFuzz_minFee_capBoundIsExact(uint16 lp, uint16 burn, uint16 royalty, uint16 minimum) public {
        lp = uint16(bound(lp, 0, 1_000));
        burn = uint16(bound(burn, 0, 1_000 - lp));
        royalty = lp == 0 ? 0 : uint16(bound(royalty, 0, 1_000));
        minimum = uint16(bound(minimum, 0, 10_000));
        if (minimum != 1_000) _setMin(false, minimum);
        uint256 lpSlice = (uint256(lp) * 2_000 + 99) / 100;
        uint256 burnSlice = (uint256(burn) * 2_000 + 99) / 100;
        uint256 royaltyPips = (uint256(lp) * 100 - lpSlice) * royalty / 10_000;
        uint256 old = lpSlice + burnSlice + royaltyPips;
        uint256 bound_ = lp == 0 && burn == 0 ? minimum : old;
        vm.assume(bound_ != 0);
        HookrTypes.RulesConfig memory c = _members(lp, burn, address(0))[0].rules;
        c.royaltyBps = royalty;
        c.royaltyTo = royalty == 0 ? address(0) : address(0xB0B);
        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _direct();
        pc.caps.maxQuoteTakePips = uint24(bound_ - 1);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        r2.bind(key, pc, abi.encode(c));
        pc.caps.maxQuoteTakePips = uint24(bound_);
        vm.prank(address(root));
        r2.bind(key, pc, abi.encode(c));
        assertEq(_minimumOf(key), lp == 0 && burn == 0 ? minimum : 0);
    }

    /// The Rules' reachable maximum quote take is still 350,000 pips at the largest minimum: a pool at the widest
    /// dynamic fee span the reach bound admits, the Snipe and Auto Burn maximum at a 5,000 share binds with caps of
    /// 350,000 and not 349,999 (the Snipe fills the room the span leaves), and binds no minimum.
    function test_minFee_reachableMaximumUnchanged() public {
        _setMin(false, 10_000);
        HookrTypes.RulesConfig memory c;
        c.maxFeePips = uint24(RulesData.maxDynamicFeeSpan(1, 5_000, 0));
        c.dynamicFeeSens = 1;
        c.burnBps = 1_000;
        c.protocolShareBps = 5_000;
        c.guardEndBlock = uint40(vm.getBlockNumber() + 10);
        c.snipeTaxPips = 600_000;
        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _direct();
        pc.baseLpFeePips = 0;
        pc.caps = HookrTypes.Caps(600_000, 349_999, 1_000);
        bytes memory data = RulesData.encode(c, 1e18);
        vm.prank(address(root));
        vm.expectRevert(IHookrRulesEvents.InvalidConfig.selector);
        r2.bind(key, pc, data);
        pc.caps.maxQuoteTakePips = 350_000;
        vm.prank(address(root));
        r2.bind(key, pc, data);
        assertEq(_minimumOf(key), 0, "every rule earns Hookr a share");
    }

    function _direct() internal returns (PoolKey memory key, HookrTypes.PoolConfig memory pc) {
        address s = _hookrToken();
        key = PoolKey(NATIVE, Currency.wrap(s), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
        pc = _pc(s);
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(key.toId()));
    }

    /// No leg is marked any more: a pool with arb recapture binds no minimum, so an executor leg has none to skip, and
    /// the Rules answer markLeg(bytes32) (0xa2697f38) for no caller, the root included.
    function test_minFee_noLegMark() public {
        PoolKey memory key = _launch(_hookrToken(), _members(0, 0, address(0)));
        bytes memory input = abi.encodeWithSelector(bytes4(0xa2697f38), key.toId());
        assertEq(bytes4(input), bytes4(keccak256("markLeg(bytes32)")));
        (bool ok,) = address(r2).call(input);
        assertFalse(ok);
        vm.prank(address(root));
        (ok,) = address(r2).call(input);
        assertFalse(ok, "not even for the root");
    }

    // ------------------------------------------------------------------ the exact-output sell's simulation

    /// simulationQuote prices an exact-output sell on a dynamic fee pool at the largest dynamic fee share, the tight
    /// bound on its real take: where that share is a pip or more the pool earns Hookr it and binds no minimum at any
    /// plain rate, so nothing is added to it, and an exact-input sell is quoted at zero. Where the whole span pays
    /// Hookr no pip (span x share below 10,000) the pool binds the minimum, and both sells are quoted at it.
    function testFuzz_minFee_exactOutputSellSimulatesTheLarger(uint16 share, uint24 span, uint16 minimum) public {
        share = uint16(bound(share, RELEASE_FLOOR, 5_000));
        // Half the runs take a span of a few pips, whose share can round to zero.
        span = uint24(minimum & 1 == 0 ? bound(span, 1, 6) : bound(span, 1, 597_000));
        span = _withinReach(span, share);
        minimum = uint16(bound(minimum, 0, 10_000));
        if (minimum != 1_000) _setMin(false, minimum);
        HookrTypes.RulesConfig memory c = _plainRules();
        c.protocolShareBps = share;
        c.maxFeePips = 3000 + span;
        c.dynamicFeeSens = 5;
        PoolKey memory key = _bindOn(r2, _hookrToken(), c, false, address(0));
        uint256 largest = uint256(span) * share / 10_000;
        uint256 bound_ = largest == 0 ? minimum : 0;
        assertEq(_minimumOf(key), bound_, "the minimum binds only where the largest share is zero");
        vm.prank(address(root));
        HookrTypes.FeeQuote memory q = r2.simulationQuote(_context(key, false, false));
        assertEq(q.quoteTakePips, largest == 0 ? minimum : largest, "the largest dynamic fee share, or the minimum");
        assertEq(q.lpFeeSurchargePips, 0, "no dynamic fee in the simulation's LP fee");
        vm.prank(address(root));
        q = r2.simulationQuote(_context(key, false, true));
        assertEq(q.quoteTakePips, bound_, "an exact-input sell: zero, or the minimum");
    }

    /// At a zero share a dynamic fee earns Hookr nothing, so a Hookr token's dynamic fee pool on Rules with a zero
    /// floor binds the minimum; its exact-output sell's simulation reserves the minimum alone (the largest dynamic fee
    /// share is zero), max(largest share, minimum) as before, and an exact-input sell is quoted at the minimum.
    function testFuzz_minFee_zeroShareExactOutputSellSimulatesTheMinimum(uint24 span, uint16 minimum) public {
        // Up to the widest span the reach bound admits at sensitivity 5 and a zero share.
        span = uint24(bound(span, 1, RulesData.maxDynamicFeeSpan(5, 0, 3000)));
        minimum = uint16(bound(minimum, 0, 10_000));
        if (minimum != 1_000) _setMin(false, minimum);
        HookrTypes.RulesConfig memory c = _plainRules();
        c.protocolShareBps = 0;
        c.maxFeePips = 3000 + span;
        c.dynamicFeeSens = 5;
        PoolKey memory key = _bindOn(r0, _hookrToken(), c, false, address(0));
        assertEq(_minimumOn(r0, key), minimum);
        vm.prank(address(root));
        HookrTypes.FeeQuote memory q = r0.simulationQuote(_context(key, false, false));
        assertEq(q.quoteTakePips, minimum, "the minimum alone");
        vm.prank(address(root));
        q = r0.simulationQuote(_context(key, false, true));
        assertEq(q.quoteTakePips, minimum, "an exact-input sell: the minimum");
    }

    /// The same exact-output sell on dynamic fee twins bound at the plain rate's 1,000 and at zero is the same swap:
    /// neither binds a minimum, so both simulate, charge and pay Hookr the same.
    function test_minFee_exactOutputSellSimulationMatchesItsTwin() public {
        IHookrLauncher.Member[] memory members = _members(0, 0, address(0));
        // The widest span the reach bound admits at sensitivity 5 and a 50% share.
        members[0].rules.maxFeePips = uint24(3000 + RulesData.maxDynamicFeeSpan(5, 5_000, 3000));
        members[0].rules.dynamicFeeSens = 5;
        members[0].rules.protocolShareBps = 5_000;
        PoolKey memory with = _launch(_hookrToken(), members);
        _setMin(false, 0);
        PoolKey memory without = _launch(_hookrToken(), members);
        assertEq(_minimumOf(with), 0);
        assertEq(_minimumOf(without), 0);
        Paid memory a = _swapAs(with, false, false, 5e22);
        Paid memory b = _swapAs(without, false, false, 5e22);
        assertGt(b.lpFee, 3000, "the sell pays a dynamic fee");
        assertEq(a.lpFee, b.lpFee, "the same dynamic fee");
        assertEq(a.quote, b.quote, "the same fill");
        assertEq(a.protocol, b.protocol, "Hookr is paid the same");
        _backed();
    }

    // ------------------------------------------------------------------ bind: other inputs

    /// A Hookr token's pool without rules freezes the minimum and is never fee-only; a pool of any other token freezes
    /// none and a pool without rules stays fee-only, reading nothing more.
    function test_minFee_hookrTokensOnly() public {
        PoolKey memory hookr = _launch(_hookrToken(), _members(0, 0, address(0)));
        assertEq(_minimumOf(hookr), 1_000);
        assertEq(r2.feeOnlyFrom(hookr.toId()), 0, "never fee-only");
        assertEq(root.feeOnlyFrom(hookr.toId()), 0);

        _setMin(false, 10_000);
        PoolKey memory other = _launch(_otherToken(), _members(0, 0, address(0)));
        assertEq(_minimumOf(other), 0, "an existing token's market binds none");
        assertEq(root.feeOnlyFrom(other.toId()), 1, "and stays fee-only");
        Paid memory p = _swapAs(other, true, true, 1 ether);
        assertEq(p.allocations, 0, "the Rules are not called");
        assertEq(p.earned, 0);
        // The launcher's own new token is a Hookr token.
        IHookrLauncher.Member[] memory members = _members(0, 0, address(0));
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(0), "N", "N", 1e27, bytes32(uint256(7))),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        assertEq(_minimumOf(launcher.position(family, 0).key), 10_000, "a launcher-created token binds it");
    }

    /// Raised and lowered rates reach only pools bound after the change; each pool keeps and charges what it froze.
    function test_minFee_frozenAtBind() public {
        PoolKey memory a = _launch(_hookrToken(), _members(0, 0, address(0)));
        _setMin(false, 2_500);
        PoolKey memory b = _launch(_hookrToken(), _members(0, 0, address(0)));
        _setMin(false, 0);
        PoolKey memory c = _launch(_hookrToken(), _members(0, 0, address(0)));
        assertEq(_minimumOf(a), 1_000);
        assertEq(_minimumOf(b), 2_500);
        assertEq(_minimumOf(c), 0);
        assertEq(root.feeOnlyFrom(c.toId()), 1, "a zero minimum and no rules is fee-only again");
        assertEq(_swapAs(a, true, true, 1 ether).protocol, 1e15);
        assertEq(_swapAs(b, true, true, 1 ether).protocol, 25e14);
        assertEq(_swapAs(c, true, true, 1 ether).allocations, 0);
        _setMin(false, 10_000);
        assertEq(_swapAs(a, true, true, 1 ether).protocol, 1e15, "a later raise never reaches a bound pool");
        _backed();
    }

    /// The Rules refuse a minimum above the 1% ceiling whatever the treasury answers.
    function test_minFee_rulesCeiling() public {
        vm.mockCall(
            address(treasury),
            abi.encodeWithSelector(IHookrTreasury.feeTerms.selector),
            abi.encode(uint16(0), uint16(0), uint16(10_001))
        );
        IHookrLauncher.Member[] memory members = _members(0, 0, address(0));
        address s = _hookrToken();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(r2),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
            )
        );
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(s, "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        vm.mockCall(
            address(treasury),
            abi.encodeWithSelector(IHookrTreasury.feeTerms.selector),
            abi.encode(uint16(0), uint16(0), uint16(10_000))
        );
        assertEq(_minimumOf(_launch(s, members)), 10_000);
    }

    /// A Rules paying an address without code has no minimum.
    function test_minFee_recipientWithoutCodeHasNone() public {
        IHookrLauncher.Member[] memory members = _members(0, 0, address(0));
        members[0].config.rules = address(rules);
        PoolKey memory key = _launch(_hookrToken(), members);
        assertEq(IHookrRecaptureRules(address(rules)).minimumFee(key.toId()), 0);
        assertEq(root.feeOnlyFrom(key.toId()), 1);
    }
}
