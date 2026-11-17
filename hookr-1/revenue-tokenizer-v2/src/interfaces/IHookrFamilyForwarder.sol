// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRevenueDoor} from "./IHookrRevenueDoor.sol";
import {IHookrForwarding} from "./IHookrForwarding.sol";

/// @title Hookr family forwarder, part of the HookRevenue Tokenizer
/// @notice The beneficiary of every HookrLauncher family locked for one revenue token in the live HookrFamilyLock.
///         The revenue token pulls it: it takes what the lock lets a beneficiary take (LP fees and arb recapture
///         accruals, never principal), a page of family members at a time, and forwards it. From a family's unlock
///         block anyone may release it to the account that added it, after a final collection into the forwarder.
/// @dev One forwarder per revenue token. The tokenizer registers families at any time, append only: the launched
///      family and the token's market family at mint, more families later. Each family has its own unlock block on
///      the parent chain's clock, which the family's `returnTo` may move later (`extendTerm`); the lock releases only
///      to its beneficiary, this forwarder, so the forwarder's own block is the one that counts. Fees paid in the
///      revenue token itself go to 0xdead, which earns nothing. A released family leaves the pull for good, and costs
///      it nothing; the Rules credit its pools earned the forwarder is still claimed.
interface IHookrFamilyForwarder is IHookrRevenueDoor, IHookrForwarding {
    /// @notice One locked family.
    /// @param id The family.
    /// @param unlockBlock The parent block from which it can be released; type(uint64).max never.
    /// @param returnTo The account the family is released to, and the only one that may extend its term.
    /// @param market Whether this is the token's own market family.
    /// @param released Whether it was released.
    struct Family {
        bytes32 id;
        uint64 unlockBlock;
        address returnTo;
        bool market;
        bool released;
    }

    /// @notice A Rules ledger and a currency in which it can credit this forwarder: a pool's royalty or Hook Block
    ///         take on a registered family's member pool.
    /// @param rules The pool's Rules, read from its root at registration.
    /// @param currency One of the pool's two currencies.
    struct RulesCredit {
        address rules;
        Currency currency;
    }

    /// @notice A constructor argument has no code or is zero.
    error InvalidConfig();
    /// @notice The caller may not do this: `register` from anyone but the tokenizer, `extendTerm` from anyone but the
    ///         family's `returnTo`.
    error Unauthorized(address caller);
    /// @notice The lock does not hold `familyId` for this forwarder.
    error NotLockedHere(bytes32 familyId);
    /// @notice `familyId` is registered here and not released yet.
    error AlreadyRegistered(bytes32 familyId);
    /// @notice `index` is past the last registered family.
    error UnknownFamily(uint256 index);
    /// @notice `familyId` releases at parent block `unlockBlock`, not before; type(uint64).max never.
    error StillLocked(bytes32 familyId, uint256 unlockBlock);
    /// @notice `familyId` was already released.
    error AlreadyReleased(bytes32 familyId);
    /// @notice A family cannot be released to zero, this forwarder, the lock or the launcher.
    error InvalidReturnTo(address returnTo);

    /// @notice `familyId` was registered as family `index`: locked here until `unlockBlock`, returning to `returnTo`.
    event FamilyRegistered(
        uint256 indexed index, bytes32 indexed familyId, uint64 unlockBlock, address indexed returnTo, bool market
    );
    /// @notice Family `index` now releases from parent block `unlockBlock`.
    event FamilyTermExtended(uint256 indexed index, uint64 unlockBlock);
    /// @notice Member `member` of `familyId` was collected: `amount0` and `amount1` of its pool's currencies.
    event Collected(bytes32 indexed familyId, uint8 member, uint256 amount0, uint256 amount1);
    /// @notice `familyId` was released to `returnTo` through the lock's `handover`, which `returnTo` accepts.
    event FamilyReturned(bytes32 indexed familyId, address indexed returnTo, address handover);
    /// @notice The launcher refused to redeem `amount` of this forwarder's ERC-6909 claim in `currency`; it stays
    ///         here for a later `flushClaims`.
    event RedeemFailed(Currency indexed currency, uint256 amount);
    /// @notice `rules` refused to pay this forwarder's credit in `currency`, the revenue token itself, to 0xdead, so
    ///         the pair left the Rules list: that credit earns nothing where it is, and no pull tries it again.
    event RulesCreditRetired(address indexed rules, Currency indexed currency);

