// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookrAttachHook} from "../src/HookrAttachHook.sol";
import {HookrExistingTokenFactory} from "../src/HookrExistingTokenFactory.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {V4PoolMath} from "../src/libraries/V4PoolMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice A plain well-behaved 18-decimals ERC20 — the token an attach creator actually
///         brings. Not a HookrToken on purpose: the whole point of the factory under test is
///         that the token predates Hookr and follows no Hookr convention.
contract PlainToken {
    string public name = "Existing Token";
    string public symbol = "EXIST";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address to, uint256 supply) {
        balanceOf[to] = supply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Keeps a cut of every transfer — the accounting-poison shape the factory must refuse.
contract TaxToken is PlainToken {
    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        uint256 kept = amount / 100;
        balanceOf[to] += amount - kept;
        balanceOf[address(0xdead)] += kept;
        return true;
    }
}

/// @notice USDT-shaped: transfers move balances but return nothing. v4 settlement and the
///         factory's refund path both need a decodable `true`, so attach must refuse it.
contract NoReturnToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address to, uint256 supply) {
        balanceOf[to] = supply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Moves balances but reports false — the silent-failure shape.
contract FalseToken is PlainToken {
    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return false;
    }
}

/// @notice A 6-decimals but otherwise perfectly behaved token. Every derived price and cap
///         figure would be off by 10^12, so the factory must refuse it outright.
contract SixDecimalsToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address to, uint256 supply) {
        balanceOf[to] = supply;
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
}

/// @notice Refuses transfers to DEAD while `blockDead` is set — the blocklist/pausable shape
///         that used to be able to brick fee collection for the whole pool.
contract BlockDeadToken is PlainToken {
    bool public blockDead = true;

    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function setBlockDead(bool blocked) external {
        blockDead = blocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!(blockDead && to == address(0xdEaD)), "blocked");
        return super.transfer(to, amount);
    }
}

/// @notice Tries to attach a second token from inside the first attach's transferFrom,
///         swallowing the nested revert so only the reentrancy lock separates the outcomes.
contract ReenterToken is PlainToken {
    HookrExistingTokenFactory public factory;
    PlainToken public accomplice;
    bool public nestedSucceeded;
    bool private armed;

    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function arm(HookrExistingTokenFactory factory_, PlainToken accomplice_) external {
        factory = factory_;
        accomplice = accomplice_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            accomplice.approve(address(factory), type(uint256).max);
            HookrExistingTokenFactory.AttachArgs memory a;
            a.token = address(accomplice);
            a.sqrtPriceX96 = 79228162514264337593543950336;
            a.tokenAmount = 1_000 ether;
            a.hookParams = _quiet();
            try factory.attach{value: 1 ether}(a) {
                nestedSucceeded = true;
            } catch {}
        }
        return super.transferFrom(from, to, amount);
    }

    function _quiet() private pure returns (HookrExistingTokenFactory.HookParams memory p) {
        p.baseFeePips = 3000;
    }

    receive() external payable {}
}

/// @notice Reenters `attach` from the OTHER token call inside an attach: the transfer INTO the
///         PoolManager on the CB_SEED settle path, one call deeper than `ReenterToken`'s pull-path
///         probe and made while the PoolManager unlock is still open. The nested revert data is
///         recorded so the test can assert WHICH gate refused it (the creation mutex).
contract SettleReenterToken is PlainToken {
    HookrExistingTokenFactory public factory;
    address public poolManager;
    PlainToken public accomplice;
    bool public nestedSucceeded;
    bytes4 public nestedRevertSelector;
    bool private armed;

    constructor(address to, uint256 supply) PlainToken(to, supply) {}

    function arm(HookrExistingTokenFactory factory_, address poolManager_, PlainToken accomplice_) external {
        factory = factory_;
        poolManager = poolManager_;
        accomplice = accomplice_;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && to == poolManager) {
            armed = false;
            accomplice.approve(address(factory), type(uint256).max);
            HookrExistingTokenFactory.AttachArgs memory a;
            a.token = address(accomplice);
            a.sqrtPriceX96 = 79228162514264337593543950336;
            a.tokenAmount = 1_000 ether;
            a.hookParams.baseFeePips = 3000;
            try factory.attach(a) {
                nestedSucceeded = true;
            } catch (bytes memory err) {
                if (err.length >= 4) nestedRevertSelector = bytes4(err);
            }
        }
        return super.transfer(to, amount);
    }

    receive() external payable {}
}

contract HookrExistingTokenFactoryTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 constant FULL_LOWER = -887220;
    int24 constant FULL_UPPER = 887220;
    uint256 constant BPS = 10_000;

    IPoolManager manager;
    HookrAttachHook hook;
    HookrExistingTokenFactory factory;
    HookrSwapRouter router;
    PoolModifyLiquidityTest lpRouter;
    PlainToken token;

    address creator = address(0xC0);
    address trader = address(0x22);
    address attacker = address(0xBADBAD);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));

        // The 1:1 hook<->factory binding is immutable on BOTH sides, so deployment predicts the
        // factory's CREATE address, mines the hook against it, then deploys the factory — whose
        // constructor re-checks every leg of the binding.
        address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bytes memory creation =
            abi.encodePacked(type(HookrAttachHook).creationCode, abi.encode(manager, predictedFactory));
        (address predictedHook, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrAttachHook{salt: salt}(manager, predictedFactory);
        assertEq(address(hook), predictedHook, "hook address");
        factory = new HookrExistingTokenFactory(manager, hook);
        assertEq(address(factory), predictedFactory, "factory address");

        router = new HookrSwapRouter(manager, IHooks(address(hook)), address(0));
        lpRouter = new PoolModifyLiquidityTest(manager);

        token = new PlainToken(creator, 100_000_000 ether);
        vm.deal(creator, 10_000 ether);
        vm.deal(trader, 1_000 ether);
        vm.deal(attacker, 1_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _quietParams() internal pure returns (HookrExistingTokenFactory.HookParams memory p) {
        p = HookrExistingTokenFactory.HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0
        });
    }

    function _args(address token_, uint256 tokenAmount)
        internal
        pure
        returns (HookrExistingTokenFactory.AttachArgs memory a)
    {
        a.token = token_;
        a.sqrtPriceX96 = SQRT_PRICE_1_1;
        a.tokenAmount = tokenAmount;
        a.hookParams = _quietParams();
    }

    function _twoBands() internal pure returns (HookrExistingTokenFactory.LpTranche[] memory bands) {
        bands = new HookrExistingTokenFactory.LpTranche[](2);
        bands[0] = HookrExistingTokenFactory.LpTranche({startOffset: 60, endOffset: 180, bps: 4000});
        bands[1] = HookrExistingTokenFactory.LpTranche({startOffset: 240, endOffset: 600, bps: 3000});
    }

    function _attach(HookrExistingTokenFactory.AttachArgs memory a, uint256 ethForPool)
        internal
        returns (PoolId poolId)
    {
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        PlainToken(a.token).approve(address(factory), a.tokenAmount + a.bandTokenAmount);
        poolId = factory.attach{value: fee + ethForPool}(a);
        vm.stopPrank();
    }

    function _key(address token_) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token_),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, PoolKey memory key, uint128 ethIn) internal returns (uint256 out) {
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: true,
            amountIn: ethIn,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: who,
            deadline: block.timestamp + 1
        });
        vm.prank(who);
        out = router.exactInput{value: ethIn}(p);
    }

    function _sell(address who, PoolKey memory key, uint128 tokensIn) internal returns (uint256 out) {
        vm.startPrank(who);
        PlainToken(Currency.unwrap(key.currency1)).approve(address(router), tokensIn);
        out = router.exactInput(
            HookrSwapRouter.ExactInputParams({
                key: key,
                zeroForOne: false,
                amountIn: tokensIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: MAX_LIMIT,
                recipient: who,
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();
    }

    function _positionLiquidity(PoolId id, int24 lower, int24 upper) internal view returns (uint128) {
        bytes32 positionId = keccak256(abi.encodePacked(address(factory), lower, upper, bytes32(0)));
        return manager.getPositionLiquidity(id, positionId);
    }

    // ------------------------------------------------------------------ the happy path

    function test_attachOpensPoolForExistingToken() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        PoolId id = _attach(a, 100 ether);

        HookrExistingTokenFactory.Attachment memory at = factory.getAttachment(address(token));
        assertEq(at.token, address(token), "attachment recorded");
        assertEq(at.creator, creator, "creator recorded");
        assertEq(factory.tokensCount(), 1, "one attach");
        assertGt(_positionLiquidity(id, FULL_LOWER, FULL_UPPER), 0, "founding position exists");

        // The pool trades in the same generation's router, over a token Hookr never minted.
        uint256 got = _buy(trader, _key(address(token)), 1 ether);
        assertGt(got, 0, "pool does not trade");
        assertEq(token.balanceOf(trader), got, "output delivered");
    }

    function test_dustAndEthReturnToCaller() public {
        // The full-range position is limited by ONE of the two legs, so each refund path gets
        // its own attach: oversupply the token leg first, then the ETH leg on a second token.
        uint256 tokenBefore = token.balanceOf(creator);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 5_000_000 ether);
        _attach(a, 100 ether);
        assertGt(token.balanceOf(creator), tokenBefore - 5_000_000 ether, "token dust came back");

        PlainToken tokenB = new PlainToken(creator, 10 ether);
        uint256 ethBefore = creator.balance;
        HookrExistingTokenFactory.AttachArgs memory b = _args(address(tokenB), 10 ether);
        _attach(b, 100 ether);
        assertGt(creator.balance, ethBefore - 100 ether - factory.creationFeeWei(), "ETH surplus came back");

        assertEq(token.balanceOf(address(factory)), 0, "factory keeps no tokens");
        assertEq(tokenB.balanceOf(address(factory)), 0, "factory keeps no tokenB");
        // The only ETH the factory holds is the accrued protocol fee ledger.
        assertEq(address(factory).balance, factory.protocolFeesWei(), "factory ETH is all protocol fees");
        assertEq(factory.protocolFeesWei(), 2 * uint256(factory.creationFeeWei()), "creation fees accrued to protocol");
    }

    /// @notice Departure (c): leftovers REFUND to the caller — the launchpad's burn-to-DEAD for
    ///         unplaced supply must never fire here, because the tokens are the caller's property.
    function test_leftoverTokensRefundNeverBurn() public {
        uint256 before = token.balanceOf(creator);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 5_000_000 ether);

        HookrExistingTokenFactory.AttachPlan memory plan = factory.previewAttach(a, 10 ether);
        assertGt(plan.tokenRefund, 0, "test needs a real leftover");

        _attach(a, 10 ether);
        assertEq(token.balanceOf(DEAD), 0, "nothing may burn at attach");
        assertEq(before - token.balanceOf(creator), plan.tokensUsed, "only the placed tokens left the caller");
    }

    /// @notice Departure (c), band half, HARDENED: unlike the launchpad — where price moves
    ///         between plan and graduation, forcing skip-don't-revert at seed time — the attach
    ///         seeds in the SAME transaction at exactly the attested price, so a band's fate is
    ///         fully computable at validation. A band that would collapse under alignment,
    ///         leave the usable range, or quantize its slice to zero is refused up front
    ///         (planned == placed, always), and `previewAttach` refuses identically.
    function test_unplaceableBandPlanIsRefusedUpFront() public {
        HookrExistingTokenFactory.LpTranche[] memory bands = new HookrExistingTokenFactory.LpTranche[](2);
        // A healthy band, and one whose 58-tick width collapses to nothing under alignment.
        bands[0] = HookrExistingTokenFactory.LpTranche({startOffset: 60, endOffset: 180, bps: 5000});
        bands[1] = HookrExistingTokenFactory.LpTranche({startOffset: 181, endOffset: 239, bps: 5000});

        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.bandTokenAmount = 100_000 ether;
        a.bands = bands;

        vm.expectRevert(HookrExistingTokenFactory.BadLpPlan.selector);
        factory.previewAttach(a, 100 ether);

        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        token.approve(address(factory), 1_100_000 ether);
        vm.expectRevert(HookrExistingTokenFactory.BadLpPlan.selector);
        factory.attach{value: fee + 100 ether}(a);
        vm.stopPrank();

        // A geometrically healthy ladder whose slices quantize to zero tokens is refused too:
        // it would seed nothing while `_capTokens` still counted its funding.
        bands[1] = HookrExistingTokenFactory.LpTranche({startOffset: 240, endOffset: 600, bps: 5000});
        a.bands = bands;
        a.bandTokenAmount = 1; // one wei across two bands: both slices round to zero
        vm.expectRevert(HookrExistingTokenFactory.BadLpPlan.selector);
        factory.previewAttach(a, 100 ether);

        // And a band a low attested price pushes past the usable tick range.
        a.bandTokenAmount = 100_000 ether;
        a.sqrtPriceX96 = V4PoolMath.getSqrtPriceAtTick(-800_000);
        bands[1] = HookrExistingTokenFactory.LpTranche({startOffset: 240, endOffset: 200_000, bps: 5000});
        a.bands = bands;
        vm.expectRevert(HookrExistingTokenFactory.BadLpPlan.selector);
        factory.previewAttach(a, 100 ether);

        // The same ladder at a sane price attaches fine: the refusal targets the collapse, not
        // the feature — and everything the plan promises is exactly what seeds.
        a.sqrtPriceX96 = SQRT_PRICE_1_1;
        bands[1] = HookrExistingTokenFactory.LpTranche({startOffset: 240, endOffset: 600, bps: 5000});
        a.bands = bands;
        HookrExistingTokenFactory.AttachPlan memory plan = factory.previewAttach(a, 100 ether);
        assertTrue(plan.bands[0].seeded && plan.bands[1].seeded, "every validated band must seed");
        PoolId id = _attach(a, 100 ether);
        assertGt(_positionLiquidity(id, plan.bands[0].tickLower, plan.bands[0].tickUpper), 0, "band 0 minted");
        assertGt(_positionLiquidity(id, plan.bands[1].tickLower, plan.bands[1].tickUpper), 0, "band 1 minted");
    }

    // ------------------------------------------------------------------ the token boundary

    function test_refusesFeeOnTransferToken() public {
        TaxToken taxed = new TaxToken(creator, 1_000_000 ether);
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        taxed.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(taxed), 1_000_000 ether);
        vm.expectRevert(HookrExistingTokenFactory.TaxedTransfer.selector);
        factory.attach{value: fee + 10 ether}(a);
        vm.stopPrank();
    }

    function test_refusesNoReturnToken() public {
        NoReturnToken usdtish = new NoReturnToken(creator, 1_000_000 ether);
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        usdtish.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(usdtish), 1_000_000 ether);
        vm.expectRevert(HookrExistingTokenFactory.TokenCallFailed.selector);
        factory.attach{value: fee + 10 ether}(a);
        vm.stopPrank();
    }

    function test_refusesFalseReturningToken() public {
        FalseToken liar = new FalseToken(creator, 1_000_000 ether);
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        liar.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(liar), 1_000_000 ether);
        vm.expectRevert(HookrExistingTokenFactory.TokenCallFailed.selector);
        factory.attach{value: fee + 10 ether}(a);
        vm.stopPrank();
    }

    /// @notice Departure (b): every price/tranche/guard figure assumes 18/18 decimals, so a
    ///         6-decimals token is refused by name rather than mispriced by 10^12.
    function test_refusesNonStandardDecimals() public {
        SixDecimalsToken sixDec = new SixDecimalsToken(creator, 1_000_000e6);
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        sixDec.approve(address(factory), 1_000_000e6);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(sixDec), 1_000_000e6);
        vm.expectRevert(HookrExistingTokenFactory.NonStandardDecimals.selector);
        factory.attach{value: fee + 10 ether}(a);
        vm.stopPrank();
    }

    function test_refusesEOAAndDegenerateSeeds() public {
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);

        // No seed ETH above the creation fee.
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1 ether);
        vm.expectRevert(HookrExistingTokenFactory.InsufficientPayment.selector);
        factory.attach{value: fee}(a);

        // No token leg.
        a = _args(address(token), 0);
        vm.expectRevert(HookrExistingTokenFactory.BadSeed.selector);
        factory.attach{value: fee + 1 ether}(a);

        // Band funding without a band plan (and vice versa).
        a = _args(address(token), 1 ether);
        a.bandTokenAmount = 1 ether;
        vm.expectRevert(HookrExistingTokenFactory.BadLpPlan.selector);
        factory.attach{value: fee + 1 ether}(a);

        // An EOA is not a token.
        a = _args(address(0xBEEF), 1 ether);
        vm.expectRevert(HookrExistingTokenFactory.BadToken.selector);
        factory.attach{value: fee + 1 ether}(a);

        // A price at the edge of the usable range would open a one-sided pool.
        a = _args(address(token), 1 ether);
        a.sqrtPriceX96 = V4PoolMath.getSqrtPriceAtTick(FULL_LOWER);
        vm.expectRevert(HookrExistingTokenFactory.OpenPriceOutOfRange.selector);
        factory.attach{value: fee + 1 ether}(a);

        // A creator fee that would leave protocol under its 20% floor.
        a = _args(address(token), 1 ether);
        a.creatorFeeBps = 8001;
        vm.expectRevert(HookrExistingTokenFactory.BadFeeSplit.selector);
        factory.attach{value: fee + 1 ether}(a);

        vm.stopPrank();
    }

    /// @notice The seed is one-shot by construction: the PoolKey is fully determined by the
    ///         token address, so a second attach dies in the hook's write-once configurePool.
    function test_secondAttachForSameTokenRefused() public {
        _attach(_args(address(token), 1_000_000 ether), 100 ether);
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        token.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        vm.expectRevert(HookrAttachHook.AlreadyConfigured.selector);
        factory.attach{value: fee + 10 ether}(a);
        vm.stopPrank();
    }

    function test_reentrantAttachIsNeutralized() public {
        ReenterToken hostile = new ReenterToken(creator, 2_000_000 ether);
        PlainToken accomplice = new PlainToken(address(hostile), 1_000_000 ether);
        hostile.arm(factory, accomplice);
        vm.deal(address(hostile), 10 ether);

        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        hostile.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(hostile), 1_000_000 ether);
        factory.attach{value: fee + 10 ether}(a);
        vm.stopPrank();

        // The outer attach lands; the nested attempt inside transferFrom was refused by the
        // lock and swallowed by the token. Only one pool may exist.
        assertEq(hostile.nestedSucceeded(), false, "nested attach must fail");
        assertEq(factory.tokensCount(), 1, "exactly one attach");
        assertEq(factory.getAttachment(address(accomplice)).token, address(0), "accomplice got no pool");
    }

    /// @notice The deeper probe: reentry from the token transfer INTO the PoolManager on the
    ///         CB_SEED settle path, while the v4 unlock is still open. The creation mutex — not
    ///         the PoolManager's own lock or anything later — must be the gate that refuses it.
    function test_reentrantSettleDuringSeedIsNeutralizedByTheCreationMutex() public {
        SettleReenterToken hostile = new SettleReenterToken(creator, 2_000_000 ether);
        PlainToken accomplice = new PlainToken(address(hostile), 1_000_000 ether);
        hostile.arm(factory, address(manager), accomplice);

        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        hostile.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(hostile), 1_000_000 ether);
        factory.attach{value: fee + 10 ether}(a);
        vm.stopPrank();

        assertEq(hostile.nestedSucceeded(), false, "attach reentered through the CB_SEED settle transfer");
        assertEq(
            hostile.nestedRevertSelector(),
            HookrExistingTokenFactory.Reentered.selector,
            "the creation mutex must be the refusing gate"
        );
        assertEq(factory.tokensCount(), 1, "exactly one attach");
        assertEq(factory.getAttachment(address(accomplice)).token, address(0), "accomplice got no pool");
    }

    function test_strayEthRefused() public {
        vm.prank(attacker);
        (bool ok,) = address(factory).call{value: 1 ether}("");
        assertFalse(ok, "stray ETH must be refused");
    }

    function test_unlockCallbackRefusesOutsiders() public {
        _attach(_args(address(token), 1_000_000 ether), 100 ether);
        vm.prank(attacker);
        vm.expectRevert(HookrExistingTokenFactory.NotPoolManager.selector);
        factory.unlockCallback(abi.encode(uint8(1), _key(address(token)), uint160(1), uint256(0), uint256(0)));
    }

    // ------------------------------------------------------------------ guard window

    /// @notice Departure (f): the guard-window LP exemption identity is this factory — the
    ///         attach transaction seeds its own positions inside the guard it just configured,
    ///         while everyone else waits out the finite window.
    function test_guardWindowBlocksOutsideLpButNotFactory() public {
        // 1,000 tokens at 1:1 with a 0.1% cap: maxBuyWei = 1 token repriced into ETH = 1 ether.
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000 ether);
        a.hookParams.guardBlocks = 20;
        a.hookParams.maxBuyBps = 10; // 0.1% of the planned placement
        a.hookParams.snipeTaxPips = 30_000;

        // Attach succeeds with the guard live during seeding: the factory is the exempt sender.
        PoolId id = _attach(a, 100 ether);
        assertGt(_positionLiquidity(id, FULL_LOWER, FULL_UPPER), 0, "factory seeded inside its own guard");

        // An outside LP is blocked for the window...
        PoolKey memory key = _key(address(token));
        vm.startPrank(attacker);
        token.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(HookrAttachHook.ExternalLiquidityBlockedDuringGuard.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();

        // ...and a buy over the per-block cap is refused with the cumulative figure.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(HookrAttachHook.MaxBuyExceeded.selector, 2 ether, 1 ether),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _buy(trader, key, 2 ether);
        assertGt(_buy(trader, key, 0.5 ether), 0, "capped buy still goes through");

        // Once the finite window closes, permissionless LP resumes.
        vm.roll(block.number + 21);
        // Attacker needs tokens for the full-range add now that buys delivered some.
        vm.prank(creator);
        token.transfer(attacker, 10_000 ether);
        vm.prank(attacker);
        lpRouter.modifyLiquidity{value: 2 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @notice Departure (e): the anti-snipe cap is denominated against the PLANNED placement
    ///         (tokenAmount + bandTokenAmount) — never against a foreign token's totalSupply(),
    ///         which is whatever its code says it is.
    function test_capTokensBasisIsPlannedPlacement() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.bandTokenAmount = 100_000 ether;
        a.bands = _twoBands();
        a.hookParams.guardBlocks = 20;
        a.hookParams.maxBuyBps = 50; // 0.5%

        PoolId id = _attach(a, 100 ether);

        // openPrice at 1:1 is 1e18 wei per whole token, so the cap is 0.5% of 1.1M tokens
        // repriced into ETH: 5,500 ether. Against the 100M supply it would be 500,000 ether.
        (,,,,,,,,,,, uint96 maxBuyWei,,,,) = hook.poolConfig(id);
        uint256 planned = 1_100_000 ether;
        uint256 expected = (((planned * 50) / BPS) * 1e18) / 1e18;
        assertEq(uint256(maxBuyWei), expected, "cap basis is the planned placement");
        uint256 supplyBased = (((100_000_000 ether * 50) / BPS) * 1e18) / 1e18;
        assertTrue(uint256(maxBuyWei) != supplyBased, "cap must not be supply-denominated");
    }

    /// @notice Near the low tick edge `openPriceWei` reaches ~1e44 and beyond, so a modest
    ///         placement already prices past the uint96 cap ceiling. The clamp must SATURATE to
    ///         `type(uint96).max` and let the attach proceed — a cap that quantizes UP is safe
    ///         (it only ever under-restricts toward "uncapped-in-practice"), a revert is not.
    function test_maxBuyCapSaturatesAtNearEdgeAttestedPrice() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.sqrtPriceX96 = V4PoolMath.getSqrtPriceAtTick(-600_000); // ~1.1e26 ETH per whole token
        a.hookParams.guardBlocks = 20;
        a.hookParams.maxBuyBps = 100; // 1% of the planned placement, repriced into ETH

        PoolId id = _attach(a, 1 ether);
        assertGt(_positionLiquidity(id, FULL_LOWER, FULL_UPPER), 0, "attach must seed at the edge price");
        (,,,,,,,,,,, uint96 maxBuyWei,,,,) = hook.poolConfig(id);
        assertEq(uint256(maxBuyWei), type(uint96).max, "the cap must saturate to the uint96 ceiling, not revert");
    }

    /// @notice Regression for the overflow-before-clamp defect: at one tick above the usable
    ///         floor with `capTokens = type(uint128).max`, the raw `cappedTokens * openPriceWei`
    ///         product exceeds uint256 and the old clamp panicked (0x11) before it could clamp.
    ///         It now saturates, and the attach is refused for the REAL reason further down:
    ///         no such token amount can price into uint128 liquidity. (The two failures always
    ///         travel together — any product that overflows uint256 also overflows the seed's
    ///         liquidity math — which is why the panic never blocked a placeable attach; the fix
    ///         makes the clamp total so that coupling is no longer load-bearing.)
    function test_maxBuyOverflowInputFailsInLiquidityMathNotInTheClamp() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), type(uint128).max);
        a.sqrtPriceX96 = V4PoolMath.getSqrtPriceAtTick(FULL_LOWER + 1);
        a.hookParams.guardBlocks = 20;
        a.hookParams.maxBuyBps = 10_000; // the whole planned placement

        vm.expectRevert(V4PoolMath.LiquidityOverflow.selector);
        factory.previewAttach(a, 1 ether);
    }

    /// @notice FIX for the launchpad's defect 3, proven through the ATTACH pair: the snipe tax
    ///         is an LP fee, the factory's locked positions are the only LP during the guard,
    ///         and `collectPoolFees` splits LP fees with the creator — so without withholding, a
    ///         creator who buys their own guarded pool gets up to `creatorFeeBps` of the tax
    ///         straight back. Guard-era LP earnings must be protocol-only.
    function test_guardWindowFeesNeverReachTheCreator() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.creatorFeeBps = 8000; // the maximum, so the leak would be at its largest
        a.hookParams.maxFeePips = 3000; // surge off: the fee arithmetic is exactly base + tax
        a.hookParams.guardBlocks = 100;
        a.hookParams.snipeTaxPips = 200_000; // 20% snipe tax
        PoolId id = _attach(a, 100 ether);
        PoolKey memory key = _key(address(token));

        // The creator buys their own attached pool, inside the guard window they configured.
        _buy(creator, key, 0.5 ether);
        assertGt(hook.guardLpEarnedWei(id), 0, "the guard window earned the position nothing");

        uint256 protocolBefore = factory.protocolFeesWei();
        factory.collectPoolFees(address(token));

        assertEq(factory.creatorFeesWei(address(token)), 0, "guard-window fees were credited to the creator");
        uint256 collected = factory.protocolFeesWei() - protocolBefore;
        assertGt(collected, 0, "nothing was collected at all, so the test proves nothing");
        assertEq(factory.guardFeesWithheldWei(address(token)), collected, "the whole collection should be withheld");

        // Nothing to claim, and the claim path says so rather than paying out zero.
        vm.expectRevert(HookrExistingTokenFactory.NothingToClaim.selector);
        factory.claimCreatorFees(address(token));
    }

    /// @notice And the withholding is a quarantine, not a confiscation: once the finite window
    ///         closes, ordinary trading splits normally, the hook's accrual stops growing, and
    ///         the high-water mark guarantees the same wei is never withheld twice across
    ///         repeated collections.
    function test_afterTheGuardTheCreatorIsPaidNormallyAndNothingIsWithheldTwice() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.creatorFeeBps = 8000;
        a.hookParams.maxFeePips = 3000;
        a.hookParams.guardBlocks = 10;
        a.hookParams.snipeTaxPips = 200_000;
        uint256 attachBlock = block.number;
        PoolId id = _attach(a, 100 ether);
        PoolKey memory key = _key(address(token));

        _buy(creator, key, 0.5 ether);
        uint256 accrued = hook.guardLpEarnedWei(id);
        assertGt(accrued, 0);
        factory.collectPoolFees(address(token));
        assertEq(factory.creatorFeesWei(address(token)), 0);
        uint256 withheld = factory.guardFeesWithheldWei(address(token));
        assertGt(withheld, 0);

        // Guard over. A third party trades; the creator's share of THAT is ordinary income.
        vm.roll(attachBlock + 10);
        _buy(trader, key, 0.5 ether);
        assertEq(hook.guardLpEarnedWei(id), accrued, "the guard accrual kept growing after the window");

        uint256 protocolBefore = factory.protocolFeesWei();
        factory.collectPoolFees(address(token));
        uint256 creatorSide = factory.creatorFeesWei(address(token));
        uint256 protocolSide = factory.protocolFeesWei() - protocolBefore;

        // The accrual uses v4's round-UP fee arithmetic while collected fees round down, so a
        // wei or two of the guard window can still be outstanding here; it is withheld from
        // this collection rather than forgotten — the conservative direction, and the only one
        // that cannot leak snipe tax back to the creator.
        uint256 residual = factory.guardFeesWithheldWei(address(token)) - withheld;
        assertLe(residual, 2, "more than rounding dust was carried past the guard window");
        assertGt(creatorSide, 0, "post-guard fees were withheld too");
        assertEq(creatorSide, ((creatorSide + protocolSide - residual) * 8000) / BPS, "post-guard split is not 80/20");
        assertLe(factory.guardFeesWithheldWei(address(token)), accrued, "withheld more than the guard ever earned");
    }

    // ------------------------------------------------------------------ fee collection

    /// @notice Departure (d): a token that refuses transfers to DEAD must not brick ETH-side
    ///         fee collection. The refused burn resolves its currency delta as factory-held
    ///         ERC-6909 claims inside the same unlock, and can be completed later.
    function test_tokenSideBurnRefusalDoesNotBrickEthFees() public {
        BlockDeadToken blocky = new BlockDeadToken(creator, 10_000_000 ether);
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        blocky.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(blocky), 1_000_000 ether);
        factory.attach{value: fee + 100 ether}(a);
        vm.stopPrank();

        // Buys accrue ETH-side LP fees; sells accrue token-side LP fees.
        PoolKey memory key = _key(address(blocky));
        uint256 bought = _buy(trader, key, 5 ether);
        _sell(trader, key, uint128(bought / 2));

        // Collection must not revert even though the token refuses its burn leg.
        factory.collectPoolFees(address(blocky));

        uint256 deferred = factory.deferredBurnClaims(address(blocky));
        assertGt(deferred, 0, "token-side fees deferred, not lost");
        assertEq(
            manager.balanceOf(address(factory), Currency.wrap(address(blocky)).toId()),
            deferred,
            "deferred burn is 1:1 claim-backed"
        );
        assertEq(blocky.balanceOf(DEAD), 0, "nothing burned yet");
        assertGt(factory.creatorFeesWei(address(blocky)), 0, "ETH side still split to the creator");
        assertGt(factory.protocolFeesWei(), factory.creationFeeWei(), "ETH side still split to protocol");

        // Retrying while the token still refuses reverts wholesale, claims intact.
        vm.expectRevert();
        factory.retryDeferredBurn(address(blocky));
        assertEq(factory.deferredBurnClaims(address(blocky)), deferred, "claims untouched by failed retry");

        // Once the token relents, anyone can complete the burn.
        blocky.setBlockDead(false);
        vm.prank(attacker);
        factory.retryDeferredBurn(address(blocky));
        assertEq(factory.deferredBurnClaims(address(blocky)), 0, "claims consumed");
        assertEq(blocky.balanceOf(DEAD), deferred, "burn completed to DEAD");
    }

    /// @notice Hook-economics smoke through an attach pair: every launchpad-generation block
    ///         proof was made under a HookrToken; this is the same composition — auto-burn to
    ///         DEAD, in-swap LP donation, deterministic pot tick and payout — over a token
    ///         Hookr never minted.
    function test_hookEconomicsComposeThroughAnAttachedForeignToken() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.hookParams.burnBps = 100;
        a.hookParams.lpBps = 25;
        a.hookParams.potBps = 50;
        a.hookParams.potEveryNBuys = 2;
        a.hookParams.potMinBuyWei = 0.001 ether;
        PoolId id = _attach(a, 100 ether);
        PoolKey memory key = _key(address(token));

        uint256 out = _buy(trader, key, 1 ether);
        assertGt(out, 0, "cut-bearing buy failed");
        uint256 burned = token.balanceOf(DEAD);
        assertGt(burned, 0, "auto-burn block inactive on an attached token");
        assertEq(hook.totalBurnedTokens(id), burned, "burn ledger disagrees with DEAD");
        assertGt(hook.totalLpDonatedWei(id), 0, "LP donation block inactive");
        assertEq(hook.potBuyCount(id), 1, "pot counter did not advance");
        assertGt(hook.potWei(id), 0, "pot did not accrue");
        assertEq(hook.burnVaultWei(id), 0, "legacy burn vault must stay empty");
        assertEq(hook.nativeClaimBalance(), hook.potWei(id), "pot must be 1:1 claim-backed");

        // The second qualifying buy, in a distinct block, is the Nth of potEveryNBuys = 2 and
        // takes the pot.
        vm.roll(block.number + 1);
        _buy(trader, key, 1 ether);
        assertEq(hook.potBuyCount(id), 2, "second block's qualifying buy not counted");
        assertGt(hook.claimableWei(trader), 0, "deterministic pot did not pay the scheduled winner");
        assertEq(hook.potWei(id), 0, "won pot must empty");
        assertEq(hook.nativeClaimBalance(), hook.claimableWei(trader), "claims must keep backing the won pot");
        assertGt(token.balanceOf(DEAD), burned, "auto-burn composed on the second buy");
        assertEq(address(hook).balance, 0, "shared hook must not custody physical ETH");
    }

    /// @notice The disclosed buy-brick edge, pinned as behavior rather than fixed: a token
    ///         admin who blocklists ONLY the dead address bricks every exact-input buy on a
    ///         pool configured with `burnBps > 0` — the afterSwap burn transfer reverts and the
    ///         whole swap reverts atomically with it, no funds lost, while the token trades
    ///         normally everywhere else. A deferred-burn fallback in afterSwap is deliberately
    ///         NOT taken this generation: the hook's audit value is byte-equality with
    ///         HookrHook. See HOOKR_ATTACH_DESIGN.md.
    function test_burnBpsWithDeadBlocklistedTokenRevertsBuysAtomically() public {
        BlockDeadToken blocky = new BlockDeadToken(creator, 10_000_000 ether);
        uint256 fee = factory.creationFeeWei();
        vm.startPrank(creator);
        blocky.approve(address(factory), 1_000_000 ether);
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(blocky), 1_000_000 ether);
        a.hookParams.burnBps = 100;
        factory.attach{value: fee + 100 ether}(a);
        vm.stopPrank();

        PoolKey memory key = _key(address(blocky));
        vm.expectRevert();
        _buy(trader, key, 1 ether);
        assertEq(blocky.balanceOf(trader), 0, "the reverted buy must deliver nothing");

        // Selective by construction: the moment the token unblocks DEAD, the same pool trades.
        blocky.setBlockDead(false);
        assertGt(_buy(trader, key, 1 ether), 0, "unblocked token must trade again");
        assertGt(blocky.balanceOf(DEAD), 0, "auto-burn resumed with the unblock");
    }

    /// @notice The band loop in `collectPoolFees` pokes every stored band's position. With
    ///         validation guaranteeing planned == placed, the loop's anti-brick `continue` (a
    ///         stored band whose position is absent) is unreachable for pools this factory
    ///         attached and is retained purely as defense-in-depth — the failure it guards
    ///         against would brick the token's entire fee collection, ETH side included. This
    ///         covers the reachable shape: a banded plan collecting through the loop, twice.
    function test_collectPoolFeesSweepsBandFeesOnABandedPlan() public {
        HookrExistingTokenFactory.LpTranche[] memory bands = new HookrExistingTokenFactory.LpTranche[](1);
        bands[0] = HookrExistingTokenFactory.LpTranche({startOffset: 60, endOffset: 600, bps: 10_000});
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.bandTokenAmount = 500_000 ether;
        a.bands = bands;
        HookrExistingTokenFactory.AttachPlan memory plan = factory.previewAttach(a, 10 ether);
        PoolId id = _attach(a, 10 ether);
        PoolKey memory key = _key(address(token));
        assertGt(_positionLiquidity(id, plan.bands[0].tickLower, plan.bands[0].tickUpper), 0, "band minted");

        // Push spot into the band so the band position itself earns, then collect through the
        // full-range AND band pokes.
        _buy(trader, key, 5 ether);
        factory.collectPoolFees(address(token));
        uint256 firstCreatorSide = factory.creatorFeesWei(address(token));
        assertGt(firstCreatorSide, 0, "banded collection accrued nothing");

        // Repeat collection walks the same band loop again without double-counting.
        _buy(trader, key, 1 ether);
        factory.collectPoolFees(address(token));
        assertGt(factory.creatorFeesWei(address(token)), firstCreatorSide, "second collection accrued nothing");
        assertEq(
            _positionLiquidity(id, plan.bands[0].tickLower, plan.bands[0].tickUpper),
            plan.bands[0].liquidity,
            "collection must never touch band principal"
        );
    }

    /// @notice The end-to-end lifecycle over a foreign 18-decimals token: attach with bands,
    ///         trade both directions, collect and split fees, claim both sides — and confirm
    ///         the liquidity is locked by construction throughout.
    function test_e2eForeignTokenLifecycle() public {
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        a.bandTokenAmount = 200_000 ether;
        a.bands = _twoBands();
        a.creatorFeeBps = 6000;
        PoolId id = _attach(a, 100 ether);
        PoolKey memory key = _key(address(token));

        uint128 seeded = _positionLiquidity(id, FULL_LOWER, FULL_UPPER);
        assertGt(seeded, 0);

        // Trade both directions so both fee legs accrue.
        uint256 bought = _buy(trader, key, 5 ether);
        assertGt(bought, 0);
        uint256 ethOut = _sell(trader, key, uint128(bought / 2));
        assertGt(ethOut, 0);

        // Nobody — not even via a direct PoolManager unlock — can reduce the factory's position.
        vm.prank(attacker);
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: -int256(uint256(seeded)), salt: bytes32(0)
            }),
            ""
        );
        assertEq(_positionLiquidity(id, FULL_LOWER, FULL_UPPER), seeded, "position reduced");

        // Permissionless collection: ETH splits 60/40 creator/protocol, token side burns.
        uint256 protocolBefore = factory.protocolFeesWei();
        factory.collectPoolFees(address(token));
        uint256 creatorSide = factory.creatorFeesWei(address(token));
        uint256 protocolSide = factory.protocolFeesWei() - protocolBefore;
        assertGt(creatorSide, 0, "creator fees accrued");
        assertGt(protocolSide, 0, "protocol fees accrued");
        // 60/40 split up to rounding.
        assertApproxEqAbs(creatorSide * 4000, protocolSide * 6000, 6000, "configured split respected");
        assertGt(token.balanceOf(DEAD), 0, "token side burned");

        // Creator claims to a nominated payout address.
        address payout = address(0xFEE);
        vm.prank(creator);
        factory.setCreatorPayout(address(token), payout);
        factory.claimCreatorFees(address(token));
        assertEq(payout.balance, creatorSide, "creator side delivered");

        // Owner withdraws protocol fees; the factory ends the day empty-handed.
        factory.withdrawProtocolFees(address(this));
        assertEq(address(factory).balance, 0, "factory keeps nothing");
        assertEq(factory.protocolFeesWei(), 0);

        // Collection is repeatable without draining principal.
        _buy(trader, key, 1 ether);
        factory.collectPoolFees(address(token));
        assertEq(_positionLiquidity(id, FULL_LOWER, FULL_UPPER), seeded, "principal untouched by collection");
    }

    // ------------------------------------------------------------------ preview equivalence

    /// @notice Revert parity: every validation-time refusal `attach` raises, `previewAttach`
    ///         raises identically for the same inputs — a preview that silently passes a plan
    ///         execution would refuse is a lie in the UI. (Transfer-time refusals —
    ///         TaxedTransfer, TokenCallFailed — are execution-only by nature: the preview never
    ///         touches token transfer code.)
    function test_previewAttachRevertsExactlyWhereAttachWould() public {
        // No seed ETH.
        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), 1_000_000 ether);
        vm.expectRevert(HookrExistingTokenFactory.BadSeed.selector);
        factory.previewAttach(a, 0);

        // No token leg.
        a = _args(address(token), 0);
        vm.expectRevert(HookrExistingTokenFactory.BadSeed.selector);
        factory.previewAttach(a, 1 ether);

        // Band funding without a band plan.
        a = _args(address(token), 1 ether);
        a.bandTokenAmount = 1 ether;
        vm.expectRevert(HookrExistingTokenFactory.BadLpPlan.selector);
        factory.previewAttach(a, 1 ether);

        // An EOA is not a token.
        a = _args(address(0xBEEF), 1 ether);
        vm.expectRevert(HookrExistingTokenFactory.BadToken.selector);
        factory.previewAttach(a, 1 ether);

        // Non-18-decimals token.
        SixDecimalsToken sixDec = new SixDecimalsToken(creator, 1_000_000e6);
        a = _args(address(sixDec), 1_000_000e6);
        vm.expectRevert(HookrExistingTokenFactory.NonStandardDecimals.selector);
        factory.previewAttach(a, 1 ether);

        // A price at the edge of the usable range.
        a = _args(address(token), 1 ether);
        a.sqrtPriceX96 = V4PoolMath.getSqrtPriceAtTick(FULL_LOWER);
        vm.expectRevert(HookrExistingTokenFactory.OpenPriceOutOfRange.selector);
        factory.previewAttach(a, 1 ether);

        // A creator fee split past the protocol floor.
        a = _args(address(token), 1 ether);
        a.creatorFeeBps = 8001;
        vm.expectRevert(HookrExistingTokenFactory.BadFeeSplit.selector);
        factory.previewAttach(a, 1 ether);
    }

    /// @notice `previewAttach` mirrors execution wei-for-wei: same liquidity, same consumed
    ///         amounts, same refunds — across prices, seed ratios, and band configurations.
    function testFuzz_previewMatchesExecution(uint256 ethSeed, uint256 tokenSeed, uint256 bandSeed, int24 tickSeed)
        public
    {
        uint256 ethForPool = bound(ethSeed, 0.01 ether, 500 ether);
        uint256 tokenAmount = bound(tokenSeed, 1e18, 20_000_000 ether);
        uint256 bandTokenAmount = bound(bandSeed, 0, 1_000_000 ether);
        // Validation now refuses a plan whose band slice quantizes to zero tokens (BadLpPlan),
        // so the fuzz explores plans that place: dust-level band funding degrades to no bands.
        if (bandTokenAmount > 0 && bandTokenAmount < 0.01 ether) bandTokenAmount = 0;
        int24 tick = int24(bound(int256(tickSeed), -100_000, 100_000));

        HookrExistingTokenFactory.AttachArgs memory a = _args(address(token), tokenAmount);
        a.sqrtPriceX96 = V4PoolMath.getSqrtPriceAtTick(tick);
        if (bandTokenAmount > 0) {
            a.bandTokenAmount = bandTokenAmount;
            a.bands = _twoBands();
        }

        HookrExistingTokenFactory.AttachPlan memory plan = factory.previewAttach(a, ethForPool);

        uint256 ethBefore = creator.balance;
        uint256 tokenBefore = token.balanceOf(creator);
        PoolId id = _attach(a, ethForPool);

        assertEq(_positionLiquidity(id, FULL_LOWER, FULL_UPPER), plan.liquidity, "full-range liquidity");
        assertEq(ethBefore - creator.balance, factory.creationFeeWei() + plan.ethUsed, "ETH consumed matches the plan");
        assertEq(
            tokenBefore - token.balanceOf(creator),
            plan.tokensUsed + plan.bandTokensUsed,
            "tokens consumed match the plan"
        );
        for (uint256 i; i < plan.bands.length; ++i) {
            if (!plan.bands[i].seeded) continue;
            assertEq(
                _positionLiquidity(id, plan.bands[i].tickLower, plan.bands[i].tickUpper),
                plan.bands[i].liquidity,
                "band liquidity matches the plan"
            );
        }
        assertEq(token.balanceOf(address(factory)), 0, "factory keeps no tokens");
        assertEq(address(factory).balance, factory.protocolFeesWei(), "factory ETH is all protocol fees");
    }
}
