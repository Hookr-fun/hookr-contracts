// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";

/// @notice Implemented core surface. Off-swap module selectors belong to the composed published ABI.
interface IHookrRulesCore {
    error AlreadyBound();
    error GuardLiquidity();
    error GuardExactOutput();
    error GuardBuyLimit(uint256 actual, uint256 limit);
    /// @notice R4-3: a buy other than the launch buy within LAUNCH_REFUSAL_SECONDS of the pool's launch.
    error LaunchSecond(uint256 opensAt);
    error ReentrantClaim();
    error PotUnavailable(uint16 potBps);
    error SimulationRequired();
    error UnknownIntegrator(address integrator);
    event RulesBound(PoolId indexed id, address indexed root, bytes32 configHash, bytes config);
    event IntegratorPaid(PoolId indexed id, Currency indexed quote, address indexed integrator, uint256 amount);
    function poolManager() external view returns (IPoolManager);
    function registry() external view returns (IHookrRegistry);
    function protocolRecipient() external view returns (address);
    function trustedRoot() external view returns (address);
    function minProtocolShareBps() external view returns (uint16);
    function configSchemaHash() external pure returns (bytes32);
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data) external returns (bytes32);
    function beforeAddLiquidity(PoolId id, address sender) external view;
    function removalLockedUntil(PoolId id) external view returns (uint256);
    function beforeSwap(HookrTypes.SwapContext calldata x) external returns (HookrTypes.FeeQuote memory);
    function settleSwap(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z) external returns (uint256);
    function protocolFeePaid(address payer, Currency quote) external view returns (uint256);
    function claimable(Currency currency, address beneficiary) external view returns (uint256);
}
