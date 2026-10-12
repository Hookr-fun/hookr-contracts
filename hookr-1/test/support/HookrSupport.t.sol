// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrToken} from "../../src/interfaces/IHookrToken.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";

contract ManagerMarker {}

contract ProtocolClaimsMock {
    using CurrencyLibrary for Currency;
    IPoolManager public immutable poolManager;
    address public immutable protocolRecipient;
    mapping(Currency => mapping(address => uint256)) public claimable;
    bool public misreport;

    constructor(IPoolManager manager, address recipient) {
        poolManager = manager;
        protocolRecipient = recipient;
    }

    receive() external payable {}

    function credit(Currency currency, address user, uint256 amount) external {
        claimable[currency][user] += amount;
    }

    function setMisreport(bool enabled) external {
        misreport = enabled;
    }

    function claimTo(Currency currency, address to) external returns (uint256 amount) {
        amount = claimable[currency][msg.sender];
        claimable[currency][msg.sender] = 0;
        currency.transfer(to, amount);
        if (misreport) ++amount;
    }
}

contract RejectNative {
    receive() external payable {
        revert();
    }
}

contract ReenterTarget {
    HookrTreasury public treasury;
    bool public reentered;

    function setTreasury(HookrTreasury value) external {
        treasury = value;
    }

    receive() external payable {
        (reentered,) = address(treasury).call(abi.encodeCall(HookrTreasury.forwardBalance, (Currency.wrap(address(0)))));
    }
}

/// @dev A false-return transfer must roll back its balance changes in the isolated delivery frame.
contract FalseReturnToken {
    mapping(address => uint256) public balanceOf;
    address public rejectedTarget;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setRejectedTarget(address target) external {
        rejectedTarget = target;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return to != rejectedTarget;
    }
}

contract HookrTreasuryTest is Test {
    Currency internal constant NATIVE = Currency.wrap(address(0));
    IPoolManager internal manager;
    HookrTreasury internal treasury;
    ProtocolClaimsMock internal source;
    address internal target = address(0xBEEF);
    address internal user = address(0xCAFE);

    function setUp() public {
        manager = IPoolManager(address(new ManagerMarker()));
        treasury = new HookrTreasury(address(this), target, manager);
        source = new ProtocolClaimsMock(manager, address(treasury));
        treasury.admitSource(address(source));
    }

    function _changeTarget(address next) internal {
        treasury.proposeTarget(next);
        vm.warp(vm.getBlockTimestamp() + treasury.TARGET_DELAY());
        treasury.acceptTarget();
    }

    function testCollectionCannotConsumeUserClaimsOrOldTreasuryBalance() public {
        vm.deal(address(source), 12 ether);
        vm.deal(address(treasury), 3 ether);
        source.credit(NATIVE, address(treasury), 5 ether);
        source.credit(NATIVE, user, 7 ether);
        vm.prank(user);
        assertEq(treasury.collect(address(source), NATIVE), 5 ether);
        assertEq(target.balance, 5 ether);
        assertEq(address(treasury).balance, 3 ether);
        assertEq(address(source).balance, 7 ether);
        assertEq(source.claimable(NATIVE, user), 7 ether);
        assertEq(source.claimable(NATIVE, address(treasury)), 0);
        assertEq(treasury.collect(address(source), NATIVE), 0);
        assertEq(target.balance, 5 ether);
    }

    function testDeliveryFailureRetainsProtocolCashThenRetries() public {
        _changeTarget(address(new RejectNative()));
        vm.deal(address(source), 4 ether);
        source.credit(NATIVE, address(treasury), 4 ether);
        assertEq(treasury.collect(address(source), NATIVE), 4 ether);
        assertEq(address(treasury).balance, 4 ether);
        assertEq(source.claimable(NATIVE, address(treasury)), 0);
        _changeTarget(target);
        vm.prank(user);
        (uint256 amount, bool delivered) = treasury.forwardBalance(NATIVE);
        assertEq(amount, 4 ether);
        assertTrue(delivered);
        assertEq(target.balance, 4 ether);
        assertEq(address(treasury).balance, 0);
    }

    function testFalseReturnCannotTransferAndLeaveAnApparentDeferredBalance() public {
        FalseReturnToken token = new FalseReturnToken();
        Currency currency = Currency.wrap(address(token));
        token.mint(address(source), 100);
        token.setRejectedTarget(target);
        source.credit(currency, address(treasury), 100);
        assertEq(treasury.collect(address(source), currency), 100);
        assertEq(token.balanceOf(target), 0);
        assertEq(token.balanceOf(address(treasury)), 100);
        token.setRejectedTarget(address(0));
        (uint256 amount, bool delivered) = treasury.forwardBalance(currency);
        assertEq(amount, 100);
        assertTrue(delivered);
        assertEq(token.balanceOf(target), 100);
        assertEq(token.balanceOf(address(treasury)), 0);
    }

    function testReportedReceiptMismatchRollsBackSourceClaim() public {
        vm.deal(address(source), 1 ether);
        source.credit(NATIVE, address(treasury), 1 ether);
        source.setMisreport(true);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.ReceiptMismatch.selector, 1 ether + 1, 1 ether));
        treasury.collect(address(source), NATIVE);
        assertEq(address(source).balance, 1 ether);
        assertEq(source.claimable(NATIVE, address(treasury)), 1 ether);
        assertEq(address(treasury).balance, 0);
        assertEq(target.balance, 0);
    }

    function testRecipientCannotReenterCollectionOrSweep() public {
        ReenterTarget receiver = new ReenterTarget();
        receiver.setTreasury(treasury);
        _changeTarget(address(receiver));
        vm.deal(address(source), 2 ether);
        vm.deal(address(treasury), 3 ether);
        source.credit(NATIVE, address(treasury), 2 ether);
        treasury.collect(address(source), NATIVE);
        assertFalse(receiver.reentered());
        assertEq(address(receiver).balance, 2 ether);
        assertEq(address(treasury).balance, 3 ether);
    }

    function testSourceMustAssignOnlyProtocolClaimsToThisTreasury() public {
        ProtocolClaimsMock wrong = new ProtocolClaimsMock(manager, user);
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.admitSource(address(wrong));
        wrong = new ProtocolClaimsMock(IPoolManager(address(new ManagerMarker())), address(treasury));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.admitSource(address(wrong));
        vm.expectRevert(IHookrTreasury.SourceAlreadyAdmitted.selector);
        treasury.admitSource(address(source));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.collect(address(wrong), NATIVE);
    }

    function testRuntimeChangeDisablesSourceCollection() public {
        vm.etch(address(source), hex"00");
        vm.expectRevert(IHookrTreasury.SourceCodeChanged.selector);
        treasury.collect(address(source), NATIVE);
    }

    function testOwnerRotationAndDestinationAuthority() public {
        vm.prank(user);
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.proposeTarget(user);
        vm.expectRevert(IHookrTreasury.InvalidTarget.selector);
        treasury.proposeTarget(address(source));
        vm.expectRevert(IHookrTreasury.InvalidTarget.selector);
        treasury.proposeTarget(address(manager));
        vm.expectRevert(IHookrTreasury.NotSelf.selector);
        treasury.deliver(NATIVE, user, 1);
        treasury.proposeOwner(user);
        vm.expectRevert(IHookrTreasury.NotPendingOwner.selector);
        treasury.acceptOwnership();
        vm.prank(user);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), user);
        assertEq(treasury.pendingOwner(), address(0));
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        treasury.proposeTarget(user);
    }
}

