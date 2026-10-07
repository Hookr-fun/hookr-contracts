// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrSwapRewardMinter} from "./interfaces/IHookrSwapRewardMinter.sol";
import {HookrSwapRewardMinter} from "./HookrSwapRewardMinter.sol";

/// @title Hookr swap reward minter factory
/// @notice Deploys reward programmes and attests them. The advisory binds only minters this factory created, so a
///         pool can never be pointed at look-alike code.
/// @dev The protocol share inside every slice is this factory's immutable, not a creator input. It is bounded below
///      by the house protocol floor (2,000 bps, the release `minProtocolShareBps`) and above by the same 50% ceiling as
///      every other Hookr add-on; the owner picks the rate between them when deploying the factory. CREATE2 salts are bound to the caller, so no one can squat a
///      creator's predicted minter address. The factory has no owner and holds nothing.
contract HookrSwapRewardMinterFactory {
    /// @notice The house protocol floor: the smallest share any fee-charging Hookr rule may pay the protocol.
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice The protocol share ceiling, the same 50% every Hookr add-on keeps.
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice The launch default protocol share: the floor.
    uint16 public constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice The protocol share every minter from this factory applies to its funded slices.
    uint16 public immutable protocolShareBps;
    /// @notice Whether this factory created the address.
    mapping(address minter => bool) public isMinter;

    error InvalidShare(uint16 share);

    /// @notice A reward programme was created.
    event MinterDeployed(
        address indexed minter,
        address indexed creator,
        PoolId indexed poolId,
        IHookrSwapRewardMinter.Mode mode,
        address rewardToken,
        bytes32 salt
    );

    /// @param protocolShareBps_ The protocol share, from 2,000 to 5,000 bps.
    constructor(uint16 protocolShareBps_) {
        if (protocolShareBps_ < MIN_PROTOCOL_SHARE_BPS || protocolShareBps_ > MAX_PROTOCOL_SHARE_BPS) {
            revert InvalidShare(protocolShareBps_);
        }
        protocolShareBps = protocolShareBps_;
    }

    /// @notice Deploys and attests one reward programme. The minter constructor validates every parameter.
    /// @param p The programme parameters.
    /// @param salt Caller-chosen salt; the effective CREATE2 salt also binds the caller.
    /// @return minter The new programme.
    function deploy(IHookrSwapRewardMinter.Params calldata p, bytes32 salt) external returns (address minter) {
        minter = address(new HookrSwapRewardMinter{salt: _salt(msg.sender, salt)}(p, protocolShareBps));
        isMinter[minter] = true;
        emit MinterDeployed(minter, msg.sender, p.poolId, p.mode, p.rewardToken, salt);
    }

    /// @notice The address `deploy(p, salt)` called by `creator` would produce.
    function predict(address creator, IHookrSwapRewardMinter.Params calldata p, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(HookrSwapRewardMinter).creationCode, abi.encode(p, protocolShareBps)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(creator, salt), initHash))))
        );
    }

    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
