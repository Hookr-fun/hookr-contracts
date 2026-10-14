// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {GasBenchFixture} from "./GasBenchFixture.sol";
import {ReleaseWiring} from "./ReleaseWiring.sol";
import {SystemHandler} from "../invariant/SystemHandler.sol";

/// @dev Logs and checks a fixture's deployment. The logs (`-vv`) list every address, the clock, the deployer's nonce,
///      each root's registration and Rules admission and the quote catalog in its order; a change to a fixture's
///      sequence of deployments or timelock waits shows as a difference between two runs' logs. The pins hold for a
///      run without --isolate, as the CI Tests step runs these suites. Under --isolate (the gas bench step, the
///      lane profile) every top-level call is a transaction that spends a nonce of the test contract, so the same
///      fixture lands elsewhere, and only the order of its creations and calls keeps those addresses: compare two
///      isolated runs' logs when a fixture's calls move.
abstract contract FixtureLog is Test {
    using PoolIdLibrary for PoolKey;

    function _log(string memory name, address a) internal pure {
        console2.log(name, a);
    }

    function _log(string memory name, uint256 v) internal pure {
        console2.log(name, v);
    }

    function _log(string memory name, bytes32 v) internal pure {
        console2.log(name, vm.toString(v));
    }

    function _logKey(string memory name, PoolKey memory k) internal pure {
        _log(string.concat(name, ".id"), PoolId.unwrap(k.toId()));
        _log(string.concat(name, ".currency0"), Currency.unwrap(k.currency0));
        _log(string.concat(name, ".currency1"), Currency.unwrap(k.currency1));
        _log(string.concat(name, ".hooks"), address(k.hooks));
    }

    function _logRoot(string memory name, HookrRegistry registry, address root, address rules) internal view {
        _log(name, root);
        _log(string.concat(name, ".flags"), uint160(root) & 0x3fff);
        _log(string.concat(name, ".registered"), registry.isRoot(root) ? 1 : 0);
        IHookrRegistry.Admission memory a = registry.admission(root, rules);
        _log(string.concat(name, ".rules"), a.implementation);
        _log(string.concat(name, ".rules.kind"), uint256(a.kind));
        _log(string.concat(name, ".rules.maxLpFeePips"), a.caps.maxLpFeePips);
        _log(string.concat(name, ".rules.maxQuoteTakePips"), a.caps.maxQuoteTakePips);
        _log(string.concat(name, ".rules.maxSubjectTakeBps"), a.caps.maxSubjectTakeBps);
        _log(string.concat(name, ".rules.gasLimit"), a.gasLimit);
        _log(string.concat(name, ".rules.phaseMask"), a.phaseMask);
        _log(string.concat(name, ".rules.feeOnly"), a.feeOnly ? 1 : 0);
        _log(string.concat(name, ".rules.failOpen"), a.failOpen ? 1 : 0);
        _log(string.concat(name, ".rules.codeHash"), a.codeHash);
        _log(string.concat(name, ".rules.schemaHash"), a.schemaHash);
    }

    function _logCatalog(HookrRegistry registry) internal view {
        address[] memory q = registry.quoteAssets();
        _log("catalog.length", q.length);
        for (uint256 i; i < q.length; ++i) {
            _log(string.concat("catalog.", vm.toString(i)), q[i]);
        }
    }

    function _logClock(address deployer) internal view {
        _log("clock.timestamp", vm.getBlockTimestamp());
        _log("clock.number", vm.getBlockNumber());
        _log("deployer.nonce", vm.getNonce(deployer));
    }

    /// @dev A root's address follows HookrRoot's code, so it is derived, never pinned: the `skip`-th CREATE2 address
    ///      from `deployer` (counting from salt 0) that carries the permission flags, registered and admitting `rules`
    ///      with the fixture's caps.
    function _checkRoot(
        HookrRegistry registry,
        address deployer,
        HookrRoot root,
        bytes32 initHash,
        uint256 skip,
        address rules,
        uint24 maxQuoteTakePips
    ) internal view {
        assertEq(ReleaseWiring.ROOT_FLAGS, root.PERMISSION_FLAGS(), "the helper mines HookrRoot's flags");
        uint256 counter = ReleaseWiring.mineSalt(deployer, initHash, ReleaseWiring.ROOT_FLAGS, 0);
        for (uint256 i; i < skip; ++i) {
            counter = ReleaseWiring.mineSalt(deployer, initHash, ReleaseWiring.ROOT_FLAGS, counter + 1);
        }
        assertEq(address(root), vm.computeCreate2Address(bytes32(counter), initHash, deployer), "the root's salt");
        assertTrue(registry.isRoot(address(root)), "registered");
        IHookrRegistry.Admission memory a = registry.admission(address(root), rules);
        assertEq(a.implementation, rules, "Rules admitted");
        assertEq(uint256(a.kind), uint256(IHookrRegistry.Kind.RULES));
        assertEq(a.codeHash, rules.codehash);
        assertEq(a.caps.maxLpFeePips, 600_000);
        assertEq(a.caps.maxQuoteTakePips, maxQuoteTakePips);
        assertEq(a.caps.maxSubjectTakeBps, 1000);
        assertEq(a.gasLimit, 2_000_000);
        assertEq(a.phaseMask, 3);
        assertFalse(a.feeOnly);
        assertFalse(a.failOpen);
    }

    function _checkCatalog(HookrRegistry registry, address[] memory expected) internal view {
        assertEq(registry.quoteAssets(), expected, "the quote catalog, in order");
    }
}

