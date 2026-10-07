// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrFamilyLauncher} from "./interfaces/IHookrFamilyLauncher.sol";
import {PayLaterTerms} from "./PayLaterTerms.sol";
import {PayLaterVaultDeployer} from "./PayLaterVaultDeployer.sol";
import {IHookrRulesConfigView} from "./interfaces/IHookrRulesConfigView.sol";

/// @title Pay Later factory
/// @notice The listing gate for Pay Later vaults: pins the Hookr 1 Launcher, deploys one vault per family and
///         beneficiary at a deterministic address (through its own `PayLaterVaultDeployer`), refuses terms whose
///         per-block depth share exceeds a quarter of the reference pool's base LP fee rate or whose top guard is below
///         `minTopGuardBps`, refuses a reference band whose top is less than 10x the spot price (the band-reach rule,
///         `PayLaterTerms.MIN_BAND_REACH_BPS`), sets every vault's protocol share of premiums to `protocolShareBps`, and
///         optionally refuses a reference pool that does not charge at least `minDynamicFeeSpanPips` of dynamic fee.
///         The app would list only vaults this factory created (`isVault`).
/// @dev Holds no funds and has no owner. It replaces nothing in Hookr 1: a vault can also be deployed directly,
///      but only factory vaults carry the pinned Launcher and the dynamic fee floor.
contract PayLaterFactory {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant Q96 = 1 << 96;

    /// @notice Least band reach a listing needs, in basis points of the spot price (100,000: the band-top price at
    ///         least 10x the spot price). A constant safety limit; every vault checks it again when it takes custody.
    uint256 public constant MIN_BAND_REACH_BPS = PayLaterTerms.MIN_BAND_REACH_BPS;

    /// @notice The Hookr 1 Launcher every vault must use.
    IHookrFamilyLauncher public immutable launcher;
    /// @notice The Hookr registry read through the Launcher.
    IHookrRegistry public immutable registry;
    /// @notice Least dynamic fee span (maxFeePips - baseLpFeePips, with nonzero sensitivity) the reference pool
    ///         must charge. Zero disables the check.
    uint24 public immutable minDynamicFeeSpanPips;
    /// @notice Holds the vault's creation code and deploys vaults for this factory only (created in the constructor).
    PayLaterVaultDeployer public immutable vaultDeployer;
    /// @notice Least `topGuardBps` a listed vault may use (0 to 5,000; suggested 500).
    uint16 public immutable minTopGuardBps;
    /// @notice Protocol share of premiums every vault of this factory takes (2,000 to 5,000; suggested 2,000).
    uint16 public immutable protocolShareBps;

    /// @notice Vault created for a family and the beneficiary that listed it, or zero. An owner that receives the
    ///         family later can list it again under its own key.
    mapping(bytes32 familyId => mapping(address beneficiary => address vault)) public vaultOf;
    /// @notice Whether this factory created the address.
    mapping(address vault => bool) public isVault;

    error NotFamilyOwner(address caller);
    error VaultExists(address vault);
    error DynamicFeeTooLow(uint256 spanPips, uint256 minimum);
    error DepthShareAboveFee(uint256 depthBps, uint256 baseLpFeePips);
    error TopGuardBelowFloor(uint256 topGuardBps, uint256 floor);
    error DynamicFeeUnreadable(address rules);
    error BandReachTooShort(uint256 reachBps, uint256 minimumBps);
    error InvalidConfig();

    event VaultCreated(
        bytes32 indexed familyId, address indexed vault, address indexed beneficiary, uint8 member, bytes32 termsHash
    );

    /// @param launcher_ The Hookr 1 Launcher.
    /// @param minDynamicFeeSpanPips_ Dynamic fee floor for reference pools; zero disables it.
    /// @param minTopGuardBps_ Floor on every listed vault's top guard, 0 to 5,000.
    /// @param protocolShareBps_ Protocol share of premiums for every vault, 2,000 to 5,000.
    constructor(
        IHookrFamilyLauncher launcher_,
        uint24 minDynamicFeeSpanPips_,
        uint16 minTopGuardBps_,
        uint16 protocolShareBps_
    ) {
        if (
            address(launcher_).code.length == 0 || minDynamicFeeSpanPips_ > 600_000
                || minTopGuardBps_ > PayLaterTerms.MAX_TOP_GUARD_BPS
                || protocolShareBps_ < PayLaterTerms.MIN_PROTOCOL_SHARE_BPS
                || protocolShareBps_ > PayLaterTerms.MAX_PROTOCOL_SHARE_BPS
        ) revert InvalidConfig();
        launcher = launcher_;
        registry = launcher_.registry();
        minDynamicFeeSpanPips = minDynamicFeeSpanPips_;
        minTopGuardBps = minTopGuardBps_;
        protocolShareBps = protocolShareBps_;
        vaultDeployer = new PayLaterVaultDeployer();
    }

    /// @notice Deploys the family's vault for its current owner. Only that owner can call; it becomes the beneficiary.
    ///         Each (family, beneficiary) pair lists once.
    /// @dev The owner then calls `HookrLauncher.transferFamily(familyId, vault, claims)` and, as the vault's
    ///      beneficiary, `vault.acceptFamily()`. Nothing moves until then. Listing rule: `terms.maxBlockDepthBps` (basis points of
    ///      the band's virtual depth) may not exceed a quarter of the reference pool's base LP fee (pips / 400). At
    ///      that share, moving the price through the band costs more in LP fees than a cheaper strike on the capped
    ///      amount is worth, even for a manipulator who controls every price recording in the window. Band-reach rule
    ///      (limit A1): the reference band's top must be at least 10x the reference pool's spot price
    ///      (`bandReachBps` at least `MIN_BAND_REACH_BPS`), so a listed vault starts with its blind spot above the
    ///      band's top a 10x rally away; the vault checks the same rule again in `acceptFamily`.
    function createVault(bytes32 familyId, uint8 member, PayLaterTerms.Terms calldata terms)
        external
        returns (address vault)
    {
        if (launcher.familyOwner(familyId) != msg.sender) revert NotFamilyOwner(msg.sender);
        address existing = vaultOf[familyId][msg.sender];
        if (existing != address(0)) revert VaultExists(existing);
        if (terms.topGuardBps < minTopGuardBps) revert TopGuardBelowFloor(terms.topGuardBps, minTopGuardBps);
        _checkListing(familyId, member, terms);
        vault = vaultDeployer.deploy(launcher, familyId, member, msg.sender, terms, protocolShareBps);
        vaultOf[familyId][msg.sender] = vault;
        isVault[vault] = true;
        emit VaultCreated(familyId, vault, msg.sender, member, PayLaterTerms.hash(terms));
    }

    /// @notice Every creator knob's lower bound, upper bound and suggested default (see `PayLaterTerms.bounds`).
    /// @dev Beyond these, the factory refuses `maxBlockDepthBps * 400 > baseLpFeePips` of the reference pool. Unit caps
    ///      and `minPremium` have no token-independent default and read zero in `defaults`.
    function termsBounds()
        external
        pure
        returns (PayLaterTerms.Terms memory lo, PayLaterTerms.Terms memory hi, PayLaterTerms.Terms memory defaults)
    {
        return PayLaterTerms.bounds();
    }

    /// @notice The deploy-time knobs' bounds and suggested defaults: the top guard floor and the protocol share of
    ///         premiums (each as lower bound, upper bound, default).
    function factoryBounds()
        external
        pure
        returns (uint16[3] memory topGuardFloor, uint16[3] memory premiumShare, uint24[3] memory dynamicFeeSpan)
    {
        topGuardFloor = [
            PayLaterTerms.MIN_TOP_GUARD_BPS, PayLaterTerms.MAX_TOP_GUARD_BPS, PayLaterTerms.DEFAULT_TOP_GUARD_FLOOR_BPS
        ];
        premiumShare = [
            PayLaterTerms.MIN_PROTOCOL_SHARE_BPS,
            PayLaterTerms.MAX_PROTOCOL_SHARE_BPS,
            PayLaterTerms.DEFAULT_PROTOCOL_SHARE_BPS
        ];
        dynamicFeeSpan = [uint24(0), uint24(600_000), uint24(0)];
    }

    /// @notice Address `createVault` would deploy for these arguments.
    function predictVault(bytes32 familyId, uint8 member, address beneficiary, PayLaterTerms.Terms calldata terms)
        external
        view
        returns (address)
    {
        return vaultDeployer.predict(launcher, familyId, member, beneficiary, terms, protocolShareBps);
    }

    /// @notice The reference band's reach now: the subject's band-top price over the reference pool's spot price, in
    ///         basis points, rounded down, normalized exactly as the vault normalizes them (`PayLaterVault.anchorCeiling`
    ///         and its spot price). `createVault` and `PayLaterVault.acceptFamily` refuse a reach below
    ///         `MIN_BAND_REACH_BPS`.
    function bandReachBps(bytes32 familyId, uint8 member) public view returns (uint256) {
        IHookrFamilyLauncher.Position memory p = launcher.position(familyId, member);
        PoolId id = p.key.toId();
        HookrTypes.PoolConfig memory pc = IHookrRoot(address(p.key.hooks)).poolConfig(id);
        (uint160 sqrtPriceX96,,,) = launcher.poolManager().getSlot0(id);
        if (sqrtPriceX96 == 0) revert InvalidConfig();
        bool subjectIs0 = pc.subject == p.key.currency0;
        uint256 top = subjectIs0
            ? uint256(TickMath.getSqrtPriceAtTick(p.tickUpper))
            : FullMath.mulDivRoundingUp(Q96, Q96, TickMath.getSqrtPriceAtTick(p.tickLower));
        uint256 spot = subjectIs0 ? uint256(sqrtPriceX96) : FullMath.mulDivRoundingUp(Q96, Q96, sqrtPriceX96);
        return PayLaterTerms.bandReachBps(top, spot);
    }

    function _checkListing(bytes32 familyId, uint8 member, PayLaterTerms.Terms calldata terms) private view {
        PoolKey memory key = launcher.position(familyId, member).key;
        PoolId id = key.toId();
        HookrTypes.PoolConfig memory pc = IHookrRoot(address(key.hooks)).poolConfig(id);
        if (uint256(terms.maxBlockDepthBps) * 400 > pc.baseLpFeePips) {
            revert DepthShareAboveFee(terms.maxBlockDepthBps, pc.baseLpFeePips);
        }
        uint256 reach = bandReachBps(familyId, member);
        if (reach < MIN_BAND_REACH_BPS) revert BandReachTooShort(reach, MIN_BAND_REACH_BPS);
        if (minDynamicFeeSpanPips == 0) return;
        try IHookrRulesConfigView(pc.rules).config(id) returns (HookrTypes.RulesConfig memory rc) {
            uint256 span = rc.maxFeePips > pc.baseLpFeePips ? rc.maxFeePips - pc.baseLpFeePips : 0;
            if (rc.dynamicFeeSens == 0 || span < minDynamicFeeSpanPips) {
                revert DynamicFeeTooLow(span, minDynamicFeeSpanPips);
            }
        } catch {
            revert DynamicFeeUnreadable(pc.rules);
        }
    }
}
