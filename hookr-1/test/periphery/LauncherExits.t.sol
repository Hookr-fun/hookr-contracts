// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRoot} from "../../src/interfaces/IHookrRoot.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {LaneExecutorStub} from "../utils/LaneExecutorStub.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @dev A contract owner/recipient with no way to receive ETH.
contract LauncherNoEtherOwner {
    HookrLauncher internal immutable launcher;

    constructor(HookrLauncher l) {
        launcher = l;
    }

    function accept(bytes32 family) external {
        launcher.acceptFamily(family);
    }

    function start(bytes32 family, address to, uint16 claims) external {
        launcher.transferFamily(family, to, claims);
    }
}

/// @dev Native recipient that, while the Launcher's unlock is open, takes the other currency for itself.
contract LauncherGreedyRecipient {
    IPoolManager internal immutable manager;
    Currency internal other;
    uint256 internal amount;

    constructor(IPoolManager m) {
        manager = m;
    }

    function arm(Currency c, uint256 a) external {
        other = c;
        amount = a;
    }

    receive() external payable {
        if (amount != 0) manager.take(other, address(this), amount);
    }
}

/// @dev Native recipient that tries to re-enter the Launcher during its own payout.
contract LauncherReenteringRecipient {
    HookrLauncher internal immutable launcher;
    bytes public reason;

    constructor(HookrLauncher l) {
        launcher = l;
    }

    receive() external payable {
        try launcher.redeem(Currency.wrap(address(0)), 1, address(this)) {}
        catch (bytes memory r) {
            reason = r;
        }
    }
}

/// @dev Stands in for a member's Rules: records the accrual claims the launcher sends it.
contract ClaimPoolRecorder {
    PoolId public lastId;
    address public lastTo;
    uint256 public calls;

    function claimPool(PoolId id, address to) external returns (uint256) {
        lastId = id;
        lastTo = to;
        ++calls;
        return 7;
    }
}

