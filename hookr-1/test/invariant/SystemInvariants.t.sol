// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {IHookrLiquidityVault} from "../../src/interfaces/IHookrLiquidityVault.sol";
import {HookrPairRoot} from "../../src/factory/HookrPairRoot.sol";
import {SystemHandler} from "./SystemHandler.sol";

/// @notice Whole-system invariants over a release-shaped deployment (SystemDeploy), after every fuzzer call.
/// @dev Ported from the 2026-09-24 audit's one-transaction system suite (P1-P11, E1-E2, R1) and extended to what that
///      audit never saw:
///      - P1/E2  every Rules' PoolManager claims equal its liabilities, the sum of every beneficiary's claim, and the
///               event ledger (HookFee credited less Claimed).
///      - P2     the PoolManager is locked with no open delta, and no action left a hook with an open delta.
///      - P3     roots, pair roots, the factory, Router, Quoter, Forwarder, Launcher and the advisories hold nothing;
///               the Launcher's positions equal the PoolManager's.
///      - P4     treasury accounting per source: protocol claims owed plus collected equal protocol credited; the
///               vault's skims owed plus paid equal skimmed; treasury, target and the target's ERC-6909 balances equal
///               everything collected. Claims never exceed balances.
///      - P6/P7  paymaster holdings and Programs cash ledgers reconcile.
///      - V3/V4  vault shares equal the vault position's liquidity and the holders' balances; realised fees owed to
///               holders and the protocol never exceed the vault's ERC-6909 claims; the vault holds no tokens.
///      - PS2    every pool's protocol share is at least its Rules' minProtocolShareBps.
///      - I2     each integrator's claim owed plus claimed equals what the Rules credited it (IntegratorPaid).
///      - FA3/FA4 advisory surcharges stay within their frozen ceilings (guard ceilings while a guard lasts), and the
///               bound session tiers and keeper bounds never change.
///      - PR3    pair roots carry flags 0x2080, stay registered and verified, and hold nothing.
///      Handler-side checks (counted in `violations`): E1 HookFee equals the FeesAllocated split (the protocol's part
///      plus any integrator's), I0 a pool freezes the integrator it names at the listed rate, I1 the integrator's part
///      is exactly its frozen rate of Hookr's share, rounded down, E3 quote take within the frozen maximum, P5/P5b
///      protocol-paid ledger and rebates, P8 principal locks, P9 quote equals swap, P10 and S1 realised LP fee (exact
///      native fee incl. the pool's own base and the decayed Snipe, composed with any Uniswap protocol fee), R1 Rules
///      fail only in the guard, G1/G2/G3 the per-parent-block buy cap (never passed, never refusing a buy within it)
///      and the dev buy's closed block, DF-02 the executed swap's fee covers its move, DF-A the anchor follows the
///      executed price, DB1-DB4 dev buy bounds, PS1 no bind below the share floor, FA1/FA2 keeper bounds, PR1/PR2 pair
///      roots return no delta and charge base plus the clamped surcharge, PR4 a pair root refuses a second pool,
///      V1/V2/V5 vault deposits, withdrawals and fee claims move exactly the amounts they report (a withdrawal's
///      principal is its burned liquidity's), X1/X2 ERC-6909 exits are exact, P11 exits never revert.
///      Reach: the campaign starts in a session (SystemDeploy) with family E part way down its Snipe decay, every
///      handler hashes its seed, and test/invariant/mutations.sh requires the default profile to fail on four
///      single-line mutations of HookrRules (the launch buy's block closure, the decay's shape, the dynamic fee, the
///      buy cap).
contract SystemInvariantsTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    SystemHandler internal h;
    IPoolManager internal pm;

    function setUp() public virtual {
        h = new SystemHandler();
        pm = h.manager();
        bytes4[] memory sel = new bytes4[](25);
        sel[0] = SystemHandler.swapRouter.selector;
        sel[1] = SystemHandler.swapRouter.selector;
        sel[2] = SystemHandler.swapForwarder.selector;
        sel[3] = SystemHandler.lockerBundle.selector;
        sel[4] = SystemHandler.dustAdd.selector;
        sel[5] = SystemHandler.dustRemove.selector;
        sel[6] = SystemHandler.launcherAdd.selector;
        sel[7] = SystemHandler.launcherWithdraw.selector;
        sel[8] = SystemHandler.launcherTransfer.selector;
        sel[9] = SystemHandler.launcherRedeem.selector;
        sel[10] = SystemHandler.claim.selector;
        sel[11] = SystemHandler.treasuryOps.selector;
        sel[12] = SystemHandler.programDay.selector;
        sel[13] = SystemHandler.protocolFee.selector;
        sel[14] = SystemHandler.multicallBundle.selector;
        sel[15] = SystemHandler.bundle4337.selector;
        sel[16] = SystemHandler.clock.selector;
        sel[17] = SystemHandler.staleSyncThen.selector;
        sel[18] = SystemHandler.launchDevBuy.selector;
        sel[19] = SystemHandler.floorProbe.selector;
        sel[20] = SystemHandler.keeperReprice.selector;
        sel[21] = SystemHandler.pairSwap.selector;
        sel[22] = SystemHandler.vaultOps.selector;
        sel[23] = SystemHandler.vaultOps.selector;
        sel[24] = SystemHandler.nearCapBuy.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        targetContract(address(h));
        // Every fuzzed call comes from one account no invariant reads: on a fork, whose base fee is not zero, a call's
        // sender is left holding ETH for its gas, which would read as a balance of a checked contract.
        targetSender(address(uint160(uint256(keccak256("hookr.invariant.sender")))));
    }

    function _currencies() internal view returns (Currency[4] memory cs) {
        cs = [
            Currency.wrap(address(0)),
            Currency.wrap(address(h.Q())),
            Currency.wrap(address(h.SA())),
            Currency.wrap(address(h.SB()))
        ];
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    /// @dev P1/E2.
    function _checkRules() internal view {
        HookrRules[2] memory rs = [h.rules1(), h.rules2()];
        Currency[4] memory cs = _currencies();
        uint256 nb = h.beneficiaryCount();
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 4; ++j) {
                uint256 liab = rs[i].totalLiability(cs[j]);
                assertEq(pm.balanceOf(address(rs[i]), cs[j].toId()), liab, "P1 PoolManager claims != liabilities");
                uint256 sum;
                for (uint256 b; b < nb; ++b) {
                    sum += rs[i].claimable(cs[j], h.beneficiaries(b));
                }
                assertEq(sum, liab, "P1 sum of claimables != liabilities");
                assertEq(
                    h.ghostCredited(address(rs[i]), Currency.unwrap(cs[j]))
                        - h.ghostClaimed(address(rs[i]), Currency.unwrap(cs[j])),
                    liab,
                    "E2 event ledger does not reconstruct the liability"
                );
                assertEq(_bal(cs[j], address(rs[i])), 0, "P3 Rules hold tokens");
                address[3] memory integrators = [h.integratorA(), h.integratorB(), h.integratorC()];
                for (uint256 n; n < 3; ++n) {
                    address c = Currency.unwrap(cs[j]);
                    assertEq(
                        rs[i].claimable(cs[j], integrators[n])
                            + h.ghostIntegratorClaimed(address(rs[i]), c, integrators[n]),
                        h.ghostIntegratorCredited(address(rs[i]), c, integrators[n]),
                        "I2 integrator owed + claimed != credited"
                    );
                }
            }
        }
    }

    /// @dev P2/P3.
    function _checkCustody() internal view {
        assertFalse(pm.isUnlocked(), "P2 PoolManager left unlocked");
        assertEq(pm.getNonzeroDeltaCount(), 0, "P2 nonzero delta count");
        assertEq(h.curated().hookDeltas(), 0, "P2 an action left a hook with an open delta (curated)");
        assertEq(h.generic().hookDeltas(), 0, "P2 an action left a hook with an open delta (generic)");
        Currency[4] memory cs = _currencies();
        uint256 np = h.pairCount();
        address[] memory holders = new address[](11 + np);
        holders[0] = address(h.root1());
        holders[1] = address(h.root2());
        holders[2] = address(h.router());
        holders[3] = address(h.quoter());
        holders[4] = address(h.fwd());
        holders[5] = address(h.launcher());
        holders[6] = address(h.factory());
        holders[7] = address(h.feeAdvisory());
        holders[8] = address(h.sessionAdvisory());
        holders[9] = address(h.curated());
        holders[10] = address(h.generic());
        for (uint256 i; i < np; ++i) {
            holders[11 + i] = h.pairRoots(i);
        }
        for (uint256 i; i < holders.length; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertEq(_bal(cs[j], holders[i]), 0, "P3 periphery or root holds tokens");
                assertEq(pm.balanceOf(holders[i], cs[j].toId()), 0, "P3 periphery or root holds claims");
            }
        }
        address l = address(h.launcher());
        for (uint256 s; s < h.devSubjectCount(); ++s) {
            assertEq(IERC20(h.devSubject(s)).balanceOf(l), 0, "P3 Launcher holds a launched subject");
        }
        HookrLauncher launcher = h.launcher();
        for (uint256 f; f < h.familyCount(); ++f) {
            bytes32 fam = h.family(f);
            uint8 n = launcher.memberCount(fam);
            for (uint8 m; m < n; ++m) {
                IHookrLauncher.Position memory p = launcher.position(fam, m);
                if (p.key.tickSpacing == 0) continue;
                bytes32 pk = Position.calculatePositionKey(l, p.tickLower, p.tickUpper, keccak256(abi.encode(fam, m)));
                assertEq(pm.getPositionLiquidity(p.key.toId(), pk), p.liquidity, "P3 launcher custody mismatch");
            }
        }
    }

    /// @dev P4.
    function _checkTreasury() internal view {
        Currency[4] memory cs = _currencies();
        address tr = address(h.treasury());
        address r1 = address(h.rules1());
        address r2 = address(h.rules2());
        address target = address(0x7A76E7);
        HookrLiquidityVault v = h.vault();
        for (uint256 j; j < 4; ++j) {
            address c = Currency.unwrap(cs[j]);
            if (j < 2) {
                assertEq(
                    h.rules1().claimable(cs[j], tr) + h.ghostCollected(r1, c),
                    h.ghostProtocolCredited(r1, c),
                    "P4 rules1 protocol owed + collected != credited"
                );
                assertEq(
                    h.rules2().claimable(cs[j], tr) + h.ghostCollected(r2, c),
                    h.ghostProtocolCredited(r2, c),
                    "P4 rules2 protocol owed + collected != credited"
                );
            }
            assertEq(
                v.protocolFees(cs[j]) + h.ghostVaultPaid(c),
                h.ghostVaultSkim(c),
                "P4 vault skims owed + paid != skimmed"
            );
            assertEq(
                _bal(cs[j], target) + _bal(cs[j], tr) + pm.balanceOf(target, cs[j].toId()),
                h.ghostCollected(r1, c) + h.ghostCollected(r2, c) + h.ghostVaultPaid(c),
                "P4 target + treasury != collected"
            );
            assertEq(pm.balanceOf(tr, cs[j].toId()), 0, "P4 treasury holds claims");
        }
    }

    /// @dev P6/P7.
    function _checkPaymasterPrograms() internal view {
        HookrPaymaster p = h.paymaster();
        address q = address(h.Q());
        if (h.postOpReverts() == 0) {
            assertEq(address(p).balance, p.totalCredit(address(0)) + p.revenue(address(0)), "P6 native holdings");
            assertEq(h.Q().balanceOf(address(p)), p.totalCredit(q) + p.revenue(q), "P6 token holdings");
        } else {
            assertGe(address(p).balance, p.totalCredit(address(0)) + p.revenue(address(0)), "P6 native holdings");
        }
        HookrPrograms pr = h.programs();
        assertLe(pr.reservedCash(q), h.Q().balanceOf(address(pr)), "P7 reservedCash above balance");
        uint256[2] memory ids = [h.immediateId(), h.dailyId()];
        uint256 open;
        for (uint256 i; i < 2; ++i) {
            IHookrPrograms.Program memory g = pr.program(ids[i]);
            assertLe(g.cashPaid, g.cashAllocated, "P7 cashPaid above cashAllocated");
            assertLe(g.cashAllocated + g.cashRefunded, g.terms.cashBudget, "P7 allocated + refunded above budget");
            if (g.terms.rewardToken == q) open += g.terms.cashBudget - g.cashPaid - g.cashRefunded;
        }
        assertEq(pr.reservedCash(q), open, "P7 reservedCash != sum of open program cash");
    }

    /// @dev V3/V4.
    function _checkVault() internal view {
        HookrLiquidityVault v = h.vault();
        Currency[4] memory cs = _currencies();
        uint256[4] memory owed;
        for (uint256 j; j < 4; ++j) {
            owed[j] = v.protocolFees(cs[j]);
            assertEq(_bal(cs[j], address(v)), 0, "V4 vault holds tokens");
        }
        for (uint256 r; r < h.rangeCount(); ++r) {
            SystemHandler.Range memory g = h.rangeAt(r);
            PoolKey memory k = g.pair ? h.pairKey(g.pool) : h.key(g.pool);
            uint256 supply = v.totalSupply(g.id);
            IHookrLiquidityVault.Range memory rg = v.range(g.id);
            Currency[2] memory rc = h.rangeCurrencies(g.id);
            uint256 sum;
            for (uint256 a; a < 4; ++a) {
                address who = h.actors(a);
                uint256 bal = v.balanceOf(who, g.id);
                sum += bal;
                IHookrLiquidityVault.Account memory acc = v.account(g.id, who);
                uint256 f0 = acc.owed0;
                uint256 f1 = acc.owed1;
                unchecked {
                    f0 += FullMath.mulDiv(rg.feesPerShare0X128 - acc.feesPerShare0X128, bal, FixedPoint128.Q128);
                    f1 += FullMath.mulDiv(rg.feesPerShare1X128 - acc.feesPerShare1X128, bal, FixedPoint128.Q128);
                }
                owed[_index(cs, rc[0])] += f0;
                owed[_index(cs, rc[1])] += f1;
            }
            assertEq(sum, supply, "V3 vault share balances != totalSupply");
            bytes32 pk = Position.calculatePositionKey(address(v), g.lower, g.upper, bytes32(0));
            assertEq(pm.getPositionLiquidity(k.toId(), pk), supply, "V3 vault shares != position liquidity");
        }
        for (uint256 j; j < 4; ++j) {
            assertGe(pm.balanceOf(address(v), cs[j].toId()), owed[j], "V4 vault fees owed above its claims");
        }
    }

    function _index(Currency[4] memory cs, Currency c) internal pure returns (uint256) {
        for (uint256 j; j < 4; ++j) {
            if (Currency.unwrap(cs[j]) == Currency.unwrap(c)) return j;
        }
        revert("unknown range currency");
    }

    /// @dev PS2.
    function _checkFloors() internal view {
        for (uint256 i; i < h.poolCount(); ++i) {
            PoolKey memory k = h.key(i);
            HookrRules r = address(k.hooks) == address(h.root1()) ? h.rules1() : h.rules2();
            assertEq(r.minProtocolShareBps(), 2_000, "PS2 minProtocolShareBps changed");
            assertGe(r.config(k.toId()).protocolShareBps, r.minProtocolShareBps(), "PS2 pool share below the floor");
        }
    }

    /// @dev FA3/FA4.
    function _checkAdvisories() internal view {
        HookrFeeAdvisory fee = h.feeAdvisory();
        HookrSessionAdvisory session = h.sessionAdvisory();
        (
            IHookrFeeAdvisory.Session memory fs,
            IHookrFeeAdvisory.Bounds memory fb,
            IHookrFeeAdvisory.Session memory ps,
            IHookrSessionAdvisory.Bound memory sb
        ) = h.frozen();
        PoolId feeId = h.key(2).toId();
        PoolId sessionId = h.key(3).toId();
        PoolId pairId = h.pairKey(1).toId();
        assertEq(keccak256(abi.encode(fee.sessionTiers(feeId))), keccak256(abi.encode(fs)), "FA4 session tiers changed");
        assertEq(keccak256(abi.encode(fee.poolBounds(feeId))), keccak256(abi.encode(fb)), "FA4 keeper bounds changed");
        assertEq(keccak256(abi.encode(fee.sessionTiers(pairId))), keccak256(abi.encode(ps)), "FA4 pair tiers changed");
        assertEq(
            keccak256(abi.encode(session.schedule(address(h.root1()), sessionId))),
            keccak256(abi.encode(sb)),
            "FA4 session schedule changed"
        );
        assertLe(fee.surcharge(feeId, true), fb.cap, "FA3 fee surcharge above its cap");
        assertLe(fee.surcharge(feeId, false), fb.cap, "FA3 fee surcharge above its cap");
        assertLe(fee.surcharge(pairId, true), fee.poolBounds(pairId).cap, "FA3 pair surcharge above its cap");
        assertLe(fee.surcharge(pairId, false), fee.poolBounds(pairId).cap, "FA3 pair surcharge above its cap");
        uint256 limit = block.number < sb.guardEnd ? sb.guardLimit : sb.limit;
        assertLe(session.surchargeAt(address(h.root1()), sessionId, block.timestamp), limit, "FA3 session above limit");
        assertLe(limit, 50_000, "FA3 session limit above the admission cap");
    }

    /// @dev PR3.
    function _checkPairs() internal view {
        for (uint256 i; i < h.pairCount(); ++i) {
            address r = h.pairRoots(i);
            assertEq(uint160(r) & 0x3fff, 0x2080, "PR3 pair root flags");
            assertEq(HookrPairRoot(r).PERMISSION_FLAGS(), 0x2080, "PR3 declared flags");
            (, bool verified) = h.registry().rootStatus(r);
            assertTrue(verified, "PR3 pair root unverified");
        }
    }

    function _checkViolations() internal view {
        if (h.violations() != 0) {
            string[] memory log = h.violationLog();
            for (uint256 i; i < log.length; ++i) {
                console2.log(log[i]);
            }
            assertEq(h.violations(), 0, log[0]);
        }
    }

    function invariant_system() public view {
        _checkRules();
        _checkCustody();
        _checkTreasury();
        _checkPaymasterPrograms();
        _checkVault();
        _checkFloors();
        _checkAdvisories();
        _checkPairs();
        _checkViolations();
    }

    /// @dev L: after every run, every party exits and every ledger drains to zero. HOOKR_INVARIANT_COVERAGE=true prints
    ///      each run's handler coverage first.
    function afterInvariant() public virtual {
        if (vm.envOr("HOOKR_INVARIANT_COVERAGE", false)) _printCoverage();
        h.liveness();
        _checkViolations();
        HookrRules[2] memory rs = [h.rules1(), h.rules2()];
        Currency[4] memory cs = _currencies();
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertEq(rs[i].totalLiability(cs[j]), 0, "L liabilities left after every exit");
                assertEq(pm.balanceOf(address(rs[i]), cs[j].toId()), 0, "L Rules claims left after every exit");
            }
        }
        HookrLiquidityVault v = h.vault();
        for (uint256 r; r < h.rangeCount(); ++r) {
            assertEq(v.totalSupply(h.rangeAt(r).id), 0, "L vault shares left after every exit");
        }
        for (uint256 j; j < 4; ++j) {
            assertEq(v.protocolFees(cs[j]), 0, "L vault protocol fees left after collection");
        }
        invariant_system();
    }

    /// @dev E3 on a guarded dev buy whose Snipe the room clips: base 96,343, maxFeePips 143,039, snipeTaxPips 498,093,
    ///      share 4,637, LP Rewards 200 bps, Auto Burn 100, royalty 500. The buy pays no dynamic fee and the whole
    ///      room as Snipe, so its share is rounded once, 228,820 pips, and its take 243,267. HookrRules._validate bounds
    ///      it so, on the unclipped snipeTaxPips; a handler that tested the clipped Snipe rounded twice, 228,819, and
    ///      flagged the buy. The campaign's shrunk counterexample, pinned.
    function test_E3_guardedBuyWithAClippedSnipeTakesTheJointlyRoundedShare() public {
        h.launchDevBuy(19_968);
        assertEq(h.devLaunches(), 1, "the dev buy launched");
        this.invariant_system();
    }

    /// @dev G2 on a sell that filled nothing: after a dev buy, a real sell drains the band's quote and leaves the price
    ///      in an empty range, and a second exact-input sell there moves the price with zero amounts. Its direction
    ///      cannot be read from the amounts, and it moves no guard counter, so it is not a buy; a handler that read it
    ///      as one flagged G2 although the launch parent block stayed closed to buys. The campaign's counterexample,
    ///      pinned.
    function test_G2_aSellThatFilledNothingIsNotABuy() public {
        h.launchDevBuy(10_008);
        h.lockerBundle(109_182_686);
        h.lockerBundle(19_718);
        this.invariant_system();
    }

    /// @dev Deterministic drive of every handler (seeded), printing coverage. Same checks as the invariant.
    ///      The checks run as external calls so each gets fresh memory; gas metering is paused for the long drive.
    function test_smoke_allHandlers() public {
        vm.pauseGasMetering();
        uint256 s = 0x5eed;
        for (uint256 i; i < 400; ++i) {
            s = uint256(keccak256(abi.encode(s, i)));
            _drive(s % 24, s >> 5);
            this.invariant_system();
        }
        _printCoverage();
        afterInvariant();
    }

    function _drive(uint256 op, uint256 seed) internal {
        if (op == 0) h.swapRouter(seed);
        else if (op == 1) h.swapForwarder(seed);
        else if (op == 2) h.lockerBundle(seed);
        else if (op == 3) h.dustAdd(seed);
        else if (op == 4) h.dustRemove(seed);
        else if (op == 5) h.launcherAdd(seed);
        else if (op == 6) h.launcherWithdraw(seed);
        else if (op == 7) h.launcherTransfer(seed);
        else if (op == 8) h.launcherRedeem(seed);
        else if (op == 9) h.claim(seed);
        else if (op == 10) h.treasuryOps(seed);
        else if (op == 11) h.programDay(seed);
        else if (op == 12) h.protocolFee(seed);
        else if (op == 13) h.multicallBundle(seed);
        else if (op == 14) h.bundle4337(seed);
        else if (op == 15) h.staleSyncThen(seed);
        else if (op == 16) h.launchDevBuy(seed);
        else if (op == 17) h.floorProbe(seed);
        else if (op == 18) h.keeperReprice(seed);
        else if (op == 19) h.pairSwap(seed);
        else if (op == 20) h.vaultOps(seed);
        else if (op == 21) h.swapRouter(seed);
        else if (op == 22) h.nearCapBuy(seed);
        else h.clock(seed);
    }

    function _printCoverage() internal view {
        (string[] memory labels, uint256[] memory counts) = h.coverage();
        for (uint256 i; i < labels.length; ++i) {
            console2.log(labels[i], counts[i]);
        }
        console2.log("executions", h.executions(), "devLaunches", h.devLaunches());
        console2.log("rebateOps", h.rebateOps(), "rebatesPaid", h.rebatesPaid());
        console2.log("postOpReverts", h.postOpReverts(), "quoteMismatchAfterTrigger", h.quoteMismatchAfterTrigger());
        console2.log("dynamicChecks", h.dynamicChecks(), "anchorChecks", h.anchorChecks());
        console2.log("lpFeeChecks", h.lpFeeChecks(), "guardBuys", h.guardBuys());
        console2.log("protocolFeeChecks", h.protocolFeeChecks());
        console2.log("pairDeltaChecks", h.pairDeltaChecks(), "vaultPrincipalChecks", h.vaultPrincipalChecks());
        console2.log("pools", h.poolCount(), "families", h.familyCount());
    }
}

