// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {HookrQuoter} from "../../src/lens/HookrQuoter.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {HookrCreate3, ICREATE3Factory} from "../../script/HookrCreate3.sol";
import {HookrLink} from "../../script/HookrLink.sol";

/// @notice Test double with zefram CREATE3Factory's behaviour (solmate CREATE3):
///         hashedSalt = keccak256(abi.encodePacked(msg.sender, salt)); proxy = CREATE2(this, hashedSalt, proxy initcode);
///         the proxy then CREATEs the contract at nonce 1. Live parity with the real factory on 4663 is established
///         by the recorded eth_call vectors below and by the fork rehearsal.
contract Create3FactoryDouble {
    error DeploymentFailed();
    error InitializationFailed();

    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed) {
        bytes32 hashed = keccak256(abi.encodePacked(msg.sender, salt));
        bytes memory proxyCode = hex"67363d3d37363d34f03d5260086018f3";
        address proxy;
        assembly ("memory-safe") {
            proxy := create2(0, add(proxyCode, 32), mload(proxyCode), hashed)
        }
        if (proxy == address(0)) revert DeploymentFailed();
        deployed = _deployed(hashed);
        (bool ok,) = proxy.call{value: msg.value}(creationCode);
        if (!ok || deployed.code.length == 0) revert InitializationFailed();
    }

    function getDeployed(address deployer, bytes32 salt) external view returns (address) {
        return _deployed(keccak256(abi.encodePacked(deployer, salt)));
    }

    function _deployed(bytes32 hashed) private view returns (address) {
        address proxy = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), hashed, HookrCreate3.PROXY_INITCODE_HASH))
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }
}

/// @notice An empty contract for deploy-guard tests.
contract Empty {}

