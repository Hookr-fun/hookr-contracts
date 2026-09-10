// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookrMaturityTokenV1} from "./interfaces/IHookrMaturityTokenV1.sol";

/// @title HookrTokenV61
/// @notice Fixed-supply Hookr launch token with a transfer-aware acquisition clock.
/// @dev There is deliberately no owner, mint, pause, blacklist, transfer callback, or tax. The
///      acquisition clock is accounting metadata only: it cannot make a transfer fail. Incoming
///      units are timestamped at the current block and blended with the recipient's existing age.
contract HookrTokenV61 is IHookrMaturityTokenV1 {
    uint16 public constant BPS = 10_000;
    bytes32 public constant MATURITY_POLICY_HASH = keccak256("hookr.maturity.weighted-acquisition.v1");

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    string public tagline;
    string public logoURI;
    address public immutable creator;
    address public immutable launchpad;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint40) public weightedAcquiredAt;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAddress();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory tagline_,
        string memory logoURI_,
        address creator_,
        uint256 supply_
    ) {
        if (creator_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        tagline = tagline_;
        logoURI = logoURI_;
        creator = creator_;
        launchpad = msg.sender;
        totalSupply = supply_;
        balanceOf[msg.sender] = supply_;
        if (supply_ != 0) weightedAcquiredAt[msg.sender] = uint40(block.timestamp);
        emit Transfer(address(0), msg.sender, supply_);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function maturityTokenVersion() external pure returns (uint32) {
        return 1;
    }

    function maturityPolicyHash() external pure returns (bytes32) {
        return MATURITY_POLICY_HASH;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        return _transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Current age of the account's weighted balance, or zero for an empty account.
    function holdingAge(address account) public view returns (uint40) {
        uint40 acquiredAt = weightedAcquiredAt[account];
        if (balanceOf[account] == 0 || acquiredAt == 0) return 0;
        return uint40(block.timestamp) - acquiredAt;
    }

    /// @notice Linear maturity from zero to 10,000 bps over `fullMaturitySeconds`.
    function maturityBps(address account, uint40 fullMaturitySeconds) external view returns (uint16) {
        if (balanceOf[account] == 0) return 0;
        if (fullMaturitySeconds == 0) return BPS;
        uint40 age = holdingAge(account);
        if (age >= fullMaturitySeconds) return BPS;
        return uint16(Math.mulDiv(uint256(age), BPS, fullMaturitySeconds));
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        if (to == address(0)) revert ZeroAddress();

        uint256 fromBalance = balanceOf[from];
        balanceOf[from] = fromBalance - value;

        if (from != to && value != 0) {
            uint256 toBalance = balanceOf[to];
            uint40 now40 = uint40(block.timestamp);
            uint40 oldTimestamp = weightedAcquiredAt[to];

            // Express the weighted mean as an age to keep the arithmetic bounded and use mulDiv
            // for full-width multiplication. A malformed zero timestamp is treated as age zero.
            uint40 oldAge = oldTimestamp == 0 ? 0 : now40 - oldTimestamp;
            uint256 newBalance = toBalance + value;
            uint40 blendedAge = uint40(Math.mulDiv(toBalance, uint256(oldAge), newBalance));
            weightedAcquiredAt[to] = now40 - blendedAge;

            unchecked {
                balanceOf[to] = newBalance;
            }

            if (fromBalance == value) weightedAcquiredAt[from] = 0;
        } else {
            // A self-transfer must have the same checked-balance semantics as an ERC-20 transfer
            // without changing either the balance or its acquisition clock.
            unchecked {
                balanceOf[to] += value;
            }
        }

        emit Transfer(from, to, value);
        return true;
    }
}
