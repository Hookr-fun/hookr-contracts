// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";
import {Actor} from "./mocks/Actors.sol";

/// @notice The reference partner launcher's surface: launch as family owner, `collect` (withdraw 0 to the creator,
///         anyone can call) and a creator-only principal `withdraw`. No claimRecapture and no transferFamily
///         pass-through.
contract CollectAndExitLauncher {
    HookrLauncher public immutable launcher;
    address public immutable root;
    mapping(bytes32 familyId => address) public creatorOf;

    constructor(HookrLauncher launcher_, address root_) {
        launcher = launcher_;
        root = root_;
    }

    function launch(HookrToken subject, IHookrLauncher.Member[] calldata members)
        external
        payable
        returns (bytes32 familyId)
    {
        subject.approve(address(launcher), type(uint256).max);
        (familyId,) = launcher.launch{value: msg.value}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)), root, members, block.timestamp
        );
        creatorOf[familyId] = msg.sender;
    }

    /// @notice Pays a member's LP fees to the family's creator. Anyone can call.
    function collect(bytes32 familyId, uint8 member) external returns (uint256, uint256) {
        return launcher.withdraw(familyId, member, 0, 0, 0, creatorOf[familyId], block.timestamp);
    }

    /// @notice The creator withdraws principal.
    function withdraw(bytes32 familyId, uint8 member, uint128 liquidity) external returns (uint256, uint256) {
        require(msg.sender == creatorOf[familyId], "creator");
        return launcher.withdraw(familyId, member, liquidity, 0, 0, msg.sender, block.timestamp);
    }

    receive() external payable {}
}

/// @notice VERIFY-2 regression (the RCM-2 fix after a full exit). HookrLauncher refused every withdraw on an empty
///         position, fee collection included, so once a kit-like owner contract's creator had withdrawn all principal,
///         a liquidity owner accrual left in the Rules could never move again (183.83 ETH after one arb recapture,
///         412.10 ETH after two, when the LP leg still went to the owner). A recapture member now stays collectable
///         after a full exit: a zero withdraw on the empty position calls no PoolManager and moves the accrual to the
///         owner's recipient. Only the family owner can. The accrual here is an LP leg that found no in-range liquidity
///         when it was flushed; with liquidity in range, later legs are donated to it instead.
contract MoneyFullExitLpLegTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CollectAndExitLauncher internal kit;
    HookrToken internal subject;
    PoolKey internal a;
    PoolKey internal refA;
    bytes32 internal family;

    function setUp() public {
        _setUpPartnerShaped();
        kit = new CollectAndExitLauncher(launcher, address(root));
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        subject.transfer(address(kit), 2e24);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMemberAt(ETH);
        vm.deal(creator, 1e25);
        vm.prank(creator);
        family = kit.launch{value: 1e24}(subject, members);
        a = launcher.position(family, 0).key;
        refA = _hookless(a.currency0, a.currency1);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        _nextBlock();
    }

    function _ownerAccruedEth() internal view returns (uint256) {
        return _recap().poolAccrued(a.toId(), ETH);
    }

    function test_regression_theLpLegReachesTheCreatorAfterAFullExit() public {
        // An arb recapture leaves an LP leg pending; the creator exits the whole launch position in the same block.
        _buy(a, ETH, whale, 3e22);
        uint256 leg = _accrued(a);
        assertGt(leg, 1e18, "an LP leg, pending");
        vm.prank(creator);
        kit.withdraw(family, 0, 1e24);
        assertEq(launcher.position(family, 0).liquidity, 0, "the launch position is empty");
        // A full release period later a third party adds: the leg is flushed first, finds no in-range liquidity and
        // becomes the family owner's accrual.
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        Actor lp3 = _newActor(a);
        lp3.modify(a, -60_000, 60_000, int256(1e24));
        uint256 accrued = _ownerAccruedEth();
        assertEq(accrued, leg, "the whole leg, to the owner of the empty position");
        console2.log("LP leg accrued to the emptied launch position (wei ETH)", accrued);

        // The kit's fee collection, which anyone can call, moves it into the creator's Rules claim.
        uint256 claimBefore = rules.claimable(ETH, creator);
        vm.prank(attacker);
        (uint256 fees0, uint256 fees1) = kit.collect(family, 0);
        assertEq(fees0 + fees1, 0, "an empty position pays no fees");
        assertEq(_ownerAccruedEth(), 0, "the accrual moved");
        assertEq(rules.claimable(ETH, creator) - claimBefore, accrued, "into the creator's claim");

        // Only the family owner moves it: nobody else can withdraw or claim on the empty member.
        vm.startPrank(attacker);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.withdraw(family, 0, 0, 0, 0, attacker, block.timestamp);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.claimRecapture(family, 0, attacker);
        vm.stopPrank();
        // An empty position pays nothing, so a withdraw asking for a minimum is refused.
        vm.prank(address(kit));
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.withdraw(family, 0, 0, 1, 0, creator, block.timestamp);

        // With the third party in range, a later arb recapture's leg is donated to it, not accrued to the empty owner.
        _nextBlock();
        _buy(a, ETH, whale, 3e22);
        uint256 second = _accrued(a);
        assertGt(second, 0);
        _nextBlock();
        lp3.modify(a, 60_000, 60_060, 1e18);
        _flushAll(a);
        assertEq(_accrued(a), 0, "donated");
        assertEq(_ownerAccruedEth(), 0, "nothing to the empty owner");

        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        rules.claim(ETH);
        assertEq(creator.balance - balanceBefore, claimBefore + accrued, "paid out");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// A member launched without recapture still refuses a withdraw on its empty position.
    function test_anEmptyMemberWithoutRecaptureStillRefusesAWithdraw() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMemberAt(ETH);
        delete members[0].recapture;
        HookrToken s2 = _newSubject();
        s2.transfer(address(kit), 1e24);
        vm.prank(creator);
        bytes32 f2 = kit.launch{value: 1e24}(s2, members);
        uint128 all = uint128(launcher.position(f2, 0).liquidity);
        vm.prank(creator);
        kit.withdraw(f2, 0, all);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        kit.collect(f2, 0);
    }
}