contract HookrTokenTest is Test {
    HookrToken internal token;
    address internal recipient = address(0xCAFE);
    address internal spender = address(0xBEEF);
    uint256 internal constant SUPPLY = 1_000_000 ether;

    function setUp() public {
        token = new HookrToken("Example", "EX", SUPPLY, recipient);
    }

    function testOneIssuanceAndNoMintAuthority() public {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        (bool success,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", recipient, 1));
        assertFalse(success);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzTransfersConserveSupply(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        vm.prank(recipient);
        token.transfer(spender, amount);
        assertEq(token.balanceOf(recipient) + token.balanceOf(spender), SUPPLY);
        vm.prank(spender);
        token.transfer(spender, amount);
        assertEq(token.balanceOf(spender), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testAllowanceSpendAndInfiniteAllowance() public {
        vm.prank(recipient);
        token.approve(spender, 2);
        vm.prank(spender);
        token.transferFrom(recipient, spender, 1);
        assertEq(token.allowance(recipient, spender), 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1, 2));
        token.transferFrom(recipient, spender, 2);
        vm.prank(recipient);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(recipient, spender, 1);
        assertEq(token.allowance(recipient, spender), type(uint256).max);
        assertEq(token.balanceOf(spender), 2);
    }

    /// @notice A token's tagline and logo URI start empty. Its creator sets them once, in the transaction that created
    ///         it, within their bounds; nobody else can, and nothing changes them afterwards.
    function testPresentationIsSetOnceByItsCreator() public {
        HookrToken t = new HookrToken("Presented", "PRS", SUPPLY, recipient);
        assertEq(t.tagline(), "");
        assertEq(t.logoURI(), "");
        string memory tagline160 = _bytes(160);
        string memory logo300 = _bytes(300);
        vm.prank(spender);
        vm.expectRevert(IHookrToken.NotPresenter.selector);
        t.setPresentation("x", "y");
        vm.expectRevert(IHookrToken.InvalidMetadata.selector);
        t.setPresentation(_bytes(161), "");
        vm.expectRevert(IHookrToken.InvalidMetadata.selector);
        t.setPresentation("", _bytes(301));
        t.setPresentation(tagline160, logo300);
        assertEq(t.tagline(), tagline160);
        assertEq(t.logoURI(), logo300);
        vm.expectRevert(IHookrToken.NotPresenter.selector);
        t.setPresentation("again", "");
        assertEq(t.tagline(), tagline160, "set for good");
    }

    /// @notice The token setUp created in an earlier transaction can no longer be given a presentation, even by its
    ///         creator: the creator was held in transient storage.
    function testPresentationClosesWithTheCreatingTransaction() public {
        vm.expectRevert(IHookrToken.NotPresenter.selector);
        token.setPresentation("late", "late");
        assertEq(token.tagline(), "");
    }

    /// @notice Tokens with and without a presentation share one runtime codehash.
    function testPresentationKeepsOneCodehash() public {
        HookrToken a = new HookrToken("A", "A", 1, recipient);
        HookrToken b = new HookrToken("B", "B", 2, spender);
        b.setPresentation("a tagline", "ipfs://logo");
        assertEq(address(a).codehash, address(b).codehash);
        assertEq(address(a).codehash, keccak256(type(HookrToken).runtimeCode));
    }

    function _bytes(uint256 n) internal pure returns (string memory s) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = "a";
        }
        s = string(b);
    }

    function testRejectsBurnAndInvalidIssuance() public {
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(IHookrToken.ZeroSupply.selector);
        new HookrToken("Example", "EX", 0, recipient);
        vm.expectRevert(IHookrToken.InvalidMetadata.selector);
        new HookrToken("", "EX", 1, recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new HookrToken("Example", "EX", 1, address(0));
    }
}