/// @notice PeripheryFixture's addresses, clock and wiring after `_setUpPeriphery`, and the keys `_launch` opens. Every
///         address the fixture deploys with CREATE follows its nonce and is pinned here, as are its clock and nonce:
///         the suites built on it, the labs, the SDK parity suite and the service's vectors and LP replay fixture
///         read these addresses and timestamps.
contract PeripheryFixtureAddressesTest is PeripheryFixture, FixtureLog {
    address internal constant MANAGER = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;
    address internal constant REGISTRY = 0x2e234DAe75C793f67A35089C9d99245E1C58470b;
    address internal constant ROUTER = 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a;
    address internal constant QUOTER = 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9;
    address internal constant LAUNCHER = 0xc7183455a4C133Ae270771860664b6B7ec320bB1;
    address internal constant RULES = 0xA4AD4f68d0b91CFD19687c881e50f3A00242828c;
    address internal constant TOKEN_A = 0x03A6a84cD762D9707A21605b548aaaB891562aAb;
    address internal constant TOKEN_B = 0xD6BbDE9174b1CdAa358d2Cf4D57D1a9F7178FBfF;

    function setUp() public {
        _setUpPeriphery();
    }

    function test_peripheryFixture_addressesClockAndWiring() public {
        _log("manager", address(manager));
        _log("registry", address(registry));
        _log("registry.delay", registry.delay());
        _log("router", address(router));
        _log("quoter", address(quoter));
        _log("launcher", address(launcher));
        _log("launcher.active", registry.isLauncher(address(launcher)) ? 1 : 0);
        _logRoot("root", registry, address(root), address(rules));
        _log("rules", address(rules));
        _log("tokenA", address(tokenA));
        _log("tokenB", address(tokenB));
        _logCatalog(registry);
        _logClock(address(this));

        assertEq(address(manager), MANAGER);
        assertEq(address(registry), REGISTRY);
        assertEq(address(router), ROUTER);
        assertEq(address(quoter), QUOTER);
        assertEq(address(launcher), LAUNCHER);
        assertEq(address(rules), RULES);
        assertEq(address(tokenA), TOKEN_A);
        assertEq(address(tokenB), TOKEN_B);
        assertEq(registry.delay(), 1 days);
        assertTrue(registry.isLauncher(address(launcher)));
        bytes32 initHash = ReleaseWiring.rootInitHash(manager, registry, address(router), address(quoter), address(0));
        _checkRoot(registry, address(this), root, initHash, 0, address(rules), 200_000);
        address[] memory catalog = new address[](2);
        (catalog[0], catalog[1]) = (TOKEN_A, TOKEN_B);
        _checkCatalog(registry, catalog);
        // Three registry delays from the start (timestamp 1); eleven deployments, the spent HookrEngagement nonce
        // included.
        assertEq(vm.getBlockTimestamp(), 1 + 3 days);
        assertEq(vm.getBlockNumber(), 1);
        assertEq(vm.getNonce(address(this)), 11);

        (bytes32 f0, PoolKey memory k0, HookrToken s0,) = _launch(true, false);
        _log("launch.subjectFirst.family", f0);
        _log("launch.subjectFirst.subject", address(s0));
        _logKey("launch.subjectFirst", k0);
        (bytes32 f1, PoolKey memory k1,,) = _launch(true, true);
        _log("launch.native.family", f1);
        _logKey("launch.native", k1);
        assertEq(address(s0), TOKEN_A, "tokenA sorts first, so it is the subject-first launch's subject");
        assertEq(Currency.unwrap(k0.currency0), TOKEN_A);
        assertEq(Currency.unwrap(k0.currency1), TOKEN_B);
        assertEq(Currency.unwrap(k1.currency0), address(0));
        assertEq(Currency.unwrap(k1.currency1), TOKEN_A);
    }
}

