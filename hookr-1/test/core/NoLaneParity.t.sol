// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";

/// @notice Outcome parity for pools without a recapture lane: the same launches and swaps as on the release commit
///         b515830 (HookrRoot before the lane), with every amount in and out, every Rules claim, every burn and every
///         pool's final price, tick and liquidity folded into one digest. The digest below was recorded by running this
///         file unchanged on b515830; a pool without a lane must reproduce it to the wei. The source uses only what both
///         commits share (the launcher member without the recapture block), so it runs on either.
contract NoLaneParityTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @dev Recorded on b515830 (`forge test --match-path test/core/NoLaneParity.t.sol -vv` there).
    bytes32 internal constant B515830_DIGEST = 0xab9c1c5fa284c5c6f8f8f5028e9304113af18e360bfe8703b2b67298023afcbc;
    address internal constant DEAD = address(0xdead);

    bytes32 internal digest;
    uint256 internal count;

    function setUp() public {
        _setUpPeriphery();
    }

    function _fold(string memory label, uint256 value) internal {
        digest = keccak256(abi.encode(digest, value));
        count++;
        emit log_named_uint(label, value);
    }

    function _subject() internal returns (HookrToken t) {
        t = new HookrToken("P", "P", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        t.transfer(trader, 1e27);
        vm.prank(trader);
        t.approve(address(router), type(uint256).max);
    }

    function _open(HookrToken subject, IHookrLauncher.Member memory m) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = m;
        (bytes32 family,) = launcher.launch{value: m.quote.isAddressZero() ? 1e24 : 0}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _trade(PoolKey memory key, bool buy, bool exactInput, uint128 amount, string memory label) internal {
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        Currency quote = root.poolConfig(key.toId()).quote;
        uint256 value = buy && quote.isAddressZero() ? (exactInput ? amount : p.amountBound) : 0;
        vm.prank(trader);
        (uint256 amountIn, uint256 amountOut) = router.swap{value: value}(p, address(0), new uint256[](0));
        _fold(string.concat(label, ".in"), amountIn);
        _fold(string.concat(label, ".out"), amountOut);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 7);
    }

    function _close(PoolKey memory key, HookrToken subject, string memory label) internal {
        Currency quote = root.poolConfig(key.toId()).quote;
        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(key.toId());
        _fold(string.concat(label, ".sqrtPrice"), sqrtPrice);
        _fold(string.concat(label, ".tick"), uint256(int256(tick) + (1 << 32)));
        _fold(string.concat(label, ".liquidity"), manager.getLiquidity(key.toId()));
        _fold(string.concat(label, ".protocol"), rules.claimable(quote, protocol));
        _fold(string.concat(label, ".royalty"), rules.claimable(quote, royalty));
        _fold(string.concat(label, ".trader"), rules.claimable(quote, trader));
        _fold(string.concat(label, ".burned"), subject.balanceOf(DEAD));
        _fold(string.concat(label, ".feeOnlyFrom"), root.feeOnlyFrom(key.toId()));
    }

    function _run(PoolKey memory key, HookrToken subject, bool guarded, string memory label) internal {
        _trade(key, true, true, 1e20, string.concat(label, ".buyIn"));
        _trade(key, false, true, 5e19, string.concat(label, ".sellIn"));
        if (!guarded) _trade(key, true, false, 1e19, string.concat(label, ".buyOut"));
        _trade(key, false, false, 1e19, string.concat(label, ".sellOut"));
        _trade(key, true, true, 3e21, string.concat(label, ".bigBuy"));
        _trade(key, false, true, 2e21, string.concat(label, ".bigSell"));
        _close(key, subject, label);
    }

    function test_noLanePoolsMatchTheReleaseToTheWei() public {
        // Fee-only after launch: base fee and protocol share only.
        HookrToken s1 = _subject();
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        m.rules.burnBps = 0;
        m.rules.lpBps = 0;
        m.rules.royaltyBps = 0;
        m.rules.royaltyTo = address(0);
        _run(_open(s1, m), s1, false, "feeOnly");
        // Every rule without dynamic fees, on an ERC-20 quote.
        HookrToken s2 = _subject();
        _run(_open(s2, _member(Currency.wrap(address(tokenB)))), s2, false, "full");
        // Hookr dynamic fees with Auto Burn and LP Rewards.
        HookrToken s3 = _subject();
        m = _member(Currency.wrap(address(0)));
        m.rules.maxFeePips = 50_000;
        m.rules.dynamicFeeSens = 5;
        _run(_open(s3, m), s3, false, "dynamic");
        // Anti-Snipe: a decaying tax with a per-block cap.
        HookrToken s4 = _subject();
        m = _member(Currency.wrap(address(0)));
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 1_000);
        m.rules.snipeTaxPips = 300_000;
        m.rules.snipeFloorPips = 10_000;
        m.rules.snipeDecaySeconds = 600;
        m.rules.maxBuyQuoteAmount = 1e22;
        _run(_open(s4, m), s4, true, "guarded");
        emit log_named_uint("values", count);
        emit log_named_bytes32("digest", digest);
        assertEq(digest, B515830_DIGEST, "a pool without a lane must reproduce b515830's outcomes");
    }
}
