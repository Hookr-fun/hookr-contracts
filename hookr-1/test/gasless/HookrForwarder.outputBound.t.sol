// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {GaslessToken, MockRegistry, MockRoot, MockPermit2, MockRouter} from "./GaslessMocks.sol";

/// @dev Code a compromised deployer could place at the predicted HookrRouter address: it takes the forwarder's
///      allowance and reports a fill, delivering `deliver` of the output to `payee`.
contract SquatRouter {
    address internal immutable thief;
    uint256 public deliver;
    address public payee;

    constructor(address thief_) {
        thief = thief_;
    }

    function set(uint256 deliver_, address payee_) external {
        deliver = deliver_;
        payee = payee_;
    }

    function swapFor(IHookrRouter.Swap calldata p, address, uint256, address, address, uint256[] calldata)
        external
        returns (uint256, uint256)
    {
        address input = Currency.unwrap(p.zeroForOne ? p.key.currency0 : p.key.currency1);
        address output = Currency.unwrap(p.zeroForOne ? p.key.currency1 : p.key.currency0);
        uint256 a = GaslessToken(input).allowance(msg.sender, address(this));
        GaslessToken(input).transferFrom(msg.sender, thief, a);
        if (deliver != 0) {
            if (output == address(0)) payable(payee).transfer(deliver);
            else GaslessToken(output).mint(payee, deliver);
        }
        return (a, type(uint128).max);
    }

    receive() external payable {}
}

/// @dev Code at the router address that lends: it keeps the whole input, pays the recipient `deliver` of the output
///      from its own balance and reports a fill; `reclaim` takes the loan back through an allowance the recipient gave
///      this address.
contract LendingSquatRouter {
    uint256 public deliver;

    function set(uint256 deliver_) external {
        deliver = deliver_;
    }

    function swapFor(IHookrRouter.Swap calldata p, address, uint256, address, address, uint256[] calldata)
        external
        returns (uint256, uint256)
    {
        address input = Currency.unwrap(p.zeroForOne ? p.key.currency0 : p.key.currency1);
        address output = Currency.unwrap(p.zeroForOne ? p.key.currency1 : p.key.currency0);
        uint256 a = GaslessToken(input).allowance(msg.sender, address(this));
        GaslessToken(input).transferFrom(msg.sender, address(this), a);
        GaslessToken(output).transfer(p.recipient, deliver);
        return (a, deliver);
    }

    function reclaim(address token, address from, uint256 amount) external {
        GaslessToken(token).transferFrom(from, address(this), amount);
    }
}

/// @dev Submits a fee-free intent anyone may relay and reclaims the loan in the same transaction, so the lender's
///      balance is never at risk.
contract LendAndReclaim {
    function run(
        HookrForwarder fwd,
        LendingSquatRouter squat,
        IHookrForwarder.HookrSwapIntent calldata i,
        address owner,
        address output,
        uint256 amount
    ) external {
        fwd.execute(i, owner, "");
        squat.reclaim(output, i.recipient, amount);
    }
}

