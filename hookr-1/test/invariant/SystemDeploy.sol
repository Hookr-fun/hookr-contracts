// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {HookrRootFactory} from "../../src/factory/HookrRootFactory.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrFactoryRegistry} from "../../src/interfaces/IHookrFactoryRegistry.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {EntryPointV07Code} from "../gasless/EntryPointV07Code.sol";
import {SysLocker, SysMulticall, SysProbe, SysFeeAdapter, SysAccount} from "./SystemHelpers.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";

/// @notice Release-shaped deployment for the system invariant campaign, wired as the rehearsal wires 4663: the real
///         Permit2 and EntryPoint v0.7 runtimes at their chain addresses, the Forwarder pinned into the Router, two
///         registered HookrRoots each with its own HookrRules (minProtocolShareBps 2,000, the Treasury as protocol
///         recipient), a curated locker pinned in both roots, the Launcher, HookrFeeAdvisory with session tiers and
///         HookrSessionAdvisory admitted on the first root, the root factory with two pair roots (one advised),
///         the Liquidity Vault as a second Treasury source, Programs (Immediate and DailySwap), and the Paymaster in
///         CREDIT and TOKEN modes with rebates on. The PoolManager's protocol fee controller is a V4FeeAdapter model
///         (permissionless triggerFeeUpdate).
/// @dev Root pools (index: family, member, root, quote, rules):
///      0 famA.0 root1 native: guard 30 blocks, Snipe 30% decaying to 2% over 600 s, buy cap, dynamic fee (5, 10%),
///        Auto Burn, LP Rewards, royalty, 25% protocol share.
///      1 famA.1 root1 Q: dynamic fee (3, 5%), LP Rewards, protocol share at the 20% floor.
///      2 famB.0 root1 Q: HookrFeeAdvisory with session tiers, Auto Burn, LP Rewards, royalty, 30% share.
///      3 famB.1 root1 native: HookrSessionAdvisory, guard 80 blocks, flat 5% Snipe, buy cap, 25% share.
///      4 famC.0 root2 Q: fee-only (base fee alone, 20% share): the root skips Rules on every swap.
///      5 famD.0 root2 native: dynamic fee at the widest span (10, 60%), LP Rewards, royalty, 50% share.
///      6 famE.0 root1 native, launched after the deploy's timelock warps: base 1%, guard 300 blocks, Snipe 40%
///        decaying to 2% over 3,600 s with a quarter of the decay gone when the campaign starts, buy cap, Auto Burn,
///        LP Rewards, 25% share. Outside the Programs scopes.
///      Families launched later by the dev-buy handler append to the same list. Pair pools: 0 (SB/Q, no advisory) and
///      1 (native/SA, HookrFeeAdvisory with tiers through bindPair).
///      The deploy runs from Saturday 2026-11-21 and the campaign starts on Wednesday 2026-11-25 at 09:00 in New York
///      (CAMPAIGN_START): pre-market, half an hour before the open, the day before Thanksgiving (a full closure) and
///      two days before the Friday 13:00 early close.
abstract contract SystemDeploy is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant PERMIT2 = Chain4663Code.PERMIT2_ADDRESS;
    address internal constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant FEE_SETTER = address(0xFEE5);
    address internal constant TARGET = address(0x7A76E7);
    address internal constant ROYALTY_A = address(0x40A1);
    address internal constant ROYALTY_B = address(0x40B2);
    /// @dev Three integrators on the treasury's list: family A's native member names the first (half of Hookr's
    ///      share), family D the second, and family C the third, whose Hookr minimum override is zero and which approved
    ///      family C's pool id, so that pool of a Hookr token binds no minimum and stays fee-only. Every other Hookr
    ///      token pool without a rule that earns Hookr a share (a dev-buy launch's second member) binds the treasury's
    ///      1,000-pip minimum, whichever integrator it names without its approval; a pool with such a rule binds none.
    address internal constant INTEGRATOR_A = address(0x1A7EA);
    address internal constant INTEGRATOR_B = address(0x1A7EB);
    address internal constant INTEGRATOR_C = address(0x1A7EC);
    uint16 internal constant INTEGRATOR_A_BPS = 5_000;
    uint16 internal constant INTEGRATOR_B_BPS = 1_234;
    uint16 internal constant INTEGRATOR_C_BPS = 2_000;
    address internal constant PM_OWNER = address(0xA11CE0);
    address internal constant PM_TREASURY = address(0x7E57);
    address internal constant ATTESTOR = address(0xA77E);
    address internal constant REVIEWER = address(0x4E71);
    address internal constant BUNDLER = address(0xB0B);
    address internal constant BUX_OWNER = address(0xB0C5);
    address internal constant KEEPER = address(0x4EE9);
    uint128 internal constant Q_PER_ETH = 2000e18;
    uint48 internal constant DELAY = 1 days;
    uint16 internal constant MIN_SHARE = 2_000;
    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    uint24 internal constant FEE_ADMISSION_CAP = 50_000;
    uint32 internal constant FEE_ADVISORY_GAS = 100_000;
    uint24 internal constant SESSION_ADMISSION_CAP = 50_000;
    uint32 internal constant SESSION_ADVISORY_GAS = 150_000;
    uint24 internal constant PAIR_ADVISORY_CAP = 2_000;
    uint32 internal constant PAIR_ADVISORY_GAS = 60_000;
    uint16 internal constant VAULT_SKIM_BPS = 1_000;
    uint256 internal constant SA_SUPPLY = 1e30;
    /// @dev Seconds between family E's launch and the campaign's start.
    uint256 internal constant FAM_E_AGE = 900;

    /// @dev What the campaign knows about a root pool.
    struct Meta {
        bytes32 family;
        uint8 member;
        bool devBuy;
        bool dynamic;
        bool advised;
        address creator;
        uint256 launchedAt;
    }

    IPoolManager public manager;
    HookrRegistry public registry;
    HookrForwarder public fwd;
    HookrRouter public router;
    HookrQuoter public quoter;
    SysLocker public curated;
    SysLocker public generic;
    HookrLauncher public launcher;
    HookrRoot public root1;
    HookrRoot public root2;
    HookrTreasury public treasury;
    HookrRules public rules1;
    HookrRules public rules2;
    HookrFeeAdvisory public feeAdvisory;
    HookrSessionAdvisory public sessionAdvisory;
    HookrRootFactory public factory;
    HookrLiquidityVault public vault;
    HookrPrograms public programs;
    HookrReferralRegistry public referrals;
    HookrPaymaster public paymaster;
    SysFeeAdapter public feeAdapter;
    SysMulticall public multicall;
    SysProbe public probe;
    SysAccount public acct0;
    SysAccount public acct1;
    HookrToken public Q;
    HookrToken public SA;
    HookrToken public SB;

    uint256[4] internal actorPk;
    address[4] public actors;
    bytes32 public famA;
    bytes32 public famB;
    bytes32 public famC;
    bytes32 public famD;
    bytes32 public famE;
    HookrToken public SE;
    PoolKey[] internal keys;
    Meta[] internal metas;
    PoolKey[] internal pairKeys;
    address[] public pairRoots;
    uint256 public immediateId;
    uint256 public dailyId;
    /// @dev Session tiers and fee bounds frozen at bind, captured right after the binds.
    IHookrFeeAdvisory.Session internal frozenFeeSession;
    IHookrFeeAdvisory.Bounds internal frozenFeeBounds;
    IHookrFeeAdvisory.Session internal frozenPairSession;
    IHookrSessionAdvisory.Bound internal frozenSession;

    function poolCount() external view returns (uint256) {
        return keys.length;
    }

    function key(uint256 i) external view returns (PoolKey memory) {
        return keys[i];
    }

    function meta(uint256 i) external view returns (Meta memory) {
        return metas[i];
    }

    function pairCount() external view returns (uint256) {
        return pairKeys.length;
    }

    function pairKey(uint256 i) external view returns (PoolKey memory) {
        return pairKeys[i];
    }

    function frozen()
        external
        view
        returns (
            IHookrFeeAdvisory.Session memory feeSession,
            IHookrFeeAdvisory.Bounds memory feeBounds,
            IHookrFeeAdvisory.Session memory pairSession,
            IHookrSessionAdvisory.Bound memory session
        )
    {
        return (frozenFeeSession, frozenFeeBounds, frozenPairSession, frozenSession);
    }

    /// @dev Unix time of a New York wall-clock hour, in the EST or EDT offset the calendar reads for it.
    function _ny(uint256 y, uint256 m, uint256 d, uint256 h) internal pure returns (uint256) {
        uint256 local = HookrMarketCalendar.dayOf(y, m, d) * 1 days + h * 1 hours;
        return local + HookrMarketCalendar.utcOffset(local + HookrMarketCalendar.EST);
    }

    /// @notice When the campaign starts: Wednesday 2026-11-25, 09:00 in New York.
    function campaignStart() public pure returns (uint256) {
        return _ny(2026, 11, 25, 9);
    }

    function _deploySystem() internal {
        vm.chainId(4663);
        // Saturday 2026-11-21, 11:00 in New York. The timelocks, the daily program's first UTC midnight and the
        // paymaster's timelock bring the deploy to Wednesday 2026-11-25 00:00 UTC, before family E and the campaign.
        vm.warp(_ny(2026, 11, 21, 11));
        vm.roll(70_000_000);
        vm.etch(PERMIT2, Chain4663Code.PERMIT2);
        vm.etch(EP, EntryPointV07Code.RUNTIME);
        for (uint256 i; i < 4; ++i) {
            actorPk[i] = 0xA000 + i;
            actors[i] = vm.addr(actorPk[i]);
            vm.deal(actors[i], 1e26);
        }
        vm.deal(address(this), 1e28);
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        feeAdapter = new SysFeeAdapter(manager, FEE_SETTER);
        manager.setProtocolFeeController(address(feeAdapter));
        registry = new HookrRegistry(address(this), manager, DELAY);
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        fwd = new HookrForwarder(PERMIT2, address(registry), predictedRouter);
        router = new HookrRouter(manager, registry, address(fwd));
        require(address(router) == predictedRouter, "router prediction");
        quoter = new HookrQuoter(manager, registry);
        curated = new SysLocker(manager, address(this));
        generic = new SysLocker(manager, address(this));
        launcher = new HookrLauncher(manager, registry);
        _mineRoots();
        treasury = new HookrTreasury(address(this), TARGET, manager);
        rules1 = new HookrRules(manager, registry, address(treasury), address(root1), MIN_SHARE);
        rules2 = new HookrRules(manager, registry, address(treasury), address(root2), MIN_SHARE);
        treasury.admitSource(address(rules1));
        treasury.admitSource(address(rules2));
        // Listed through the treasury's 30-minute timelock, accepted after `_admit`'s registry delay.
        treasury.proposeIntegrator(INTEGRATOR_A, INTEGRATOR_A_BPS);
        treasury.proposeIntegrator(INTEGRATOR_B, INTEGRATOR_B_BPS);
        treasury.proposeIntegrator(INTEGRATOR_C, INTEGRATOR_C_BPS);
        treasury.proposeIntegratorMinFee(INTEGRATOR_C, 0);
        sessionAdvisory = new HookrSessionAdvisory(address(this), DELAY);
        feeAdvisory = new HookrFeeAdvisory(address(this), DELAY, registry, address(sessionAdvisory));
        factory = new HookrRootFactory(manager, IHookrFactoryRegistry(address(registry)));
        vault = new HookrLiquidityVault(manager, address(treasury), address(this), DELAY, VAULT_SKIM_BPS);
        Q = new HookrToken("Quote USD", "QUSD", 1e36, address(this));
        SB = new HookrToken("Subject B", "SUBB", 1e36, address(this));
        _admit();
        treasury.acceptIntegrator(INTEGRATOR_A);
        treasury.acceptIntegrator(INTEGRATOR_B);
        treasury.acceptIntegrator(INTEGRATOR_C);
        treasury.acceptIntegratorMinFee(INTEGRATOR_C);
        treasury.admitSource(address(vault));
        for (uint256 i; i < 4; ++i) {
            Q.transfer(actors[i], 1e30);
            SB.transfer(actors[i], 1e30);
            _approveAll(actors[i], address(Q));
            _approveAll(actors[i], address(SB));
        }
        _launchFamilies();
        for (uint256 i; i < 4; ++i) {
            if (i != 0) {
                vm.prank(actors[0]);
                SA.transfer(actors[i], 1e25);
            }
            _approveAll(actors[i], address(SA));
        }
        _deployPairs();
        _deployPrograms();
        _deployPaymaster();
        multicall = new SysMulticall(address(this));
        probe = new SysProbe();
        vm.deal(address(multicall), 1e25);
        Q.transfer(address(multicall), 1e28);
        SB.transfer(address(multicall), 1e28);
        vm.prank(actors[0]);
        SA.transfer(address(multicall), 1e24);
        _multicallApprove(address(Q));
        _multicallApprove(address(SA));
        _multicallApprove(address(SB));
        // Family E launches after every timelock warp, so its guard and its Snipe decay are live when the campaign
        // starts, a quarter of the way into the decay.
        uint256 start = campaignStart();
        require(vm.getBlockTimestamp() < start - FAM_E_AGE, "deploy ran past the campaign start");
        vm.warp(start - FAM_E_AGE);
        _launchLate();
        vm.warp(start);
    }

    /// @dev Family E: new token, root1, native, base 1%, guarded 300 blocks, Snipe 40% decaying to 2% over 3,600 s,
    ///      buy cap, Auto Burn, LP Rewards, 25% protocol share.
    function _launchLate() private {
        IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
        ms[0] = _member(Currency.wrap(address(0)), address(rules1));
        ms[0].config.baseLpFeePips = 10_000;
        ms[0].rules.maxFeePips = 10_000;
        ms[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 300);
        ms[0].rules.snipeTaxPips = 400_000;
        ms[0].rules.snipeFloorPips = 20_000;
        ms[0].rules.snipeDecaySeconds = 3_600;
        ms[0].rules.maxBuyQuoteAmount = 5e19;
        ms[0].rules.burnBps = 100;
        ms[0].rules.lpBps = 200;
        ms[0].rules.protocolShareBps = 2_500;
        address subject;
        vm.prank(actors[2]);
        (famE, subject) = launcher.launch{value: 2e21}(
            IHookrLauncher.Token(address(0), "Subject E", "SUBE", 1e24, bytes32("e")),
            address(root1),
            ms,
            vm.getBlockTimestamp()
        );
        SE = HookrToken(subject);
        _push(launcher.position(famE, 0).key, famE, 0, false, false, false, actors[2]);
        for (uint256 i; i < 4; ++i) {
            if (i != 2) {
                vm.prank(actors[2]);
                SE.transfer(actors[i], 1e22);
            }
            _approveAll(actors[i], subject);
        }
    }

    /// @dev Both roots pin the curated locker, at the first two salts whose addresses carry the permission flags.
    function _mineRoots() private {
        HookrRoot[] memory roots =
            ReleaseWiring.deployRoots(manager, registry, address(router), address(quoter), address(curated), 2);
        (root1, root2) = (roots[0], roots[1]);
    }

    function _advisoryAdmission(address a, bytes32 schema, uint24 cap, uint32 gas)
        private
        view
        returns (IHookrRegistry.Admission memory)
    {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: a,
            codeHash: a.codehash,
            schemaHash: schema,
            caps: HookrTypes.Caps(cap, 0, 0),
            gasLimit: gas,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
    }

    /// @dev Two timelock rounds, every delay DELAY: the registry's roots, launcher, quote and root factory with the fee
    ///      advisory's keeper and the vault's skim; then the five admissions.
    function _admit() private {
        ReleaseWiring.queueRoot(registry, address(root1));
        ReleaseWiring.queueRoot(registry, address(root2));
        ReleaseWiring.queueLauncher(registry, address(launcher));
        ReleaseWiring.queueQuote(registry, address(Q));
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        feeAdvisory.queue(feeAdvisory.ADD_KEEPER(), abi.encode(KEEPER));
        vault.queue(vault.SET_SKIM(), abi.encode(VAULT_SKIM_BPS));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        ReleaseWiring.registerRoot(registry, address(root1));
        ReleaseWiring.registerRoot(registry, address(root2));
        ReleaseWiring.activateLauncher(registry, address(launcher));
        ReleaseWiring.addQuote(registry, address(Q));
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        feeAdvisory.addKeeper(KEEPER);
        vault.setSkim(VAULT_SKIM_BPS);
        IHookrRegistry.Admission memory a1 = ReleaseWiring.rulesAdmission(rules1, 400_000);
        IHookrRegistry.Admission memory a2 = ReleaseWiring.rulesAdmission(rules2, 400_000);
        IHookrRegistry.Admission memory af = _advisoryAdmission(
            address(feeAdvisory), feeAdvisory.configSchemaHash(), FEE_ADMISSION_CAP, FEE_ADVISORY_GAS
        );
        IHookrRegistry.Admission memory as_ = _advisoryAdmission(
            address(sessionAdvisory), sessionAdvisory.configSchemaHash(), SESSION_ADMISSION_CAP, SESSION_ADVISORY_GAS
        );
        IHookrRegistry.Admission memory ap = _advisoryAdmission(
            address(feeAdvisory), feeAdvisory.configSchemaHash(), PAIR_ADVISORY_CAP, PAIR_ADVISORY_GAS
        );
        ReleaseWiring.queueAdmission(registry, address(root1), a1);
        ReleaseWiring.queueAdmission(registry, address(root2), a2);
        ReleaseWiring.queueAdmission(registry, address(root1), af);
        ReleaseWiring.queueAdmission(registry, address(root1), as_);
        ReleaseWiring.queueAdmission(registry, address(factory), ap);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        ReleaseWiring.admit(registry, address(root1), a1);
        ReleaseWiring.admit(registry, address(root2), a2);
        ReleaseWiring.admit(registry, address(root1), af);
        ReleaseWiring.admit(registry, address(root1), as_);
        ReleaseWiring.admit(registry, address(factory), ap);
    }

    function _approveAll(address who, address token) internal {
        vm.startPrank(who);
        HookrToken(token).approve(address(router), type(uint256).max);
        HookrToken(token).approve(address(launcher), type(uint256).max);
        HookrToken(token).approve(address(curated), type(uint256).max);
        HookrToken(token).approve(address(generic), type(uint256).max);
        HookrToken(token).approve(address(vault), type(uint256).max);
        HookrToken(token).approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A member with the canary band (+-60,000 ticks around price 1), base 0.3% and the pool caps the rehearsal
    ///      admits. Rules fields are set by the caller.
    function _member(Currency quote, address rules_) internal pure returns (IHookrLauncher.Member memory m) {
        m.quote = quote;
        m.tickSpacing = 60;
        m.sqrtPriceX96 = uint160(1 << 96);
        m.tickLower = -60_000;
        m.tickUpper = 60_000;
        m.liquidity = 1e21;
        m.amount0Max = 2e21;
        m.amount1Max = 2e21;
        m.config.rules = rules_;
        m.config.baseLpFeePips = 3000;
        m.config.caps = HookrTypes.Caps(600_000, 400_000, 1_000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("hookr.invariant.system");
        m.rules.maxFeePips = 3000;
        m.rules.protocolShareBps = MIN_SHARE;
    }

    function _feeConfig() internal pure returns (IHookrFeeAdvisory.Config memory) {
        return IHookrFeeAdvisory.Config({
            cap: 20_000, surcharge: 1_000, premium0: 500, premium1: 0, maxStep: 5_000, minInterval: 60, maxTtl: 1 hours
        });
    }

    function _feeTiers() internal pure returns (HookrSessionTiers.Tiers memory) {
        return HookrSessionTiers.Tiers(1_000, 4_000, 6_000, 10_000, 15_000, 900, 900, 1);
    }

    function _push(PoolKey memory k, bytes32 fam, uint8 member, bool devBuy, bool dynamic, bool advised, address c)
        internal
    {
        keys.push(k);
        metas.push(Meta(fam, member, devBuy, dynamic, advised, c, block.timestamp));
    }

    function _launchFamilies() private {
        uint256 deadline = vm.getBlockTimestamp() + 1;
        Currency native = Currency.wrap(address(0));
        Currency quote = Currency.wrap(address(Q));
        // Family A: new token, root1. Member 0 native: guarded, decaying Snipe, buy cap, dynamic fee. Member 1 Q:
        // dynamic fee at the protocol share floor.
        {
            IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](2);
            ms[0] = _member(native, address(rules1));
            ms[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 30);
            ms[0].rules.snipeTaxPips = 300_000;
            ms[0].rules.snipeFloorPips = 20_000;
            ms[0].rules.snipeDecaySeconds = 600;
            ms[0].rules.maxBuyQuoteAmount = 5e19;
            ms[0].rules.maxFeePips = 100_000;
            ms[0].rules.dynamicFeeSens = 5;
            ms[0].rules.burnBps = 100;
            ms[0].rules.lpBps = 200;
            ms[0].rules.royaltyBps = 500;
            ms[0].rules.royaltyTo = ROYALTY_A;
            ms[0].rules.protocolShareBps = 2_500;
            ms[0].rules.integrator = INTEGRATOR_A;
            ms[1] = _member(quote, address(rules1));
            ms[1].rules.maxFeePips = 50_000;
            ms[1].rules.dynamicFeeSens = 3;
            ms[1].rules.lpBps = 100;
            address subject;
            vm.prank(actors[0]);
            (famA, subject) = launcher.launch{value: 2e21}(
                IHookrLauncher.Token(address(0), "Subject A", "SUBA", SA_SUPPLY, bytes32("a")),
                address(root1),
                ms,
                deadline
            );
            SA = HookrToken(subject);
            _push(launcher.position(famA, 0).key, famA, 0, false, true, false, actors[0]);
            _push(launcher.position(famA, 1).key, famA, 1, false, true, false, actors[0]);
        }
        // Family B: existing token, root1, both members advised. Member 0 Q with HookrFeeAdvisory and session tiers;
        // member 1 native with HookrSessionAdvisory, guarded longer with a flat Snipe.
        {
            IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](2);
            ms[0] = _member(quote, address(rules1));
            ms[0].rules.burnBps = 100;
            ms[0].rules.lpBps = 200;
            ms[0].rules.royaltyBps = 500;
            ms[0].rules.royaltyTo = ROYALTY_B;
            ms[0].rules.protocolShareBps = 3_000;
            ms[0].config.advisory = address(feeAdvisory);
            ms[0].config.advisoryGasLimit = FEE_ADVISORY_GAS;
            ms[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
            ms[1] = _member(native, address(rules1));
            ms[1].rules.guardEndBlock = uint40(vm.getBlockNumber() + 80);
            ms[1].rules.snipeTaxPips = 50_000;
            ms[1].rules.maxBuyQuoteAmount = 5e19;
            ms[1].rules.protocolShareBps = 2_500;
            ms[1].config.advisory = address(sessionAdvisory);
            ms[1].config.advisoryGasLimit = SESSION_ADVISORY_GAS;
            ms[1].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
            bytes[] memory adv = new bytes[](2);
            adv[0] = abi.encode(_feeConfig(), _feeTiers());
            adv[1] = abi.encode(IHookrSessionAdvisory.Schedule(500, 2_000, 3_000, 5_000, 8_000, 900, 900, 1));
            vm.prank(actors[1]);
            (famB,) = launcher.launchAdvised{value: 2e21}(
                IHookrLauncher.Token(address(SB), "", "", 0, bytes32(0)), address(root1), ms, adv, deadline
            );
            PoolKey memory k0 = launcher.position(famB, 0).key;
            PoolKey memory k1 = launcher.position(famB, 1).key;
            _push(k0, famB, 0, false, false, true, actors[1]);
            _push(k1, famB, 1, false, false, true, actors[1]);
            frozenFeeSession = feeAdvisory.sessionTiers(k0.toId());
            frozenFeeBounds = feeAdvisory.poolBounds(k0.toId());
            frozenSession = sessionAdvisory.schedule(address(root1), k1.toId());
        }
        // Family C: existing token, root2, fee-only: its integrator's Hookr minimum override is zero and the integrator
        // approved this pool's id before the launch.
        {
            IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
            ms[0] = _member(quote, address(rules2));
            ms[0].rules.integrator = INTEGRATOR_C;
            (address c0, address c1) = address(SB) < address(Q) ? (address(SB), address(Q)) : (address(Q), address(SB));
            PoolKey memory kc = PoolKey(
                Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root2))
            );
            vm.prank(INTEGRATOR_C);
            treasury.approveMinFeePool(kc.toId(), true);
            vm.prank(actors[2]);
            (famC,) =
                launcher.launch(IHookrLauncher.Token(address(SB), "", "", 0, bytes32(0)), address(root2), ms, deadline);
            _push(launcher.position(famC, 0).key, famC, 0, false, false, false, actors[2]);
            require(root2.feeOnlyFrom(kc.toId()) == 1, "family C binds its integrator's approved zero minimum");
        }
        // Family D: SA again, root2, native: the largest protocol share and the widest dynamic fee span the reach bound
        // admits with it at sensitivity 10 (230,000,000 x 432 / (5,000 x 332) = 59,855 above the 3,000 base).
        {
            IHookrLauncher.Member[] memory ms = new IHookrLauncher.Member[](1);
            ms[0] = _member(native, address(rules2));
            ms[0].rules.maxFeePips = 62_855;
            ms[0].rules.dynamicFeeSens = 10;
            ms[0].rules.lpBps = 300;
            ms[0].rules.royaltyBps = 1_000;
            ms[0].rules.royaltyTo = ROYALTY_B;
            ms[0].rules.protocolShareBps = 5_000;
            ms[0].rules.integrator = INTEGRATOR_B;
            vm.startPrank(actors[0]);
            SA.approve(address(launcher), type(uint256).max);
            (famD,) = launcher.launch{value: 2e21}(
                IHookrLauncher.Token(address(SA), "", "", 0, bytes32(0)), address(root2), ms, deadline
            );
            vm.stopPrank();
            _push(launcher.position(famD, 0).key, famD, 0, false, true, false, actors[0]);
        }
    }

    /// @dev Mines a salt whose pair root address carries 0x2080, deploys it and seeds a wide band from the generic
    ///      locker.
    function _deployPair(IHookrPairRoot.Params memory p, bytes memory data) private returns (address root) {
        bytes32 initHash = factory.initCodeHash(p);
        bytes32 salt;
        for (uint256 i;; ++i) {
            bytes32 finalSalt = keccak256(abi.encode(address(this), bytes32(i)));
            address predicted = vm.computeCreate2Address(finalSalt, initHash, address(factory));
            if (uint160(predicted) & 0x3fff == 0x2080) {
                salt = bytes32(i);
                break;
            }
        }
        (root,) = factory.deploy(salt, p, uint160(1 << 96), data);
        pairRoots.push(root);
        pairKeys.push(IHookrPairRoot(root).poolKey());
    }

    function _deployPairs() private {
        (address c0, address c1) = address(SB) < address(Q) ? (address(SB), address(Q)) : (address(Q), address(SB));
        _deployPair(
            IHookrPairRoot.Params(Currency.wrap(c0), Currency.wrap(c1), 60, 3_000, 10_000, address(0), 0, 0, false), ""
        );
        IHookrFeeAdvisory.Config memory c = IHookrFeeAdvisory.Config({
            cap: PAIR_ADVISORY_CAP,
            surcharge: 500,
            premium0: 0,
            premium1: 200,
            maxStep: 1_000,
            minInterval: 60,
            maxTtl: 1 hours
        });
        HookrSessionTiers.Tiers memory t = HookrSessionTiers.Tiers(100, 400, 600, 1_000, 1_500, 0, 0, 1);
        address advised = _deployPair(
            IHookrPairRoot.Params(
                Currency.wrap(address(0)),
                Currency.wrap(address(SA)),
                60,
                3_000,
                5_000,
                address(feeAdvisory),
                PAIR_ADVISORY_CAP,
                PAIR_ADVISORY_GAS,
                false
            ),
            abi.encode(c, t)
        );
        frozenPairSession = feeAdvisory.sessionTiers(IHookrPairRoot(advised).poolId());
    }

    function _scopes() private view returns (P.Scope[] memory s) {
        s = new P.Scope[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            HookrRoot r = HookrRoot(address(keys[i].hooks));
            PoolId id = keys[i].toId();
            s[i] = P.Scope({
                root: address(r),
                poolId: PoolId.unwrap(id),
                configHash: r.policyHash(id),
                quoteAsset: Currency.unwrap(r.poolConfig(id).quote),
                numerator: 1,
                denominator: 1,
                subjectNumerator: 0,
                subjectDenominator: 0
            });
        }
    }

    function _deployPrograms() private {
        referrals = new HookrReferralRegistry();
        programs = new HookrPrograms(manager, address(router), BUX_OWNER, 1e30, address(referrals));
        P.Scope[] memory scopes = _scopes();
        P.Milestone[] memory none = new P.Milestone[](0);
        P.NFTMetadata memory metadata;
        P.Terms memory t;
        t.mode = P.Mode.Immediate;
        t.start = uint64(vm.getBlockTimestamp());
        t.end = uint64(vm.getBlockTimestamp() + 90 days);
        t.pointBudget = 1e30;
        t.walletPointCap = 1e29;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("invariant.immediate");
        t.name = "immediate";
        t.pointDecimals = 18;
        vm.prank(actors[0]);
        immediateId = programs.createProgram(t, scopes, none, metadata);
        P.Terms memory d;
        d.mode = P.Mode.DailySwap;
        d.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        d.end = d.start + 8 days;
        d.dailyPointBudget = 1e24;
        d.pointBudget = 8e24;
        d.walletPointCap = 8e24;
        d.rewardToken = address(Q);
        d.dailyCashBudget = 1e22;
        d.cashBudget = 8e22;
        d.walletCashCap = 8e22;
        d.attestor = ATTESTOR;
        d.reviewer = REVIEWER;
        d.reviewDelay = 6 days;
        d.sourcePolicyHash = keccak256("invariant.daily");
        d.name = "daily";
        d.pointDecimals = 18;
        vm.startPrank(actors[0]);
        Q.approve(address(programs), type(uint256).max);
        dailyId = programs.createProgram(d, scopes, none, metadata);
        vm.stopPrank();
        vm.warp(d.start + 1);
    }

    function _pmGov(bytes32 kind, bytes memory args) private {
        vm.prank(PM_OWNER);
        paymaster.queue(kind, args);
    }

    function _deployPaymaster() private {
        paymaster = new HookrPaymaster(EP, address(0), PM_OWNER, DELAY, PM_TREASURY);
        IHookrPaymaster.Policy memory pol = IHookrPaymaster.Policy({
            rebateBps: 5_000,
            perOpRebateCapWei: 0.01 ether,
            perAccountDailyRebateCapWei: 0.05 ether,
            screenSanctions: false,
            dailyRebateCapWei: 1 ether,
            maxCostWei: 0.1 ether,
            maxFeePerGasWei: 100 gwei
        });
        IHookrPaymaster.TokenConfig memory cfg = IHookrPaymaster.TokenConfig({
            enabled: true, peg: false, markupBps: 1_100, maxRateStepBps: 500, maxRateTtl: 3650 days
        });
        address[] memory quotes = new address[](2);
        quotes[0] = address(0);
        quotes[1] = address(Q);
        _pmGov(keccak256("SET_POLICY"), abi.encode(pol));
        _pmGov(keccak256("SET_TOKEN"), abi.encode(address(Q), cfg, Q_PER_ETH));
        _pmGov(keccak256("ALLOW_CALL"), abi.encode(address(router), HookrRouter.swap.selector, true));
        _pmGov(keccak256("ALLOW_CALL"), abi.encode(address(rules1), HookrRules.claim.selector, false));
        _pmGov(keccak256("ALLOW_CALL"), abi.encode(address(rules2), HookrRules.claim.selector, false));
        _pmGov(keccak256("ALLOW_CALL"), abi.encode(address(fwd), HookrForwarder.execute.selector, false));
        _pmGov(keccak256("ADD_REBATE_RULES"), abi.encode(address(rules1)));
        _pmGov(keccak256("ADD_REBATE_RULES"), abi.encode(address(rules2)));
        _pmGov(keccak256("SET_REBATE_QUOTES"), abi.encode(quotes));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.startPrank(PM_OWNER);
        paymaster.setPolicy(pol);
        paymaster.setToken(address(Q), cfg, Q_PER_ETH);
        paymaster.allowCall(address(router), HookrRouter.swap.selector, true);
        paymaster.allowCall(address(rules1), HookrRules.claim.selector, false);
        paymaster.allowCall(address(rules2), HookrRules.claim.selector, false);
        paymaster.allowCall(address(fwd), HookrForwarder.execute.selector, false);
        paymaster.addRebateRules(address(rules1));
        paymaster.addRebateRules(address(rules2));
        paymaster.setRebateQuotes(quotes);
        vm.stopPrank();
        vm.deal(PM_OWNER, 100 ether);
        vm.prank(PM_OWNER);
        paymaster.fundRebates{value: 50 ether}();
        acct0 = new SysAccount(EP, address(this));
        acct1 = new SysAccount(EP, address(this));
        SysAccount[2] memory accts = [acct0, acct1];
        for (uint256 i; i < 2; ++i) {
            address a = address(accts[i]);
            paymaster.depositCredit{value: 20 ether}(a);
            vm.deal(a, 1e24);
            Q.transfer(a, 1e27);
            SB.transfer(a, 1e27);
            vm.prank(actors[0]);
            SA.transfer(a, 1e24);
            vm.startPrank(a);
            Q.approve(address(paymaster), type(uint256).max);
            Q.approve(address(router), type(uint256).max);
            SA.approve(address(router), type(uint256).max);
            SB.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _multicallApprove(address token) private {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory d = new bytes[](1);
        t[0] = token;
        d[0] = abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max);
        multicall.exec(t, v, d);
        d[0] = abi.encodeWithSignature("approve(address,uint256)", PERMIT2, type(uint256).max);
        multicall.exec(t, v, d);
    }

    receive() external payable {}
}
