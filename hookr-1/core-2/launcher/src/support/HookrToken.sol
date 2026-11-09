// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrToken} from "../interfaces/IHookrToken.sol";
import {HookrTokenBounds} from "../libraries/HookrTokenBounds.sol";

/// @title HookrToken
/// @notice Fixed-supply ERC-20 created by HookrLauncher, with EIP-2612 permit, an on-chain tagline and logo URI, and each
///         holder's tokens kept as a fresh lot and an aged bag (`lots`), which Exit Clock prices a sell by.
/// @dev The entire supply is assigned once. There is no owner, mint, pause, tax or upgrade surface. The EIP-712 domain
///      permits are signed under (the token's name, version "1", block.chainid and this address) is computed on each
///      use and never cached in an immutable, so every HookrToken has the same runtime code and codehash, by which
///      HookrRules and its blocks recognise a Hookr token. A permit signed under one chain id does not verify after a
///      fork changes it. The tagline and logo URI live in storage for the same reason. They are set at most once, by the
///      account that created the token and only in the transaction that created it (`setPresentation`), then never
///      change; a token that is not given them keeps both empty for good. The constructor keeps its four arguments, so a
///      token's address does not depend on them.
///
///      The ERC-20 surface is OpenZeppelin 5's (same functions, events, errors and allowance rules: an infinite allowance
///      is never spent and `transferFrom` emits no Approval), with each holder's balance and lot packed in one word: the
///      balance in bits 0-107, the fresh lot's amount in bits 108-215 and the lot's time, `freshSince`, in the top 40.
///      Tokens received join the fresh lot and move its time toward now by their share of the lot, rounded toward now; a
///      lot received from nothing starts at now. Tokens sent leave the fresh lot first, then the aged bag, and leave the
///      lot's time alone. A lot FRESH_WINDOW past its time has aged: `lots` reports it in the aged bag from then, and the
///      holder's next transfer writes it there. A transfer to oneself changes nothing. So hold time is never carried by
///      a transfer, a top-up shifts a lot's time rather than restarting it, and an old lot lends its age to new tokens
///      for the window at most. The supply is at most 2^108 - 1, so no balance or lot passes 108 bits.
///
///      For the transaction it runs in, the token also keeps what each holder sent since it last received (`_sends`,
///      transient: the fresh part, the total and the lot's time before the first send), so `lotsBefore` can give a
///      holder's lots as they stood before its last sends: a router that collects a sale leg by leg before each swap
///      lets Exit Clock price every leg on the lots as a sale in one pool sees them.
contract HookrToken is HookrReleased, IERC20, IERC20Metadata, IERC20Errors, IERC20Permit, IERC5267, IHookrToken {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev keccak256 of the domain's version, "1".
    bytes32 private constant VERSION_HASH = keccak256("1");
    /// @dev The longest tagline and logo URI, in bytes.
    uint256 private constant MAX_TAGLINE_BYTES = 160;
    uint256 private constant MAX_LOGO_URI_BYTES = 300;
    /// @dev The largest supply, and a holder word's balance and lot bits.
    uint256 public constant MAX_SUPPLY = HookrTokenBounds.MAX_SUPPLY;
    uint256 private constant FRESH_SHIFT = 108;
    uint256 private constant SINCE_SHIFT = 216;
    /// @dev How long a fresh lot stays fresh after its time: the longest Exit Clock horizon a pool can set, so no lot ages
    ///      before it matures on any pool.
    uint256 private constant FRESH_WINDOW = 30 days;
    /// @dev erc7201:hookr.token.sends, keccak256(abi.encode(uint256(keccak256("hookr.token.sends")) - 1)) & ~0xff: the
    ///      base of each holder's transient sends word (keccak256(holder, base)): the fresh part sent (bits 0-107), the
    ///      total sent (bits 108-215) and the lot's time before the first send (bits 216-255), since the holder last
    ///      received in this transaction.
    bytes32 private constant SENDS_SLOT = 0x2509fdef2ea1d6977cff4872eaefc429ddc1514c869a9d54bf98b06cf18e7000;
    /// @dev The meter's day: UTC days of `block.timestamp`.
    uint256 private constant DAY = 1 days;
    /// @dev A meter word: balance-seconds in its day in units of 2^48 (bits 0-76; a day's are below 2^108 x 86,400 <
    ///      2^125; a wallet's round down, the supply's up, so the wallets never sum past the supply, by at most 2^48
    ///      balance-seconds a move, a wei held a day), the time of its last move (77-108), its day (109-124), the last
    ///      day it wrote an entry for (125-140), the metered flag (bit 141: the account read as a wallet at its last
    ///      move) and, in the supply's word only, the supply held by wallets (142-249), so a move between a wallet and a
    ///      contract touches one word for the supply.
    uint256 private constant UNIT_SHIFT = 48;
    uint256 private constant UNIT_ROUND = (uint256(1) << 48) - 1;
    uint256 private constant BSU_MASK = (uint256(1) << 77) - 1;
    uint256 private constant LAST_SHIFT = 77;
    uint256 private constant DAY_SHIFT = 109;
    uint256 private constant WRITTEN_SHIFT = 125;
    uint256 private constant METERED = uint256(1) << 141;
    uint256 private constant SUPPLY_SHIFT = 142;
    uint256 private constant MASK16 = type(uint16).max;
    uint256 private constant MASK32 = type(uint32).max;
    /// @dev A day entry's balance-seconds, exact (bits 0-127).
    uint256 private constant BS_MASK = (uint256(1) << 128) - 1;
    /// @dev A day entry: the day's balance-seconds (bits 0-127), the balance at the day's end (128-235) and the days
    ///      back to the previous entry (236-255; zero: none).
    uint256 private constant ENTRY_BALANCE_SHIFT = 128;
    uint256 private constant ENTRY_PREV_SHIFT = 236;
    uint256 private constant MASK20 = (uint256(1) << 20) - 1;
    /// @dev The most entries one `balanceSeconds` read walks back through.
    uint256 private constant READ_ENTRIES = 256;
    /// @dev A cursor that says no entry lies at or before its edge, and none ever will.
    uint256 private constant NONE = type(uint32).max;

    /// @dev Each holder's word: balance (bits 0-107), fresh lot (bits 108-215) and freshSince (bits 216-255).
    mapping(address account => uint256) private _holders;
    mapping(address account => mapping(address spender => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    /// @dev Each owner's next permit nonce.
    mapping(address owner => uint256) private _nonces;
    /// @inheritdoc IHookrToken
    string public tagline;
    /// @inheritdoc IHookrToken
    string public logoURI;
    /// @dev The account that created this token, until it sets the presentation or its creating transaction ends.
    address private transient _presenter;
    /// @dev Each wallet's meter word (address zero: the wallets' supply, whose balance rides in the word).
    mapping(address account => uint256) private _meters;
    /// @dev Each wallet's closed days (address zero: the wallets' supply).
    mapping(address account => mapping(uint256 day => uint256)) private _days;

    constructor(string memory name_, string memory symbol_, uint256 supply, address recipient) {
        if (supply == 0) revert ZeroSupply();
        if (supply > MAX_SUPPLY) revert SupplyTooLarge();
        if (
            bytes(name_).length == 0 || bytes(name_).length > 64 || bytes(symbol_).length == 0
                || bytes(symbol_).length > 16
        ) {
            revert InvalidMetadata();
        }
        if (recipient == address(0)) revert ERC20InvalidReceiver(address(0));
        _name = name_;
        _symbol = symbol_;
        _totalSupply = supply;
        _holders[recipient] = supply | supply << FRESH_SHIFT | block.timestamp << SINCE_SHIFT;
        if (_isWallet(recipient)) {
            // The supply starts metered in the wallet's hands (a launcher is a contract: its meter starts at the first
            // transfer to a wallet).
            _meters[recipient] = _started();
            _meters[address(0)] = _started() | supply << SUPPLY_SHIFT;
        }
        emit Transfer(address(0), recipient, supply);
        _presenter = msg.sender;
    }

    /// @inheritdoc IERC20Metadata
    function name() public view returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC20Metadata
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC20Metadata
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @inheritdoc IERC20
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) external view returns (uint256) {
        return _holders[account] & MAX_SUPPLY;
    }

    /// @inheritdoc IHookrToken
    function lots(address account) external view returns (uint256 balance, uint256 fresh, uint256 freshSince) {
        return _lots(_holders[account]);
    }

    /// @inheritdoc IHookrToken
    function lotsBefore(address account, uint256 back)
        external
        view
        returns (uint256 balance, uint256 fresh, uint256 freshSince)
    {
        (balance, fresh, freshSince) = _lots(_holders[account]);
        uint256 sends = _sends(account);
        if (sends == 0) return (balance, fresh, freshSince);
        uint256 total = (sends >> FRESH_SHIFT) & MAX_SUPPLY;
        if (back > total) back = total;
        // The fresh part left first, so the last `back` sent are the aged part's tail, then the fresh part's.
        uint256 agedOut = total - (sends & MAX_SUPPLY);
        uint256 freshBack = back - (back < agedOut ? back : agedOut);
        balance += back;
        if (freshBack != 0) {
            if (fresh == 0) freshSince = sends >> SINCE_SHIFT;
            fresh += freshBack;
        }
    }

    /// @inheritdoc IHookrToken
    function meterOf(address account) external view returns (uint256 balanceSecondsToday, uint256 lastMove, uint256 day, bool metered) {
        uint256 word = _meters[account];
        return ((word & BSU_MASK) << UNIT_SHIFT, (word >> LAST_SHIFT) & MASK32, (word >> DAY_SHIFT) & MASK16, word & METERED != 0);
    }

    /// @inheritdoc IHookrToken
    function balanceSeconds(address account, uint256 fromDay, uint256 toDay) external view returns (uint256[] memory out) {
        (out,,) = _balanceSeconds(account, _holders[account] & MAX_SUPPLY, fromDay, toDay, 0);
    }

    /// @inheritdoc IHookrToken
    function balanceSecondsFrom(address account, uint256 fromDay, uint256 toDay, uint256 hint)
        external view returns (uint256[] memory, uint256, uint256)
    {
        return _balanceSeconds(account, _holders[account] & MAX_SUPPLY, fromDay, toDay, hint);
    }

    /// @inheritdoc IHookrToken
    function walletSupplySeconds(uint256 fromDay, uint256 toDay) external view returns (uint256[] memory out) {
        (out,,) = _balanceSeconds(address(0), _supply(), fromDay, toDay, 0);
    }

    /// @inheritdoc IHookrToken
    function walletSupplySecondsFrom(uint256 fromDay, uint256 toDay, uint256 hint)
        external view returns (uint256[] memory, uint256, uint256)
    {
        return _balanceSeconds(address(0), _supply(), fromDay, toDay, hint);
    }

    /// @inheritdoc IHookrToken
    function walletSupply() external view returns (uint256) {
        return _supply();
    }

    /// @dev The supply held by wallets, as metered (the supply word's own field).
    function _supply() private view returns (uint256) {
        return (_meters[address(0)] >> SUPPLY_SHIFT) & MAX_SUPPLY;
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value, true);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = _allowances[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(msg.sender, current, value);
            unchecked {
                _approve(from, msg.sender, current - value, false);
            }
        }
        _transfer(from, to, value);
        return true;
    }

    /// @inheritdoc IHookrToken
    function setPresentation(string calldata tagline_, string calldata logoURI_) external {
        if (msg.sender != _presenter) revert NotPresenter();
        _presenter = address(0);
        if (bytes(tagline_).length > MAX_TAGLINE_BYTES || bytes(logoURI_).length > MAX_LOGO_URI_BYTES) {
            revert InvalidMetadata();
        }
        tagline = tagline_;
        logoURI = logoURI_;
    }

    /// @inheritdoc IERC20Permit
    /// @dev Reverts ERC2612ExpiredSignature after `deadline`, ECDSAInvalidSignature or ECDSAInvalidSignatureS for a
    ///      malformed or malleable signature, and ERC2612InvalidSigner when the signature recovers to anyone but
    ///      `owner`. An accepted permit uses `owner`'s nonce, so a signature verifies once; anyone may submit it.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);
        bytes32 structHash;
        unchecked {
            // A nonce counts up by one per accepted permit, so it never overflows.
            structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _nonces[owner]++, deadline));
        }
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash), v, r, s);
        if (signer != owner) revert ERC2612InvalidSigner(signer, owner);
        _approve(owner, spender, value, true);
    }

    /// @inheritdoc IERC20Permit
    function nonces(address owner) external view returns (uint256) {
        return _nonces[owner];
    }

    /// @inheritdoc IERC20Permit
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @inheritdoc IERC5267
    /// @dev Fields 0x0f: name, version, chain id and verifying contract; no salt and no extensions. The chain id is
    ///      block.chainid when read.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name_,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", name(), "1", block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /// @dev `word`'s balance, fresh lot and lot time, the lot counted in the aged bag once FRESH_WINDOW has passed its
    ///      time, so a read and the next write see the same lot.
    function _lots(uint256 word) private view returns (uint256 balance, uint256 fresh, uint256 since) {
        balance = word & MAX_SUPPLY;
        fresh = (word >> FRESH_SHIFT) & MAX_SUPPLY;
        since = word >> SINCE_SHIFT;
        if (fresh != 0 && since + FRESH_WINDOW <= block.timestamp) (fresh, since) = (0, 0);
    }

    /// @dev OpenZeppelin's `_transfer` and `_update` for a transfer between two accounts (the supply is minted once in
    ///      the constructor and never burned). The sender's fresh lot leaves first, then its aged bag, and its lot's time
    ///      stays; the receiver's lot grows by `value` and its time moves toward now by `value`'s share of the lot,
    ///      rounded up. Either lot has aged into the bag first if its window has passed.
    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        (uint256 balance, uint256 fresh, uint256 since) = _lots(_holders[from]);
        if (balance < value) revert ERC20InsufficientBalance(from, balance, value);
        if (from != to) {
            _meterSides(from, to, balance, value);
            unchecked {
                if (value != 0) {
                    // The transaction's sends: the fresh part and the total, bounded by the balance when they began,
                    // and the lot's time before the first of them.
                    uint256 sends = _sends(from);
                    uint256 fresher = value < fresh ? value : fresh;
                    if (sends == 0) sends = since << SINCE_SHIFT;
                    _setSends(from, sends + fresher + (value << FRESH_SHIFT));
                }
                // value <= balance. A lot emptied by the send drops its time.
                balance -= value;
                if (value < fresh) fresh -= value;
                else (fresh, since) = (0, 0);
                _holders[from] = balance | fresh << FRESH_SHIFT | since << SINCE_SHIFT;
                (balance, fresh, since) = _lots(_holders[to]);
                // Every balance is at most the supply, below 2^108.
                balance += value;
                if (value != 0) {
                    // A receive starts the receiver's sends over: what it sends next leaves the lot as it now stands.
                    if (_sends(to) != 0) _setSends(to, 0);
                    uint256 next = fresh + value;
                    if (fresh == 0) {
                        since = block.timestamp;
                    } else if (since < block.timestamp) {
                        // The time moves toward now by (now - since) * value / next, rounded up: the product is below
                        // 2^40 * 2^108, and the step is at most now - since, so the time never passes now.
                        uint256 product = (block.timestamp - since) * value;
                        since += product / next + (product % next == 0 ? 0 : 1);
                    }
                    fresh = next;
                }
                _holders[to] = balance | fresh << FRESH_SHIFT | since << SINCE_SHIFT;
            }
        }
        emit Transfer(from, to, value);
    }

    /// @dev The meter, run before a transfer moves the balances: each side that is a wallet accrues its balance-seconds
    ///      up to now (closing its last day into an entry when the day changed), and the wallets' supply accrues the
    ///      same way when it changes: a transfer between a wallet and a contract, or a side whose wallet status changed
    ///      since its last move (a contract deployed onto a funded address, a 7702 designator set or cleared).
    function _meterSides(address from, address to, uint256 held, uint256 value) private {
        bool fromWallet = _isWallet(from);
        bool toWallet = _isWallet(to);
        uint256 fromWord = _meters[from];
        uint256 toWord = _meters[to];
        uint256 toHeld = _holders[to] & MAX_SUPPLY;
        // The wallets' supply as metered so far, then as it stands after this transfer.
        uint256 supplyWord = _meters[address(0)];
        uint256 supply = (supplyWord >> SUPPLY_SHIFT) & MAX_SUPPLY;
        uint256 next = supply;
        // The metered balances leave the count and the wallet balances after the move join it; a balance the meter never
        // saw (nothing on chain writes one) is clamped rather than let the transfer fail.
        if (fromWord & METERED != 0) next = next > held ? next - held : 0;
        if (toWord & METERED != 0) next = next > toHeld ? next - toHeld : 0;
        if (fromWallet) next += held - value;
        if (toWallet) next += toHeld + value;
        if (next != supply) {
            _meters[address(0)] = _meter(address(0), supplyWord, supply, true) | next << SUPPLY_SHIFT;
        }
        if (fromWallet || fromWord != 0) _meters[from] = _meter(from, fromWord, held, fromWallet);
        if (toWallet || toWord != 0) _meters[to] = _meter(to, toWord, toHeld, toWallet);
    }

    /// @dev Accrues `account`'s meter with `held` tokens up to now: within its day the day's balance-seconds grow; on a
    ///      new day the old day closes into an entry (its balance-seconds, the balance at its end, the days back to the
    ///      previous entry) and the new day starts. `wallet` false stops the meter (the account reads as a contract):
    ///      the day closes and the word keeps its history unmetered; a later wallet status starts it again from then.
    function _meter(address account, uint256 word, uint256 held, bool wallet) private returns (uint256) {
        // Stopped and still a contract: nothing to accrue (its stop wrote the entry that reads its days after as zero).
        if (word & METERED == 0 && !wallet) return word;
        uint256 today = block.timestamp / DAY;
        uint256 bs;
        uint256 last = block.timestamp;
        uint256 day = today;
        uint256 written;
        if (word & METERED != 0) {
            bs = (word & BSU_MASK) << UNIT_SHIFT;
            last = (word >> LAST_SHIFT) & MASK32;
            day = (word >> DAY_SHIFT) & MASK16;
            written = (word >> WRITTEN_SHIFT) & MASK16;
        } else if (word != 0) {
            // Unmetered since its last move: its entries stay, metering starts again now if it is a wallet.
            written = (word >> WRITTEN_SHIFT) & MASK16;
        }
        // The supply's word rounds its units up, a wallet's down.
        uint256 round = account == address(0) ? UNIT_ROUND : 0;
        unchecked {
            if (day == today) {
                bs += held * (block.timestamp - last);
            } else {
                // Close `day`; the days between it and today had `held` all day, which the entry's balance tells.
                written = _close(account, day, written, bs + held * ((day + 1) * DAY - last), held);
                bs = held * (block.timestamp - today * DAY);
            }
            if (!wallet) {
                // Stopped: today closes too, so its balance-seconds as a wallet are kept, with no balance carried into
                // the days after (a contract's read zero); the word stays unmetered until a wallet status starts it.
                if (bs != 0 || written != 0) written = _close(account, today, written, bs, 0);
                return written << WRITTEN_SHIFT;
            }
            bs = (bs + round) >> UNIT_SHIFT;
        }
        return bs | block.timestamp << LAST_SHIFT | today << DAY_SHIFT | written << WRITTEN_SHIFT | METERED;
    }

    /// @dev Writes `day`'s entry (`bs` balance-seconds, `held` at its end, the days back to `written`, the previous
    ///      entry) and returns `day` as the last written. A day that already has an entry (the meter stopped and started
    ///      again in it) adds to it and keeps its link.
    function _close(address account, uint256 day, uint256 written, uint256 bs, uint256 held) private returns (uint256) {
        // Nothing held, nothing accrued, nothing before: no entry (an all-zero word would read as none).
        if (bs == 0 && held == 0 && written == 0) return 0;
        uint256 back;
        if (written == day) {
            uint256 old = _days[account][day];
            bs += old & BS_MASK;
            back = old >> ENTRY_PREV_SHIFT;
        } else if (written != 0) {
            back = day - written;
        }
        _days[account][day] = bs | held << ENTRY_BALANCE_SHIFT | back << ENTRY_PREV_SHIFT;
        return day;
    }

    /// @dev A meter word that starts now, with nothing accrued.
    function _started() private view returns (uint256) {
        return block.timestamp << LAST_SHIFT | (block.timestamp / DAY) << DAY_SHIFT | METERED;
    }

    /// @dev `account`'s balance-seconds on each closed day from `fromDay` to `toDay`, `held` its balance now, read from a
    ///      cursor: `hint` is the cursor a previous read returned for the day before `fromDay` or after `toDay` (zero:
    ///      none yet, start from the newest entry). A cursor is an entry day, or the edge day itself while the account
    ///      had not moved past it (its entry may be written later; the read then finds it, or walks from the newest
    ///      entry through the moves since), or NONE when no entry lies at or before the edge and none ever will (the
    ///      days at or before it read zero; the days after it read as they are). The entry at or before `fromDay - 1` found, the days read forward: a day with
    ///      its own entry reads it, a day without reads the balance the last entry ended with all day, the day of the
    ///      account's last move reads the word's accrual plus the rest of the day (and the day's stop entry, if the
    ///      meter stopped and started in it), later days the balance all day, days before the first entry zero. A
    ///      stopped account reads zero after its last entry.
    function _balanceSeconds(address account, uint256 held, uint256 fromDay, uint256 toDay, uint256 hint)
        private view returns (uint256[] memory out, uint256 startCursor, uint256 endCursor)
    {
        uint256 today = block.timestamp / DAY;
        if (fromDay == 0 || fromDay > toDay || toDay >= today) revert DaysNotClosed();
        out = new uint256[](toDay - fromDay + 1);
        uint256 word = _meters[account];
        bool metered = word & METERED != 0;
        uint256 day = (word >> DAY_SHIFT) & MASK16;
        uint256 at;
        uint256 entry;
        // NONE: nothing lies at or before the edge, so the days read from no earlier entry (their own entries, the open
        // day and the days after it still read as they are).
        if (hint != 0 && hint != NONE) {
            entry = _days[account][hint];
            if (entry != 0) at = hint;
        }
        if (at == 0 && hint != NONE) {
            at = (word >> WRITTEN_SHIFT) & MASK16;
            entry = at == 0 ? 0 : _days[account][at];
        }
        uint256 reads;
        while (at >= fromDay) {
            uint256 back = entry >> ENTRY_PREV_SHIFT;
            if (back == 0) { at = 0; entry = 0; break; }
            if (++reads > READ_ENTRIES) revert TooManyEntries();
            at -= back;
            entry = _days[account][at];
        }
        startCursor = _cursor(metered, day, fromDay - 1, at);
        for (uint256 e = fromDay; e <= toDay; ++e) {
            uint256 bs;
            if (metered && e > day) bs = held * DAY;
            else if (metered && e == day) {
                bs = ((word & BSU_MASK) << UNIT_SHIFT) + held * ((day + 1) * DAY - ((word >> LAST_SHIFT) & MASK32));
                uint256 own = _days[account][day];
                if (own != 0) { at = day; entry = own; bs += own & BS_MASK; }
            } else {
                uint256 own = _days[account][e];
                if (own != 0) { at = e; entry = own; bs = own & BS_MASK; }
                else if (at != 0) bs = ((entry >> ENTRY_BALANCE_SHIFT) & MAX_SUPPLY) * DAY;
            }
            out[e - fromDay] = bs;
        }
        endCursor = _cursor(metered, day, toDay, at);
    }

    /// @dev The cursor for `edge`: the edge itself while the metered account has not moved past it (its entry is not
    ///      final), else the entry at or before it (`at`), else NONE.
    function _cursor(bool metered, uint256 day, uint256 edge, uint256 at) private pure returns (uint256) {
        if (metered && edge >= day) return edge;
        return at != 0 ? at : NONE;
    }

    /// @dev The wallet predicate the core uses (HookrWallets): no code, or an exact 23-byte EIP-7702 designator.
    function _isWallet(address account) private view returns (bool wallet) {
        assembly ("memory-safe") {
            let size := extcodesize(account)
            wallet := iszero(size)
            if eq(size, 23) {
                extcodecopy(account, 0, 0, 3)
                wallet := eq(shr(232, mload(0)), 0xef0100)
            }
        }
    }

    /// @dev `account`'s sends word for this transaction (SENDS_SLOT).
    function _sends(address account) private view returns (uint256 word) {
        bytes32 slot = _sendsSlot(account);
        assembly ("memory-safe") {
            word := tload(slot)
        }
    }

    function _setSends(address account, uint256 word) private {
        bytes32 slot = _sendsSlot(account);
        assembly ("memory-safe") {
            tstore(slot, word)
        }
    }

    function _sendsSlot(address account) private pure returns (bytes32 slot) {
        bytes32 base = SENDS_SLOT;
        assembly ("memory-safe") {
            mstore(0, account)
            mstore(32, base)
            slot := keccak256(0, 64)
        }
    }

    /// @dev OpenZeppelin's `_approve`, with its zero-address checks; `emitEvent` false only when an allowance is spent.
    function _approve(address owner, address spender, uint256 value, bool emitEvent) private {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        if (emitEvent) emit Approval(owner, spender, value);
    }

    /// @dev keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(name), keccak256("1"), block.chainid, this)).
    function _domainSeparator() private view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), VERSION_HASH, block.chainid, address(this)));
    }
}