/// @notice F-009 (code part): the Forwarder approved `maxIn` to whatever code sits at its immutable router address
///         and trusted the returned fill, so code squatted there (deployer key or its EIP-7702 delegate on a chain
///         not yet deployed) took each relayed intent's signed input and delivered nothing. The Forwarder now reads
///         the recipient's balance of the output around the swap and reverts `OutputShort` unless it rose by the
///         signed bound: the net minimum on exact input, the exact output less an output-side relayer fee on exact
///         output. A relayer fee above an exact output is refused up front (`InvalidIntent(7)`).
contract HookrForwarderOutputBoundTest is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant OWNER = address(0xA11CE);
    address constant RELAYER = address(0xFEE);
    address constant RECIPIENT = address(0x1002);
    address constant THIEF = address(0x7715);

    MockRegistry registry = new MockRegistry();
    MockRoot root = new MockRoot();
    GaslessToken t0 = new GaslessToken();
    GaslessToken t1 = new GaslessToken();

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2()).code);
        registry.set(address(root));
    }

    function _intent(Currency c0, Currency c1, bool zeroForOne, int128 amount, uint128 bound_, uint256 fee)
        internal
        view
        returns (IHookrForwarder.HookrSwapIntent memory i)
    {
        i.key = PoolKey(c0, c1, 0x800000, 60, IHooks(address(root)));
        i.zeroForOne = zeroForOne;
        i.amountSpecified = amount;
        i.amountBound = bound_;
        i.recipient = RECIPIENT;
        i.relayer = RELAYER;
        i.relayerFee = fee;
        i.nonce = 1;
        i.deadline = block.timestamp + 60;
    }

    function _sorted() internal view returns (Currency, Currency) {
        return address(t0) < address(t1)
            ? (Currency.wrap(address(t0)), Currency.wrap(address(t1)))
            : (Currency.wrap(address(t1)), Currency.wrap(address(t0)));
    }

    function _fundOwner(Currency input, uint256 amount) internal {
        GaslessToken(Currency.unwrap(input)).mint(OWNER, amount);
        vm.prank(OWNER);
        GaslessToken(Currency.unwrap(input)).approve(PERMIT2, type(uint256).max);
    }

    /// @notice The funnel from the audit's PoC: a squatted router takes the signed input and reports a fill. It now
    ///         reverts and the owner keeps its balance.
    function test_squattedRouterCannotKeepTheInput() public {
        SquatRouter squat = new SquatRouter(THIEF);
        HookrForwarder fwd = new HookrForwarder(PERMIT2, address(registry), address(squat));
        (Currency c0, Currency c1) = _sorted();
        IHookrForwarder.HookrSwapIntent memory i = _intent(c0, c1, true, -1000, 1, 10);
        root.setQuote(c0);
        _fundOwner(c0, 5000);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputShort.selector, Currency.unwrap(c1), 1, 0));
        fwd.execute(i, OWNER, "");
        assertEq(GaslessToken(Currency.unwrap(c0)).balanceOf(OWNER), 5000);
        assertEq(GaslessToken(Currency.unwrap(c0)).balanceOf(THIEF), 0);

        // Output delivered to anyone but the recipient does not count.
        squat.set(1_000_000, RELAYER);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputShort.selector, Currency.unwrap(c1), 1, 0));
        fwd.execute(i, OWNER, "");
    }

    /// @notice Exact input: the recipient must net at least amountBound; one unit short reverts.
    function test_exactInputBoundIsEnforcedAtTheUnit() public {
        MockRouter router = new MockRouter();
        HookrForwarder fwd = new HookrForwarder(PERMIT2, address(registry), address(router));
        (Currency c0, Currency c1) = _sorted();
        IHookrForwarder.HookrSwapIntent memory i = _intent(c0, c1, true, -1000, 700, 10);
        root.setQuote(c0);
        _fundOwner(c0, 5000);
        router.set(1000, 699);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputShort.selector, Currency.unwrap(c1), 700, 699));
        fwd.execute(i, OWNER, "");
        router.set(1000, 700);
        vm.prank(RELAYER);
        (uint256 amountIn, uint256 amountOut) = fwd.execute(i, OWNER, "");
        assertEq(amountIn, 1000);
        assertEq(amountOut, 700);
        assertEq(GaslessToken(Currency.unwrap(c1)).balanceOf(RECIPIENT), 700);
    }

    /// @notice Exact output with an output-side relayer fee: the recipient must get the exact output less the fee.
    ///         A fee above the exact output is refused before any pull.
    function test_exactOutputBoundNetOfOutputFee() public {
        MockRouter router = new MockRouter();
        HookrForwarder fwd = new HookrForwarder(PERMIT2, address(registry), address(router));
        (Currency c0, Currency c1) = _sorted();
        IHookrForwarder.HookrSwapIntent memory i = _intent(c0, c1, true, 500, 1000, 20);
        root.setQuote(c1); // output is the quote: a sell, fee from output
        _fundOwner(c0, 1000);
        router.set(700, 499);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputShort.selector, Currency.unwrap(c1), 480, 479));
        fwd.execute(i, OWNER, "");
        router.set(700, 500);
        vm.prank(RELAYER);
        fwd.execute(i, OWNER, "");
        assertEq(GaslessToken(Currency.unwrap(c1)).balanceOf(RECIPIENT), 480);
        assertEq(GaslessToken(Currency.unwrap(c1)).balanceOf(RELAYER), 20);

        i.nonce = 2;
        i.relayerFee = 501;
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.InvalidIntent.selector, 7));
        fwd.execute(i, OWNER, "");
    }

    /// @notice Native output is measured on the recipient's ETH balance.
    function test_nativeOutputIsMeasured() public {
        SquatRouter router = new SquatRouter(THIEF);
        vm.deal(address(router), 1 ether);
        HookrForwarder fwd = new HookrForwarder(PERMIT2, address(registry), address(router));
        Currency eth = Currency.wrap(address(0));
        Currency token = Currency.wrap(address(t1));
        IHookrForwarder.HookrSwapIntent memory i = _intent(eth, token, false, -1000, 900, 0);
        i.relayer = address(0);
        root.setQuote(eth); // selling the token for ETH
        _fundOwner(token, 1000);
        router.set(899, RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(IHookrForwarder.OutputShort.selector, address(0), 900, 899));
        fwd.execute(i, OWNER, "");
        router.set(900, RECIPIENT);
        fwd.execute(i, OWNER, "");
        assertEq(RECIPIENT.balance, 900);
    }

    /// @notice Known limit, pinned: the bound is a balance delta, so code at the router address can pay it from its
    ///         own balance and take it back in the same transaction through an output-token allowance the recipient
    ///         gave the router address. Such allowances are normal, since HookrRouter pulls a direct swap's input from
    ///         its caller. The owner pays the whole signed input and nets no output. Custody of the deployer key, which
    ///         alone decides what code the router's CREATE3 address holds, is the control.
    function test_pinned_lendAndReclaimPassesGivenAnOutputAllowance() public {
        LendingSquatRouter squat = new LendingSquatRouter();
        HookrForwarder fwd = new HookrForwarder(PERMIT2, address(registry), address(squat));
        LendAndReclaim relayer = new LendAndReclaim();
        (Currency c0, Currency c1) = _sorted();
        GaslessToken input = GaslessToken(Currency.unwrap(c0));
        GaslessToken output = GaslessToken(Currency.unwrap(c1));
        IHookrForwarder.HookrSwapIntent memory i = _intent(c0, c1, true, -1000, 900, 0);
        i.recipient = OWNER;
        i.relayer = address(0);
        root.setQuote(c0);
        _fundOwner(c0, 1000);
        output.mint(address(squat), 900);
        squat.set(900);
        vm.prank(OWNER);
        output.approve(address(squat), type(uint256).max);

        relayer.run(fwd, squat, i, OWNER, address(output), 900);
        assertEq(input.balanceOf(OWNER), 0, "owner paid the whole signed input");
        assertEq(output.balanceOf(OWNER), 0, "owner netted no output");
        assertEq(input.balanceOf(address(squat)), 1000, "the code at the router address kept the input");
        assertEq(output.balanceOf(address(squat)), 900, "its loan came back");
    }

    /// @notice The same lend without that allowance: the reclaim fails, the whole transaction reverts and the owner
    ///         keeps the input.
    function test_lendWithoutOutputAllowanceCannotReclaim() public {
        LendingSquatRouter squat = new LendingSquatRouter();
        HookrForwarder fwd = new HookrForwarder(PERMIT2, address(registry), address(squat));
        LendAndReclaim relayer = new LendAndReclaim();
        (Currency c0, Currency c1) = _sorted();
        GaslessToken output = GaslessToken(Currency.unwrap(c1));
        IHookrForwarder.HookrSwapIntent memory i = _intent(c0, c1, true, -1000, 900, 0);
        i.recipient = OWNER;
        i.relayer = address(0);
        root.setQuote(c0);
        _fundOwner(c0, 1000);
        output.mint(address(squat), 900);
        squat.set(900);

        vm.expectRevert();
        relayer.run(fwd, squat, i, OWNER, address(output), 900);
        assertEq(GaslessToken(Currency.unwrap(c0)).balanceOf(OWNER), 1000);
        assertEq(output.balanceOf(OWNER), 0);
        assertEq(output.balanceOf(address(squat)), 900);
    }
}
