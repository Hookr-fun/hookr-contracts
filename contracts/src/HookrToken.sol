// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookrToken
/// @notice Fixed-supply ERC-20 launched through the Hookr launchpad.
///         No owner, no mint, no pause, no blacklist, no tax — the full supply is
///         minted once to the launchpad which sells it along the bonding curve and
///         seeds the Uniswap v4 pool at graduation.
contract HookrToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    /// @notice Short creator-supplied one-liner shown on token pages.
    string public tagline;
    /// @notice Optional logo URI (may be empty; UIs fall back to an initials tile).
    string public logoURI;
    /// @notice Wallet that launched this token.
    address public immutable creator;
    /// @notice The launchpad this token was launched through.
    address public immutable launchpad;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        emit Transfer(address(0), msg.sender, supply_);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        balanceOf[from] -= value;
        unchecked {
            // Cannot overflow: sum of balances bounded by totalSupply.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }
}