/// @notice The same fixture with the release's registry delay and Rules floor, as the fork and recapture suites
///         override them: the same addresses, three 30-minute delays.
contract PeripheryFixtureReleaseHooksAddressesTest is PeripheryFixture, FixtureLog {
    function _registryDelay() internal pure override returns (uint48) {
        return 30 minutes;
    }

    function _minProtocolShareBps() internal pure override returns (uint16) {
        return 2_000;
    }

    function setUp() public {
        _deployPeriphery(IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)))));
    }

    function test_peripheryFixture_releaseHooks_addressesClockAndWiring() public view {
        _log("manager", address(manager));
        _log("registry", address(registry));
        _log("registry.delay", registry.delay());
        _log("router", address(router));
        _log("quoter", address(quoter));
        _log("launcher", address(launcher));
        _logRoot("root", registry, address(root), address(rules));
        _log("rules", address(rules));
        _log("rules.minProtocolShareBps", rules.minProtocolShareBps());
        _log("tokenA", address(tokenA));
        _log("tokenB", address(tokenB));
        _logCatalog(registry);
        _logClock(address(this));

        assertEq(address(manager), 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);
        assertEq(address(registry), 0x2e234DAe75C793f67A35089C9d99245E1C58470b);
        assertEq(address(router), 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a);
        assertEq(address(quoter), 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9);
        assertEq(address(launcher), 0xc7183455a4C133Ae270771860664b6B7ec320bB1);
        assertEq(address(rules), 0xA4AD4f68d0b91CFD19687c881e50f3A00242828c);
        assertEq(address(tokenA), 0x03A6a84cD762D9707A21605b548aaaB891562aAb);
        assertEq(address(tokenB), 0xD6BbDE9174b1CdAa358d2Cf4D57D1a9F7178FBfF);
        assertEq(registry.delay(), 30 minutes);
        assertEq(rules.minProtocolShareBps(), 2_000);
        bytes32 initHash = ReleaseWiring.rootInitHash(manager, registry, address(router), address(quoter), address(0));
        _checkRoot(registry, address(this), root, initHash, 0, address(rules), 200_000);
        assertEq(vm.getBlockTimestamp(), 1 + 3 * 30 minutes);
        assertEq(vm.getNonce(address(this)), 11);
    }
}

/// @notice GasBenchFixture's addresses, clock and wiring after its setUp, with its two standing pools: the forwarder
///         deployed before the router it pins, ten catalog quotes (the two standing ones first) and three 30-minute
///         delays.
contract GasBenchFixtureAddressesTest is GasBenchFixture, FixtureLog {
    function test_gasBenchFixture_addressesClockAndWiring() public view {
        _log("manager", address(manager));
        _log("ur", ur);
        _log("permit2", permit2);
        _log("registry", address(registry));
        _log("registry.delay", registry.delay());
        _log("forwarder", address(fwd));
        _log("router", address(router));
        _log("quoter", address(quoter));
        _log("launcher", address(launcher));
        _log("launcher.active", registry.isLauncher(address(launcher)) ? 1 : 0);
        _logRoot("root", registry, address(root), address(rules));
        _log("rules", address(rules));
        _log("subject", address(subject));
        _log("quoteFee", address(quoteFee));
        _log("quoteFull", address(quoteFull));
        for (uint256 i; i < 8; ++i) {
            _log(string.concat("quotes.", vm.toString(i)), address(quotes[i]));
        }
        _logCatalog(registry);
        _log("feeFamily", feeFamily);
        _logKey("feeKey", feeKey);
        _log("fullFamily", fullFamily);
        _logKey("fullKey", fullKey);
        _logClock(address(this));

        assertEq(address(registry), 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);
        assertEq(address(fwd), 0x2e234DAe75C793f67A35089C9d99245E1C58470b);
        assertEq(address(router), 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a);
        assertEq(address(quoter), 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9);
        assertEq(address(launcher), 0xc7183455a4C133Ae270771860664b6B7ec320bB1);
        assertEq(address(rules), 0x1d1499e622D69689cdf9004d05Ec547d650Ff211);
        assertEq(address(subject), 0xA4AD4f68d0b91CFD19687c881e50f3A00242828c);
        assertEq(address(quoteFee), 0x03A6a84cD762D9707A21605b548aaaB891562aAb);
        assertEq(address(quoteFull), 0xD6BbDE9174b1CdAa358d2Cf4D57D1a9F7178FBfF);
        address[8] memory q = [
            0x15cF58144EF33af1e14b5208015d11F9143E27b9,
            0x212224D2F2d262cd093eE13240ca4873fcCBbA3C,
            0x2a07706473244BC757E10F2a9E86fB532828afe3,
            0x3D7Ebc40AF7092E3F1C81F2e996cbA5Cae2090d7,
            0xD16d567549A2a2a2005aEACf7fB193851603dd70,
            0x96d3F6c20EEd2697647F543fE6C08bC2Fbf39758,
            0x13aa49bAc059d709dd0a18D6bb63290076a702D7,
            0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240
        ];
        address[] memory catalog = new address[](10);
        (catalog[0], catalog[1]) = (address(quoteFee), address(quoteFull));
        for (uint256 i; i < 8; ++i) {
            assertEq(address(quotes[i]), q[i]);
            catalog[2 + i] = q[i];
        }
        _checkCatalog(registry, catalog);
        assertEq(registry.delay(), 30 minutes);
        bytes32 initHash = ReleaseWiring.rootInitHash(manager, registry, address(router), address(quoter), ur);
        _checkRoot(registry, address(this), root, initHash, 0, address(rules), 200_000);
        assertEq(address(feeKey.hooks), address(root));
        assertEq(address(fullKey.hooks), address(root));
        assertEq(vm.getBlockTimestamp(), 1 + 3 * 30 minutes);
        assertEq(vm.getBlockNumber(), 1);
        assertEq(vm.getNonce(address(this)), 19);
    }
}

