// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManagerDoor} from "./IPositionManagerDoor.sol";

/// @title Hookr position NFT door, part of the HookRevenue Tokenizer
/// @notice One locked bundle of Uniswap v4 position NFTs whose fees flow to a HookRevenue Tokenizer revenue token.
/// @dev A door is created by HookrPositionNftDoorFactory in one transaction: deploy, receive every listed NFT from the
///      PositionManager, then `activate`. From then on nothing about it can change: the NFT list, the revenue token and the
///      unlock time are fixed, there is no owner, no pause and no sweep of listed principal. Anyone may `pull` (collect
///      fees and forward them to the revenue token) and, once the unlock time has passed, anyone may `release`: each NFT
///      gets a final strict fee collection and goes back to the account that deposited it; an NFT whose collection
///      fails stays in the door and can be released later, without holding the others.
interface IHookrPositionNftDoor {
    // ------------------------------------------------------------------ events

    /// @notice The door has every listed NFT and is live.
    event Activated(address indexed revenueToken, uint64 unlockAt, uint256[] tokenIds, address[] assets);

    /// @notice A position's fees were collected into the door.
    event Collected(uint256 indexed tokenId);

    /// @notice A position's fee collection reverted (or ran past the per-collection gas cap); the other positions were
    ///         still collected.
    event CollectFailed(uint256 indexed tokenId, bytes reason);

    /// @notice Everything the door held of `asset` went to the revenue token.
    event Forwarded(address indexed asset, uint256 amount);

    /// @notice The revenue token refused `amount` of `asset`; it stays in the door until a later `pull` gets it through.
    event ForwardFailed(address indexed asset, uint256 amount);
    /// @notice `asset`'s `balanceOf` did not answer within `BALANCE_GAS`; the asset was skipped this time.
    event BalanceReadFailed(address indexed asset);
    /// @notice `amount` of `asset`, which the door does not list, was forwarded to the revenue token.
    event UnlistedForwarded(address indexed asset, uint256 amount);

    /// @notice A position NFT went back to its depositor.
    event Released(uint256 indexed tokenId, address indexed depositor);

    /// @notice A position's final collection failed during `release`, so this NFT stayed in the door; `release` can be
    ///         called again for it. The matching `CollectFailed` carries the reason.
    event ReleaseHeld(uint256 indexed tokenId);

    /// @notice An NFT that is not the door's principal went out through `rescueUnlisted`: one that was never on the
    ///         list to the door's creator, a released one back to its depositor.
    event UnlistedReturned(uint256 indexed tokenId, address indexed to);

    // ------------------------------------------------------------------ errors

    /// @notice The revenue token address is zero.
    error RevenueTokenZero();
    /// @notice The unlock time is not in the future (and not FOREVER).
    error UnlockNotInFuture(uint64 unlockAt, uint256 now_);
    /// @notice The NFT list is empty.
    error NoPositions();
    /// @notice The NFT list is longer than MAX_POSITIONS.
    error TooManyPositions(uint256 count, uint256 max);
    /// @notice A token id appears twice in the list.
    error DuplicateToken(uint256 tokenId);
    /// @notice Only the factory may call this.
    error OnlyFactory();
    /// @notice Only the PositionManager may hand NFTs to the door.
    error OnlyPositionManager();
    /// @notice The door only accepts NFTs while it is being created.
    error NotAccepting();
    /// @notice The NFT is not on the door's list.
    error NotListed(uint256 tokenId);
    /// @notice The NFT is on the door's list, so it is principal and only `release` moves it.
    error Listed(uint256 tokenId);
    /// @notice The NFT was already received.
    error AlreadyReceived(uint256 tokenId);
    /// @notice The door never received this listed NFT, so it cannot activate.
    error NotReceived(uint256 tokenId);
    /// @notice The door does not own this NFT.
    error NotOwned(uint256 tokenId);
    /// @notice A listed position has no liquidity at activation, so it could never earn.
    error NoLiquidity(uint256 tokenId);
    /// @notice The door is already active.
    error AlreadyActive();
    /// @notice The door is not active yet.
    error NotActive();
    /// @notice Every NFT has gone back to its depositor.
    error AlreadyReleased();
    /// @notice The call re-entered the door.
    error Reentered();
    /// @notice Too little gas is left to give the next position's collection its full cap.
    error InsufficientGas(uint256 tokenId, uint256 gasLeft, uint256 needed);
    /// @notice The unlock time has not passed.
    error StillLocked(uint64 unlockAt, uint256 now_);
    /// @notice The door is locked forever; it never releases.
    error LockedForever();
    /// @notice `release` moved no NFT because every remaining position's final collection failed; `tokenId` and
    ///         `reason` are the first failure's.
    error NoneReleased(uint256 tokenId, bytes reason);
    /// @notice `asset` is native ETH or one of the door's assets: `pull` forwards those.
    error ListedAsset(address asset);
    /// @notice The door holds nothing of `asset`, or its balance cannot be read.
    error NothingToForward(address asset);
    /// @notice `asset` refused the transfer to the revenue token.
    error ForwardRefused(address asset);

