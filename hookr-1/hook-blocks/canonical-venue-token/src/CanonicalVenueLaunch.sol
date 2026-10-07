// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "hookr/interfaces/IHookrOwnedRoots.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrLauncher} from "hookr/periphery/HookrLauncher.sol";
import {IHookrLaunchFee} from "hookr/interfaces/IHookrLaunchFee.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {CanonicalVenueToken} from "./CanonicalVenueToken.sol";
import {CanonicalVenueTokenDeployer} from "./CanonicalVenueTokenDeployer.sol";
import {CanonicalVenueSettlement} from "./CanonicalVenueSettlement.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";

/// @title CanonicalVenueLaunch
/// @notice CanonicalVenueSettlement's `launch`, as a module the settlement creates in its
///         own constructor and reaches only by DELEGATECALL, so it runs in the settlement's context (its address,
///         storage, transient permits, balances and events) while its code stays out of the settlement's runtime.
///         This is the pattern HookrRules uses for HookrRecapture. The settlement's runtime stays under EIP-170
///         (24,576 bytes) with room for the Hookr 1 recapture pass-through.
/// @dev Storage: slot 0 is the settlement's venue mapping, declared here first with the same type, and the
///      transient slots are the settlement's own seeds, so both contracts address the same state. A direct call
///      (not a DELEGATECALL from the settlement) reverts `NotDelegated` before touching anything. Every immutable is
///      the settlement's value, passed by the settlement's constructor. The launch checks, permits and exact
///      accounting are the settlement's, unchanged; see CanonicalVenueSettlement.launch.
contract CanonicalVenueLaunch {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @dev Must stay the first state variable, mirroring CanonicalVenueSettlement's slot 0.
    mapping(address token => CanonicalVenueSettlement.Venue) private _venues;

    bytes32 private constant LOCK = keccak256("hookr.canonical-venue.lock");
    bytes32 private constant PAYER = keccak256("hookr.canonical-venue.payer");
    address private constant DEAD = address(0xdead);

    /// @notice The settlement that created this module; the only context it runs in.
    address public immutable settlement;
    IPoolManager private immutable poolManager;
    IHookrRegistry private immutable registry;
    HookrLauncher private immutable launcher;
    bytes32 private immutable launcherCodeHash;
    CanonicalVenueTokenDeployer private immutable tokenDeployer;
    address private immutable sessionAdvisory;

    error NotDelegated();
    error Reentered();
    error InvalidLaunch();
    error QuoteNotCatalogued(Currency quote);
    error AdvisoryUnsupported();
    error InvalidRecipient(address recipient);
    error InvalidValue();
    error Expired();
    error BalanceMismatch();

    event CanonicalLaunched(
        address indexed token,
        PoolId indexed poolId,
        address indexed creator,
        address root,
        bytes32 familyId,
        uint256 supply,
        uint256 retained
    );

    /// @dev Called by the settlement's constructor, which has already checked the wiring.
    constructor(
        IPoolManager manager,
        IHookrRegistry registry_,
        HookrLauncher launcher_,
        CanonicalVenueTokenDeployer deployer,
        address sessionAdvisory_
    ) {
        settlement = msg.sender;
        poolManager = manager;
        registry = registry_;
        launcher = launcher_;
        launcherCodeHash = address(launcher_).codehash;
        tokenDeployer = deployer;
        sessionAdvisory = sessionAdvisory_;
    }

    /// @notice CanonicalVenueSettlement.launch, run in the settlement's context. Same arguments, results, checks,
    ///         events and errors.
    /// @dev The launcher takes msg.value as the launch's native budget plus its launch fee (IHookrLaunchFee: zero at
    ///      deploy, at most 0.01 of the native currency, changed only through the registry owner's timelock or cleared
    ///      by its guardian), exactly, and pays the fee to the treasury's target before the pool opens. The caller pays
    ///      it here: msg.value is the native quote budget (zero for an ERC-20 quote) plus the fee the launcher reports
    ///      in this call, exactly, and all of it is forwarded, so a fee that changes before the call lands refuses the
    ///      launch (`InvalidValue`) instead of taking a different amount.
    ///      The root must be open for this settlement as the launcher's caller (`rootOpenFor`): the registry's brakes,
    ///      and for an owned root its factory's answer for the settlement. The launcher asks the same question and
    ///      refuses the family otherwise, so this refuses (`InvalidLaunch`) exactly the launches the launcher would,
    ///      before the token is deployed; for a root that is not owned it equals `rootOpen`.
    function launch(
        CanonicalVenueSettlement.TokenSpec calldata spec,
        address root,
        IHookrLauncher.Member calldata member,
        bytes calldata advisoryData,
        address supplyRecipient,
        uint256 deadline
    ) external payable returns (address token, bytes32 familyId) {
        if (address(this) != settlement) revert NotDelegated();
        if (_tget(LOCK) != 0) revert Reentered();
        _tset(LOCK, 1);
        _tset(PAYER, uint256(uint160(msg.sender)));
        if (block.timestamp > deadline) revert Expired();
        if (
            supplyRecipient == address(0) || supplyRecipient == address(this) || supplyRecipient == address(poolManager)
                || supplyRecipient == DEAD || supplyRecipient == address(launcher)
        ) revert InvalidRecipient(supplyRecipient);
        // A royalty paid to the settlement would sit in its Rules claims, which it forwards to LP recipients.
        if (member.rules.royaltyTo == address(this)) revert InvalidRecipient(address(this));
        if (
            address(launcher).codehash != launcherCodeHash || !registry.isLauncher(address(launcher))
                || !IHookrOwnedRoots(address(registry)).rootOpenFor(root, address(this))
                || address(IHookrRoot(root).poolManager()) != address(poolManager)
        ) revert InvalidLaunch();
        if (!registry.isQuote(Currency.unwrap(member.quote))) revert QuoteNotCatalogued(member.quote);
        _checkAdvisory(member.config, advisoryData.length);

        token = tokenDeployer.deploy(
            keccak256(abi.encode(msg.sender, spec.salt)),
            spec.name,
            spec.symbol,
            spec.supply,
            member.quote,
            member.tickSpacing,
            root
        );
        PoolKey memory key = CanonicalVenueToken(token).canonicalPoolKey();
        {
            (PoolKey memory launcherKey, bool available) =
                launcher.memberKey(token, member.quote, member.tickSpacing, root);
            if (!available || PoolId.unwrap(launcherKey.toId()) != PoolId.unwrap(key.toId())) revert InvalidLaunch();
        }
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        uint256 subjectBudget = tokenIs0 ? member.amount0Max : member.amount1Max;
        uint256 quoteBudget = tokenIs0 ? member.amount1Max : member.amount0Max;
        if (subjectBudget > spec.supply) revert InvalidLaunch();
        bool nativeQuote = Currency.unwrap(member.quote) == address(0);
        (uint256 launchFee,,,,) = IHookrLaunchFee(address(launcher)).launchFee();
        if (msg.value != (nativeQuote ? quoteBudget : 0) + launchFee) revert InvalidValue();
        uint256 quoteBase = HookrSettlement.balance(member.quote, address(this)) - (nativeQuote ? msg.value : 0);
        if (!nativeQuote && quoteBudget != 0) {
            IERC20 asset = IERC20(Currency.unwrap(member.quote));
            uint256 before = asset.balanceOf(address(this));
            asset.safeTransferFrom(msg.sender, address(this), quoteBudget);
            if (asset.balanceOf(address(this)) != before + quoteBudget) revert BalanceMismatch();
            asset.forceApprove(address(launcher), quoteBudget);
        }
        IERC20(token).forceApprove(address(launcher), subjectBudget);

        CanonicalVenueToken(token).setVenuePermit(address(launcher), address(poolManager), subjectBudget);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = member;
        bytes[] memory advisoryConfigs = new bytes[](1);
        advisoryConfigs[0] = advisoryData;
        address subject;
        (familyId, subject) = launcher.launchAdvised{value: msg.value}(
            IHookrLauncher.Token(token, "", "", 0, bytes32(0)), root, members, advisoryConfigs, deadline
        );
        CanonicalVenueToken(token).setVenuePermit(address(launcher), address(poolManager), 0);
        IERC20(token).forceApprove(address(launcher), 0);
        if (!nativeQuote) IERC20(Currency.unwrap(member.quote)).forceApprove(address(launcher), 0);
        if (subject != token || launcher.familyOwner(familyId) != address(this)) revert InvalidLaunch();

        _venues[token] = CanonicalVenueSettlement.Venue(
            root, member.quote, familyId, msg.sender, address(0), IHookrRoot(root).poolConfig(key.toId()).rules
        );
        uint256 retained = IERC20(token).balanceOf(address(this));
        if (retained != 0) IERC20(token).safeTransfer(supplyRecipient, retained);
        HookrSettlement.send(member.quote, msg.sender, HookrSettlement.balance(member.quote, address(this)) - quoteBase);
        _tset(LOCK, 0);
        _tset(PAYER, 0);
        emit CanonicalLaunched(token, key.toId(), msg.sender, root, familyId, spec.supply, retained);
    }

    /// @dev No advisory (every advisory field zero, no data), or `sessionAdvisory` as BEFORE_SWAP, not fail-open.
    function _checkAdvisory(HookrTypes.PoolConfig calldata pc, uint256 dataLength) private view {
        if (pc.advisory == address(0)) {
            if (pc.advisoryGasLimit != 0 || pc.advisoryPhases != 0 || pc.advisoryFailOpen || dataLength != 0) {
                revert AdvisoryUnsupported();
            }
        } else if (pc.advisory != sessionAdvisory || pc.advisoryPhases != HookrTypes.BEFORE_SWAP || pc.advisoryFailOpen)
        {
            revert AdvisoryUnsupported();
        }
    }

    function _tget(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _tset(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }
}