/// @notice SystemDeploy's addresses, clock and wiring as the invariant campaign deploys it (a SystemHandler, deployed by
///         the test): both roots at the first two matching salts, every CREATE address of the handler and the launch
///         time of every pool.
contract SystemDeployAddressesTest is FixtureLog {
    using PoolIdLibrary for PoolKey;

    SystemHandler internal h;

    function setUp() public {
        h = new SystemHandler();
    }

    function test_systemDeploy_addressesClockAndWiring() public view {
        _log("handler", address(h));
        _log("manager", address(h.manager()));
        _log("feeAdapter", address(h.feeAdapter()));
        _log("registry", address(h.registry()));
        _log("forwarder", address(h.fwd()));
        _log("router", address(h.router()));
        _log("quoter", address(h.quoter()));
        _log("curated", address(h.curated()));
        _log("generic", address(h.generic()));
        _log("launcher", address(h.launcher()));
        _log("launcher.active", h.registry().isLauncher(address(h.launcher())) ? 1 : 0);
        _logRoot("root1", h.registry(), address(h.root1()), address(h.rules1()));
        _logRoot("root2", h.registry(), address(h.root2()), address(h.rules2()));
        _log("treasury", address(h.treasury()));
        _log("rules1", address(h.rules1()));
        _log("rules2", address(h.rules2()));
        _log("sessionAdvisory", address(h.sessionAdvisory()));
        _log("feeAdvisory", address(h.feeAdvisory()));
        _log("factory", address(h.factory()));
        _log("vault", address(h.vault()));
        _log("Q", address(h.Q()));
        _log("SB", address(h.SB()));
        _log("SA", address(h.SA()));
        _log("SE", address(h.SE()));
        _log("referrals", address(h.referrals()));
        _log("programs", address(h.programs()));
        _log("paymaster", address(h.paymaster()));
        _log("acct0", address(h.acct0()));
        _log("acct1", address(h.acct1()));
        _log("multicall", address(h.multicall()));
        _log("probe", address(h.probe()));
        _log("immediateId", h.immediateId());
        _log("dailyId", h.dailyId());
        _logCatalog(h.registry());
        _logFamilies();
        _logClock(address(h));
        _checkSystem();
    }

    function _logFamilies() internal view {
        _log("famA", h.famA());
        _log("famB", h.famB());
        _log("famC", h.famC());
        _log("famD", h.famD());
        _log("famE", h.famE());
        uint256 n = h.poolCount();
        _log("pools", n);
        for (uint256 i; i < n; ++i) {
            _logKey(string.concat("pool.", vm.toString(i)), h.key(i));
            _log(string.concat("pool.", vm.toString(i), ".launchedAt"), h.meta(i).launchedAt);
        }
        uint256 m = h.pairCount();
        _log("pairs", m);
        for (uint256 i; i < m; ++i) {
            _log(string.concat("pairRoot.", vm.toString(i)), h.pairRoots(i));
            _logKey(string.concat("pair.", vm.toString(i)), h.pairKey(i));
        }
    }

    function _checkSystem() internal view {
        assertEq(address(h), 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);
        assertEq(address(h.manager()), 0x104fBc016F4bb334D775a19E8A6510109AC63E00);
        assertEq(address(h.feeAdapter()), 0x037eDa3aDB1198021A9b2e88C22B464fD38db3f3);
        assertEq(address(h.registry()), 0xDDc10602782af652bB913f7bdE1fD82981Db7dd9);
        assertEq(address(h.fwd()), 0x7FdB3132Ff7D02d8B9e221c61cC895ce9a4bb773);
        assertEq(address(h.router()), 0xfD07C974e33dd1626640bA3a5acF0418FaacCA7a);
        assertEq(address(h.quoter()), 0xD76ffbd1eFF76C510C3a509fE22864688aC3A588);
        assertEq(address(h.curated()), 0x4ff05a443250A64a18C68CEdd2122cFDf3872140);
        assertEq(address(h.generic()), 0xc98D9175A32ca68C4B83dB84B4707AF82ae37cC4);
        assertEq(address(h.launcher()), 0x40b4863C923385D1632d640B097DDeA6EaB92e76);
        assertEq(address(h.treasury()), 0x794aC86b74c89e4c4f5722e8cdB15e982ecD1C92);
        assertEq(address(h.rules1()), 0x4ACAB01227c1c49b1031885DC8182740c44c4d81);
        assertEq(address(h.rules2()), 0xd2370659448fFD21B13d36B883EdaB0b6Fb0c0f7);
        assertEq(address(h.sessionAdvisory()), 0x8370f44f744910857aD1b4A399f117F8Fb630527);
        assertEq(address(h.feeAdvisory()), 0xda6719a78fa8c4b64217AfcEA5Bd8c60d2f0F587);
        assertEq(address(h.factory()), 0x0A1EB1b2d96a175608edEF666c171d351109d8AA);
        assertEq(address(h.vault()), 0xA3996282Ce23B9d0b4FdF619BE68bed88530910E);
        assertEq(address(h.Q()), 0x839E166D896412633432F1873A5D5b2A0eF01B77);
        assertEq(address(h.SB()), 0x469f432f6806a5fFb053A2f06FcB8534808b6ea1);
        assertEq(address(h.referrals()), 0xDF38721753d6f665918553db80602Edd7B6563F0);
        assertEq(address(h.programs()), 0xd98fA1c7450580E4340accF6Ea7b7A9521A6B34b);
        assertEq(address(h.paymaster()), 0xC34B9719ec6922444668e9A39b32263A8b857430);
        assertEq(address(h.acct0()), 0x376001Ad273C2d917aeFa9003144Aa0d48a144Ac);
        assertEq(address(h.acct1()), 0x3FAc7a6098E689f3cfDFf983B2De37D9ad9bAee9);
        assertEq(address(h.multicall()), 0x086308161252462e0091b84a541a5879892bBaAd);
        assertEq(address(h.probe()), 0x172d2a81D20D7Df32E83D15b4bD6AA72E97f995c);
        HookrRegistry registry = h.registry();
        bytes32 initHash = ReleaseWiring.rootInitHash(
            h.manager(), registry, address(h.router()), address(h.quoter()), address(h.curated())
        );
        _checkRoot(registry, address(h), h.root1(), initHash, 0, address(h.rules1()), 400_000);
        _checkRoot(registry, address(h), h.root2(), initHash, 1, address(h.rules2()), 400_000);
        address[] memory catalog = new address[](1);
        catalog[0] = address(h.Q());
        _checkCatalog(registry, catalog);
        // Families A to D launch after the deploy's two registry delays, Saturday 2026-11-21 11:00 in New York plus
        // two days; family E launches 900 seconds before the campaign starts, where the deploy leaves the clock.
        for (uint256 i; i < 6; ++i) {
            assertEq(h.meta(i).launchedAt, h.campaignStart() - 2 days + 2 hours, "families A to D");
        }
        assertEq(h.meta(6).launchedAt, h.campaignStart() - 900, "family E");
        assertEq(h.campaignStart(), 1_795_615_200);
        assertEq(vm.getBlockTimestamp(), h.campaignStart());
        assertEq(vm.getBlockNumber(), 70_000_000);
        assertEq(vm.getNonce(address(h)), 28);
    }
}
