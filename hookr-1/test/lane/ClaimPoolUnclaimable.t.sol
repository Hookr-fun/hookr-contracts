// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {MockRestrictedToken} from "../mocks/MockRestrictedToken.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice RL-01: HookrRecapture.claimPool, which HookrLauncher.claimRecapture and every withdraw or fee collection of
///         a recapture member call with a recipient the family owner names, refused zero and the Rules themselves but
///         accepted the Rules' trusted root, the PoolManager and the HookrRecapture module. None of them ever calls
///         the Rules' claim, claimTo or claimAsClaims, so the liquidity owner's whole accrual became a Rules claim no
///         one could be paid, a liability left on the ledger for good. claimPool now refuses all three, as the Rules
///         refuse them as an integrator.
/// @dev The setup is RecaptureClaimsTest's: a recapture pool whose LP share of an arb recapture becomes the liquidity
///      owner's accrual (no in-range liquidity at its flush).
contract ClaimPoolUnclaimableTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    MockRestrictedToken internal rst;
    PoolKey internal key;
    Currency internal q;
    PoolId internal id;
    bytes32 internal family;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        _openLane(address(exec));
        rst = new MockRestrictedToken("Restricted", "RST", 1e30, "frozen");
        _catalogQuote(address(rst));
        rst.transfer(creator, 1e27);
        rst.transfer(whale, 1e27);
        rst.transfer(address(exec), 1e27);
        vm.prank(creator);
        rst.approve(address(launcher), type(uint256).max);
        vm.prank(whale);
        rst.approve(address(router), type(uint256).max);
        q = Currency.wrap(address(rst));
        (key, family) = _openPoolWithFamily(q, _laneRules(false), _recaptureOnlyRc());
        id = key.toId();
        address subject = Currency.unwrap(_subjectOf(key));
        ERC20(subject).transfer(address(exec), 1e24);
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = ScriptedExecutor.Step(key, Currency.unwrap(key.currency0) == subject, 1e15);
        exec.setPlan(steps, false, false, q);
        exec.set(ScriptedExecutor.Mode.PLAN, 1e19);
        _buy(key, q, whale, 1e20);
        // The LP share is pending; the creator exits in this block, so it becomes the creator's accrual at its flush.
        _pendingToOwner(key, family, 0, creator);
    }

    /// @dev The accounts that can never claim a Rules claim: the Rules, their trusted root, the PoolManager and their
    ///      HookrRecapture module.
    function _cannotClaim() internal view returns (address[4] memory list) {
        (bool ok, bytes memory out) = address(rules).staticcall(abi.encodeWithSignature("recaptureModule()"));
        require(ok, "rules call");
        (address module,) = abi.decode(out, (address, bytes32));
        assertEq(rules.trustedRoot(), address(root), "the pool's root is the Rules' trusted root");
        list = [address(rules), address(root), address(manager), module];
    }

    /// The PoC: claimRecapture naming any of them is refused, the accrual stays the pool's and the ledger is
    /// unchanged; the family owner then claims it to itself.
    function test_claimRecaptureRefusesEveryAccountThatCanNeverClaim() public {
        address[4] memory cannotClaim = _cannotClaim();
        uint256 owed = _ownerAccrued(key);
        assertGt(owed, 0, "the accrual exists");
        uint256 liabilities = rules.totalLiability(q);
        for (uint256 i; i < cannotClaim.length; ++i) {
            vm.prank(creator);
            vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
            launcher.claimRecapture(family, 0, cannotClaim[i]);
            assertEq(rules.claimable(q, cannotClaim[i]), 0);
        }
        assertEq(_ownerAccrued(key), owed, "the accrual stays the pool's");
        assertEq(rules.totalLiability(q), liabilities, "the ledger is unchanged");
        uint256 held = rules.claimable(q, creator);
        vm.prank(creator);
        assertEq(launcher.claimRecapture(family, 0, creator), 1, "one currency moved");
        assertEq(rules.claimable(q, creator) - held, owed, "the family owner holds the accrual");
    }

    /// A withdraw moves the accrual to its recipient, so one naming any of them is refused whole: the Rules, their
    /// root and their module by claimPool, the PoolManager already by the launcher. The family owner then withdraws to
    /// itself and takes the accrual as a claim.
    function test_withdrawToAnAccountThatCanNeverClaimIsRefused() public {
        address[4] memory cannotClaim = _cannotClaim();
        uint256 owed = _ownerAccrued(key);
        for (uint256 i; i < cannotClaim.length; ++i) {
            vm.prank(creator);
            if (cannotClaim[i] == address(manager)) vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
            else vm.expectRevert(IHookrRulesEvents.Unauthorized.selector);
            launcher.withdraw(family, 0, 0, 0, 0, cannotClaim[i], vm.getBlockTimestamp());
        }
        assertEq(_ownerAccrued(key), owed, "the accrual stays the pool's");
        uint256 held = rules.claimable(q, creator);
        vm.prank(creator);
        launcher.withdraw(family, 0, 0, 0, 0, creator, vm.getBlockTimestamp());
        assertEq(rules.claimable(q, creator) - held, owed, "the family owner holds the accrual");
    }
}