/// @notice Unit tests for direct PoolManager exits, ERC-6909 claim delivery and redemption, and storage layout.
contract LauncherExitsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SLOT = 0xe360b19a8732989700805aac9d6e452e852d1078d68e6b904d61b3d7a73a4200;
    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev Opens the root's recapture lane on a stand-in executor and launches one native member with arb recapture
    ///      on at the Rules' defaults.
    function _launchRecaptureMember() internal returns (bytes32 family, PoolKey memory key) {
        ArbSysKit.install(vm, ArbSysKit.L2_BASE, vm.getBlockNumber());
        LaneExecutorStub exec = new LaneExecutorStub(2_500);
        registry.queue(
            OPEN_LANE, abi.encode(address(root), address(exec), address(exec).codehash, uint32(600_000), uint16(2_500))
        );
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, 600_000, 2_500);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        (members[0].recapture,) = IHookrRecaptureRules(address(rules)).recaptureDefaults();
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @notice N17: a recapture member's accrual claim and every withdraw on it call the Rules named by the third word
    ///         of the root's poolConfig answer, the pool's `rules`, read without decoding the rest.
    function testAccrualFollowsTheRulesWordOfPoolConfig() public {
        (bytes32 family, PoolKey memory key) = _launchRecaptureMember();
        PoolId id = key.toId();
        assertEq(launcher.claimRecapture(family, 0, address(this)), 0, "the real Rules: nothing accrued yet");
        ClaimPoolRecorder recorder = new ClaimPoolRecorder();
        HookrTypes.PoolConfig memory pc = root.poolConfig(id);
        pc.rules = address(recorder);
        vm.mockCall(address(root), abi.encodeCall(IHookrRoot.poolConfig, (id)), abi.encode(pc));
        assertEq(launcher.claimRecapture(family, 0, address(0xC0DE)), 7);
        assertEq(PoolId.unwrap(recorder.lastId()), PoolId.unwrap(id));
        assertEq(recorder.lastTo(), address(0xC0DE));
        launcher.withdraw(family, 0, 0, 0, 0, address(0xBEEF), vm.getBlockTimestamp());
        assertEq(recorder.lastTo(), address(0xBEEF), "a fee collection moves the accrual to its recipient");
        assertEq(recorder.calls(), 2);
    }

    /// @notice N17: like the decoded read it replaced, the narrow read bubbles a failed call's revert and refuses a
    ///         short answer or a `rules` word that is not an address.
    function testAccrualReadRefusesWhatTheDecodedReadRefused() public {
        (bytes32 family, PoolKey memory key) = _launchRecaptureMember();
        bytes memory query = abi.encodeCall(IHookrRoot.poolConfig, (key.toId()));
        bytes memory full = abi.encode(root.poolConfig(key.toId()));
        assertEq(full.length, 14 * 32, "fourteen static words");

        bytes memory reason = abi.encodeWithSignature("Error(string)", "root refuses");
        vm.mockCallRevert(address(root), query, reason);
        vm.expectRevert(reason);
        launcher.claimRecapture(family, 0, address(this));
        vm.clearMockedCalls();

        bytes memory short = new bytes(13 * 32);
        for (uint256 i; i < short.length; ++i) {
            short[i] = full[i];
        }
        vm.mockCall(address(root), query, short);
        vm.expectRevert(bytes(""));
        launcher.claimRecapture(family, 0, address(this));

        bytes memory dirty = bytes.concat(full);
        dirty[64] = 0x01;
        vm.mockCall(address(root), query, dirty);
        vm.expectRevert(bytes(""));
        launcher.claimRecapture(family, 0, address(this));
        vm.expectRevert(bytes(""));
        launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
    }

    function _trade(PoolKey memory key) internal {
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e21);
        IHookrRouter.Swap memory sell = _swap(key, false, true, 1e20);
        bool native = Currency.unwrap(key.currency0) == address(0);
        vm.startPrank(trader);
        router.swap{value: native ? 1e21 : 0}(buy, address(0), new uint256[](0));
        router.swap(sell, address(0), new uint256[](0));
        vm.stopPrank();
    }

    function testNamespacedStorageMatchesErc7201() public {
        assertEq(SLOT, keccak256(abi.encode(uint256(keccak256("hookr.launcher")) - 1)) & ~bytes32(uint256(0xff)));
        (bytes32 family, PoolKey memory key,,) = _launch(true, false);
        // The namespace holds the nonce, then the families, transfers, ranges and poolFamily mappings; the reentrancy
        // lock is transient.
        assertEq(uint256(vm.load(address(launcher), SLOT)), 1, "nonce");
        for (uint256 i = 1; i <= 4; ++i) {
            assertEq(vm.load(address(launcher), bytes32(uint256(SLOT) + i)), bytes32(0), "a mapping's own slot");
        }
        bytes32 ownerSlot = keccak256(abi.encode(family, uint256(SLOT) + 1));
        assertEq(address(uint160(uint256(vm.load(address(launcher), ownerSlot)))), address(this));
        launcher.transferFamily(family, trader, 3);
        bytes32 transferSlot = keccak256(abi.encode(family, uint256(SLOT) + 2));
        uint256 word = uint256(vm.load(address(launcher), transferSlot));
        assertEq(address(uint160(word)), trader, "pending owner");
        assertEq(uint16(word >> 160), 3, "claims");
        bytes32 poolSlot = keccak256(abi.encode(key.toId(), uint256(SLOT) + 4));
        assertEq(vm.load(address(launcher), poolSlot), family);
        assertEq(launcher.poolFamily(key.toId()), family);
    }

    function testFamilyAndMemberRecordsArePacked() public {
        (bytes32 family, PoolKey memory key, HookrToken subject,) = _launch(true, true);
        IHookrLauncher.Position memory p = launcher.position(family, 0);
        assertEq(Currency.unwrap(key.currency0), address(0), "native quote sorts first");
        bytes32 familySlot = keccak256(abi.encode(family, uint256(SLOT) + 1));
        uint256 word = uint256(vm.load(address(launcher), familySlot));
        assertEq(address(uint160(word)), address(this), "owner");
        assertEq(uint8(word >> 160), launcher.memberCount(family), "memberCount");
        assertEq(uint64(word >> 168), launcher.principalLockedUntil(family), "lockedUntil");
        assertEq(word >> 232, 0, "family word padding");
        assertEq(
            address(uint160(uint256(vm.load(address(launcher), bytes32(uint256(familySlot) + 1))))), address(subject)
        );
        assertEq(address(uint160(uint256(vm.load(address(launcher), bytes32(uint256(familySlot) + 2))))), address(root));
        bytes32 memberSlot = keccak256(abi.encode(uint256(0), keccak256(abi.encode(family, uint256(SLOT) + 3))));
        word = uint256(vm.load(address(launcher), memberSlot));
        assertEq(address(uint160(word)), address(0), "quote");
        assertEq(int24(uint24(word >> 160)), key.tickSpacing, "tickSpacing");
        assertEq(int24(uint24(word >> 184)), p.tickLower, "tickLower");
        assertEq(int24(uint24(word >> 208)), p.tickUpper, "tickUpper");
        assertEq(uint256(vm.load(address(launcher), bytes32(uint256(memberSlot) + 1))), p.liquidity, "liquidity");
        assertEq(vm.load(address(launcher), bytes32(uint256(memberSlot) + 2)), bytes32(0), "two words per member");
        // A member with no position reads as all zero.
        IHookrLauncher.Position memory none = launcher.position(family, 1);
        assertEq(Currency.unwrap(none.key.currency1), address(0));
        assertEq(address(none.key.hooks), address(0));
        assertEq(none.key.tickSpacing, 0);
        assertEq(none.liquidity, 0);
    }

    function testMemberKeyMatchesLaunchedKey() public {
        (bytes32 family, PoolKey memory key,, Currency quote) = _launch(false, false);
        address subject = Currency.unwrap(root.poolConfig(key.toId()).subject);
        (PoolKey memory predicted, bool available) = launcher.memberKey(subject, quote, 60, address(root));
        assertEq(PoolId.unwrap(predicted.toId()), PoolId.unwrap(key.toId()));
        assertEq(PoolId.unwrap(predicted.toId()), PoolId.unwrap(launcher.position(family, 0).key.toId()));
        assertFalse(available);
    }

    function testClaimBitsDeliverEitherSideAsErc6909() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, true);
        _trade(key);
        uint128 liq = launcher.position(family, 0).liquidity;
        address to = address(0xC1A1);
        uint256 id0 = uint256(uint160(Currency.unwrap(key.currency0)));
        uint256 id1 = uint256(uint160(Currency.unwrap(key.currency1)));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidClaims.selector, uint256(4)));
        launcher.withdrawWithClaims(family, 0, 0, 0, 0, to, 4, block.timestamp);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.withdrawWithClaims(family, 0, 0, 0, 0, address(manager), 1, block.timestamp);

        (uint256 f0, uint256 f1) = launcher.withdrawWithClaims(family, 0, 0, 0, 0, to, 1, block.timestamp);
        assertEq(manager.balanceOf(to, id0), f0);
        assertEq(to.balance, 0);
        assertEq(tokenA.balanceOf(to), f1);
        (uint256 a0, uint256 a1) = launcher.withdrawWithClaims(family, 0, liq, 1, 1, to, 3, block.timestamp);
        assertEq(manager.balanceOf(to, id0), f0 + a0);
        assertEq(manager.balanceOf(to, id1), a1);
        assertEq(tokenA.balanceOf(to), f1);
        assertEq(address(launcher).balance, 0);
        assertEq(tokenA.balanceOf(address(launcher)), 0);
    }

    function testRedeemNeedsApprovalAndOnlyBurnsCallersClaims() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, true);
        uint128 liq = launcher.position(family, 0).liquidity;
        address holder = address(0xC1A1);
        (uint256 a0, uint256 a1) = launcher.withdrawWithClaims(family, 0, liq, 0, 0, holder, 3, block.timestamp);
        uint256 id0 = uint256(uint160(Currency.unwrap(key.currency0)));
        uint256 id1 = uint256(uint160(Currency.unwrap(key.currency1)));
        assertGt(a0, 0);
        assertGt(a1, 0);

        // Without approval the Launcher cannot burn the holder's claim.
        vm.prank(holder);
        vm.expectRevert();
        launcher.redeem(key.currency0, a0, holder);
        // Someone else cannot redeem the holder's claim, even with the holder's operator approval to the Launcher.
        vm.prank(holder);
        manager.setOperator(address(launcher), true);
        vm.prank(trader);
        vm.expectRevert();
        launcher.redeem(key.currency0, a0, trader);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidAmount.selector, uint256(0)));
        launcher.redeem(key.currency0, 0, holder);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidRecipient.selector, address(manager)));
        launcher.redeem(key.currency0, a0, address(manager));

        address out = address(0x0B0B);
        vm.prank(holder);
        launcher.redeem(key.currency0, a0, out);
        assertEq(out.balance, a0);
        assertEq(manager.balanceOf(holder, id0), 0);
        vm.prank(holder);
        manager.setOperator(address(launcher), false);
        vm.prank(holder);
        manager.approve(address(launcher), id1, a1);
        vm.prank(holder);
        launcher.redeem(key.currency1, a1, out);
        assertEq(tokenA.balanceOf(out), a1);
        assertEq(manager.balanceOf(holder, id1), 0);
        assertEq(manager.allowance(holder, address(launcher), id1), 0);
    }

    function testRecipientThatRejectsEtherCanTakeNativeSideAsClaim() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, true);
        _trade(key);
        LauncherNoEtherOwner sink = new LauncherNoEtherOwner(launcher);
        uint128 liq = launcher.position(family, 0).liquidity;
        vm.expectRevert();
        launcher.withdraw(family, 0, liq, 0, 0, address(sink), block.timestamp);
        (uint256 a0,) = launcher.withdrawWithClaims(family, 0, liq, 0, 0, address(sink), 1, block.timestamp);
        assertEq(manager.balanceOf(address(sink), 0), a0);
    }

    function testPreviousOwnerThatRejectsEtherCannotBlockAcceptance() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, true);
        LauncherNoEtherOwner old = new LauncherNoEtherOwner(launcher);
        launcher.transferFamily(family, address(old), 0);
        old.accept(family);
        _trade(key);
        old.start(family, trader, 0);
        vm.prank(trader);
        vm.expectRevert();
        launcher.acceptFamily(family);
        // The old owner chooses its own fee form: native fees as a claim.
        old.start(family, trader, 1);
        vm.prank(trader);
        launcher.acceptFamily(family);
        assertEq(launcher.familyOwner(family), trader);
        assertGt(manager.balanceOf(address(old), 0), 0, "old owner's native fees kept as a claim");
    }

    function testNativeRecipientCannotReenter() public {
        (bytes32 family,,,) = _launch(true, true);
        LauncherReenteringRecipient r = new LauncherReenteringRecipient(launcher);
        launcher.withdraw(family, 0, 1e20, 0, 0, address(r), block.timestamp);
        assertEq(bytes4(r.reason()), IHookrLauncher.Reentered.selector);
    }

    /// Review probe: a native recipient that takes the other currency inside the Launcher's unlock only creates its
    /// own debt, so the whole exit reverts; no Launcher credit leaks. Disarmed, the same recipient is paid.
    function testNativeRecipientCannotSpendLauncherCredit() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, true);
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e21);
        vm.prank(trader);
        router.swap{value: 1e21}(buy, address(0), new uint256[](0));
        LauncherGreedyRecipient r = new LauncherGreedyRecipient(manager);
        r.arm(key.currency1, 1e20);
        vm.expectRevert();
        launcher.withdraw(family, 0, 1e22, 0, 0, address(r), block.timestamp);
        r.arm(key.currency1, 0);
        (uint256 a0,) = launcher.withdraw(family, 0, 1e22, 0, 0, address(r), block.timestamp);
        assertEq(address(r).balance, a0);
    }

    function testUnlockCallbackRejectsStrangers() public {
        vm.expectRevert(IHookrLauncher.InvalidCallback.selector);
        launcher.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(IHookrLauncher.InvalidCallback.selector);
        launcher.unlockCallback("");
    }
}
