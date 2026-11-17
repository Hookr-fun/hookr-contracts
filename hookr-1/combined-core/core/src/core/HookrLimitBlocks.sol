// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {HookrRulesStorage as S} from "../libraries/HookrRulesStorage.sol";
import {HookrSettings} from "../libraries/HookrSettings.sol";
import {HookrBlockCall as Call} from "../libraries/HookrBlockCall.sol";
import {IHookrBlock} from "../interfaces/IHookrBlock.sol";
import {HookrWallets} from "../libraries/HookrWallets.sol";

/// @notice Guard-time Wallet Cap and launch windows, shared by root-agnostic core instances.
/// @dev The core authenticates hook callers and writes tails. Only the separate wallet-cap namespace is mutated.
contract HookrLimitBlocks is IHookrBlock {
    uint32 private constant WALLET = 1 << 19;
    uint32 private constant WINDOWS = 1 << 23;
    uint128 private constant COLD_FIELDS = uint128(0x7ffff) | uint128(0xfff) << 85;
    uint256 private constant LANE_READ_GAS = 50_000;
    bytes4 private constant LANE_OF = 0xda500641;
    address private immutable SELF = address(this);

    error Unauthorized();
    error InvalidLimitContext();
    error BuyPaused(PoolId id, uint256 openAt);
    error SellLocked(PoolId id, uint256 openAt);
    error LiquidityLocked(PoolId id, uint256 openAt);
    error GuardWalletLimit(address wallet, uint256 actual, uint256 limit);
    error UnsupportedOut();

    modifier delegated() {
        if (address(this) == SELF) revert Unauthorized();
        _;
    }

    function blockMasks() external pure returns (uint256 hooks, uint256 cold) {
        uint256 both = WALLET | WINDOWS;
        hooks = both | uint256(WINDOWS) << 32 | uint256(WINDOWS) << 64 | uint256(WINDOWS) << 96
            | uint256(WALLET) << 128 | both << 192;
        cold = uint256(COLD_FIELDS) | both << 128;
    }

    /// @dev Pure settings canonicality is checked here; C2 checks the guard/config relation before writing Bound.
    function blockBind(PoolKey calldata, HookrTypes.PoolConfig calldata pc)
        external view delegated returns (uint256)
    {
        (uint256 context, uint128 cold, uint32 hot,) = Call.bindTail();
        HookrSettings.Settings memory settings = HookrSettings.decode(hot, cold);
        if ((settings.walletCap || settings.windows) &&
            (context & S.CTX_GUARD == 0 || pc.liquidityOwner == address(0))) revert InvalidLimitContext();
        return 0; // No LP/take maxima, charge minima, outflow, or bind-time storage write.
    }

    function blockAddLiquidity(PoolId id, address sender) external view delegated {
        (uint256 context, uint128 cold) = Call.addLiquidityTail();
        if (context & S.CTX_GUARD == 0) return;
        S.Bound storage b = S.rules().pools[id];
        uint256 opens = uint256(b.launchedAt) + uint256((cold >> 94) & 7) * 12;
        if (block.timestamp < opens && !_ownLaunch(b, sender)) revert LiquidityLocked(id, opens);
    }

    function blockQuote(HookrTypes.SwapContext calldata x, HookrTypes.SwapSimulation calldata)
        external view delegated returns (uint256 lp, uint256 take, uint256 burn, uint256 hookr)
    {
        Call.Quote memory q = Call.quoteTail();
        _identity(q.context, x);
        if (q.context & S.CTX_GUARD != 0) {
            S.Bound storage b = S.rules().pools[x.id];
            if (x.isBuy) {
                uint256 opens = uint256(b.launchedAt) + uint256((q.cold >> 85) & 511) * 12;
                if (block.timestamp < opens && !_ownLaunch(b, x.sender)) revert BuyPaused(x.id, opens);
            } else {
                uint256 opens = uint256(b.launchedAt) + uint256((q.cold >> 94) & 7) * 12;
                if (block.timestamp < opens) revert SellLocked(x.id, opens);
            }
        }
        return (q.lp, q.take, q.burn, q.hookr);
    }

    function blockSettle(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z)
        external delegated returns (uint256)
    {
        Call.Settle memory tail = Call.settleTail();
        _identity(tail.context, x);
        if (tail.context & S.CTX_STATIC != 0) revert InvalidLimitContext();
        uint256 mantissa = tail.cold & 0x3fff;
        if (tail.context & S.CTX_GUARD != 0 && x.isBuy && mantissa != 0 && tail.context & S.CTX_LAUNCH_BUY == 0) {
            if (x.authenticated || tail.context & S.CTX_LANE == 0 || !_laneLeg(x.id, x.sender)) {
                S.Bound storage b = S.rules().pools[x.id];
                mapping(address => uint256) storage bought = S.walletCap().bought[x.subject][b.launchedAt];
                uint256 amount = z.actualSubject - z.subjectBurn;
                uint256 cap = mantissa * 10 ** uint256((tail.cold >> 14) & 31);
                address wallet = x.authenticated ? x.payer : tx.origin;
                _count(bought, wallet, amount, cap);
                // R4-4 fix G (next core 10-22): a named payer that is a contract also counts against its
                // transaction's signer, so throwaway contracts with code in one transaction share their signer's cap
                // (launch-protection LP-2; a contract buying from its constructor has no code yet, NC47). An EIP-7702
                // delegated account is a wallet (HookrWallets): it signed its own delegation, so it counts alone and
                // never against the relayer or keeper that sent it (attack round 1, B-1).
                if (x.authenticated && wallet != tx.origin && !HookrWallets.isWallet(wallet)) _count(bought, tx.origin, amount, cap);
            }
        }
        return tail.protocol;
    }

    function _count(mapping(address => uint256) storage bought, address wallet, uint256 amount, uint256 cap) private {
        uint256 total = bought[wallet] + amount;
        if (total > cap) revert GuardWalletLimit(wallet, total, cap);
        bought[wallet] = total;
    }

    function blockOut(bytes calldata) external view delegated returns (bytes memory) { revert UnsupportedOut(); }

    function _identity(uint256 context, HookrTypes.SwapContext calldata x) private pure {
        if ((context & S.CTX_BUY != 0) != x.isBuy || (context & S.CTX_AUTHENTICATED != 0) != x.authenticated) {
            revert InvalidLimitContext();
        }
    }
    function _ownLaunch(S.Bound storage b, address sender) private view returns (bool) {
        return sender == b.liquidityOwner && block.timestamp == b.launchedAt;
    }
    /// @dev Root is the hook caller preserved by DELEGATECALL. Only the first ABI word is copied, never a return blob.
    function _laneLeg(PoolId id, address sender) private view returns (bool found) {
        if (sender == address(0)) return false;
        address root = msg.sender;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, LANE_OF)
            mstore(add(ptr, 4), id)
            let ok := staticcall(LANE_READ_GAS, root, ptr, 36, ptr, 32)
            if and(ok, gt(returndatasize(), 31)) { found := eq(mload(ptr), sender) }
        }
    }
}
