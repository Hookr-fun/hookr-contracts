// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice Collecting what the Rules owe in ETH. A pool quoted in ETH with LP Rewards and a creator royalty accrues
///         ETH to the royalty's recipient on every buy; the recipient takes it with one call to the Rules, which burns
///         the ERC-6909 claim the Rules hold at the PoolManager and takes the ETH out.
contract ClaimTest is Pools {
    address internal royaltyTo = makeAddr("royalty recipient");

    /// @notice The royalty recipient's claim, after two buys.
    function test_claimEth() public {
        BenchToken token = _newToken();
        IHookrLauncher.Member memory m = _member(RULES);
        m.quote = Currency.wrap(address(0));
        m.liquidity = 1e21;
        m.amount0Max = 2_000 ether;
        m.rules.lpBps = 100;
        m.rules.royaltyBps = 1_000;
        m.rules.royaltyTo = royaltyTo;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        vm.deal(address(this), 2_000 ether);
        (bytes32 family,) = LAUNCHER.launch{value: 2_000 ether}(
            IHookrLauncher.Token(address(token), "", "", 0, bytes32(0)), ROOT, members, vm.getBlockTimestamp() + 3600
        );
        PoolKey memory key = LAUNCHER.position(family, 0).key;
        _nextBlock();
        _swapUniversal(ROUTER_CURATED, trader, key, true, 1 ether);
        _nextBlock();
        _swapUniversal(ROUTER_CURATED, trader, key, true, 1 ether);

        Currency eth = Currency.wrap(address(0));
        require(IHookrRules(RULES).claimable(eth, royaltyTo) != 0, "nothing accrued");
        vm.prank(royaltyTo, royaltyTo);
        IHookrRules(RULES).claim(eth);
        _record(
            Figure({
                id: "claim.eth",
                piece: "claim",
                label: "Claim ETH from the Rules (what a royalty recipient takes)",
                action: "claim",
                gas: _lastCallGas(),
                baseline: ABSOLUTE,
                router: DIRECT,
                test: "bench/test/Claim.t.sol:test_claimEth"
            })
        );
    }
}
