// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {IHookrFamilyLock} from "hookr/interfaces/IHookrFamilyLock.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrForwarding} from "../base/HookrForwarding.sol";
import {HookrForward} from "../libraries/HookrForward.sol";
import {EndKind} from "../types/EndKind.sol";
import {IHookrFamilyForwarder} from "../interfaces/IHookrFamilyForwarder.sol";
import {IHookrRulesDoor} from "../interfaces/IHookrRulesDoor.sol";

/// @title Hookr family forwarder, part of the HookRevenue Tokenizer
/// @notice The beneficiary of the HookrLauncher families locked for one revenue token. See IHookrFamilyForwarder for
///         the rules.
/// @dev Reaches the families only through the lock's beneficiary entry points (`collect`, `claimRecapture`,
///      `release`) and the launcher's `redeem` for ERC-6909 claims a release leaves here.
///
///      The families still locked here sit in a compact open list (`openCount`): a release takes its family out by
///      swap and pop, so a released family costs a pull nothing, however many there are. A pull walks the members
///      of the open families from a cursor (a position in that list, and a member), at most one lap. For each member
///      it calls the lock's `collect` (LP fees, paid here) and `claimRecapture` (the accrual, moved into this
///      forwarder's Rules claims). Then it claims this forwarder's Rules credit, one (Rules, currency) pair at a
///      time from its own cursor, over every pair seen when a family was registered (`rulesCredits`), so credit
///      earned during a family's term is still claimed after its release; credit in the revenue token itself is
///      claimed to 0xdead. Then it forwards the registered
///      currencies in turn from their own cursor (IHookrForwarding): native ETH and listed assets to the token, the
///      revenue token to 0xdead, anything else less Hookr's leg into the token's drop box (an immediate drop at a
///      release period under an hour, the stray stream at an hour or more). Each
///      outside call is its own attempt with a gas cap, so one member whose quote is paused or whose Rules refuse a
///      claim this block holds nothing else up, and what it could not pull waits where it is. Before every member,
///      and before every step to the next family, the pull checks that `MEMBER_GAS` plus the reserve for the Rules
///      page and the forwards is left, so it always ends inside its stipend; the next pull carries on from there.
///
///      Gas: the tokenizer gives the forwarder `PULL_GAS` (12,000,000). One member costs at most `MEMBER_GAS`
///      (1,500,000), one Rules pair at most `RULES_ITEM_GAS` (1,300,000) and one currency at most `FORWARD_ITEM_GAS`
///      (2,340,000); the pull keeps back two Rules pairs and two currencies, so it collects at least three members
///      whatever they burn, and claims the other pairs while the gas allows and in turn. One member on the real local
///      core takes about 120,000. `CLAIM_GAS` is sized for the costliest currency a pair can be in, a revenue token
///      listing eight assets, at its costliest moment: each of the eight has its first income streaming and the
///      forwarder held some of it while that income landed, so the claim releases all eight streams and writes the
///      forwarder's first credit in every asset: 938,153 on the real HookrRules, measured cold (767,910 into a
///      forwarder that never held it). A claim that fails leaves the forwarder as it was, so a smaller cap would
///      fail on every pull. `COLLECT_GAS` is not sized that way: a member quoted in a revenue token listing eight
///      assets collects in about 852,000 while the forwarder never held that token, but about 1,025,000 when the
///      forwarder held some of it as its first income landed in every asset, which anyone can arrange by sending
///      the forwarder 1 wei of it first. That collection fails inside its try (no `Collected`; the fees stay in the
///      PoolManager) while the same pull forwards the wei and writes the forwarder's slots, so the next pull
///      collects everything: a one-pull delay per newly listed asset of that quote, not stuck income. The tokenizer
///      admits such a member as a launch member with no royalty or Hook Block, in a handed family, or as a market
///      quoted in an ETH-only revenue token that lists more assets later.
contract HookrFamilyForwarder is IHookrFamilyForwarder, HookrForwarding {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant COLLECT_GAS = 1_000_000;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant RECAPTURE_GAS = 300_000;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant CLAIM_GAS = 1_200_000;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant MEMBER_GAS = 1_500_000;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant RULES_ITEM_GAS = 1_300_000;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant RULES_PAGE = 2;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant FORWARD_PAGE = 2;
    /// @inheritdoc IHookrFamilyForwarder
    uint256 public constant PULL_BASE_GAS = 150_000;
    /// @inheritdoc IHookrFamilyForwarder
    uint32 public constant PULL_GAS = 12_000_000;
    /// @dev Gas a pull keeps for the cursor writes and its return after the last forward.
    uint256 internal constant END_GAS = 30_000;

    /// @inheritdoc IHookrFamilyForwarder
    address public immutable lock;
    /// @inheritdoc IHookrFamilyForwarder
    address public immutable launcher;
    /// @inheritdoc IHookrFamilyForwarder
    address public immutable tokenizer;
    IPoolManager internal immutable _manager;

    Family[] internal _families;
    /// @dev Each registered family's index plus one.
    mapping(bytes32 familyId => uint256) internal _slot;
    address[] internal _currencies;
    mapping(address currency => bool) internal _isCurrency;
    /// @dev The families still locked here, by index into `_families`, in no order; and each one's position plus one.
    uint256[] internal _openFamilies;
    mapping(uint256 family => uint256) internal _openPosition;
    /// @dev Every (Rules, currency) pair a registered family's members can credit this forwarder in, once each.
    RulesCredit[] internal _rulesCredits;
    mapping(bytes32 pair => bool) internal _isRulesCredit;
    /// @dev Where the next pull starts: a position in the open list, the member in that family, the Rules pair to
    ///      claim and the currency to forward.
    uint64 internal _cursorFamily;
    uint8 internal _cursorMember;
    uint32 internal _cursorRules;
    uint32 internal _cursorCurrency;
    /// @dev The latest unlock block of any family: what `ends` answers while one is open.
    uint64 internal _latestUnlock;

    /// @param token_ The revenue token every pull pays.
    /// @param lock_ The HookrFamilyLock; its launcher and that launcher's PoolManager are read from it.
    /// @param tokenizer_ The tokenizer that may register families.
    constructor(address token_, address lock_, address tokenizer_) HookrForwarding(token_) {
        if (lock_.code.length == 0 || tokenizer_ == address(0)) revert InvalidConfig();
        lock = lock_;
        tokenizer = tokenizer_;
        address launcher_ = IHookrFamilyLock(lock_).launcher();
        if (launcher_.code.length == 0) revert InvalidConfig();
        launcher = launcher_;
        _manager = IHookrLauncher(launcher_).poolManager();
        _addCurrency(address(0));
    }

    /// @notice Takes the native ETH the lock's `collect` pays this beneficiary; forwarded by the token's pull.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    /// @inheritdoc IHookrFamilyForwarder
    function familyCount() external view returns (uint256) {
        return _families.length;
    }

    /// @inheritdoc IHookrFamilyForwarder
    function familyAt(uint256 i) external view returns (Family memory) {
        if (i >= _families.length) revert UnknownFamily(i);
        return _families[i];
    }

    /// @inheritdoc IHookrFamilyForwarder
    function families(uint256 start, uint256 count) external view returns (Family[] memory out) {
        uint256 n = _families.length;
        if (start >= n) return out;
        if (count > n - start) count = n - start;
        out = new Family[](count);
        for (uint256 k; k < count; ++k) {
            out[k] = _families[start + k];
        }
    }

    /// @inheritdoc IHookrFamilyForwarder
    function indexOf(bytes32 familyId) external view returns (bool registered, uint256 index) {
        uint256 slot = _slot[familyId];
        if (slot == 0) return (false, 0);
        return (true, slot - 1);
    }

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev Native ETH first, always.
    function currencies() external view returns (address[] memory) {
        return _currencies;
    }

    /// @inheritdoc IHookrFamilyForwarder
    function openCount() external view returns (uint256) {
        return _openFamilies.length;
    }

    /// @inheritdoc IHookrFamilyForwarder
    function rulesCredits() external view returns (RulesCredit[] memory) {
        return _rulesCredits;
    }

    /// @notice When the stream ends: `ENDED` while no family is locked here, `FOREVER` when one is locked for good,
    ///         otherwise `AT_BLOCK` at the latest unlock block of the families.
    function ends() external view returns (EndKind kind, uint64 endsAt) {
        if (_openFamilies.length == 0) return (EndKind.ENDED, 0);
        uint64 latest = _latestUnlock;
        if (latest == type(uint64).max) return (EndKind.FOREVER, 0);
        return (EndKind.AT_BLOCK, latest);
    }

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev The launcher holds every family position under the salt `keccak256(abi.encode(familyId, member))`; the
    ///      unclaimed fees are the fee growth inside the range since the position last settled, times its liquidity.
    ///      Needs a real PoolManager (`extsload`).
    function pendingFees(uint256 i, uint8 member) external view returns (uint256 amount0, uint256 amount1) {
        if (i >= _families.length) revert UnknownFamily(i);
        bytes32 familyId = _families[i].id;
        IHookrLauncher.Position memory p = IHookrLauncher(launcher).position(familyId, member);
        PoolId poolId = p.key.toId();
        (uint128 liquidity, uint256 last0, uint256 last1) = _manager.getPositionInfo(
            poolId, launcher, p.tickLower, p.tickUpper, keccak256(abi.encode(familyId, member))
        );
        if (liquidity == 0) return (0, 0);
        (uint256 inside0, uint256 inside1) = _manager.getFeeGrowthInside(poolId, p.tickLower, p.tickUpper);
        unchecked {
            amount0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    // ------------------------------------------------------------------ tokenizer and returnTo

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev Reads every member's pool once, adds its currencies to the forward list and, when the pool has Rules on
    ///      its root, the (Rules, currency) pairs to the Rules list; puts the family on the open list. A family
    ///      released from here may be registered again: it gets a new index, and `indexOf` answers the newest.
    function register(bytes32 familyId, address returnTo, bool market) external returns (uint256 index) {
        if (msg.sender != tokenizer) revert Unauthorized(msg.sender);
        uint256 slot = _slot[familyId];
        if (slot != 0 && !_families[slot - 1].released) revert AlreadyRegistered(familyId);
        (address beneficiary, uint64 unlockBlock) = IHookrFamilyLock(lock).lockOf(familyId);
        if (beneficiary != address(this)) revert NotLockedHere(familyId);
        if (returnTo == address(0) || returnTo == address(this) || returnTo == lock || returnTo == launcher) {
            revert InvalidReturnTo(returnTo);
        }
        uint8 n = IHookrLauncher(launcher).memberCount(familyId);
        for (uint8 m; m < n; ++m) {
            PoolKey memory key = IHookrLauncher(launcher).position(familyId, m).key;
            _addCurrency(Currency.unwrap(key.currency0));
            _addCurrency(Currency.unwrap(key.currency1));
            address rules = _rulesOf(key);
            if (rules != address(0)) {
                _addRulesCredit(rules, key.currency0);
                _addRulesCredit(rules, key.currency1);
            }
        }
        index = _families.length;
        _families.push(Family(familyId, unlockBlock, returnTo, market, false));
        _slot[familyId] = index + 1;
        _openFamilies.push(index);
        _openPosition[index] = _openFamilies.length;
        if (unlockBlock > _latestUnlock) _latestUnlock = unlockBlock;
        emit FamilyRegistered(index, familyId, unlockBlock, returnTo, market);
    }

    /// @inheritdoc IHookrFamilyForwarder
    function extendTerm(uint256 i, uint64 newUnlockBlock) external {
        if (i >= _families.length) revert UnknownFamily(i);
        Family storage f = _families[i];
        if (msg.sender != f.returnTo) revert Unauthorized(msg.sender);
        if (f.released) revert AlreadyReleased(f.id);
        uint64 current = f.unlockBlock;
        if (newUnlockBlock <= current) revert TermNotExtended(newUnlockBlock, current);
        f.unlockBlock = newUnlockBlock;
        if (newUnlockBlock > _latestUnlock) _latestUnlock = newUnlockBlock;
        emit FamilyTermExtended(i, newUnlockBlock);
    }

    // ------------------------------------------------------------------ the token and anyone

    /// @notice Collects a page of open family members, claims a page of Rules credit and forwards a page of
    ///         currencies to the revenue token. Only the revenue token.
    function pull() external onlyRevenueToken nonReentrant {
        uint256 n = _openFamilies.length;
        uint256 r = _rulesCredits.length;
        uint256 c = _currencies.length;
        uint256 forwardReserve = (c < FORWARD_PAGE ? c : FORWARD_PAGE) * FORWARD_ITEM_GAS + END_GAS;
        uint256 reserve = (r < RULES_PAGE ? r : RULES_PAGE) * RULES_ITEM_GAS + forwardReserve;
        uint256 p = _cursorFamily;
        uint256 m = _cursorMember;
        if (p >= n) (p, m) = (0, 0);
        for (uint256 lap; lap < n;) {
            if (gasleft() < MEMBER_GAS + reserve) break;
            bytes32 id = _families[_openFamilies[p]].id;
            if (m < IHookrLauncher(launcher).memberCount(id)) {
                _pullMember(id, uint8(m));
                ++m;
            } else {
                (p, m) = (p + 1 == n ? 0 : p + 1, 0);
                ++lap;
            }
        }
        uint256 k = _cursorRules;
        if (k >= r) k = 0;
        for (uint256 j; j < r; ++j) {
            if (gasleft() < RULES_ITEM_GAS + forwardReserve) break;
            RulesCredit storage credit = _rulesCredits[k];
            if (_claimRules(credit.rules, credit.currency)) {
                _retireRulesCredit(k);
                if (--r == 0) break;
                if (k == r) k = 0;
            } else {
                k = k + 1 == r ? 0 : k + 1;
            }
        }
        uint256 a = _cursorCurrency;
        for (uint256 j; j < c; ++j) {
            if (gasleft() < FORWARD_ITEM_GAS + END_GAS) break;
            _forwardHeld(_currencies[a]);
            a = a + 1 == c ? 0 : a + 1;
        }
        (_cursorFamily, _cursorMember, _cursorRules, _cursorCurrency) = (uint64(p), uint8(m), uint32(k), uint32(a));
    }

    /// @inheritdoc IHookrFamilyForwarder
    /// @dev The final collection runs before the lock's `release`, which takes the fees earned since as ERC-6909
    ///      claims and moves them here; those are redeemed into the forwarder in the same call. Fees the family earns
    ///      while `returnTo` has not yet accepted reach the handover, whose `sweep` sends them here as claims too:
    ///      `flushClaims` then. The family leaves the open list; its Rules pairs stay on the Rules list, so the
    ///      forwarder's credit there (the final `claimRecapture` included) is still claimed by later pulls.
    function release(uint256 i) external nonReentrant returns (address handover) {
        if (i >= _families.length) revert UnknownFamily(i);
        Family storage f = _families[i];
        bytes32 familyId = f.id;
        if (f.released) revert AlreadyReleased(familyId);
        uint64 unlockBlock = f.unlockBlock;
        if (unlockBlock == type(uint64).max || block.number < unlockBlock) revert StillLocked(familyId, unlockBlock);
        f.released = true;
        _close(i);
        uint8 n = IHookrLauncher(launcher).memberCount(familyId);
        PoolKey[] memory keys = new PoolKey[](n);
        for (uint8 m; m < n; ++m) {
            _pullMember(familyId, m);
            keys[m] = IHookrLauncher(launcher).position(familyId, m).key;
        }
        address returnTo = f.returnTo;
        handover = IHookrFamilyLock(lock).release(familyId, returnTo);
        for (uint8 m; m < n; ++m) {
            _flush(keys[m].currency0);
            _flush(keys[m].currency1);
        }
        emit FamilyReturned(familyId, returnTo, handover);
    }

    /// @inheritdoc IHookrFamilyForwarder
    function flushClaims(Currency currency) external nonReentrant returns (uint256 amount) {
        return _flush(currency);
    }

    // ------------------------------------------------------------------ internals

    /// @dev One member: the lock's `collect` (LP fees paid here; on a recapture member the launcher moves the accrual
    ///      into this forwarder's Rules claims in the same call) and `claimRecapture` (whatever accrued in between).
    ///      Each call is capped and wrapped on its own. The Rules credit they leave is claimed from the Rules list.
    ///      On a pool of the revenue token itself (its market) the token's side is taken as an ERC-6909 claim: the
    ///      token refuses a transfer to its own door, which would fail the whole collection, and a claim held in the
    ///      PoolManager earns nothing, as at 0xdead. `flushClaims` redeems it to 0xdead.
    function _pullMember(bytes32 familyId, uint8 member) private {
        PoolKey memory key = IHookrLauncher(launcher).position(familyId, member).key;
        address token = revenueToken;
        uint8 claims =
            (Currency.unwrap(key.currency0) == token ? 1 : 0) | (Currency.unwrap(key.currency1) == token ? 2 : 0);
        try IHookrFamilyLock(lock).collect{gas: COLLECT_GAS}(familyId, member, claims) returns (
            uint256 amount0, uint256 amount1
        ) {
            emit Collected(familyId, member, amount0, amount1);
        } catch {}
        try IHookrFamilyLock(lock).claimRecapture{gas: RECAPTURE_GAS}(familyId, member) returns (uint256) {} catch {}
    }

    /// @dev Takes family `i` off the open list by swap and pop, and keeps the pull cursor on the family it pointed
    ///      at: when that was family `i`, the family moved into its place starts at its first member; when it was
    ///      the family moved, the cursor follows it.
    function _close(uint256 i) private {
        uint256 position = _openPosition[i] - 1;
        uint256 last = _openFamilies.length - 1;
        if (position != last) {
            uint256 moved = _openFamilies[last];
            _openFamilies[position] = moved;
            _openPosition[moved] = position + 1;
        }
        _openFamilies.pop();
        delete _openPosition[i];
        uint256 cursor = _cursorFamily;
        if (cursor == position) _cursorMember = 0;
        else if (cursor == last) _cursorFamily = uint64(position);
    }

    /// @dev The Rules of the member's pool, read from its root's `poolConfig`; zero when the read fails.
    function _rulesOf(PoolKey memory key) private view returns (address) {
        if (address(key.hooks).code.length == 0) return address(0);
        try IHookrRoot(address(key.hooks)).poolConfig{gas: BALANCE_GAS}(key.toId()) returns (
            HookrTypes.PoolConfig memory pc
        ) {
            return pc.rules;
        } catch {
            return address(0);
        }
    }

    /// @dev Claims this forwarder's credit in `currency` on `rules`, when there is one: into the forwarder, or to
    ///      0xdead for the revenue token itself, which refuses a transfer to its own door (the recapture LP share can
    ///      accrue in either currency of the market). A Rules that refuses the payout this block (a paused quote)
    ///      keeps the credit for a later pull. A Rules that refuses to pay the revenue token to 0xdead would refuse it
    ///      on every pull, and that credit earns nothing where it is (the PoolManager holds it), so the pair is
    ///      retired (returns true).
    function _claimRules(address rules, Currency currency) private returns (bool retire) {
        if (rules.code.length == 0) return false;
        (bool read, uint256 owed) =
            HookrForward.read(rules, abi.encodeCall(IHookrRulesDoor.claimable, (currency, address(this))), BALANCE_GAS);
        if (!read || owed == 0) return false;
        bool own = Currency.unwrap(currency) == revenueToken;
        try IHookrRulesDoor(rules).claimTo{gas: CLAIM_GAS}(currency, own ? DEAD : address(this)) returns (uint256) {}
        catch {
            return own;
        }
    }

    /// @dev Takes Rules pair `k` off the list by swap and pop; it stays known, so no later registration adds it again.
    function _retireRulesCredit(uint256 k) private {
        RulesCredit memory credit = _rulesCredits[k];
        uint256 last = _rulesCredits.length - 1;
        if (k != last) _rulesCredits[k] = _rulesCredits[last];
        _rulesCredits.pop();
        emit RulesCreditRetired(credit.rules, credit.currency);
    }

    /// @dev Redeems this forwarder's ERC-6909 claim in `currency` through the launcher into the forwarder, or to
    ///      0xdead for the revenue token itself, which no door may hold. A refused redeem leaves the claim here
    ///      (`RedeemFailed`), for a later `flushClaims`.
    function _flush(Currency currency) private returns (uint256 amount) {
        uint256 id = currency.toId();
        amount = _manager.balanceOf(address(this), id);
        if (amount == 0) return 0;
        _manager.approve(launcher, id, amount);
        address to = Currency.unwrap(currency) == revenueToken ? DEAD : address(this);
        try IHookrLauncher(launcher).redeem(currency, amount, to) {}
        catch {
            emit RedeemFailed(currency, amount);
            return 0;
        }
    }

    /// @dev Adds the pair (`rules`, `currency`) to the Rules list once.
    function _addRulesCredit(address rules, Currency currency) private {
        bytes32 pair = keccak256(abi.encode(rules, currency));
        if (_isRulesCredit[pair]) return;
        _isRulesCredit[pair] = true;
        _rulesCredits.push(RulesCredit(rules, currency));
    }

    /// @dev Adds a currency to the forward list once.
    function _addCurrency(address currency) private {
        if (_isCurrency[currency]) return;
        _isCurrency[currency] = true;
        _currencies.push(currency);
    }

    function _isOwnAsset(address asset) internal view override returns (bool) {
        return _isCurrency[asset];
    }
}
