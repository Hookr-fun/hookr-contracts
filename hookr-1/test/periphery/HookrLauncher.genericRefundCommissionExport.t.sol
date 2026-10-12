// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {ServiceEventExport} from "../utils/ServiceEventExport.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @dev Any PoolManager caller. Empty hookData, so HookrRoot treats it as the unauthenticated payer.
contract GenericPartialFillBuyer is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function buy(PoolKey calldata key, int256 amountSpecified, uint160 limit) external payable {
        manager.unlock(abi.encode(key, amountSpecified, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, int256 amountSpecified, uint160 limit) = abi.decode(data, (PoolKey, int256, uint160));
        BalanceDelta delta = manager.swap(key, SwapParams(true, amountSpecified, limit), "");
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) {
            manager.sync(key.currency0);
            manager.settle{value: uint256(uint128(-a0))}();
        }
        if (a1 > 0) manager.take(key.currency1, address(this), uint256(uint128(a1)));
        return "";
    }

    receive() external payable {}
}

/// @notice M-06 regression, chain half. One partial-fill refund credited to a generic PoolManager caller and then
///         claimed made the commission service's feeLots throw for every campaign, day and fee source, and any
///         unattributed refund blocked royalty campaigns for the whole Rules/currency.
/// @dev Original numbers (unfixed service, b7aeae64): refund 22,499,999,769,128,357 wei credited and claimed back,
///      net attack cost 10,260,961,925 wei plus gas; feeLots then threw "Collection exceeds indexed liabilities"
///      permanently. Since the L-09 fix (OD-7) the generic-caller refund reverts UnauthenticatedRefund, so this test
///      asserts that and exports a curated-Router partial-fill refund credited to and claimed by the payer instead.
contract HookrLauncherGenericRefundCommissionExportTest is ServiceEventExport {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal attacker = address(0xA77A);

    function setUp() public {
        _setUpPeriphery();
        vm.deal(attacker, 1_000 ether);
    }

    function testExportGenericRefundClaim() public {
        _begin();
        (bytes32 victimFamily, PoolKey memory victim,,) = _launch(true, true);
        _capture(address(this));

        _begin();
        IHookrRouter.Swap memory buy = _swap(victim, true, true, 1 ether);
        vm.prank(trader, trader);
        router.swap{value: 1 ether}(buy, address(0), new uint256[](0));
        _capture(trader);

        _begin();
        uint256 royaltyOwed = rules.claimable(Currency.wrap(address(0)), royalty);
        vm.prank(royalty, royalty);
        rules.claim(Currency.wrap(address(0)));
        _capture(royalty);
        assertGt(royaltyOwed, 0, "victim royalty claimed");

        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].liquidity = 1e19;
        members[0].amount0Max = 20 ether;
        members[0].amount1Max = 20 ether;
        members[0].rules.royaltyTo = attacker;
        _begin();
        vm.prank(attacker, attacker);
        (bytes32 family,) = launcher.launch{value: 20 ether}(
            IHookrLauncher.Token(address(0), "Atk", "ATK", 1e27, bytes32(uint256(7))),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        _capture(attacker);
        PoolKey memory own = launcher.position(family, 0).key;

        GenericPartialFillBuyer buyer = new GenericPartialFillBuyer(manager);
        (uint160 sqrtP,,,) = manager.getSlot0(own.toId());
        uint160 limit = sqrtP - sqrtP / 1e9;
        // L-09 (OD-7): the generic-caller refund this vector was built on no longer exists. An unauthenticated partial
        // fill that would credit a refund to the PoolManager caller now reverts UnauthenticatedRefund in afterSwap.
        vm.prank(attacker, attacker);
        try buyer.buy{value: 1 ether}(own, -1 ether, limit) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), CustomRevert.WrappedError.selector);
            assertEq(_wrappedReasonSelector(err), IHookrRootState.UnauthenticatedRefund.selector);
        }
        assertEq(rules.claimable(Currency.wrap(address(0)), address(buyer)), 0, "no generic-caller refund");

        // The refund path that remains is the curated Router's: the same partial fill credits the authenticated payer,
        // which the service must still attribute and reconcile when it is claimed.
        uint256 before = rules.claimable(Currency.wrap(address(0)), attacker);
        _begin();
        IHookrRouter.Swap memory partialBuy = _swap(own, true, true, 1 ether);
        partialBuy.sqrtPriceLimitX96 = limit;
        partialBuy.recipient = attacker;
        vm.prank(attacker, attacker);
        router.swap{value: 1 ether}(partialBuy, address(0), new uint256[](0));
        _capture(attacker);
        uint256 refund = rules.claimable(Currency.wrap(address(0)), attacker) - before;
        assertGt(refund, 0, "curated partial-fill refund credited to the payer");

        _begin();
        vm.prank(attacker, attacker);
        uint256 claimed = rules.claim(Currency.wrap(address(0)));
        _capture(attacker);
        assertEq(claimed, before + refund, "payer claimed its refund");

        _begin();
        buy = _swap(victim, true, true, 1 ether);
        vm.prank(trader, trader);
        router.swap{value: 1 ether}(buy, address(0), new uint256[](0));
        _capture(trader);

        _begin();
        vm.prank(royalty, royalty);
        rules.claim(Currency.wrap(address(0)));
        _capture(royalty);

        emit log_named_string(
            "M06_VECTOR_GENERIC_REFUND_CLAIM",
            _vector(
                string.concat(
                    '"poolId":"',
                    vm.toString(PoolId.unwrap(victim.toId())),
                    '","familyId":"',
                    vm.toString(victimFamily),
                    '","attackPool":"',
                    vm.toString(PoolId.unwrap(own.toId())),
                    '","buyer":"',
                    vm.toString(attacker),
                    '","royaltyTo":"',
                    vm.toString(royalty),
                    '","attacker":"',
                    vm.toString(attacker),
                    '","trader":"',
                    vm.toString(trader),
                    '","refund":"',
                    vm.toString(refund),
                    '",'
                )
            )
        );
    }

    /// @dev WrappedError(address target, bytes4 selector, bytes reason, bytes details): returns reason's selector.
    function _wrappedReasonSelector(bytes memory err) internal pure returns (bytes4) {
        bytes32 w;
        assembly {
            let args := add(err, 36)
            let reasonOffset := mload(add(args, 64))
            w := mload(add(add(args, reasonOffset), 32))
        }
        return bytes4(w);
    }
}
