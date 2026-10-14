// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {ArbSysKit} from "../kit/ArbSysMock.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {HookrOwnedProfiles} from "../../src/owned/HookrOwnedProfiles.sol";
import {HookrOwnedRootFactory} from "../../src/owned/HookrOwnedRootFactory.sol";
import {HookrOwnedRootsLens} from "../../src/lens/HookrOwnedRootsLens.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice The Hookr 1 stack as PeripheryFixture builds it, with the release's 30-minute delay and 2,000-bps protocol
///         floor, plus owned roots: the Hookr treasury, a second Rules module on the shared root that pays it (the
///         release's shared Rules), the tier-1 profile book, the lens, the tier-2 factory on the shared root admitted
///         through the timelocked SET_ROOT_FACTORY, the treasury's owned-root registry, and Hookr's public standard
///         profile on the shared root.
abstract contract OwnedRootsFixture is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant CLASS = 0x2acc;
    /// @dev A dynamic fee sensitivity (of Hookr 1's 1-10 range) that turns the dynamic fee on in fixture pools.
    uint8 internal constant DYNAMIC_FEE_SENS = 3;
    /// @dev The release's protocol share floor: the shared Rules and every companion are built with it.
    uint16 internal constant PROTOCOL_FLOOR = 2_000;
    /// @dev The release registry's timelock.
    uint48 internal constant DELAY = 30 minutes;
    /// @dev The Hookr treasury's target, without code (the owner Safe in a release).
    address internal constant TARGET = address(0x7A26E8);
    Currency internal constant ETH = Currency.wrap(address(0));

    HookrTreasury internal hookrTreasury;
    /// @dev The shared root's Rules that pay the Hookr treasury, as the release's do; the fixture's `rules` pay a
    ///      code-less recipient and serve the tier-1 cases that need no treasury.
    HookrRules internal sharedRules;
    HookrOwnedProfiles internal book;
    HookrOwnedRootFactory internal factory;
    HookrOwnedRootsLens internal lens;
    bytes32 internal templateProfile;
    address internal brand = address(0xB4A9D);
    address internal stranger = address(0x5717);
    uint256 internal tokenNonce;
    uint256 internal saltNonce;

    function _registryDelay() internal pure virtual override returns (uint48) {
        return DELAY;
    }

    function _minProtocolShareBps() internal pure virtual override returns (uint16) {
        return PROTOCOL_FLOOR;
    }

    /// @dev The owned-roots stack on a fresh local PoolManager.
    function _setUpOwned() internal {
        _setUpPeriphery();
        _wireOwned();
    }

    /// @dev The same stack on an existing PoolManager (a fork's).
    function _setUpOwnedOn(IPoolManager pm) internal {
        _deployPeriphery(pm);
        _wireOwned();
    }

    function _wireOwned() private {
        ArbSysKit.install(vm, ArbSysKit.L2_BASE, vm.getBlockNumber());
        hookrTreasury = new HookrTreasury(address(this), TARGET, manager);
        sharedRules = new HookrRules(manager, registry, address(hookrTreasury), address(root), PROTOCOL_FLOOR);
        _admit(address(root), _rulesAdmission(address(sharedRules)));
        hookrTreasury.admitSource(address(sharedRules));
        book = new HookrOwnedProfiles(registry);
        lens = new HookrOwnedRootsLens(address(0));
        factory = _newFactory(500);
        _activateFactory(address(factory));
        hookrTreasury.setOwnedRootRegistry(address(registry));
        templateProfile = book.writeProfile(bytes32("standard"), _profile(F.ALL_FEATURES, true, address(this)));
        vm.deal(address(this), 1e30);
        vm.deal(trader, 1e28);
        vm.deal(brand, 1e28);
        vm.deal(stranger, 1e28);
    }

    function _newFactory(uint256 cap) internal returns (HookrOwnedRootFactory) {
        return new HookrOwnedRootFactory(
            registry,
            book,
            address(root),
            address(sharedRules),
            address(hookrTreasury),
            keccak256(type(HookrRoot).creationCode),
            keccak256(type(HookrRules).creationCode),
            cap
        );
    }

    /// @dev The timelocked SET_ROOT_FACTORY pinned to the factory's runtime codehash.
    function _activateFactory(address f) internal {
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(f, f.codehash, true));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.setRootFactory(f, f.codehash, true);
    }

    /// @dev What a launch reverts with when `rules` refuses its bind with InvalidConfig: the root's ModuleCallReverted
    ///      carrying that reason.
    function _bindRefusal(address rules_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IHookrRootEvents.ModuleCallReverted.selector,
            rules_,
            IHookrRules.bind.selector,
            abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
        );
    }

    /// @dev A queued ADMIT of `a` on `scope`, executed after the delay.
    function _admit(address scope, IHookrRegistry.Admission memory a) internal {
        ReleaseWiring.admitAfterDelay(registry, scope, a);
    }

    /// @dev The fixtures' Rules admission for `implementation` (200,000 pips of the quote).
    function _rulesAdmission(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return ReleaseWiring.rulesAdmission(HookrRules(implementation), 200_000);
    }

    function _advisoryAdmission(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: keccak256("test.owned.zero-advisory"),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
    }

    /// @dev The release's GATE admission for `implementation` at 100,000 gas.
    function _gateAdmission(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return ReleaseWiring.gateAdmission(implementation, 100_000);
    }

    /// @dev A public or owner-only profile of `owner_` on the shared root naming the treasury-paying shared Rules at
    ///      the release caps, with `mask` and the lane allowed.
    function _profile(bytes32 mask, bool publicOpening, address owner_)
        internal
        view
        returns (IHookrOwnedProfiles.Profile memory p)
    {
        p.root = address(root);
        p.rules = address(sharedRules);
        p.advisories = new address[](0);
        p.gates = new address[](0);
        p.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        p.ruleMask = mask;
        p.laneEnabled = true;
        p.publicOpening = publicOpening;
        p.owner = owner_;
    }

    /// @dev Public selections against the standard profile at its current version, owned by `owner_`.
    function _sel(address owner_, bytes32 mask) internal view returns (IHookrOwnedRootFactory.RootSelections memory) {
        return _selFor(templateProfile, owner_, mask, true);
    }

    /// @dev Selections against `profileId` at its current version (what the deployer read).
    function _selFor(bytes32 profileId, address owner_, bytes32 mask, bool publicOpening)
        internal
        view
        returns (IHookrOwnedRootFactory.RootSelections memory)
    {
        return IHookrOwnedRootFactory.RootSelections({
            profileId: profileId,
            profileVersion: book.profile(profileId).version,
            ruleMask: mask,
            publicOpening: publicOpening,
            owner: owner_
        });
    }

    /// @dev The CREATE3 address of `deployer`'s `salt` under `fac`, computed in scratch memory (no allocation).
    function _create3(address fac, address deployer, uint256 salt) internal pure returns (address predicted) {
        bytes32 proxyHash = CREATE3.PROXY_BYTECODE_HASH;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, deployer)
            mstore(add(ptr, 32), salt)
            let ns := keccak256(ptr, 64)
            mstore(ptr, fac)
            mstore8(add(ptr, 11), 0xff)
            mstore(add(ptr, 32), ns)
            mstore(add(ptr, 64), proxyHash)
            let proxy := and(keccak256(add(ptr, 11), 85), 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(ptr, proxy)
            mstore8(add(ptr, 10), 0xd6)
            mstore8(add(ptr, 11), 0x94)
            mstore8(add(ptr, 32), 0x01)
            predicted := and(keccak256(add(ptr, 10), 23), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev A salt from `start` whose CREATE3 address under `deployer`'s namespace in `fac` carries CLASS.
    function _mineFor(address fac, address deployer, uint256 start) internal pure returns (bytes32 salt) {
        for (uint256 i = start;; ++i) {
            if (uint160(_create3(fac, deployer, i)) & Hooks.ALL_HOOK_MASK == CLASS) return salt = bytes32(i);
        }
    }

    /// @dev A fresh salt for `deployer` under the fixture's factory.
    function _mine(address deployer) internal returns (bytes32) {
        return _mineFor(address(factory), deployer, _start(deployer));
    }

    /// @dev A salt whose address under `fac` does NOT carry CLASS.
    function _unmined(address fac, address deployer, uint256 start) internal pure returns (bytes32 salt) {
        for (uint256 i = start;; ++i) {
            if (uint160(_create3(fac, deployer, i)) & Hooks.ALL_HOOK_MASK != CLASS) return salt = bytes32(i);
        }
    }

    /// @dev The deploy fee `fac` takes now: the treasury's owned-root fee.
    function _fee(HookrOwnedRootFactory fac) internal view returns (uint256) {
        return fac.deployFee();
    }

    /// @dev The factory call itself, with the reviewed creation codes and `fee` attached: the next external call, so a
    ///      test may prank and expect a revert before it (read the fee first).
    function _deployCall(
        HookrOwnedRootFactory fac,
        uint256 fee,
        IHookrOwnedRootFactory.RootSelections memory sel,
        bytes32 salt
    ) internal returns (address) {
        return _deployCallWith(fac, fee, type(HookrRoot).creationCode, type(HookrRules).creationCode, sel, salt);
    }

    /// @dev The factory call with the given creation codes and `fee` attached, the next external call.
    function _deployCallWith(
        HookrOwnedRootFactory fac,
        uint256 fee,
        bytes memory rootCode,
        bytes memory rulesCode,
        IHookrOwnedRootFactory.RootSelections memory sel,
        bytes32 salt
    ) internal returns (address) {
        return fac.deploy{value: fee}(rootCode, rulesCode, sel, salt);
    }

    /// @dev `deployer` deploys `sel` with `salt` through `fac`, paying the current fee.
    function _deployWith(
        HookrOwnedRootFactory fac,
        address deployer,
        IHookrOwnedRootFactory.RootSelections memory sel,
        bytes32 salt
    ) internal returns (HookrRoot ownedRoot, HookrRules companion) {
        uint256 fee = _fee(fac);
        vm.deal(deployer, deployer.balance + fee);
        vm.prank(deployer);
        ownedRoot = HookrRoot(_deployCall(fac, fee, sel, salt));
        companion = HookrRules(fac.rulesOf(address(ownedRoot)));
    }

    /// @dev `sel.owner` deploys `sel` through the fixture's factory with a fresh salt, and holds the root at once.
    function _deployOwned(IHookrOwnedRootFactory.RootSelections memory sel)
        internal
        returns (HookrRoot ownedRoot, HookrRules companion)
    {
        return _deployWith(factory, sel.owner, sel, _mineFor(address(factory), sel.owner, _start(sel.owner)));
    }

    /// @dev A salt start unique to this call for `deployer`, so consecutive deployments mine apart.
    function _start(address deployer) internal returns (uint256) {
        return (uint256(uint160(deployer)) << 64) + (++saltNonce << 32);
    }

    /// @dev Default rules: Auto Burn, LP Rewards and Royalty; no guard, no dynamic fee.
    function _rc() internal view returns (HookrTypes.RulesConfig memory c) {
        c.maxFeePips = 3000;
        c.burnBps = 100;
        c.lpBps = 200;
        c.royaltyBps = 500;
        c.protocolShareBps = 2500;
        c.royaltyTo = royalty;
    }

    /// @dev Plain rules: no feature, only the base fee and the floor protocol share.
    function _plainRc() internal pure returns (HookrTypes.RulesConfig memory c) {
        c.maxFeePips = 3000;
        c.protocolShareBps = PROTOCOL_FLOOR;
    }

    /// @dev One native-quote member on `rulesAddr`, committing to `policyId`.
    function _nativeMember(address rulesAddr, HookrTypes.RulesConfig memory c, bytes32 policyId)
        internal
        pure
        returns (IHookrLauncher.Member memory m)
    {
        m.quote = Currency.wrap(address(0));
        m.tickSpacing = 60;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000;
        m.tickUpper = 60_000;
        m.liquidity = 1e22;
        m.amount0Max = 1e22;
        m.amount1Max = 1e22;
        m.config.rules = rulesAddr;
        m.config.baseLpFeePips = 3000;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = policyId;
        m.rules = c;
    }

    /// @dev The member with the recapture lane on at the Rules' defaults.
    function _withRecapture(IHookrLauncher.Member memory m) internal pure returns (IHookrLauncher.Member memory) {
        (m.recapture,) = IHookrRecaptureRules(m.config.rules).recaptureDefaults();
        return m;
    }

    function _members(IHookrLauncher.Member memory m) internal pure returns (IHookrLauncher.Member[] memory ms) {
        ms = new IHookrLauncher.Member[](1);
        ms[0] = m;
    }

    function _newToken() internal returns (IHookrLauncher.Token memory) {
        return IHookrLauncher.Token(address(0), "Owned", "OWN", 1e27, bytes32(++tokenNonce));
    }

    /// @dev Launches a new token against native ETH on `rootAddr` as `caller`. On an owner-only owned root only its
    ///      owner of record may open a pool, so the cases that open one there launch as that owner.
    function _launchAs(address caller, address rootAddr, IHookrLauncher.Member memory m)
        internal
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        IHookrLauncher.Token memory t = _newToken();
        IHookrLauncher.Member[] memory ms = _members(m);
        vm.prank(caller);
        (family, subject) = launcher.launch{value: m.amount0Max}(t, rootAddr, ms, vm.getBlockTimestamp());
        key = launcher.position(family, 0).key;
    }

    /// @dev Native quote is always currency0, so a buy is zeroForOne.
    function _swapParams(PoolKey memory key, bool buy, bool exactInput, uint128 amount)
        internal
        view
        returns (IHookrRouter.Swap memory p)
    {
        p = IHookrRouter.Swap(
            key,
            buy,
            exactInput ? -int128(amount) : int128(amount),
            exactInput ? 1 : uint128(1e25),
            buy ? MIN_PRICE : MAX_PRICE,
            trader,
            vm.getBlockTimestamp()
        );
    }

    function _trade(PoolKey memory key, bool buy, bool exactInput, uint128 amount)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        IHookrRouter.Swap memory p = _swapParams(key, buy, exactInput, amount);
        uint256 value = buy ? (exactInput ? amount : p.amountBound) : 0;
        if (!buy) {
            vm.prank(trader);
            HookrToken(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);
        }
        vm.prank(trader);
        (amountIn, amountOut) = router.swap{value: value}(p, address(0), new uint256[](0));
    }

    /// @dev The treasury's Hookr minimum for pools `recapture` names, set through its 30-minute timelock.
    function _setTreasuryMinimum(bool recapture, uint16 pips) internal {
        if (hookrTreasury.minFeePips(recapture) == pips) return;
        hookrTreasury.proposeMinFee(recapture, pips);
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY());
        hookrTreasury.acceptMinFee(recapture);
    }

    /// @dev The treasury's owned-root fee set through its 30-minute timelock.
    function _setDeployFee(uint256 fee) internal {
        if (hookrTreasury.ownedRootFee() == fee) return;
        hookrTreasury.proposeOwnedRootFee(fee);
        vm.warp(vm.getBlockTimestamp() + hookrTreasury.TERMS_DELAY());
        hookrTreasury.acceptOwnedRootFee();
    }

    /// @dev Anyone collects the treasury's native claim from `source`: a companion is admitted by provenance on its
    ///      first collection.
    function _collect(address source) internal returns (uint256) {
        return hookrTreasury.collect(source, ETH);
    }

    /// @dev The Hookr minimum a Hookr token's pool without an integrator binds on `rulesAddr`: zero when the Rules pay
    ///      an address without code, else the treasury's rate for the pool's kind.
    function _minimumOf(address rulesAddr, bool recapture) internal view returns (uint256 minFee) {
        address recipient = HookrRules(rulesAddr).protocolRecipient();
        if (recipient.code.length == 0) return 0;
        (,, minFee) = IHookrTreasury(recipient).feeTerms(address(0), recapture, PoolId.wrap(bytes32(0)));
    }

    /// @dev This suite's copy of `HookrRules._earnsHookr`: whether a rule of `c` can pay Hookr at least a pip of some
    ///      swap at the pool's share on base fee `base`, in which case the pool binds no Hookr minimum.
    function _earnsHookr(HookrTypes.RulesConfig memory c, uint256 base) internal pure returns (bool) {
        uint256 share = c.protocolShareBps;
        if (share == 0) return false;
        if (c.lpBps != 0 || c.burnBps != 0) return true;
        uint256 span = c.maxFeePips > base ? c.maxFeePips - base : 0;
        return span * share >= 10_000 || uint256(c.snipeTaxPips) * share >= 10_000;
    }

    /// @dev This suite's copy of `HookrRules._validate`'s quote-take bound for a configuration without Snipe: the
    ///      largest buy take (the dynamic fee share clipped to the room left by base and LP Rewards, plus LP Rewards'
    ///      and Auto Burn's protocol slices in pips rounded up and the royalty), the largest sell take (the unclipped
    ///      dynamic fee share), and `royalty + minimum`, whichever is largest, where `minFee` is the minimum the pool
    ///      binds (zero when `_earnsHookr`). Checked against HookrRules itself in OwnedRootsMinimumFee.t.sol.
    function _quoteTakeBound(HookrTypes.RulesConfig memory c, uint256 basePips, uint256 minFee)
        internal
        pure
        returns (uint256 bound)
    {
        uint256 lpSlice = (uint256(c.lpBps) * c.protocolShareBps + 99) / 100;
        uint256 lpNet = uint256(c.lpBps) * 100 - lpSlice;
        uint256 royaltyPips = lpNet * c.royaltyBps / 10_000;
        uint256 burnSlice = (uint256(c.burnBps) * c.protocolShareBps + 99) / 100;
        uint256 lpReward = lpNet - royaltyPips;
        uint256 span = uint256(c.maxFeePips) - basePips;
        uint256 room = 600_000 - basePips - lpReward;
        uint256 dynamicFee = span > room ? room : span;
        bound = dynamicFee * c.protocolShareBps / 10_000 + lpSlice + royaltyPips + burnSlice;
        uint256 sell = span * c.protocolShareBps / 10_000;
        if (sell > bound) bound = sell;
        if (royaltyPips + minFee > bound) bound = royaltyPips + minFee;
    }
}
