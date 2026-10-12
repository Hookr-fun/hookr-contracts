// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrFamilyLock} from "../../src/periphery/HookrFamilyLock.sol";
import {HookrFamilyRelease} from "../../src/periphery/HookrFamilyRelease.sol";
import {IHookrFamilyLock} from "../../src/interfaces/IHookrFamilyLock.sol";
import {IHookrFamilyRelease} from "../../src/interfaces/IHookrFamilyRelease.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {LaneExecutorStub} from "../utils/LaneExecutorStub.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @dev An existing subject whose transfers to `target` call back into the lock, as a hostile issuer could, and record
///      what the lock answered.
contract HostileSubject is ERC20 {
    address public target;
    HookrFamilyLock public lock;
    bytes32 public family;
    bytes public answer;
    bool internal armed;

    constructor() ERC20("Hostile", "HST") {
        _mint(msg.sender, 1e30);
    }

    function arm(address target_, HookrFamilyLock lock_, bytes32 family_) external {
        (target, lock, family, armed) = (target_, lock_, family_, true);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (armed && to == target) {
            armed = false;
            try lock.release(family, target) {
                answer = "released";
            } catch (bytes memory reason) {
                answer = reason;
            }
        }
    }
}

/// @dev A beneficiary contract that tries to release the family it is paid fees for, from its native receive.
contract ReenteringBeneficiary {
    HookrFamilyLock public lock;
    bytes32 public family;
    bytes public answer;

    function aim(HookrFamilyLock lock_, bytes32 family_) external {
        (lock, family) = (lock_, family_);
    }

    function collect() external {
        lock.collect(family, 0, 0);
    }

    receive() external payable {
        try lock.release(family, address(this)) {
            answer = "released";
        } catch (bytes memory reason) {
            answer = reason;
        }
    }
}

