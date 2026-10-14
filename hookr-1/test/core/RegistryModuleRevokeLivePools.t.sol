// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice A revoke blocks new binds only and never silently disables a live pool. On the real 4663 PoolManager,
///         Universal Router and Permit2 runtimes, six live pools (fee-only and full Rules, each with and without
///         HookrFeeAdvisory, and both again under Rules that pay a HookrTreasury, as the release deploys them) trade
///         through the router, the Universal Router and the forwarder, add liquidity, collect fees and remove
///         principal; then every claim those swaps credited is paid for real: the protocol and the royalty recipient
///         claim from the Rules, the liquidity owner's accrual moves to the family owner, and HookrTreasury collects its
///         Rules source and forwards it to its target. Every amount and every balance is the same after the root's
///         Rules modules and advisory are revoked as without the revocation, and no registry admission is read on any of
///         those paths.
contract RegistryModuleRevokeLivePoolsTest is GasBenchFixture {
    using PoolIdLibrary for PoolKey;

    /// @dev The HookrTreasury's target, to which `collect` forwards what it pulls.
    address internal constant TARGET = address(0x7A7);
    uint256 internal constant POOLS = 6;

    address internal guardian = address(0x6A7D);
    HookrFeeAdvisory internal advisory;
    HookrTreasury internal treasury;
    /// @dev Rules that pay the HookrTreasury, with the release's 2,000 bps protocol share floor.
    HookrRules internal paid;
    bytes32 internal advisedFamily;
    bytes32 internal advisedFullFamily;
    bytes32 internal paidFamily;
    bytes32 internal paidFullFamily;
    PoolKey internal advisedKey;
    PoolKey internal advisedFullKey;
    PoolKey internal paidKey;
    PoolKey internal paidFullKey;

    function setUp() public override {
        super.setUp();
        advisory = new HookrFeeAdvisory(address(this), 30 minutes, registry, address(0));
        treasury = new HookrTreasury(address(this), TARGET, manager);
        paid = new HookrRules(manager, registry, address(treasury), address(root), 2_000);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: advisory.configSchemaHash(),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 200_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        IHookrRegistry.Admission memory p = _rulesAdmission(address(paid));
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        registry.queue(registry.ADMIT(), abi.encode(address(root), p));
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        registry.admit(address(root), p);
        registry.setGuardian(guardian);
        treasury.admitSource(address(paid));
        advisedFamily = _launchAdvisedFamily(Currency.wrap(address(quoteFee)), false);
        advisedKey = launcher.position(advisedFamily, 0).key;
        advisedFullFamily = _launchAdvisedFamily(Currency.wrap(address(quoteFull)), true);
        advisedFullKey = launcher.position(advisedFullFamily, 0).key;
        paidFamily = _launchPaidFamily(Currency.wrap(address(quoteFee)), false);
        paidKey = launcher.position(paidFamily, 0).key;
        paidFullFamily = _launchPaidFamily(Currency.wrap(address(quoteFull)), true);
        paidFullKey = launcher.position(paidFullFamily, 0).key;
    }

    function _rulesAdmission(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: HookrRules(implementation).configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    function _advisedMembers(Currency quote, bool full) internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote, 120, full);
        members[0].config.advisory = address(advisory);
        members[0].config.advisoryGasLimit = 200_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
    }

    function _advisedConfigs() internal pure returns (bytes[] memory configs) {
        configs = new bytes[](1);
        configs[0] = abi.encode(IHookrFeeAdvisory.Config(1000, 500, 0, 0, 5000, 60, 1 hours));
    }

    function _launchAdvisedFamily(Currency quote, bool full) internal returns (bytes32 family) {
        (family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            _advisedMembers(quote, full),
            _advisedConfigs(),
            vm.getBlockTimestamp()
        );
    }

    /// @dev One member on the Rules that pay the HookrTreasury, at a spacing no fixture pool uses.
    function _launchPaidFamily(Currency quote, bool full) internal returns (bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote, 200, full);
        members[0].config.rules = address(paid);
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
    }

    function _routerSwapOut(PoolKey memory key, bool buy, uint128 amount) internal returns (uint256 amountOut) {
        IHookrRouter.Swap memory p = _params(key, buy, amount);
        vm.prank(trader);
        (, amountOut) = router.swap(p, address(0), new uint256[](0));
    }

    /// @dev Every path a live pool serves, recorded: router buys and sells, a Universal Router buy, a relayed buy, an
    ///      add, a fee collection and a principal removal on each pool. Then every claim those swaps credited, paid to
    ///      its recipient: the liquidity owner's accrual on each pool, every Rules claimable of every account the swaps
    ///      could credit, and the HookrTreasury's claim on its Rules source, collected and forwarded to its target. Last,
    ///      what each Rules still owes and every balance the payments reach.
    function _exercise() internal returns (uint256[] memory out) {
        PoolKey[POOLS] memory keys = [feeKey, fullKey, advisedKey, advisedFullKey, paidKey, paidFullKey];
        bytes32[POOLS] memory families =
            [feeFamily, fullFamily, advisedFamily, advisedFullFamily, paidFamily, paidFullFamily];
        HookrRules[2] memory sources = [rules, paid];
        Currency[3] memory currencies =
            [Currency.wrap(address(subject)), Currency.wrap(address(quoteFee)), Currency.wrap(address(quoteFull))];
        address[6] memory claimants = [protocol, royaltyTo, address(this), trader, owner, RELAYER];
        address[8] memory holders =
            [protocol, royaltyTo, TARGET, address(treasury), address(this), trader, owner, RELAYER];
        out = new uint256[](POOLS * 11 + 2 * 3 * 6 * 2 + 3 * 2 + 2 * 3 + 8 * 3);
        uint256 n;
        for (uint256 i; i < POOLS; ++i) {
            uint256 lockedUntil = launcher.principalLockedUntil(families[i]);
            if (vm.getBlockNumber() <= lockedUntil) vm.roll(lockedUntil + 1);
            out[n++] = _routerSwapOut(keys[i], true, 1e21);
            _nextBlock();
            out[n++] = _routerSwapOut(keys[i], false, 5e20);
            _nextBlock();
            uint256 before = subject.balanceOf(trader);
            _urSwap(keys[i], true, 1e20);
            out[n++] = subject.balanceOf(trader) - before;
            _nextBlock();
            (, uint256 relayedOut) = _relayed(keys[i], true, 1e20, 100 + i);
            out[n++] = relayedOut;
            _nextBlock();
            uint256 deadline = vm.getBlockTimestamp() + 1000;
            (uint256 a0, uint256 a1) = launcher.addLiquidity(families[i], 0, 1e20, 1e22, 1e22, deadline);
            (out[n++], out[n++]) = (a0, a1);
            (a0, a1) = launcher.withdraw(families[i], 0, 0, 0, 0, address(this), deadline);
            (out[n++], out[n++]) = (a0, a1);
            (a0, a1) = launcher.withdraw(families[i], 0, 5e19, 0, 0, address(this), deadline);
            (out[n++], out[n++]) = (a0, a1);
            // The liquidity owner's accrual (LP shares no in-range liquidity took), moved to the family owner.
            out[n++] = launcher.claimRecapture(families[i], 0, address(this));
        }
        for (uint256 s; s < sources.length; ++s) {
            for (uint256 c; c < currencies.length; ++c) {
                for (uint256 k; k < claimants.length; ++k) {
                    uint256 owed = sources[s].claimable(currencies[c], claimants[k]);
                    out[n++] = owed;
                    if (owed != 0) {
                        vm.prank(claimants[k]);
                        out[n++] = sources[s].claim(currencies[c]);
                        assertEq(sources[s].claimable(currencies[c], claimants[k]), 0, "claimed in full");
                    } else {
                        out[n++] = 0;
                    }
                }
            }
        }
        for (uint256 c; c < currencies.length; ++c) {
            out[n++] = paid.claimable(currencies[c], address(treasury));
            out[n++] = treasury.collect(address(paid), currencies[c]);
            assertEq(paid.claimable(currencies[c], address(treasury)), 0, "collected in full");
        }
        for (uint256 s; s < sources.length; ++s) {
            for (uint256 c; c < currencies.length; ++c) {
                out[n++] = sources[s].totalLiability(currencies[c]);
            }
        }
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 c; c < currencies.length; ++c) {
                out[n++] = currencies[c].balanceOf(holders[h]);
            }
        }
        assertEq(n, out.length, "every value recorded");
    }

    /// @dev Where `_exercise` records a Rules claimable and what its recipient was paid: `owed`, then `paid`.
    function _claimAt(uint256 source, uint256 currency, uint256 claimant) internal pure returns (uint256) {
        return POOLS * 11 + ((source * 3 + currency) * 6 + claimant) * 2;
    }

    /// Revoking the root's Rules modules and its advisory changes nothing on a pool already open: its trades, its
    /// liquidity, its claims, the treasury's collection and every balance they reach come out exactly as without the
    /// revocation.
    function test_livePoolsServeIdenticallyAfterTheirModulesAreRevoked() public {
        uint256 snapshot = vm.snapshotState();
        uint256[] memory expected = _exercise();
        assertGt(expected[1], 0, "a sell pays out");
        // The baseline really pays: the protocol and the royalty recipient claim on the full pool's quote, the
        // treasury collects from both of its pools, and nothing is owed afterwards.
        assertGt(expected[_claimAt(0, 2, 0)], 0, "the full pool credits the protocol");
        assertGt(expected[_claimAt(0, 2, 1)], 0, "the full pool credits the royalty");
        assertGt(expected[_claimAt(1, 2, 1)], 0, "the paid full pool credits the royalty");
        uint256 collected = POOLS * 11 + 2 * 3 * 6 * 2;
        assertGt(expected[collected + 2 * 1 + 1], 0, "the treasury collects its minimum on the fee-only pool");
        assertGt(expected[collected + 2 * 2 + 1], 0, "the treasury collects its share on the full pool");
        for (uint256 i = collected + 6; i < collected + 12; ++i) {
            assertEq(expected[i], 0, "every claim paid");
        }
        vm.revertToState(snapshot);

        vm.startPrank(guardian);
        registry.revokeModuleAdmission(address(root), address(rules));
        registry.revokeModuleAdmission(address(root), address(paid));
        registry.revokeModuleAdmission(address(root), address(advisory));
        vm.stopPrank();
        assertEq(registry.admission(address(root), address(rules)).implementation, address(0));
        assertEq(registry.admission(address(root), address(paid)).implementation, address(0));
        assertEq(registry.admission(address(root), address(advisory)).implementation, address(0));

        // No path a live pool serves, and no claim or collection, reads an admission.
        vm.expectCall(address(registry), abi.encodeWithSelector(IHookrRegistry.admission.selector), 0);
        uint256[] memory got = _exercise();
        assertEq(got, expected);
    }

    /// After the brake, new pools cannot bind the revoked modules; other modules keep launching, and a new deployment
    /// admitted through the timelock replaces a revoked one.
    function test_newPoolsRefuseRevokedModules() public {
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(advisory));
        IHookrLauncher.Member[] memory members = _advisedMembers(Currency.wrap(address(quotes[0])), true);
        bytes[] memory configs = _advisedConfigs();
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp();
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, advisory));
        launcher.launchAdvised(token, address(root), members, configs, deadline);
        // The same member without the advisory opens.
        _launchOne(Currency.wrap(address(quotes[0])), 60, true);

        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(rules));
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quotes[1])), 60, true);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, rules));
        launcher.launch(token, address(root), members, deadline);

        HookrRules replacement = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(replacement));
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        members[0].config.rules = address(replacement);
        (bytes32 family,) = launcher.launch(token, address(root), members, vm.getBlockTimestamp());
        PoolKey memory key = launcher.position(family, 0).key;
        assertEq(root.poolConfig(key.toId()).rules, address(replacement));
    }
}
