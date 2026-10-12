// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {QuoteClassesForkFixture} from "../core/QuoteClassesFork.t.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

interface QuoteGateway {
    function finalizeInboundTransfer(address token, address from, address to, uint256 amount, bytes calldata data)
        external
        payable;
    function calculateL2TokenAddress(address l1Token) external view returns (address);
    function counterpartGateway() external view returns (address);
}

interface QuoteL1Router {
    function outboundTransfer(
        address token,
        address to,
        uint256 amount,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes calldata data
    ) external payable returns (bytes memory);
    function getGateway(address token) external view returns (address);
}

interface QuoteMeta {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function l1Address() external view returns (address);
}

interface QuoteStock {
    function initialize(bytes32 uid, string calldata name, string calldata symbol) external;
    function uid() external view returns (bytes32);
    function mint(address to, uint256 amount) external;
}

/// @dev An ordinary L1 ERC-20 anyone can deploy, carrying any name, symbol and decimals.
contract QuoteL1Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d, uint256 supply) {
        (name, symbol, decimals) = (n, s, d);
        balanceOf[msg.sender] = supply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Q-02: quote look-alikes on a 4663 fork. The chain's standard bridge gateway deploys a token for any L1
///         ERC-20 anyone deposits, all with one runtime, so no bridged token is reviewed by its code: the reviewed
///         bridged tokens are catalog entries by address, and every other bridged token is an any-quote mode quote,
///         badged UNREVIEWED and stopped by `dismissAnyQuoteNow`. A copy of the stock class's runtime initialized with
///         a real stock's uid, name and symbol has no supply, so it is no class member.
contract QuoteLookAlikesTest is QuoteClassesForkFixture {
    address internal constant L1_ROUTER = 0x6a2E3a1e16FC29f27Ce61429746D558d656975bB;
    address internal constant L1_INBOX = 0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D;
    bytes32 internal constant INBOX_MESSAGE_DELIVERED = keccak256("InboxMessageDelivered(uint256,bytes)");
    address internal attacker = address(0xA77AC4);

    function _alias(address l1) internal pure returns (address a) {
        unchecked {
            a = address(uint160(l1) + uint160(0x1111000000000000000000000000000000001111));
        }
    }

    /// @dev The L2 leg of a standard-gateway deposit: the call the chain's retryable makes from the aliased L1
    ///      gateway, with the gateway data the L1 gateway builds.
    function _deliver(address l1Token, string memory n, string memory s, uint8 d, uint256 amount) internal {
        bytes memory gatewayData = abi.encode(abi.encode(n), abi.encode(s), abi.encode(d));
        QuoteGateway gw = QuoteGateway(BRIDGE_GATEWAY);
        vm.prank(_alias(gw.counterpartGateway()));
        gw.finalizeInboundTransfer(l1Token, attacker, attacker, amount, abi.encode(gatewayData, bytes("")));
    }

    function launchOnExternal(address quote) external {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _forkMember(quote);
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    /// A wstETH look-alike bridged by anyone carries wstETH's name, symbol, decimals, runtime and beacon. It is an
    /// UNREVIEWED quote while any-quote mode is on, never CLASS, and the open-quote brake stops it while the real
    /// wstETH, a catalog entry, stays a quote.
    function test_bridgedLookAlikeIsUnreviewedAndStopsWithOpenQuotes() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _admitGenesis();
        address l1Fake = address(uint160(uint256(keccak256("any L1 token anyone deploys"))));
        address fake = QuoteGateway(BRIDGE_GATEWAY).calculateL2TokenAddress(l1Fake);
        _deliver(l1Fake, QuoteMeta(WSTETH).name(), QuoteMeta(WSTETH).symbol(), QuoteMeta(WSTETH).decimals(), 1e30);
        assertEq(fake.codehash, BRIDGED_CLASS, "same runtime as every bridged token");
        assertEq(address(uint160(uint256(vm.load(fake, BEACON_SLOT)))), BRIDGED_BEACON, "same beacon");
        assertEq(keccak256(bytes(QuoteMeta(fake).symbol())), keccak256(bytes(QuoteMeta(WSTETH).symbol())));
        assertEq(IERC20(fake).balanceOf(attacker), 1e30);

        // Open quotes admit it as the live launchpad would, but only as UNREVIEWED; wstETH is reviewed by address.
        assertTrue(registry.isQuote(fake));
        assertEq(uint8(registry.badgeForQuote(fake)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        assertEq(uint8(registry.badgeForQuote(WSTETH)), uint8(IHookrRegistry.QuoteBadge.CATALOG));

        // The open-quote brake stops the look-alike and leaves wstETH and the other reviewed bridged tokens.
        registry.dismissAnyQuoteNow();
        assertFalse(registry.isQuote(fake));
        assertEq(uint8(registry.badgeForQuote(fake)), uint8(IHookrRegistry.QuoteBadge.NONE));
        _fund(fake, address(this), FUNDS);
        IERC20(fake).approve(address(launcher), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, fake));
        this.launchOnExternal(fake);
        address[4] memory reviewed = [WSTETH, USDC, USDT, UNI];
        for (uint256 i; i < reviewed.length; ++i) {
            assertTrue(registry.isQuote(reviewed[i]));
            assertEq(uint8(registry.badgeForQuote(reviewed[i])), uint8(IHookrRegistry.QuoteBadge.CATALOG));
        }
        _fund(WSTETH, address(this), FUNDS);
        IERC20(WSTETH).approve(address(launcher), type(uint256).max);
        this.launchOnExternal(WSTETH);
    }

    /// The same end to end: an ERC-20 deployed on an Ethereum fork is deposited through the chain's real L1 router,
    /// and the retryable it records, replayed on the 4663 fork, deploys a token that the open-quote brake stops.
    /// A manual run: needs ETH_POC_RPC (an Ethereum mainnet endpoint), read from the environment, which no CI job sets;
    /// skipped without it.
    function test_endToEndFromAnEthereumDeposit() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        string memory l1Rpc = vm.envOr("ETH_POC_RPC", string(""));
        if (bytes(l1Rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 l2Fork = vm.activeFork();
        (string memory n, string memory s, uint8 d) =
            (QuoteMeta(WSTETH).name(), QuoteMeta(WSTETH).symbol(), QuoteMeta(WSTETH).decimals());

        vm.createSelectFork(l1Rpc);
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker, attacker);
        QuoteL1Token t = new QuoteL1Token(n, s, d, 1e30);
        address gw = QuoteL1Router(L1_ROUTER).getGateway(address(t));
        t.approve(gw, type(uint256).max);
        vm.recordLogs();
        QuoteL1Router(L1_ROUTER).outboundTransfer{value: 0.02 ether}(
            address(t), attacker, 1e24, 1_000_000, 1 gwei, abi.encode(uint256(0.01 ether), bytes(""))
        );
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory message;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == L1_INBOX && logs[i].topics[0] == INBOX_MESSAGE_DELIVERED) {
                message = abi.decode(logs[i].data, (bytes));
            }
        }
        assertGt(message.length, 9 * 32, "retryable recorded");
        // Retryable layout: to, l2CallValue, deposit, maxSubmissionCost, excessFeeRefund, callValueRefund, gasLimit,
        // maxFeePerGas, dataLength, data.
        address to;
        uint256 dataLength;
        assembly {
            to := mload(add(message, 0x20))
            dataLength := mload(add(message, 0x120))
        }
        bytes memory l2Call = new bytes(dataLength);
        for (uint256 i; i < dataLength; ++i) {
            l2Call[i] = message[9 * 32 + i];
        }
        assertEq(to, BRIDGE_GATEWAY, "the retryable targets the L2 standard gateway");

        vm.selectFork(l2Fork);
        _admitGenesis();
        address fake = QuoteGateway(BRIDGE_GATEWAY).calculateL2TokenAddress(address(t));
        vm.prank(_alias(gw));
        (bool ok,) = BRIDGE_GATEWAY.call(l2Call);
        assertTrue(ok, "retryable executes");
        assertEq(IERC20(fake).balanceOf(attacker), 1e24);
        assertEq(uint8(registry.badgeForQuote(fake)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        registry.dismissAnyQuoteNow();
        assertFalse(registry.isQuote(fake));
        assertEq(uint8(registry.badgeForQuote(fake)), uint8(IHookrRegistry.QuoteBadge.NONE));
    }

    /// A copy of AAPL's exact runtime (the beacon is an immutable, so it delegates to the Robinhood beacon) can be
    /// initialized with AAPL's own uid, name and symbol, but only the issuer can mint it: with no supply it is no
    /// class member, so it never carries the CLASS badge. In any-quote mode it is UNREVIEWED, like any contract.
    function test_stockLookAlikeWithoutSupplyIsNoClassMember() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        _admitGenesis();
        bytes memory runtime = AAPL.code;
        bytes memory init = abi.encodePacked(hex"61", uint16(runtime.length), hex"80600c6000396000f3", runtime);
        address copy;
        vm.prank(attacker);
        assembly {
            copy := create(0, add(init, 0x20), mload(init))
        }
        assertTrue(copy != address(0));
        assertEq(copy.codehash, STOCK_CLASS);
        vm.prank(attacker);
        QuoteStock(copy).initialize(QuoteStock(AAPL).uid(), QuoteMeta(AAPL).name(), QuoteMeta(AAPL).symbol());
        assertEq(QuoteStock(copy).uid(), QuoteStock(AAPL).uid());
        assertEq(keccak256(bytes(QuoteMeta(copy).symbol())), keccak256(bytes(QuoteMeta(AAPL).symbol())));
        assertEq(QuoteMeta(copy).totalSupply(), 0);
        vm.prank(attacker);
        vm.expectRevert();
        QuoteStock(copy).mint(attacker, 1);

        assertEq(uint8(registry.badgeForQuote(copy)), uint8(IHookrRegistry.QuoteBadge.UNREVIEWED));
        assertEq(uint8(registry.badgeForQuote(AAPL)), uint8(IHookrRegistry.QuoteBadge.CLASS));
        registry.dismissAnyQuoteNow();
        assertFalse(registry.isQuote(copy));
        assertEq(uint8(registry.badgeForQuote(copy)), uint8(IHookrRegistry.QuoteBadge.NONE));
        assertTrue(registry.isQuote(AAPL) && registry.isQuote(NVDA));
    }
}