    // ------------------------------------------------------------------ constants

    /// @notice The unlock value that means the NFTs never come back: type(uint64).max.
    function FOREVER() external view returns (uint64);

    /// @notice The most position NFTs one door can hold: 64. Creation, `pull` and `release` are each one transaction
    ///         over the whole list, and Robinhood Chain 4663 caps a transaction at 32,000,000 gas; 64 positions keep
    ///         every one of them well inside it (a release of 64 needs about 15M). A revenue token can take several
    ///         doors.
    function MAX_POSITIONS() external view returns (uint256);

    /// @notice The most gas one position's fee collection may use: 1,500,000. A collection on a live Hookr pool runs in
    ///         about 131k cold; this is over ten times that, so no honest hook is cut off, while a hook that burns gas
    ///         can cost a `pull` at most this much per position.
    function COLLECT_GAS_CAP() external view returns (uint256);

    /// @notice Gas kept back for the door's own work between the floor check and the collection call: 120,000.
    function COLLECT_GAS_MARGIN() external view returns (uint256);

    /// @notice The least gas that must be left before each position's collection starts: enough for the call to receive
    ///         its full `COLLECT_GAS_CAP` (the EVM forwards at most 63/64 of what is left) plus the margin, 1,643,809.
    ///         A starved `pull` reverts `InsufficientGas` here instead of passing an out-of-gas collection off as a
    ///         position failure.
    function COLLECT_GAS_FLOOR() external view returns (uint256);

    /// @notice Gas one forward to the revenue token gets: 300,000, for an ERC-20 `transfer` or the native send into the
    ///         token's empty `receive`. A transfer that burns more fails on its own (`ForwardFailed`) and the asset
    ///         waits in the door; the assets after it still get their full forward.
    function FORWARD_GAS() external view returns (uint256);
    /// @notice Gas one `balanceOf` read of a door asset gets: 50,000. A read that fails is reported
    ///         (`BalanceReadFailed`) and skipped, so a pool token whose view reverts or burns gas holds neither the
    ///         other assets' forwards nor a release.
    function BALANCE_GAS() external view returns (uint256);

    // ------------------------------------------------------------------ actions

    /// @notice Collects every held position's accrued fees (base LP fee, LP Rewards and the arb recapture LP leg all
    ///         land as position fees) and forwards everything the door holds to the revenue token. Anyone may call it, at
    ///         any time after activation, including after release (then it only forwards what reached the door).
    /// @dev Each collection gets at most `COLLECT_GAS_CAP` gas; one position's failure is reported with `CollectFailed`
    ///      and does not block the others. Each asset is forwarded on its own with `FORWARD_GAS`; a refused forward is
    ///      reported with `ForwardFailed` and the asset waits in the door. Reverts with `InsufficientGas` when too little gas is left
    ///      before a position, so a starved call cannot pass an out-of-gas collection off as a position failure.
    function pull() external;

    /// @notice `pull` for the listed positions in `ids` alone (any order; an id not on the door's list is `NotListed`,
    ///         an empty list `NoPositions`), then forwards everything the door holds. Lets an honest position be
    ///         collected on its own gas when another position's hook burns its whole cap on every collection, which
    ///         would otherwise set the cost of the whole-list `pull`. Anyone may call it.
    function pullSome(uint256[] calldata ids) external;

