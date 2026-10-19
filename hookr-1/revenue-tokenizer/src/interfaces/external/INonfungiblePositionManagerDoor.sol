// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Uniswap v3 NonfungiblePositionManager, the subset the v3 position-NFT door uses
/// @notice The reads, transfers, permit and the one action the v3 door, its factory and the tokenizer call on the
///         NonfungiblePositionManager.
/// @dev A v3 position is an ERC-721 whose fees `collect` pays to a recipient in the pool's two ERC-20s (WETH9 for the
///      native side; a v3 pool never holds native ETH). `collect` on a position with liquidity pokes the pool first,
///      so one call collects everything owed. `permit` is ERC721Permit's: `v, r, s` over
///      `Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)` under
///      `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` with the manager's
///      name, version "1" and a per-position sequential nonce; an owner with code is asked through ERC-1271.
interface INonfungiblePositionManagerDoor {
    /// @notice What `collect` takes: the position, where to pay and the most of each side to collect.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice The v3 factory whose pools the positions sit in.
    function factory() external view returns (address);
    /// @notice The wrapped native token the manager pays the native side in.
    function WETH9() external view returns (address);
    /// @notice A position: its permit nonce and operator, its pool (the two tokens and the fee), its range, its
    ///         liquidity, its fee growth snapshots and the fees already owed to it.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    /// @notice Collects up to the maxima of a position's fees and pays them to `params.recipient`. The caller must
    ///         own or be approved for the position.
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    /// @notice The owner of a position; reverts for a token that does not exist.
    function ownerOf(uint256 tokenId) external view returns (address);
    /// @notice Moves a position; the caller must be its owner or approved for it.
    function transferFrom(address from, address to, uint256 tokenId) external;
    /// @notice Moves a position and, when `to` holds code, requires its `onERC721Received` to accept it.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    /// @notice Approves `spender` for `tokenId` on its owner's signature. Anyone may relay it; `spender` must not be
    ///         the owner.
    function permit(address spender, uint256 tokenId, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external payable;
    /// @notice `keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)")`.
    function PERMIT_TYPEHASH() external view returns (bytes32);
    /// @notice The manager's EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
