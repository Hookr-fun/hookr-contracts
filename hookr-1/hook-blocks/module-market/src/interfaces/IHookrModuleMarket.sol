// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {ModuleMarketTypes} from "./ModuleMarketTypes.sol";
import {IHookrBondVault} from "./IHookrBondVault.sol";
import {IHookrUsageFeeRouter} from "./IHookrUsageFeeRouter.sol";

/// @title IHookrModuleMarket
/// @notice The module registry of the bonded module marketplace: versions, installs, the exit lifecycle and
///         slashing. A registry-side sidecar beside HookrRegistry; it changes no hook.
interface IHookrModuleMarket {
    /// @notice The Hookr registry whose admissions and roots this marketplace reads.
    function registry() external view returns (IHookrRegistry);

    /// @notice The bond token ($HOOKR).
    function hookr() external view returns (IERC20);

    /// @notice One whole bond token in raw units (10 ** decimals).
    function bondUnit() external view returns (uint256);

    /// @notice The bond vault, zero until wired.
    function vault() external view returns (IHookrBondVault);

    /// @notice The usage fee router, zero until wired.
    function router() external view returns (IHookrUsageFeeRouter);

    /// @notice Who is paid the protocol's share of every usage fee: the router books the share to the protocol and
    ///         pays all of it, whenever collected, to whoever holds this role at payment time.
    function protocolRecipient() external view returns (address);

    /// @notice The version a module address was published as, or zero.
    function versionOf(address module) external view returns (uint256);

    /// @notice The full record of a version.
    function getVersion(uint256 versionId) external view returns (ModuleMarketTypes.Version memory);

    /// @notice The wallet paid the developer share of `versionId`: the module family's current owner.
    function payee(uint256 versionId) external view returns (address);

    /// @notice True while the version accepts new bond (status LISTED).
    function acceptsBond(uint256 versionId) external view returns (bool);

    /// @notice True once bonds may be withdrawn (status RELEASED or TERMINATED).
    function bondReleased(uint256 versionId) external view returns (bool);

    /// @notice Whether a pool that installed the version was bound with `rules` as its Rules, which credits the
    ///         version's usage fees as claims. Recorded at install; the router collects the version's fees only
    ///         from such a Rules, and never re-reads its registry admission, so a later revoke cannot strand them.
    function usesRules(uint256 versionId, address rules) external view returns (bool);

    /// @notice Records that the calling module is being frozen into a pool. Called by the module's `bind`.
    /// @dev Reverts, and so reverts the pool's initialization, unless the caller is a listed, bonded, open
    ///      version with no slash pending, whose registry admission for that root is no wider than its manifest,
    ///      and the root is in the middle of binding exactly `key`. Records the pool's Rules (`usesRules`).
    function recordInstall(PoolKey calldata key, HookrTypes.PoolConfig calldata config) external;
}