    /// @notice After the unlock time: for each NFT still in the door, collects its fees one last time and, if that
    ///         succeeded, returns it to the account that deposited it; then forwards everything collected. An NFT whose
    ///         final collection failed stays (`ReleaseHeld`) and the call can be repeated for it. Anyone may call it;
    ///         reverts before the unlock time, always on a door locked forever, with `NoneReleased` when no NFT could
    ///         move, and with `AlreadyReleased` once every NFT is out.
    function release() external;

    /// @notice `release` for the listed positions in `ids` alone (an id not on the door's list is `NotListed`, an
    ///         empty list `NoPositions`), with the same time checks and the same `NoneReleased` when none of them
    ///         could move: an honest position goes back to its depositor on the date on its own gas, whatever the
    ///         other positions' hooks do. Anyone may call it.
    function releaseSome(uint256[] calldata ids) external;

    /// @notice Returns an NFT that sits in the door but is not principal (a plain `transferFrom` never asks the
    ///         receiver): one that was never on the list goes to the door's creator, the depositor of the first listed
    ///         NFT; a listed NFT that came back after its release goes to its depositor again. Anyone may call it; it
    ///         can never touch a listed NFT that has not been released (`Listed`).
    function rescueUnlisted(uint256 tokenId) external;

    /// @notice Moves the door's whole balance of `asset`, an ERC-20 that is not one of its assets, to the revenue
    ///         token, where `dropStray` splits it among the holders (an airdrop to the door as a position's owner,
    ///         a token sent here by mistake). Anyone may call; the only destination is the revenue token. Native
    ///         ETH and the listed assets are `ListedAsset`; an empty or unreadable balance is
    ///         `NothingToForward`; a refused transfer is `ForwardRefused`.
    /// @return amount What moved.
    function forwardUnlisted(address asset) external returns (uint256 amount);

    // ------------------------------------------------------------------ views

    /// @notice The Uniswap v4 PositionManager that minted the NFTs.
    function positionManager() external view returns (IPositionManagerDoor);

    /// @notice The factory that created the door; the only account that may call `activate`.
    function factory() external view returns (address);

    /// @notice The Hookr root `isHookrPool` compares each pool's hook with.
    function hookrRoot() external view returns (address);

    /// @notice The revenue token every collected fee goes to.
    function revenueToken() external view returns (address);

    /// @notice The unlock timestamp (seconds); FOREVER (type(uint64).max) means the NFTs never come back.
    function unlockAt() external view returns (uint64);

    /// @notice The locked position NFTs, in creation order.
    function tokenIds() external view returns (uint256[] memory);

    /// @notice Every currency the door can forward (address(0) is native ETH), for the revenue token's balance sync.
    function assets() external view returns (address[] memory);

    /// @notice The account a position NFT goes back to at release.
    function depositorOf(uint256 tokenId) external view returns (address);

    /// @notice The pool a listed position sits in, read once at activation.
    function poolKeyOf(uint256 tokenId) external view returns (PoolKey memory);

    /// @notice Whether a listed position's pool hook is the Hookr root. Reported only; other pools are allowed.
    function isHookrPool(uint256 tokenId) external view returns (bool);

    /// @notice For every listed position, whether its pool hook is the Hookr root.
    function hookrPools() external view returns (bool[] memory);

    /// @notice Whether a listed position's pool hook, not being the Hookr root, runs on liquidity removals (the
    ///         before-remove, after-remove or after-remove-returns-delta flags), so its author could make this
    ///         position's fee collection fail and keep this NFT in the door. Reported only.
    function hookCanBlockCollection(uint256 tokenId) external view returns (bool);

    /// @notice True once every listed NFT is in and the door is live.
    function active() external view returns (bool);

    /// @notice True once every NFT went back to its depositor.
    function released() external view returns (bool);

    /// @notice True once this NFT went back to its depositor.
    function releasedOf(uint256 tokenId) external view returns (bool);

    /// @notice How many NFTs went back to their depositors so far.
    function releasedCount() external view returns (uint256);

    /// @notice Whether `release` would pass the time check now (active, not fully released, unlock passed, not forever).
    function canRelease() external view returns (bool);
}
