// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IHookrLogLock
/// @notice Opens a Chop log for a token, seeds its CHOP pair and holds the staked liquidity until an unlock time.
interface IHookrLogLock {
    /// @notice What `open` takes.
    /// @param token The token to wrap into a log.
    /// @param tokenAmount The amount of `token` to wrap. All of it is paired.
    /// @param chopAmount The amount of CHOP to pair against the wrapped tokens. With `tokenAmount`, it sets the
    /// pair's opening price.
    /// @param beneficiary Collects the position's rewards and receives its stake at release.
    /// @param unlockTime The first second at which the stake can be released. `type(uint64).max` never unlocks.
    /// @param deadline The last second at which this call may land.
    struct OpenParams {
        address token;
        uint256 tokenAmount;
        uint256 chopAmount;
        address beneficiary;
        uint64 unlockTime;
        uint256 deadline;
    }

    /// @notice A locked stake.
    /// @param log The log opened for the token.
    /// @param staking The log's staking token, which this contract holds.
    /// @param beneficiary Collects rewards and receives the stake at release.
    /// @param unlockTime The first second at which the stake can be released.
    /// @param staked The amount of staking tokens locked at open.
    /// @param released Whether the stake has been sent to the beneficiary.
    struct Position {
        address log;
        address staking;
        address beneficiary;
        uint64 unlockTime;
        uint256 staked;
        bool released;
    }

    /// @notice A log was opened and its staked liquidity locked.
    event Opened(
        uint256 indexed id,
        address indexed token,
        address indexed log,
        address beneficiary,
        uint64 unlockTime,
        uint256 tokenAmount,
        uint256 chopAmount,
        uint256 staked
    );

    /// @notice A position's rewards were paid to its beneficiary.
    event Collected(uint256 indexed id, address indexed token, address indexed beneficiary, uint256 amount);

    /// @notice A position's stake was released to its beneficiary.
    event Released(uint256 indexed id, address indexed beneficiary, uint256 staked);

    /// @notice A position's beneficiary changed.
    event BeneficiarySet(uint256 indexed id, address indexed previous, address indexed beneficiary);

    /// @notice A position's unlock time moved later.
    event Extended(uint256 indexed id, uint64 previous, uint64 unlockTime);

    /// @notice Chop's index manager names no CHOP token, so no canonical log can be opened through it.
    error NoCanonicalConfig();
    /// @notice The partner share is above Chop's limit, or set without a partner.
    error InvalidPartner();
    /// @notice An address argument is zero.
    error ZeroAddress();
    /// @notice An amount argument is zero.
    error ZeroAmount();
    /// @notice The deadline has passed.
    error Expired();
    /// @notice The unlock time is not in the future, or not later than the one it replaces.
    error InvalidUnlockTime();
    /// @notice The log is not registered to this contract, so it cannot make the first wrap.
    error NotCreator();
    /// @notice Wrapping minted nothing, or the pair minted no liquidity.
    error NothingMinted();
    /// @notice The caller is not the position's beneficiary.
    error NotBeneficiary();
    /// @notice The position is still locked.
    error Locked();
    /// @notice The position does not exist.
    error NoPosition();
    /// @notice The position's stake was already released.
    error AlreadyReleased();

    /// @notice Opens a log for `params.token`, pairs it with CHOP, stakes the liquidity and locks the stake.
    /// @dev The caller approves this contract for `tokenAmount` of the token and `chopAmount` of CHOP first.
    /// Reverts if any wrapped token or liquidity token would be left outside the lock.
    /// @return id The position's id.
    /// @return log The log opened for the token.
    /// @return staked The amount of staking tokens locked.
    function open(OpenParams calldata params) external returns (uint256 id, address log, uint256 staked);

    /// @notice Claims a position's matured rewards and pays them to its beneficiary.
    /// @dev Only the beneficiary. Works before and after the unlock time, and after release.
    function collect(uint256 id) external;

    /// @notice Sends a position's stake to its beneficiary once the unlock time has passed.
    /// @dev Only the beneficiary. Collects first.
    function release(uint256 id) external;

    /// @notice Hands a position to another beneficiary.
    /// @dev Only the beneficiary.
    function setBeneficiary(uint256 id, address beneficiary) external;

    /// @notice Moves a position's unlock time later. It can never move earlier.
    /// @dev Only the beneficiary.
    function extend(uint256 id, uint64 unlockTime) external;

    /// @notice A position by id.
    function positions(uint256 id)
        external
        view
        returns (address log, address staking, address beneficiary, uint64 unlockTime, uint256 staked, bool released);

    /// @notice The number of positions ever opened. Ids run from 1.
    function count() external view returns (uint256);
}
