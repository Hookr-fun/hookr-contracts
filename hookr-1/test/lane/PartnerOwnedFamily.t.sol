// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";

/// @notice A launcher contract that owns the families it launches for its creators, with the surface of a reference
///         partner launcher: launch, and fee collection paid to the creator (anyone can call). It has no
///         claimRecapture and no transferFamily pass-through.
contract CollectOnlyLauncher {
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
    function collect(bytes32 familyId, uint8 member) external returns (uint256 amount0, uint256 amount1) {
        return launcher.withdraw(familyId, member, 0, 0, 0, creatorOf[familyId], block.timestamp);
    }

    receive() external payable {}
}

/// @notice RCM-2 regression: a family owned by a launcher contract that has no claimRecapture pass-through (the
///         reference partner launcher's shape). Before the fix every arb recapture's LP leg on its lane pools accrued
///         where nothing could ever move it: only the family owner can call claimRecapture, and the owner contract
///         cannot. HookrLauncher now moves a recapture member's accrual with its fees on every withdraw or fee
///         collection, into the recipient's Rules claim, so an owner that can collect fees never strands it.
contract MoneyPartnerOwnedFamilyTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CollectOnlyLauncher internal kit;
    HookrToken internal subject;
    PoolKey internal a;
    PoolKey internal refA;
    bytes32 internal family;

    function setUp() public {
        _setUpPartnerShaped();
        kit = new CollectOnlyLauncher(launcher, address(root));
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        subject.transfer(address(kit), 1e24);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMemberAt(ETH);
        vm.deal(creator, 1e25);
        vm.prank(creator);
        family = kit.launch{value: 1e24}(subject, members);
        a = launcher.position(family, 0).key;
        assertEq(launcher.familyOwner(family), address(kit), "the launcher contract owns the family");
        refA = _hookless(a.currency0, a.currency1);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        _nextBlock();
    }

    function test_regression_theLpLegReachesTheCreatorThroughFeeCollection() public {
        _buy(a, ETH, whale, 3e22);
        uint256 leg = _accrued(a);
        assertGt(leg, 1e18, "arb recaptures left an LP leg, pending");
        // Only the family owner can move an owner accrual through claimRecapture; the creator is not the owner, and
        // the owner contract has no such call. There is none here: the pool has in-range liquidity.
        vm.prank(creator);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.claimRecapture(family, 0, creator);
        (bool ok,) =
            address(kit).call(abi.encodeWithSignature("claimRecapture(bytes32,uint8,address)", family, 0, creator));
        assertFalse(ok, "the owner contract has no claimRecapture");
        // This block's swap fees reach the creator through the kit's collection.
        uint256 creatorEth = creator.balance;
        vm.prank(attacker);
        (uint256 fees0,) = kit.collect(family, 0);
        assertGt(fees0, 0);
        assertEq(creator.balance - creatorEth, fees0, "the fees reach the creator");
        // Next block the leg is donated to the in-range liquidity, the launch position, before an add lands.
        _nextBlock();
        _newActor(a).modify(a, 60_000, 60_060, 1e18);
        _flushAll(a);
        assertEq(_accrued(a), 0, "donated");
        creatorEth = creator.balance;
        vm.prank(attacker);
        (uint256 donated,) = kit.collect(family, 0);
        assertApproxEqAbs(donated, leg, 2, "the LP leg, as the launch position's fees");
        assertEq(creator.balance - creatorEth, donated, "paid to the creator by the kit's own collection");
        console2.log("LP leg that reached the creator through collect", donated);
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// A member launched without recapture never calls its Rules on withdraw.
    function test_aMemberWithoutRecaptureCollectsWithoutARulesCall() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMemberAt(ETH);
        delete members[0].recapture;
        HookrToken s2 = _newSubject();
        s2.transfer(address(kit), 1e24);
        vm.prank(creator);
        bytes32 f2 = kit.launch{value: 1e24}(s2, members);
        PoolKey memory k = launcher.position(f2, 0).key;
        _nextBlock();
        _buy(k, ETH, whale, 1e20);
        vm.expectCall(address(rules), abi.encodeWithSignature("poolAccrued(bytes32)", k.toId()), 0);
        kit.collect(f2, 0);
    }
}
