// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";

/// @dev Sell honeypot: only allowlisted senders may transfer into the PoolManager.
contract SellHoneypot is ERC20 {
    address public immutable manager;
    mapping(address => bool) public allowed;

    constructor(address m, address creator) ERC20("Honey", "HNY") {
        manager = m;
        allowed[creator] = true;
        _mint(creator, 1e30);
    }

    function allow(address a) external {
        allowed[a] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == manager && !allowed[from]) revert("honeypot");
        super._update(from, to, value);
    }
}

/// @notice I-08, documented behaviour. Original PoC (B13Verify testC2, unfixed source): a selective sell-honeypot
/// subject launched (only token.existing.code.length is checked), a trader bought 946.56 HNY through the router and
/// could not sell it back. The existing-token lane stays permissionless on-chain by design; protection is asset
/// qualification in the app and SDK, now stated in the Launcher NatSpec and README. Pinned here: the one-way
/// honeypot still launches (so any change is deliberate), the Launcher's exact-balance funding still rejects
/// fee-on-transfer subjects at launch, and nothing the subject does blocks the LP's own exit.
contract HookrLauncherHoneypotSubjectTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testHoneypotLaunchesOneWayAndIsQualificationScope() public {
        SellHoneypot h = new SellHoneypot(address(manager), address(this));
        h.allow(address(launcher));
        h.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(h), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
        PoolKey memory k = launcher.position(family, 0).key;
        IHookrRouter.Swap memory buy = _swap(k, true, true, 1e21);
        vm.startPrank(trader);
        h.approve(address(router), type(uint256).max);
        router.swap(buy, address(0), new uint256[](0));
        vm.stopPrank();
        uint256 bal = h.balanceOf(trader);
        assertGt(bal, 0);
        IHookrRouter.Swap memory sell = _swap(k, false, true, uint128(bal / 2));
        vm.prank(trader);
        vm.expectRevert();
        router.swap(sell, address(0), new uint256[](0));
        // The LP exit is paid by the PoolManager straight to the owner.
        uint128 liq = launcher.position(family, 0).liquidity;
        launcher.withdraw(family, 0, liq, 0, 0, address(this), block.timestamp);
        assertEq(launcher.position(family, 0).liquidity, 0);
    }

    function testFeeOnTransferSubjectIsRejectedAtLaunch() public {
        // Charges 1% on every transfer, paid to 0xFEE.
        MockFeeOnTransferToken t = new MockFeeOnTransferToken("Tax", "TAX", 1e30, 100, address(0xFEE));
        t.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch(
            IHookrLauncher.Token(address(t), "", "", 0, bytes32(0)), address(root), members, block.timestamp
        );
    }
}