/// @notice HookrFamilyLock: a family's principal stays in its pools until the unlock block (for good at
///         type(uint64).max) while its beneficiary collects; a release hands it over through a HookrFamilyRelease with
///         every fee reaching the beneficiary; and the attacks: principal out before the unlock, a hijacked beneficiary
///         and reentrancy through a hostile subject.
contract HookrFamilyLockTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    HookrFamilyLock internal lock;
    address internal beneficiary = address(0xBE4E);
    address internal heir = address(0x4E14);
    address internal stranger = address(0x5757);

    function setUp() public {
        _setUpPeriphery();
        lock = new HookrFamilyLock(launcher);
    }

    /// @dev A one-member native family of tokenA, traded both ways so it has fees, and locked until `unlockBlock`.
    function _locked(uint64 unlockBlock) internal returns (bytes32 family, PoolKey memory key) {
        (family, key,,) = _launch(true, true);
        _trade(key);
        launcher.transferFamily(family, address(lock), 0);
        lock.lock(family, beneficiary, unlockBlock);
    }

    function _trade(PoolKey memory key) internal {
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e21);
        IHookrRouter.Swap memory sell = _swap(key, false, true, 1e20);
        vm.startPrank(trader);
        router.swap{value: 1e21}(buy, address(0), new uint256[](0));
        router.swap(sell, address(0), new uint256[](0));
        vm.stopPrank();
    }

    /// @dev The lock holds no native, tokenA or ERC-6909 claim of either.
    function _assertLockHoldsNothing() internal view {
        assertEq(address(lock).balance, 0, "no native");
        assertEq(tokenA.balanceOf(address(lock)), 0, "no subject");
        assertEq(manager.balanceOf(address(lock), 0), 0, "no native claim");
        assertEq(manager.balanceOf(address(lock), uint256(uint160(address(tokenA)))), 0, "no subject claim");
    }

    // ------------------------------------------------------------------------------------------------ lock

    /// @notice Locking accepts the pending transfer, pays the previous owner the fees its family earned so far, and
    ///         makes the lock the owner.
    function test_lockAcceptsAndPaysThePreviousOwner() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, true);
        _trade(key);
        launcher.transferFamily(family, address(lock), 0);
        uint256 subjectBefore = tokenA.balanceOf(address(this));
        uint256 nativeBefore = address(this).balance;
        uint64 unlockBlock = uint64(vm.getBlockNumber() + 1_000);
        vm.expectEmit(true, true, true, true, address(lock));
        emit IHookrFamilyLock.FamilyLocked(family, address(this), beneficiary, unlockBlock);
        lock.lock(family, beneficiary, unlockBlock);
        assertEq(launcher.familyOwner(family), address(lock));
        assertGt(tokenA.balanceOf(address(this)) + address(this).balance, subjectBefore + nativeBefore, "fees paid");
        (address b, uint64 u) = lock.lockOf(family);
        assertEq(b, beneficiary);
        assertEq(u, unlockBlock);
        assertEq(lock.launcher(), address(launcher));
        assertEq(lock.releaseId(), 1);
        _assertLockHoldsNothing();
    }

    function test_lockRefusals() public {
        (bytes32 family,,,) = _launch(true, true);
        uint64 later = uint64(vm.getBlockNumber() + 10);
        // No transfer to the lock started.
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.NotLockable.selector, family, address(this)));
        lock.lock(family, beneficiary, later);
        launcher.transferFamily(family, address(lock), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.InvalidBeneficiary.selector, address(0)));
        lock.lock(family, address(0), later);
        address[3] memory unpayable = [address(lock), address(launcher), address(manager)];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.InvalidBeneficiary.selector, unpayable[i]));
            lock.lock(family, unpayable[i], later);
        }
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.InvalidUnlockBlock.selector, vm.getBlockNumber()));
        lock.lock(family, beneficiary, uint64(vm.getBlockNumber()));
        // A transfer to someone else is not one to the lock.
        launcher.transferFamily(family, heir, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.NotLockable.selector, family, address(this)));
        lock.lock(family, beneficiary, later);
    }

    /// @notice Attack: once the owner starts the transfer to the lock, a stranger cannot lock the family for itself;
    ///         only the owner names the beneficiary.
    function test_beneficiaryCannotBeHijacked() public {
        (bytes32 family,,,) = _launch(true, true);
        launcher.transferFamily(family, address(lock), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.NotLockable.selector, family, stranger));
        lock.lock(family, stranger, uint64(vm.getBlockNumber() + 10));
        lock.lock(family, beneficiary, uint64(vm.getBlockNumber() + 10));
        (address b,) = lock.lockOf(family);
        assertEq(b, beneficiary);
        // Nor can anyone but the beneficiary collect, claim or release.
        address[2] memory others = [stranger, address(this)];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.NotBeneficiary.selector, family, others[i]));
            lock.collect(family, 0, 0);
            vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.NotBeneficiary.selector, family, others[i]));
            lock.claimRecapture(family, 0);
            vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.NotBeneficiary.selector, family, others[i]));
            lock.release(family, others[i]);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------------------------------------ while locked

    /// @notice The beneficiary collects fees, as tokens or ERC-6909 claims, and nothing of the principal moves.
    function test_collectPaysTheBeneficiaryAndKeepsThePrincipal() public {
        (bytes32 family, PoolKey memory key) = _locked(uint64(vm.getBlockNumber() + 1_000));
        _trade(key);
        uint128 liquidity = launcher.position(family, 0).liquidity;
        vm.prank(beneficiary);
        (uint256 a0, uint256 a1) = lock.collect(family, 0, 0);
        assertGt(a0 + a1, 0, "fees");
        assertEq(beneficiary.balance, a0, "native fees to the beneficiary");
        assertEq(tokenA.balanceOf(beneficiary), a1, "subject fees to the beneficiary");
        assertEq(launcher.position(family, 0).liquidity, liquidity, "principal untouched");
        _trade(key);
        vm.prank(beneficiary);
        (uint256 c0,) = lock.collect(family, 0, 1);
        assertEq(manager.balanceOf(beneficiary, 0), c0, "native fees as a claim");
        assertEq(launcher.position(family, 0).liquidity, liquidity, "principal untouched");
        _assertLockHoldsNothing();
    }

    /// @notice Attack: no call takes principal out before the unlock block; a lock for good never releases, even at block
    ///         2^64 - 1, where an unlock block of type(uint64).max read as a block would open.
    function test_noPrincipalBeforeTheUnlockBlock() public {
        uint256 unlockBlock = vm.getBlockNumber() + 500;
        (bytes32 family,) = _locked(uint64(unlockBlock));
        vm.roll(unlockBlock - 1);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.StillLocked.selector, family, unlockBlock));
        lock.release(family, heir);
        // The launcher refuses everyone but its owner, the lock.
        vm.prank(beneficiary);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.withdraw(family, 0, 1, 0, 0, beneficiary, vm.getBlockTimestamp());
        vm.prank(beneficiary);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.transferFamily(family, beneficiary, 0);

        (bytes32 forever,) = _lockedForGood();
        vm.roll(type(uint64).max);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.StillLocked.selector, forever, type(uint64).max));
        lock.release(forever, heir);
        vm.prank(beneficiary);
        lock.collect(forever, 0, 0);
    }

    function _lockedForGood() internal returns (bytes32 family, PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        launcher.transferFamily(family, address(lock), 0);
        lock.lock(family, beneficiary, type(uint64).max);
    }

    // ------------------------------------------------------------------------------------------------ release

    /// @notice From the unlock block the beneficiary releases the family: the fees earned until the release reach it as
    ///         ERC-6909 claims at once, the new owner accepts from the release, the fees earned in between reach the
    ///         beneficiary through the release's sweep, and the new owner holds the principal.
    function test_releaseHandsOverWithEveryFee() public {
        uint256 unlockBlock = vm.getBlockNumber() + 500;
        (bytes32 family, PoolKey memory key) = _locked(uint64(unlockBlock));
        _trade(key);
        vm.roll(unlockBlock);
        vm.prank(beneficiary);
        address handover = lock.release(family, heir);
        IHookrFamilyRelease r = IHookrFamilyRelease(handover);
        assertEq(r.lock(), address(lock));
        assertEq(r.familyId(), family);
        assertEq(r.beneficiary(), beneficiary);
        uint256 native0 = manager.balanceOf(beneficiary, 0);
        uint256 subject0 = manager.balanceOf(beneficiary, uint256(uint160(address(tokenA))));
        assertGt(native0 + subject0, 0, "the fees until the release, as claims");
        _assertLockHoldsNothing();
        (address b,) = lock.lockOf(family);
        assertEq(b, address(0), "unlocked");
        assertEq(launcher.familyOwner(family), handover);
        (address pending,) = launcher.pendingFamilyOwner(family);
        assertEq(pending, heir);

        _trade(key);
        vm.prank(heir);
        launcher.acceptFamily(family);
        assertEq(launcher.familyOwner(family), heir);
        r.sweep(Currency.wrap(address(0)));
        r.sweep(Currency.wrap(address(tokenA)));
        assertGt(
            manager.balanceOf(beneficiary, 0) + manager.balanceOf(beneficiary, uint256(uint160(address(tokenA)))),
            native0 + subject0,
            "the fees until acceptance"
        );
        assertEq(manager.balanceOf(handover, 0), 0);
        assertEq(manager.balanceOf(handover, uint256(uint160(address(tokenA)))), 0);
        uint128 liquidity = launcher.position(family, 0).liquidity;
        vm.prank(heir);
        launcher.withdraw(family, 0, liquidity, 0, 0, heir, vm.getBlockTimestamp());
        assertEq(launcher.position(family, 0).liquidity, 0, "the new owner holds the principal");
    }

    /// @notice Until the new owner accepts, the beneficiary may re-target the release; nobody else can, and after the
    ///         acceptance nobody can.
    function test_releaseRetarget() public {
        uint256 unlockBlock = vm.getBlockNumber() + 10;
        (bytes32 family,) = _locked(uint64(unlockBlock));
        vm.roll(unlockBlock);
        vm.prank(beneficiary);
        IHookrFamilyRelease r = IHookrFamilyRelease(lock.release(family, heir));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyRelease.NotAllowed.selector, stranger));
        r.transferTo(stranger);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyRelease.NotAllowed.selector, stranger));
        r.accept();
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyRelease.InvalidNewOwner.selector, address(0)));
        r.transferTo(address(0));
        // Nor the release itself: it would hold the family with nobody to accept it for it. Mutation gate FK-5.
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyRelease.InvalidNewOwner.selector, address(r)));
        r.transferTo(address(r));
        vm.prank(beneficiary);
        r.transferTo(stranger);
        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.NotPendingOwner.selector, family, heir));
        launcher.acceptFamily(family);
        vm.prank(stranger);
        launcher.acceptFamily(family);
        vm.prank(beneficiary);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        r.transferTo(heir);
    }

    function test_releaseRefusals() public {
        uint256 unlockBlock = vm.getBlockNumber() + 10;
        (bytes32 family,) = _locked(uint64(unlockBlock));
        vm.roll(unlockBlock);
        address[3] memory bad = [address(0), address(lock), address(launcher)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(beneficiary);
            vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.InvalidNewOwner.selector, bad[i]));
            lock.release(family, bad[i]);
        }
        // A released family is no longer the lock's: a second release has no beneficiary.
        vm.prank(beneficiary);
        lock.release(family, heir);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.NotBeneficiary.selector, family, beneficiary));
        lock.release(family, heir);
    }

    /// @notice A released family can be locked again by its new owner.
    function test_relockAfterRelease() public {
        uint256 unlockBlock = vm.getBlockNumber() + 10;
        (bytes32 family,) = _locked(uint64(unlockBlock));
        vm.roll(unlockBlock);
        vm.prank(beneficiary);
        lock.release(family, heir);
        vm.startPrank(heir);
        launcher.acceptFamily(family);
        launcher.transferFamily(family, address(lock), 0);
        lock.lock(family, heir, uint64(vm.getBlockNumber() + 1));
        vm.stopPrank();
        (address b,) = lock.lockOf(family);
        assertEq(b, heir);
    }

    // ------------------------------------------------------------------------------------------------ recapture

    /// @notice On a member launched with arb recapture, the beneficiary moves its accrual into its own claims: both
    ///         claimRecapture and a fee collection call the member's Rules' claimPool with the beneficiary as `to`.
    function test_claimRecaptureToTheBeneficiary() public {
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
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        launcher.transferFamily(family, address(lock), 0);
        lock.lock(family, beneficiary, uint64(vm.getBlockNumber() + 10));
        bytes memory toBeneficiary =
            abi.encodeCall(IHookrRecaptureRules.claimPool, (launcher.position(family, 0).key.toId(), beneficiary));
        vm.expectCall(address(rules), toBeneficiary);
        vm.prank(beneficiary);
        assertEq(lock.claimRecapture(family, 0), 0, "nothing accrued yet");
        vm.expectCall(address(rules), toBeneficiary);
        vm.prank(beneficiary);
        lock.collect(family, 0, 0);
        _assertLockHoldsNothing();
    }

    // ------------------------------------------------------------------------------------------------ reentrancy

    /// @notice Attack: a hostile subject that calls back into the lock when the beneficiary is paid gets Reentered;
    ///         the collection itself completes, and the family stays locked.
    function test_reentrancyThroughAHostileSubject() public {
        HostileSubject hostile = new HostileSubject();
        hostile.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(hostile), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        PoolKey memory key = launcher.position(family, 0).key;
        launcher.transferFamily(family, address(lock), 0);
        lock.lock(family, beneficiary, uint64(vm.getBlockNumber() + 1));
        // Trades in both directions so both currencies earn fees.
        hostile.transfer(trader, 1e24);
        vm.startPrank(trader);
        hostile.approve(address(router), type(uint256).max);
        router.swap(_swap(key, true, true, 1e21), address(0), new uint256[](0));
        router.swap(_swap(key, false, true, 1e21), address(0), new uint256[](0));
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 2);
        hostile.arm(beneficiary, lock, family);
        vm.prank(beneficiary);
        lock.collect(family, 0, 0);
        assertEq(bytes4(hostile.answer()), IHookrFamilyLock.Reentered.selector, "the lock refused the re-entry");
        assertEq(launcher.familyOwner(family), address(lock), "still locked");
        assertEq(hostile.balanceOf(address(lock)), 0);
        assertEq(tokenB.balanceOf(address(lock)), 0);
    }

    /// @notice Attack: a beneficiary contract re-entering the lock from its native receive, while a collection pays it,
    ///         gets Reentered, even after the unlock block.
    function test_reentrancyThroughTheBeneficiary() public {
        ReenteringBeneficiary b = new ReenteringBeneficiary();
        (bytes32 family, PoolKey memory key,,) = _launch(true, true);
        launcher.transferFamily(family, address(lock), 0);
        lock.lock(family, address(b), uint64(vm.getBlockNumber() + 1));
        _trade(key);
        vm.roll(vm.getBlockNumber() + 2);
        b.aim(lock, family);
        b.collect();
        assertEq(bytes4(b.answer()), IHookrFamilyLock.Reentered.selector);
        assertEq(launcher.familyOwner(family), address(lock), "still locked");
        assertGt(address(b).balance, 0, "the collection itself completed");
    }

    /// @notice A two-member family: the release forwards every member's fees, the subject's once, and leaves the lock
    ///         and the release holding nothing after the sweep.
    function test_releaseOfATwoMemberFamily() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(0)));
        members[1] = _member(Currency.wrap(address(tokenB)));
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        launcher.transferFamily(family, address(lock), 0);
        uint256 unlockBlock = vm.getBlockNumber() + 5;
        lock.lock(family, beneficiary, uint64(unlockBlock));
        // Both members earn fees while locked.
        _trade(launcher.position(family, 0).key);
        PoolKey memory k1 = launcher.position(family, 1).key;
        vm.startPrank(trader);
        router.swap(_swap(k1, true, true, 1e21), address(0), new uint256[](0));
        router.swap(_swap(k1, false, true, 1e20), address(0), new uint256[](0));
        vm.stopPrank();
        vm.roll(unlockBlock);
        vm.prank(beneficiary);
        IHookrFamilyRelease r = IHookrFamilyRelease(lock.release(family, heir));
        uint256[3] memory ids = [uint256(0), uint256(uint160(address(tokenA))), uint256(uint160(address(tokenB)))];
        uint256 forwarded;
        for (uint256 i; i < 3; ++i) {
            assertEq(manager.balanceOf(address(lock), ids[i]), 0, "the lock holds no claim");
            forwarded += manager.balanceOf(beneficiary, ids[i]);
        }
        assertGt(forwarded, 0);
        assertGt(manager.balanceOf(beneficiary, ids[2]), 0, "member 1's quote fees too");
        vm.prank(heir);
        launcher.acceptFamily(family);
        r.sweep(Currency.wrap(address(tokenB)));
        assertEq(manager.balanceOf(address(r), ids[2]), 0);
        assertEq(launcher.familyOwner(family), heir);
    }

    /// @notice Over unlock blocks and the block a release is tried at, a release succeeds exactly from the unlock block,
    ///         never for good, and the lock holds nothing after it.
    function testFuzz_releaseOnlyFromTheUnlockBlock(uint64 unlockOffset, uint64 tryOffset, bool forGood) public {
        unlockOffset = uint64(bound(unlockOffset, 1, 1e9));
        tryOffset = uint64(bound(tryOffset, 0, 2e9));
        uint64 unlockBlock = forGood ? type(uint64).max : uint64(vm.getBlockNumber()) + unlockOffset;
        (bytes32 family,) = _locked(unlockBlock);
        vm.roll(vm.getBlockNumber() + tryOffset);
        vm.prank(beneficiary);
        if (forGood || vm.getBlockNumber() < unlockBlock) {
            vm.expectRevert(abi.encodeWithSelector(IHookrFamilyLock.StillLocked.selector, family, unlockBlock));
            lock.release(family, heir);
            assertEq(launcher.familyOwner(family), address(lock));
        } else {
            lock.release(family, heir);
            (address pending,) = launcher.pendingFamilyOwner(family);
            assertEq(pending, heir);
        }
        _assertLockHoldsNothing();
    }
}
