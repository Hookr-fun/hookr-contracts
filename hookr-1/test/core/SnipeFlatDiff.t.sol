// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {RulesData} from "../utils/RulesData.sol";

/// @notice Digest of every Rules quote, quoter receipt, trader output and claim for flat-Snipe pools: a pool
///         with a Snipe tax and no decay quotes, settles and claims exactly as FLAT_DIGEST records. Pinned so a change
///         to any of those paths shows up as a changed digest. Each dynamic fee config takes at most the widest span
///         the reach bound admits at its sensitivity and share.
/// @dev The digest mixes in every refusal's revert data. Since r31 a module call that reverts with data reads as
///      ModuleCallReverted with the Rules' own reason (InvalidConfig, GuardBuyLimit). With that error encoded as the
///      reasonless ModuleCallFailed again, these sources give these configs' digest on r31-final, which has neither
///      the reach bound nor the reason, 0x90037e3135f54a4296f4c20d43c9c98427db60023f83bc1390a7b7177caabeb1, so the
///      bound and the reason change nothing else.
contract SnipeFlatDiffTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant FLAT_DIGEST = 0x9d45b8f951564fa7178bc7f2623f9aabdedb8b1d78c49a1bfae104f9e2d0b1bf;

    bytes32 internal digest;

    function setUp() public {
        _setUpPeriphery();
    }

    function _cfg(uint256 i) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(Currency.wrap(address(0)));
        int24[13] memory spacings = [int24(200), 240, 300, 400, 500, 600, 750, 1000, 1200, 1500, 2000, 2400, 3000];
        m.tickSpacing = spacings[i];
        uint24[6] memory snipes = [uint24(0), 1, 250_000, 500_000, 597_000, 123_457];
        uint16[4] memory shares = [uint16(0), 2500, 5000, 3333];
        uint16[3] memory sens = [uint16(0), 5, 10];
        m.rules.snipeTaxPips = snipes[i % 6];
        m.rules.protocolShareBps = shares[i % 4];
        m.rules.dynamicFeeSens = sens[i % 3];
        m.rules.maxFeePips = m.rules.dynamicFeeSens == 0 ? 3000 : uint24(3000 + 50_000 * (i % 5 + 1));
        // At most the widest span the reach bound admits at the config's sensitivity and share.
        RulesData.clampToReach(m.rules, 3000);
        m.rules.guardEndBlock = m.rules.snipeTaxPips == 0 && i % 2 == 0 ? 0 : uint40(vm.getBlockNumber() + 5);
        m.rules.maxBuyQuoteAmount = m.rules.guardEndBlock == 0 || i % 3 != 0 ? 0 : 3e18;
        if (i % 4 == 1) {
            m.rules.burnBps = 0;
            m.rules.lpBps = 0;
            m.rules.royaltyBps = 0;
            m.rules.royaltyTo = address(0);
        }
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
    }

    function _mix(bytes memory b) internal {
        digest = keccak256(abi.encodePacked(digest, b));
    }

    function _quote(PoolKey memory key, bool buy) internal {
        IHookrRouter.Swap memory p = _swap(key, buy, true, buy ? 1e18 : 1e17);
        try quoter.quote(p, trader) returns (HookrTypes.ExecutionReceipt memory r) {
            _mix(
                abi.encode(
                    r.inputAmount, r.outputAmount, r.actualQuote, r.quoteFee, r.quoteRefund, r.subjectBurn, r.lpFeePips
                )
            );
        } catch (bytes memory reason) {
            _mix(reason);
        }
    }

    function _trade(PoolKey memory key, bool buy, uint128 amount) internal {
        uint256 a = tokenA.balanceOf(trader);
        uint256 e = trader.balance;
        uint256 c = rules.claimable(Currency.wrap(address(0)), protocol);
        uint256 r = rules.claimable(Currency.wrap(address(0)), royalty);
        vm.prank(trader);
        (bool ok, bytes memory ret) = address(router).call{value: buy ? amount : 0}(
            abi.encodeCall(HookrRouter.swap, (_swap(key, buy, true, amount), address(0), new uint256[](0)))
        );
        _mix(abi.encode(ok, ok ? bytes("") : ret));
        _mix(
            abi.encode(
                int256(tokenA.balanceOf(trader)) - int256(a),
                int256(trader.balance) - int256(e),
                rules.claimable(Currency.wrap(address(0)), protocol) - c,
                rules.claimable(Currency.wrap(address(0)), royalty) - r
            )
        );
    }

    function _count(PoolKey[13] memory keys) internal pure returns (uint256 n) {
        for (uint256 i; i < 13; ++i) {
            if (keys[i].tickSpacing != 0) ++n;
        }
    }

    function testFlatSnipeDigest() public {
        uint256 t0 = vm.getBlockTimestamp();
        PoolKey[13] memory keys;
        for (uint256 i; i < 13; ++i) {
            IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
            members[0] = _cfg(i);
            try launcher.launch{value: 1e24}(
                IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
                address(root),
                members,
                vm.getBlockTimestamp()
            ) returns (
                bytes32 family, address
            ) {
                keys[i] = launcher.position(family, 0).key;
                _mix(abi.encode(i, true));
            } catch (bytes memory reason) {
                _mix(abi.encode(i, reason));
            }
        }
        uint256[6] memory times = [uint256(0), 1, 13, 120, 3600, 7 days];
        for (uint256 s; s < times.length; ++s) {
            vm.warp(t0 + times[s]);
            // Blocks 0..6 after launch cross every pool's guard end (5 blocks).
            vm.roll(vm.getBlockNumber() + (s == 0 ? 0 : 1));
            for (uint256 i; i < 13; ++i) {
                if (keys[i].tickSpacing == 0) continue;
                _quote(keys[i], true);
                _quote(keys[i], false);
                _trade(keys[i], true, 1e18);
                _trade(keys[i], true, 2e18);
                _trade(keys[i], false, 1e17);
            }
        }
        console.log("launched", _count(keys));
        console.logBytes32(digest);
        assertEq(_count(keys), 12, "one config is refused");
        assertEq(digest, FLAT_DIGEST, "flat Snipe unchanged");
    }
}