    /// @notice Gas the lock's `collect` of one member gets: 1,000,000.
    function COLLECT_GAS() external view returns (uint256);
    /// @notice Gas the lock's `claimRecapture` of one member gets: 300,000.
    function RECAPTURE_GAS() external view returns (uint256);
    /// @notice Gas one Rules `claimTo` gets: 1,200,000, above the costliest currency a pair can be in (a revenue token
    ///         listing eight assets while each of the eight has its first income streaming, claimed into a forwarder
    ///         that held some of it while that income landed: 938,153 cold on the real HookrRules).
    function CLAIM_GAS() external view returns (uint256);
    /// @notice The most gas one member's collection can take, every cap included: 1,500,000. A pull starts a member
    ///         only with this, plus its Rules and forwarding reserve, left.
    function MEMBER_GAS() external view returns (uint256);
    /// @notice The most gas one Rules pair's claim can take, every cap included: 1,300,000 (the 50,000 read, the
    ///         1,200,000 claim and the pair's own work).
    function RULES_ITEM_GAS() external view returns (uint256);
    /// @notice The most Rules pairs one pull keeps claiming gas for: 2, so a pull still collects three members whatever
    ///         they burn. More are claimed while the gas allows, and the rest in turn.
    function RULES_PAGE() external view returns (uint256);
    /// @notice The most currencies one pull keeps forwarding gas for: 2. It forwards more while the gas allows, and
    ///         the rest in turn.
    function FORWARD_PAGE() external view returns (uint256);
    /// @notice Gas a pull keeps for its own work besides the members and the forwards: 150,000.
    function PULL_BASE_GAS() external view returns (uint256);
    /// @notice The gas stipend the tokenizer gives the forwarder: 12,000,000, the token's largest. A pull at that
    ///         stipend collects at least three members and forwards at least two currencies; more families are
    ///         pulled in turn, from where the last pull stopped.
    function PULL_GAS() external view returns (uint32);

    /// @notice The HookrFamilyLock holding the families.
    function lock() external view returns (address);
    /// @notice The HookrLauncher the families live on.
    function launcher() external view returns (address);
    /// @notice The tokenizer that may register families.
    function tokenizer() external view returns (address);
    /// @notice Number of families registered.
    function familyCount() external view returns (uint256);
    /// @notice The `i`-th family.
    function familyAt(uint256 i) external view returns (Family memory);
    /// @notice Up to `count` families from `start`; fewer at the end of the list.
    function families(uint256 start, uint256 count) external view returns (Family[] memory);
    /// @notice The index of `familyId`'s newest registration and whether it was ever registered; a family released
    ///         and registered again has a new index, and its earlier entry keeps the old one.
    function indexOf(bytes32 familyId) external view returns (bool registered, uint256 index);
    /// @notice Every currency of every registered family's pools, in the order first seen: what a pull forwards.
    function currencies() external view returns (address[] memory);
    /// @notice How many registered families are still locked here: the ones a pull collects.
    function openCount() external view returns (uint256);
    /// @notice Every (Rules, currency) pair seen when a family was registered, less any retired one
    ///         (`RulesCreditRetired`): what a pull claims, whether the family is still locked or not, each into the
    ///         forwarder, the revenue token itself to 0xdead. A retired pair leaves by swap and pop, so the order is
    ///         the order first seen until one leaves.
    function rulesCredits() external view returns (RulesCredit[] memory);

    /// @notice Registers `familyId`, which the lock must already hold for this forwarder, at the end of the list.
    ///         Only the tokenizer, at any time.
    /// @param familyId The family.
    /// @param returnTo The account a release hands the family to; not zero, this forwarder, the lock or the launcher.
    /// @param market Whether this is the token's own market family.
    /// @return index The family's index: a new one each time, including for a family released from here earlier.
    function register(bytes32 familyId, address returnTo, bool market) external returns (uint256 index);
    /// @notice Moves family `i`'s unlock block to `newUnlockBlock`, which must be later (type(uint64).max for good).
    ///         Only the family's `returnTo`, only while it is locked here.
    function extendTerm(uint256 i, uint64 newUnlockBlock) external;
    /// @notice From its unlock block, collects family `i` one last time into the forwarder and releases it to its
    ///         `returnTo`, who accepts it with HookrLauncher.acceptFamily; the fees the release hands over as ERC-6909
    ///         claims are redeemed into the forwarder. What was collected reaches the token on its next pull. Anyone
    ///         may call.
    /// @return handover The HookrFamilyRelease handing the family over.
    function release(uint256 i) external returns (address handover);
    /// @notice Redeems this forwarder's PoolManager ERC-6909 claims in `currency` (left by a release, swept by its
    ///         handover, or the revenue token's own side of its market's fees, which a pull takes as a claim) into the
    ///         forwarder, for the token's next pull, or to 0xdead for the revenue token itself. Anyone may call.
    ///         Returns zero, and keeps the claim, when the redeem is refused (`RedeemFailed`).
    function flushClaims(Currency currency) external returns (uint256 amount);
    /// @notice What a pull would collect now for member `member` of family `i`, in its pool's two currencies, LP fees
    ///         only (the recapture accrual is readable on the member's Rules with `poolAccrued`).
    function pendingFees(uint256 i, uint8 member) external view returns (uint256 amount0, uint256 amount1);
}
