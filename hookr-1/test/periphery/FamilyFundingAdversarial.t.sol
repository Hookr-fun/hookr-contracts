// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

contract CrossCurrencyDonationToken is ERC20 {
    error DonationFailed();
    address private immutable _payer;
    address private _launcher;
    IERC20 private _donatedToken;
    uint256 private _donation;
    bool public armed;

    constructor() ERC20("Callback Quote", "CQ") {
        _payer = msg.sender;
        _mint(msg.sender, 1e30);
    }

    function arm(address launcher, IERC20 donatedToken, uint256 donation) external {
        _launcher = launcher;
        _donatedToken = donatedToken;
        _donation = donation;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (armed && from == _payer && to == _launcher) {
            armed = false;
            if (!_donatedToken.transfer(_launcher, _donation)) revert DonationFailed();
        }
    }
}

contract FamilyFundingAdversarialTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpPeriphery();
    }

    function testCrossCurrencyDonationCannotBecomeCallerRefund() public {
        CrossCurrencyDonationToken quote = new CrossCurrencyDonationToken();
        quote.approve(address(launcher), type(uint256).max);
        _catalogQuote(address(quote));
        tokenA.transfer(address(launcher), 13);
        quote.transfer(address(launcher), 17);
        tokenA.transfer(address(quote), 777);
        quote.arm(address(launcher), IERC20(address(tokenA)), 777);

        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(quote)));
        bool subjectFirst = address(tokenA) < address(quote);
        PoolKey memory key = PoolKey(
            Currency.wrap(subjectFirst ? address(tokenA) : address(quote)),
            Currency.wrap(subjectFirst ? address(quote) : address(tokenA)),
            0x800000,
            members[0].tickSpacing,
            IHooks(address(root))
        );
        PoolId id = key.toId();
        bytes32 expectedFamily = keccak256(abi.encode(block.chainid, address(launcher), address(this), uint256(1)));
        uint256 subjectBefore = tokenA.balanceOf(address(this));
        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 managerSubjectBefore = tokenA.balanceOf(address(manager));
        uint256 managerQuoteBefore = quote.balanceOf(address(manager));

        // Funding the quote donates subject after its opening balance and budget were recorded.
        vm.expectCall(address(tokenA), abi.encodeCall(IERC20.transfer, (address(launcher), uint256(777))));
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );

        assertEq(tokenA.balanceOf(address(this)), subjectBefore);
        assertEq(quote.balanceOf(address(this)), quoteBefore);
        assertEq(tokenA.balanceOf(address(launcher)), 13);
        assertEq(quote.balanceOf(address(launcher)), 17);
        assertEq(tokenA.balanceOf(address(quote)), 777);
        assertEq(tokenA.balanceOf(address(manager)), managerSubjectBefore);
        assertEq(quote.balanceOf(address(manager)), managerQuoteBefore);
        assertTrue(quote.armed());
        assertFalse(root.knownPool(id));
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, 0);
        assertEq(launcher.poolFamily(id), bytes32(0));
        assertEq(launcher.familyOwner(expectedFamily), address(0));
        assertEq(launcher.memberCount(expectedFamily), 0);

        // The same key and funding work once the unrelated inflow is removed.
        quote.disarm();
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        assertEq(family, expectedFamily);
        assertTrue(root.knownPool(id));
        assertEq(launcher.familyOwner(family), address(this));
        assertEq(tokenA.balanceOf(address(launcher)), 13);
        assertEq(quote.balanceOf(address(launcher)), 17);
        assertEq(tokenA.balanceOf(address(quote)), 777);
        assertLt(tokenA.balanceOf(address(this)), subjectBefore);
        assertLt(quote.balanceOf(address(this)), quoteBefore);
    }
}
