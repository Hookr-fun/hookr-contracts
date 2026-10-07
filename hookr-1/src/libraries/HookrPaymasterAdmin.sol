// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrPaymaster} from "../interfaces/IHookrPaymaster.sol";

/// @dev The paymaster's stipend for a protocolFeePaid read on a Rules contract, and the admission probe's.
uint256 constant RULES_READ_GAS = 15_000;
/// @dev IHookrRules.protocolFeePaid(address,address).
bytes4 constant PROTOCOL_FEE_PAID = 0xa32701f6;

/// @title HookrPaymasterAdmin
/// @notice The paymaster's configuration paths that never run inside a user operation: token admission, keeper rate
///         moves and the rebate Rules list.
/// @dev Deployed as an external (linked) library so the paymaster stays under the EIP-170 runtime limit: it is
///      deployed through CREATE3 and linked into the paymaster's bytecode before the paymaster is deployed. The
///      paymaster reaches it by DELEGATECALL, so every function reads and writes the paymaster mappings it is passed,
///      `msg.sender` is the paymaster's caller and every event is logged by the paymaster. The paymaster checks the
///      caller's role and consumes the timelocked operation before it calls in.
library HookrPaymasterAdmin {
    /// @notice The rate a keeper's moves are bounded against, and when its window opened.
    struct RateAnchor {
        uint128 tokenPerEth;
        uint48 windowStart;
    }

    /// @dev A keeper's cumulative rate move within one window stays within maxRateStepBps of the window's anchor, so
    ///      within any RATE_WINDOW the rate stays within two compounded steps of an anchor.
    uint256 internal constant RATE_WINDOW = 1 hours;
    uint16 internal constant MAX_MARKUP_BPS = 3_000;
    uint256 internal constant MAX_REBATE_RULES = 2;
    /// @dev Gas an admitted Rules may spend on the admission probe, cold account access included.
    uint256 internal constant RULES_PROBE_GAS = 10_000;

    /// @notice Admits `token` with `config` at `initialRate` and resets its rate anchor.
    /// @dev A peg token needs 18 decimals and a rate of 1e18. Any other token needs a nonzero rate and rate TTL, a
    ///      rate step below its markup, and (1 - step)^2 * (1 + markup) >= 1.
    /// @param tokens The paymaster's token configs.
    /// @param rates The paymaster's rates.
    /// @param anchors The paymaster's rate anchors.
    /// @param token The token.
    /// @param config Its config.
    /// @param initialRate Raw token units per 1e18 wei.
    function setToken(
        mapping(address => IHookrPaymaster.TokenConfig) storage tokens,
        mapping(address => IHookrPaymaster.Rate) storage rates,
        mapping(address => RateAnchor) storage anchors,
        address token,
        IHookrPaymaster.TokenConfig calldata config,
        uint128 initialRate
    ) external {
        if (token == address(0)) {
            revert IHookrPaymaster.InvalidTokenConfig(0);
        }
        if (config.markupBps > MAX_MARKUP_BPS) revert IHookrPaymaster.InvalidTokenConfig(1);
        if (config.peg) {
            if (initialRate != 1e18 || _decimals(token) != 18) revert IHookrPaymaster.InvalidTokenConfig(2);
        } else {
            if (initialRate == 0) revert IHookrPaymaster.InvalidTokenConfig(3);
            if (config.maxRateTtl == 0) revert IHookrPaymaster.InvalidTokenConfig(4);
            // A keeper reaches two steps from an anchor within one RATE_WINDOW (the last second of a window and the
            // first of the next), so the markup must cover two compounded steps.
            if (config.maxRateStepBps >= config.markupBps) revert IHookrPaymaster.InvalidTokenConfig(5);
            unchecked {
                // step < markup <= MAX_MARKUP_BPS
                uint256 floor = 10_000 - uint256(config.maxRateStepBps);
                if (floor * floor * (10_000 + uint256(config.markupBps)) < 1e12) {
                    revert IHookrPaymaster.InvalidTokenConfig(5);
                }
            }
        }
        tokens[token] = config;
        uint48 expiresAt = config.peg ? type(uint48).max : uint48(block.timestamp) + config.maxRateTtl;
        rates[token] =
            IHookrPaymaster.Rate({tokenPerEth: initialRate, expiresAt: expiresAt, updatedAt: uint48(block.timestamp)});
        anchors[token] = RateAnchor({tokenPerEth: initialRate, windowStart: uint48(block.timestamp)});
        emit IHookrPaymaster.TokenSet(token, config, initialRate);
    }

    /// @notice A keeper moves `token`'s rate within maxRateStepBps of the current window's anchor.
    /// @dev A window opens at the first move RATE_WINDOW or more after the last window opened, anchored at the rate
    ///      then in force.
    /// @param tokens The paymaster's token configs.
    /// @param rates The paymaster's rates.
    /// @param anchors The paymaster's rate anchors.
    /// @param keepers The paymaster's keepers.
    /// @param token An enabled token that is not a peg.
    /// @param tokenPerEth The new rate, raw token units per 1e18 wei.
    /// @param ttl Seconds the rate stays valid, at most the token's maxRateTtl.
    function setRate(
        mapping(address => IHookrPaymaster.TokenConfig) storage tokens,
        mapping(address => IHookrPaymaster.Rate) storage rates,
        mapping(address => RateAnchor) storage anchors,
        mapping(address => bool) storage keepers,
        address token,
        uint128 tokenPerEth,
        uint32 ttl
    ) external {
        if (!keepers[msg.sender]) revert IHookrPaymaster.NotKeeper(msg.sender);
        IHookrPaymaster.TokenConfig memory cfg = tokens[token];
        if (!cfg.enabled || cfg.peg) revert IHookrPaymaster.UnsupportedToken(token);
        if (ttl == 0 || ttl > cfg.maxRateTtl) revert IHookrPaymaster.RateTtlTooLong(ttl, cfg.maxRateTtl);
        RateAnchor memory anchor = anchors[token];
        if (block.timestamp >= uint256(anchor.windowStart) + RATE_WINDOW) {
            anchor = RateAnchor({tokenPerEth: rates[token].tokenPerEth, windowStart: uint48(block.timestamp)});
            anchors[token] = anchor;
        }
        uint128 base = anchor.tokenPerEth;
        uint256 step = tokenPerEth > base ? tokenPerEth - base : base - tokenPerEth;
        if (tokenPerEth == 0 || step * 10_000 > uint256(base) * cfg.maxRateStepBps) {
            revert IHookrPaymaster.RateStepTooLarge(base, tokenPerEth);
        }
        uint48 expiresAt = uint48(block.timestamp) + ttl;
        rates[token] =
            IHookrPaymaster.Rate({tokenPerEth: tokenPerEth, expiresAt: expiresAt, updatedAt: uint48(block.timestamp)});
        emit IHookrPaymaster.RateSet(token, tokenPerEth, expiresAt);
    }

    /// @notice Appends `rules` to the rebate Rules list.
    /// @dev Refuses a full list, a duplicate, and a Rules whose protocolFeePaid(0, 0) fails, returns other than
    ///      32 bytes or costs more than RULES_PROBE_GAS.
    /// @param list The paymaster's rebate Rules.
    /// @param rules The Rules ledger.
    function addRebateRules(address[] storage list, address rules) external {
        uint256 n = list.length;
        if (n >= MAX_REBATE_RULES) revert IHookrPaymaster.TooManyEntries(n + 1, MAX_REBATE_RULES);
        for (uint256 i; i < n; ++i) {
            if (list[i] == rules) revert IHookrPaymaster.InvalidPolicy(10);
        }
        uint256 before = gasleft();
        bytes memory data = abi.encodeWithSelector(PROTOCOL_FEE_PAID, address(0), address(0));
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(RULES_READ_GAS, rules, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
        }
        if (!ok || size != 32 || before - gasleft() > RULES_PROBE_GAS) revert IHookrPaymaster.InvalidPolicy(11);
        list.push(rules);
        emit IHookrPaymaster.RebateRulesSet(rules, true);
    }

    /// @notice Removes `rules` from the rebate Rules list, if listed.
    /// @param list The paymaster's rebate Rules.
    /// @param rules The Rules ledger.
    function removeRebateRules(address[] storage list, address rules) external {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == rules) {
                list[i] = list[n - 1];
                list.pop();
                emit IHookrPaymaster.RebateRulesSet(rules, false);
                return;
            }
        }
    }

    function _decimals(address token) private view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x313ce567));
        if (!ok || ret.length < 32) return 0;
        return uint8(abi.decode(ret, (uint256)));
    }
}