/// @notice CREATE3 deployment through zefram's CREATE3Factory: role-derived,
///         caller-bound and chain-agnostic salts, with the hook root's salt mined for the compiled root's permission bits.
///         Audit findings F-035, F-045, F-046 and F-047.
contract HookrReleaseCreate3Test is Test {
    struct Vector {
        address deployer;
        string releaseId;
        string role;
        uint256 counter;
        bytes32 salt;
        bytes32 hashed;
        address expected;
    }

    /// @dev Recorded 2026-09-22 against zefram's CREATE3Factory 0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d on chain
    ///      4663 (runtime keccak 0x13f328aa…0a794d) with read-only eth_calls: getDeployed(deployer, salt) returned
    ///      `expected` for every vector.
    function _vectors() internal pure returns (Vector[4] memory v) {
        v[0] = Vector(
            0x1111111111111111111111111111111111111111,
            "hookr-phase-one",
            "HookrRoot",
            9933,
            0xbc676ee0d9ed1e78556836c085dcdfcca64502d264a6af545bbcdb65b00026cd,
            0x927aa8d65e3e769c8d06fe9bc99430113f39bd8b7e51538619dcc783d5976cda,
            0x5d890d69BD19CB0Fe5B6d79a589ca80CD96D68cC
        );
        v[1] = Vector(
            0x1111111111111111111111111111111111111111,
            "hookr-phase-one",
            "HookrRegistry",
            0,
            0x360c55b505776f3f795821484aa069a8b8832214f25f0935159440c5a0000000,
            0x2557c0032d734428eaff62537c735cc71786760536ceee7a499be88d5185e518,
            0x4f98bAaffE86369Aae11bCE857Dc09D340187B82
        );
        v[2] = Vector(
            0x6AC7EA33F8831EA9dcC53393aAA88B25A785DBF0,
            "hookr",
            "HookrRules",
            0,
            0xf545decc7258169837091a328b50dc0d57bd391935ef77eb19a489d518000000,
            0x5155ef2d94e901f01ac649f4510590a963d21ae0f8f59f2e5dfeed42a7e5fc68,
            0xf82B284716706B53129d9EA70C7f0fDA24AC3C66
        );
        v[3] = Vector(
            0x000000000000000000000000000000000000dEaD,
            "a.b-c",
            "HookrTreasury",
            7,
            0xddc9793e99c2726f41d78cbc5ec310211f12a411aa90fff090742bb5ce000007,
            0x2699c9df944a35cb7805c8fed15661e5446df3fdd222cd5aff7c2529764810a1,
            0x80c887eFED475118420D38C37c9aB61EC6668B8c
        );
    }

    function testCreate3SaltDerivationMatchesLiveFactoryVectors() public pure {
        Vector[4] memory v = _vectors();
        for (uint256 i; i < v.length; ++i) {
            bytes32 raw = HookrCreate3.salt(v[i].releaseId, v[i].role, v[i].counter);
            assertEq(raw, v[i].salt);
            // Layout: 29 seed bytes and a 3-byte counter. The factory itself binds the salt to msg.sender.
            assertEq(uint256(raw) & 0xffffff, v[i].counter);
            assertEq(bytes29(raw), bytes29(HookrCreate3.seed(v[i].releaseId, v[i].role)));
            assertEq(HookrCreate3.hashedSalt(v[i].deployer, raw), v[i].hashed);
            // CREATE3Factory: keccak256(abi.encodePacked(msg.sender, salt)), 52 bytes, no padding.
            assertEq(v[i].hashed, keccak256(bytes.concat(bytes20(v[i].deployer), raw)));
            assertEq(HookrCreate3.addressOf(v[i].hashed), v[i].expected);
            assertEq(HookrCreate3.predict(v[i].deployer, v[i].releaseId, v[i].role, v[i].counter), v[i].expected);
        }
    }

    function testCreate3AddressIgnoresChainAndInitCode() public {
        Vector[4] memory v = _vectors();
        address before = HookrCreate3.predict(v[1].deployer, v[1].releaseId, v[1].role, 0);
        vm.chainId(1);
        assertEq(HookrCreate3.predict(v[1].deployer, v[1].releaseId, v[1].role, 0), before);
        vm.chainId(8453);
        assertEq(HookrCreate3.predict(v[1].deployer, v[1].releaseId, v[1].role, 0), before);
        // Different release id, role or deployer gives a different address.
        assertTrue(HookrCreate3.predict(v[1].deployer, "hookr-phase-two", v[1].role, 0) != before);
        assertTrue(HookrCreate3.predict(v[1].deployer, v[1].releaseId, "HookrTreasury", 0) != before);
        assertTrue(HookrCreate3.predict(address(0xBEEF), v[1].releaseId, v[1].role, 0) != before);
    }

    /// @dev The root's permission flags are 0x2acc. Recorded 2026-09-25 on chain 4663 (block 71,927,625):
    ///      getDeployed(0x1111…1111, raw) on the live factory returned `target`.
    function testCreate3RootMiningMatchesPlanner() public pure {
        (uint256 counter, bytes32 raw, address target) =
            HookrCreate3.mine(0x1111111111111111111111111111111111111111, "hookr-phase-one", "HookrRoot", 0x2acc);
        assertEq(counter, 16777);
        assertEq(raw, 0xbc676ee0d9ed1e78556836c085dcdfcca64502d264a6af545bbcdb65b0004189);
        assertEq(target, 0x3CbeD3b2BF82BA935cBDC08943d01dD5338E6AcC);
        assertEq(uint160(target) & 0x3fff, 0x2acc);
    }

    function testCreate3CounterBound() public {
        vm.expectRevert(abi.encodeWithSelector(HookrCreate3.CounterOutOfRange.selector, uint256(1 << 24)));
        this.saltExternal(1 << 24);
    }

    function saltExternal(uint256 counter) external pure returns (bytes32) {
        return HookrCreate3.salt("hookr", "HookrRoot", counter);
    }

    /// End to end against the factory double at the procedure's address: predicted addresses are the deployed
    /// addresses, another sender's use of the salt lands elsewhere, and the mined salt satisfies the root constructor.
    function testCreate3DeploysReleaseContractsAtPredictedAddresses() public {
        vm.etch(HookrCreate3.FACTORY, address(new Create3FactoryDouble()).code);
        IPoolManager manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        address deployer = address(0xD3910E);
        string memory release = "hookr-test";
        ICREATE3Factory factory = ICREATE3Factory(HookrCreate3.FACTORY);
        vm.startPrank(deployer);
        bytes32 registrySalt = HookrCreate3.salt(release, "HookrRegistry", 0);
        assertEq(
            factory.getDeployed(deployer, registrySalt), HookrCreate3.predict(deployer, release, "HookrRegistry", 0)
        );
        address registry = factory.deploy(
            registrySalt,
            abi.encodePacked(type(HookrRegistry).creationCode, abi.encode(deployer, manager, uint48(30 minutes)))
        );
        assertEq(registry, HookrCreate3.predict(deployer, release, "HookrRegistry", 0));
        assertEq(HookrRegistry(registry).owner(), deployer);
        bytes memory wiring = abi.encode(manager, registry);
        address router = factory.deploy(
            HookrCreate3.salt(release, "HookrRouter", 0),
            abi.encodePacked(type(HookrRouter).creationCode, abi.encode(manager, registry, address(0)))
        );
        address quoter = factory.deploy(
            HookrCreate3.salt(release, "HookrQuoter", 0), abi.encodePacked(type(HookrQuoter).creationCode, wiring)
        );
        vm.stopPrank();
        assertEq(router, HookrCreate3.predict(deployer, release, "HookrRouter", 0));
        assertEq(quoter, HookrCreate3.predict(deployer, release, "HookrQuoter", 0));
        // The root's flags come from the compiled root runtime, not a copied constant.
        address probe = address(0xF1A6);
        vm.etch(probe, vm.getDeployedCode("HookrRoot.sol:HookrRoot"));
        uint160 flags = HookrRoot(probe).PERMISSION_FLAGS();
        (uint256 counter, bytes32 rootSalt, address predictedRoot) =
            HookrCreate3.mine(deployer, release, "HookrRoot", flags);
        bytes memory rootInit =
            abi.encodePacked(type(HookrRoot).creationCode, abi.encode(manager, registry, router, quoter, address(0)));
        // Somebody else submitting the deployer's salt derives another address and cannot take the root's.
        address squatted = factory.getDeployed(address(0xBAD), rootSalt);
        assertTrue(squatted != predictedRoot);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        factory.deploy(rootSalt, rootInit);
        assertEq(predictedRoot.code.length, 0);
        // A counter that misses the bits fails the root's own constructor check.
        if (counter != 0) {
            vm.prank(deployer);
            vm.expectRevert();
            factory.deploy(HookrCreate3.salt(release, "HookrRoot", counter - 1), rootInit);
        }
        vm.prank(deployer);
        address root = factory.deploy(rootSalt, rootInit);
        assertEq(root, predictedRoot);
        assertEq(uint160(root) & 0x3fff, flags);
        assertEq(HookrRoot(root).router(), router);
        // The same salt cannot be used twice.
        vm.prank(deployer);
        vm.expectRevert();
        factory.deploy(rootSalt, rootInit);
    }

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function _registryAt(ICREATE3Factory factory, IPoolManager manager, address deployer, string memory release)
        internal
        returns (address)
    {
        return factory.deploy(
            HookrCreate3.salt(release, "HookrRegistry", 0),
            abi.encodePacked(type(HookrRegistry).creationCode, abi.encode(deployer, manager, uint48(30 minutes)))
        );
    }

    /// The forwarder is created BEFORE the router, with the router's CREATE3 prediction; the router's constructor
    /// then accepts it and pins its code hash. Both directions read back, and the pair is order-independent of nonces.
    function testCreate3ForwarderIsBuiltForThePredictedRouter() public {
        vm.etch(HookrCreate3.FACTORY, address(new Create3FactoryDouble()).code);
        vm.etch(PERMIT2, hex"00");
        IPoolManager manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        address deployer = address(0xD3910E);
        string memory release = "hookr-test";
        ICREATE3Factory factory = ICREATE3Factory(HookrCreate3.FACTORY);
        vm.startPrank(deployer);
        address registry = _registryAt(factory, manager, deployer, release);
        address predictedRouter = HookrCreate3.predict(deployer, release, "HookrRouter", 0);
        address forwarder = factory.deploy(
            HookrCreate3.salt(release, "HookrForwarder", 0),
            abi.encodePacked(type(HookrForwarder).creationCode, abi.encode(PERMIT2, registry, predictedRouter))
        );
        assertEq(predictedRouter.code.length, 0);
        address router = factory.deploy(
            HookrCreate3.salt(release, "HookrRouter", 0),
            abi.encodePacked(type(HookrRouter).creationCode, abi.encode(manager, registry, forwarder))
        );
        vm.stopPrank();
        assertEq(forwarder, HookrCreate3.predict(deployer, release, "HookrForwarder", 0));
        assertEq(router, predictedRouter);
        assertEq(HookrForwarder(forwarder).router(), router);
        assertEq(HookrForwarder(forwarder).registry(), registry);
        assertEq(HookrForwarder(forwarder).permit2(), PERMIT2);
        assertEq(HookrRouter(payable(router)).forwarder(), forwarder);
        assertEq(HookrRouter(payable(router)).forwarderCodeHash(), forwarder.codehash);
        assertEq(address(HookrRouter(payable(router)).registry()), registry);
    }

    /// A forwarder pinned to any other router address, or to another registry, is refused by the router's
    /// constructor, so the factory call reverts and the router address stays empty.
    function testCreate3RouterRefusesAMispairedForwarder() public {
        vm.etch(HookrCreate3.FACTORY, address(new Create3FactoryDouble()).code);
        vm.etch(PERMIT2, hex"00");
        IPoolManager manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        address deployer = address(0xD3910E);
        string memory release = "hookr-mispair";
        ICREATE3Factory factory = ICREATE3Factory(HookrCreate3.FACTORY);
        vm.startPrank(deployer);
        address registry = _registryAt(factory, manager, deployer, release);
        // Built for the router of ANOTHER release id: a different CREATE3 address.
        address wrongRouter = HookrCreate3.predict(deployer, "hookr-other", "HookrRouter", 0);
        address forwarder = factory.deploy(
            HookrCreate3.salt(release, "HookrForwarder", 0),
            abi.encodePacked(type(HookrForwarder).creationCode, abi.encode(PERMIT2, registry, wrongRouter))
        );
        bytes32 routerSalt = HookrCreate3.salt(release, "HookrRouter", 0);
        bytes memory routerInit =
            abi.encodePacked(type(HookrRouter).creationCode, abi.encode(manager, registry, forwarder));
        vm.expectRevert();
        factory.deploy(routerSalt, routerInit);
        vm.stopPrank();
        assertEq(HookrCreate3.predict(deployer, release, "HookrRouter", 0).code.length, 0);
    }

    /// The paymaster's external libraries HookrAccountCalls and HookrPaymasterAdmin are created first at their own
    /// CREATE3 addresses; the unlinked paymaster template is linked to exactly those library
    /// addresses (as `HookrLink` does) and deployed through the factory. Every runtime link reference then holds its
    /// library, which answers at that address.
    function testCreate3PaymasterLinksTheLibraryAtItsCreate3Address() public {
        vm.etch(HookrCreate3.FACTORY, address(new Create3FactoryDouble()).code);
        vm.etch(ENTRY_POINT, hex"00");
        address deployer = address(0xD3910E);
        string memory release = "hookr-test";
        ICREATE3Factory factory = ICREATE3Factory(HookrCreate3.FACTORY);
        string memory artifact = vm.readFile("out/HookrPaymaster.sol/HookrPaymaster.json");
        string memory linked = vm.parseJsonString(artifact, ".bytecode.object");
        string memory runtime = vm.parseJsonString(artifact, ".deployedBytecode.object");
        string[2] memory qualified = [HookrLink.ACCOUNT_CALLS, HookrLink.PAYMASTER_ADMIN];
        string[2] memory roles = ["HookrAccountCalls", "HookrPaymasterAdmin"];
        address[2] memory libraries;
        uint256[2] memory runtimeRefs;
        vm.startPrank(deployer);
        for (uint256 i; i < 2; ++i) {
            string memory placeholder = HookrLink.placeholder(qualified[i]);
            assertGt(vm.split(linked, placeholder).length - 1, 0);
            runtimeRefs[i] = vm.split(runtime, placeholder).length - 1;
            assertGt(runtimeRefs[i], 0);
            libraries[i] = factory.deploy(
                HookrCreate3.salt(release, roles[i], 0), vm.getCode(string.concat(roles[i], ".sol:", roles[i]))
            );
            assertEq(libraries[i], HookrCreate3.predict(deployer, release, roles[i], 0));
            linked = vm.replace(linked, placeholder, HookrLink.hex40(libraries[i]));
        }
        assertEq(vm.indexOf(linked, "__$"), type(uint256).max);
        address paymaster = factory.deploy(
            HookrCreate3.salt(release, "HookrPaymaster", 0),
            abi.encodePacked(
                vm.parseBytes(linked), abi.encode(ENTRY_POINT, address(0), deployer, uint48(1 days), deployer)
            )
        );
        vm.stopPrank();
        assertEq(paymaster, HookrCreate3.predict(deployer, release, "HookrPaymaster", 0));
        for (uint256 i; i < 2; ++i) {
            assertEq(HookrLink.occurrences(paymaster.code, libraries[i]), runtimeRefs[i]);
        }
        // The admin library's call guard holds its own CREATE3 address.
        uint256 start = vm.parseJsonUint(
            vm.readFile("out/HookrPaymasterAdmin.sol/HookrPaymasterAdmin.json"),
            ".deployedBytecode.immutableReferences.library_deploy_address[0].start"
        );
        assertEq(
            libraries[1].codehash,
            keccak256(
                HookrLink.withDeployAddress(
                    vm.getDeployedCode("HookrPaymasterAdmin.sol:HookrPaymasterAdmin"), start, libraries[1]
                )
            )
        );
        assertEq(IHookrPaymaster(paymaster).entryPoint(), ENTRY_POINT);
        assertEq(IHookrPaymaster(paymaster).treasury(), deployer);
        // The pure library answers a canonical SimpleAccount execute() at its CREATE3 address, and refuses junk.
        bytes memory callData = abi.encodeWithSelector(bytes4(0xb61d27f6), address(0xBEEF), uint256(0), hex"12345678");
        (bool ok, bytes memory decoded) = libraries[0].staticcall(abi.encodeWithSignature("decode(bytes)", callData));
        assertTrue(ok);
        assertGt(decoded.length, 0);
        (ok,) = libraries[0].staticcall(abi.encodeWithSignature("decode(bytes)", hex"b61d27"));
        assertFalse(ok);
    }

    function testLinkPlaceholderIsSolcFormat() public pure {
        bytes32 digest = keccak256("src/libraries/HookrAccountCalls.sol:HookrAccountCalls");
        string memory placeholder = HookrLink.placeholder(HookrLink.ACCOUNT_CALLS);
        assertEq(bytes(placeholder).length, 40);
        assertEq(placeholder, "__$86531ee0195f8cc0fbed990301ea95b0fe$__");
        assertEq(bytes1(digest), bytes1(0x86));
        assertEq(
            HookrLink.hex40(0x000000000022D473030F116dDEE9F6B43aC78BA3), "000000000022d473030f116ddee9f6b43ac78ba3"
        );
    }

    // ------------------------------------------------------------ deploy guards (F-035, F-045, F-046, F-047)

    /// @dev Runtime of zefram's CREATE3Factory read from chain 4663 at block 71,927,625 (keccak FACTORY_RUNTIME_KECCAK).
    function _factoryRuntime() internal pure returns (bytes memory) {
        return bytes.concat(
            hex"6080604052600436101561001257600080fd5b60003560e01c806350f1c464146100375763cdcb760a14610032576000"
            hex"80fd5b61023a565b346101445760407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc"
            hex"3601126101445760043573ffffffffffffffffffffffffffffffffffffffff81168103610144577fffffffffffffffff"
            hex"ffffffffffffffffffffffffffffffffffffffffffffff806100ea610116926100b760243590565b60609190911b7fff"
            hex"ffffffffffffffffffffffffffffffffffffff0000000000000000000000001660a05260b45260d490565b7fffffffff"
            hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffff60810160805201610178565b602061012660805160"
            hex"a020610449565b73ffffffffffffffffffffffffffffffffffffffff60405191168152f35b600080fd5b7f4e487b7100"
            hex"000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b601f7fffffffff"
            hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffe09101166080016080811067ffffffffffffffff82"
            hex"11176101ba57604052565b610149565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            hex"ffffffe0910116810190811067ffffffffffffffff8211176101ba57604052565b67ffffffffffffffff81116101ba57"
            hex"601f017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe01660200190565b60407fffff"
            hex"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126101445760043560243567ffffffff"
            hex"ffffffff811161014457366023820112156101445780600401359161029383610200565b906102a160405192836101bf"
            hex"565b83825236602485850101116101445760006020856102f49660246102cd970183870137840101526102f8565b6040"
            hex"5173ffffffffffffffffffffffffffffffffffffffff90911681529081906020820190565b0390f35b6040517fffffff"
            hex"ffffffffffffffffffffffffffffffffff0000000000000000000000003360601b166020820190815260348083019390"
            hex"935291815261033f6054826101bf565b519020908161034c61040e565b6020815191016000f59173ffffffffffffffff"
            hex"ffffffffffffffffffffffff8316156103b05760009161037f8392610449565b936020825192019034905af161039361"
            hex"056c565b50806103a6575b6103a39061059c565b90565b50803b151561039a565b60646040517f08c379a00000000000"
            hex"0000000000000000000000000000000000000000000000815260206004820152601160248201527f4445504c4f594d45"
            hex"4e545f4641494c45440000000000000000000000000000006044820152fd5b6040519061041d6040836101bf565b6010"
            hex"82527f67363d3d37363d34f03d5260086018f3000000000000000000000000000000006020830152565b73ffffffffff"
            hex"ffffffffffffffffffffffffffffff6103a39161046a61040e565b602081519101206040519060208201927fff000000"
            hex"0000000000000000000000000000000000000000000000000000000084523060601b6021840152603583015260558201"
            hex"52605581526104bf6075826101bf565b5190206040517fd6940000000000000000000000000000000000000000000000"
            hex"00000000000000602082019081529290911660601b7fffffffffffffffffffffffffffffffffffffffff000000000000"
            hex"0000000000001660228201527f0100000000000000000000000000000000000000000000000000000000000000603682"
            hex"0152601781526105506037826101bf565b51902073ffffffffffffffffffffffffffffffffffffffff1690565b3d1561"
            hex"0597573d9061057d82610200565b9161058b60405193846101bf565b82523d6000602084013e565b606090565b156105"
            hex"a357565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004"
            hex"820152601560248201527f494e495449414c495a4154494f4e5f4641494c454400000000000000000000006044820152"
            hex"fdfea2646970667358221220919f388be7e0b490f905563f98dc2db27a422bc96ac27fd994eb50e43762f95364736f6c"
            hex"634300081c0033"
        );
    }

    function _deployExternal(
        address deployer,
        string memory releaseId,
        string memory role,
        bytes memory initCode,
        bytes32 runtimeKeccak,
        bool canary
    ) external returns (address) {
        return HookrCreate3.deploy(deployer, releaseId, role, 0, initCode, runtimeKeccak, canary);
    }

    function _requireFactoryExternal() external view {
        HookrCreate3.requireFactory();
    }

    function testRealFactoryRuntimeMatchesPin() public pure {
        assertEq(keccak256(_factoryRuntime()), HookrCreate3.FACTORY_RUNTIME_KECCAK);
    }

    /// F-035: no deploy path runs unless the factory holds exactly the pinned runtime.
    function testDeployRefusesAbsentOrForeignFactory() public {
        vm.expectRevert(abi.encodeWithSelector(HookrCreate3.FactoryMismatch.selector, HookrCreate3.FACTORY, bytes32(0)));
        this._requireFactoryExternal();
        vm.etch(HookrCreate3.FACTORY, address(new Create3FactoryDouble()).code);
        bytes memory init = type(Empty).creationCode;
        bytes32 runtime = keccak256(type(Empty).runtimeCode);
        vm.expectRevert(
            abi.encodeWithSelector(
                HookrCreate3.FactoryMismatch.selector, HookrCreate3.FACTORY, HookrCreate3.FACTORY.codehash
            )
        );
        this._deployExternal(address(this), "hookr-test", "Empty", init, runtime, false);
        vm.etch(HookrCreate3.FACTORY, _factoryRuntime());
        this._requireFactoryExternal();
        address deployed = this._deployExternal(address(this), "hookr-test", "Empty", init, runtime, false);
        assertEq(deployed, HookrCreate3.predict(address(this), "hookr-test", "Empty", 0));
    }

    /// F-045: a contract qualifies by address and runtime keccak, and deploy refuses a result whose runtime differs.
    function testQualifyByAddressAndRuntimeKeccak() public {
        vm.etch(HookrCreate3.FACTORY, _factoryRuntime());
        bytes memory init = type(Empty).creationCode;
        bytes32 wrong = keccak256("some other runtime");
        vm.expectRevert();
        this._deployExternal(address(this), "hookr-test", "Empty", init, wrong, false);
        address predicted = HookrCreate3.predict(address(this), "hookr-test", "Empty", 0);
        assertEq(predicted.code.length, 0);
        bytes32 runtime = keccak256(type(Empty).runtimeCode);
        address deployed = this._deployExternal(address(this), "hookr-test", "Empty", init, runtime, false);
        assertTrue(HookrCreate3.qualified(deployed, runtime));
        assertFalse(HookrCreate3.qualified(deployed, wrong));
        assertFalse(HookrCreate3.qualified(address(0xDEAD), bytes32(0)));
        // An occupied address is never redeployed or re-qualified by the deploy path.
        vm.expectRevert(abi.encodeWithSelector(HookrCreate3.AddressOccupied.selector, deployed));
        this._deployExternal(address(this), "hookr-test", "Empty", init, runtime, false);
    }

    /// F-046: canary mode refuses production release ids and production mode refuses canary ids, so a canary can
    /// never consume a production salt; the two namespaces give different addresses.
    function testCanaryNamespaceIsSeparate() public {
        vm.etch(HookrCreate3.FACTORY, _factoryRuntime());
        bytes memory init = type(Empty).creationCode;
        bytes32 runtime = keccak256(type(Empty).runtimeCode);
        assertTrue(HookrCreate3.isCanary("canary-hookr-1"));
        assertFalse(HookrCreate3.isCanary("hookr-1"));
        assertFalse(HookrCreate3.isCanary("canary"));
        vm.expectRevert(abi.encodeWithSelector(HookrCreate3.WrongNamespace.selector, "hookr-1", true));
        this._deployExternal(address(this), "hookr-1", "Empty", init, runtime, true);
        vm.expectRevert(abi.encodeWithSelector(HookrCreate3.WrongNamespace.selector, "canary-hookr-1", false));
        this._deployExternal(address(this), "canary-hookr-1", "Empty", init, runtime, false);
        address canary = this._deployExternal(address(this), "canary-hookr-1", "Empty", init, runtime, true);
        address production = HookrCreate3.predict(address(this), "hookr-1", "Empty", 0);
        assertTrue(canary != production);
        assertEq(production.code.length, 0);
    }

    /// F-047: the miner never returns an address starting with 0x91, Uniswap's routing-declination prefix.
    function testMinerRejectsDeclinedPrefix() public pure {
        assertFalse(HookrCreate3.fits(address(uint160(0x91 << 152 | 0x2acc)), 0x2acc));
        assertTrue(HookrCreate3.fits(address(uint160(0x90 << 152 | 0x2acc)), 0x2acc));
        assertTrue(HookrCreate3.fits(address(uint160(0x92 << 152 | 0x2acc)), 0x2acc));
        assertTrue(HookrCreate3.fits(0x3CbeD3b2BF82BA935cBDC08943d01dD5338E6AcC, 0x2acc));
        assertFalse(HookrCreate3.fits(0x3CbeD3b2BF82BA935cBDC08943d01dD5338E6AcC, 0x28cc));
    }
}
