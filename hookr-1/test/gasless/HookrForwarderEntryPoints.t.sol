// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {HookrForwarder} from "../../src/gasless/HookrForwarder.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {IPermit2Signature} from "../../src/interfaces/external/IPermit2Signature.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {GaslessToken, MockRegistry, MockRoot, MockRouter} from "./GaslessMocks.sol";

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev An EIP-2612 token, the input side of the intents below.
contract ForwarderPermitToken is ERC20Permit {
    constructor() ERC20("Permit Quote", "PQ") ERC20Permit("Permit Quote") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token whose fallback answers every call it has no function for, as WETH9's payable fallback does: its
///      `permit` succeeds and grants nothing.
contract PhantomPermitToken is GaslessToken {
    fallback() external payable {}
}

/// @dev A smart wallet that signs through ERC-1271: it accepts its signer key's ECDSA signature over the digest and
///      answers `answer`, the ERC-1271 magic value unless a test sets another.
contract Erc1271Wallet is IERC1271 {
    address public immutable signer;
    bytes4 public answer = IERC1271.isValidSignature.selector;

    constructor(address signer_) {
        signer = signer_;
    }

    function setAnswer(bytes4 value) external {
        answer = value;
    }

    function approveToken(address token, address spender) external {
        ERC20(token).approve(spender, type(uint256).max);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) return 0xffffffff;
        return answer;
    }
}

/// @dev The code an EIP-7702 account delegates to: ERC-1271 for the account's own key.
contract Erc1271Delegate {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        bool valid = err == ECDSA.RecoverError.NoError && recovered == address(this);
        return valid ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    fallback() external payable {}
}

/// @dev A delegate with no ERC-1271 (a session-key wallet): every call it has no function for returns nothing.
contract PlainDelegate {
    fallback() external payable {}
}

/// @notice HookrForwarder's entry points against the real Permit2 (the Robinhood Chain 4663 runtime, etched at its
///         address): executeWithTokenPermit with a valid EIP-2612 permit, a bad one, an expired one and one a front-
///         runner already submitted; ERC-1271 signers (a smart wallet and an EIP-7702 account) accepted through Permit2
///         and a wallet answering the wrong magic value refused; a Permit2 unordered nonce invalidated before use.
/// @dev The forwarder only tries the permit and ignores its failure: Permit2's allowance and the signed witness decide
///      every pull, so a permit that fails, expired or was front-run grants nothing by itself, and a call that fails
///      after it rolls the permit back. The router is GaslessMocks' MockRouter: it pulls the input the forwarder
///      approved and pays the recipient, so the Permit2 pull and the forwarder's own checks run for real.
contract HookrForwarderEntryPointsTest is Test {
    address internal constant PERMIT2 = Chain4663Code.PERMIT2_ADDRESS;
    address internal constant RELAYER = address(0xFEE);
    address internal constant RECIPIENT = address(0x1002);
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    /// @dev Permit2's errors (SignatureTransfer, SignatureVerification) and the revert of its token pull (solmate's
    ///      SafeTransferLib) when the owner's allowance to Permit2 does not cover it.
    bytes4 internal constant INVALID_NONCE = bytes4(keccak256("InvalidNonce()"));
    bytes4 internal constant INVALID_SIGNER = bytes4(keccak256("InvalidSigner()"));
    bytes4 internal constant INVALID_CONTRACT_SIGNATURE = bytes4(keccak256("InvalidContractSignature()"));
    string internal constant TRANSFER_FROM_FAILED = "TRANSFER_FROM_FAILED";
    uint256 internal constant IN = 1_000;
    uint256 internal constant OUT = 500;
    uint256 internal constant FEE = 10;
    uint256 internal constant PULL = IN + FEE;
    uint256 internal constant HELD = 10_000;
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;

    MockRegistry internal registry;
    MockRoot internal root;
    MockRouter internal router;
    ForwarderPermitToken internal input;
    GaslessToken internal output;
    HookrForwarder internal fwd;
    address internal owner;

    function setUp() public {
        vm.chainId(4663);
        vm.setEvmVersion("prague");
        vm.etch(PERMIT2, Chain4663Code.PERMIT2);
        owner = vm.addr(OWNER_PK);
        registry = new MockRegistry();
        root = new MockRoot();
        router = new MockRouter();
        input = new ForwarderPermitToken();
        output = new GaslessToken();
        fwd = new HookrForwarder(PERMIT2, address(registry), address(router));
        registry.set(address(root));
        // A buy: the input is the pool's quote, so the relayer fee is paid from the input.
        root.setQuote(Currency.wrap(address(input)));
        router.set(IN, OUT);
        input.mint(owner, HELD);
    }

    // ───────────────────────────── executeWithTokenPermit ─────────────────────────────

    /// The permit approves Permit2 (never the forwarder) for the owner, then the intent pulls through Permit2 with the
    /// signed witness: the owner pays the input and the fee, the relayer gets the fee and nothing stays behind.
    function test_executeWithTokenPermit_validPermit_approvesPermit2AndExecutes() public {
        assertEq(input.allowance(owner, PERMIT2), 0, "no Permit2 allowance yet");
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        IHookrForwarder.TokenPermit memory p = _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _sign(i, OWNER_PK);
        vm.expectEmit(address(input));
        emit IERC20.Approval(owner, PERMIT2, PULL);
        vm.prank(RELAYER);
        (uint256 amountIn, uint256 amountOut) = fwd.executeWithTokenPermit(i, owner, sig, p);
        assertEq(amountIn, IN);
        assertEq(amountOut, OUT);
        assertEq(input.nonces(owner), 1, "the permit was used");
        assertEq(input.allowance(owner, PERMIT2), 0, "the pull spent the permitted amount");
        assertEq(input.allowance(owner, address(fwd)), 0, "the forwarder is never the spender");
        _assertExecuted(i, owner, address(input), 1);
    }

    /// A permit signed by another key, for another spender or for another value fails inside the forwarder and is
    /// ignored: with no Permit2 allowance the pull fails and nothing changes; with a standing allowance the intent
    /// executes and the permit's nonce is still unused.
    function test_executeWithTokenPermit_badPermit_isIgnored() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        bytes memory sig = _sign(i, OWNER_PK);
        IHookrForwarder.TokenPermit[3] memory bad = [
            _permit(OTHER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours),
            _permit(OWNER_PK, address(fwd), PULL, vm.getBlockTimestamp() + 1 hours),
            _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours)
        ];
        bad[2].value = PULL + 1;
        for (uint256 k; k < bad.length; ++k) {
            vm.prank(RELAYER);
            vm.expectRevert(bytes(TRANSFER_FROM_FAILED));
            fwd.executeWithTokenPermit(i, owner, sig, bad[k]);
            assertEq(input.nonces(owner), 0);
            assertEq(input.allowance(owner, PERMIT2), 0);
            assertFalse(fwd.isNonceUsed(owner, i.nonce));
        }
        vm.prank(owner);
        input.approve(PERMIT2, PULL);
        vm.prank(RELAYER);
        fwd.executeWithTokenPermit(i, owner, sig, bad[0]);
        assertEq(input.nonces(owner), 0, "the bad permit never counted");
        _assertExecuted(i, owner, address(input), 1);
    }

    /// An expired permit is ignored the same way.
    function test_executeWithTokenPermit_expiredPermit_isIgnored() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        bytes memory sig = _sign(i, OWNER_PK);
        IHookrForwarder.TokenPermit memory p = _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() - 1);
        vm.prank(RELAYER);
        vm.expectRevert(bytes(TRANSFER_FROM_FAILED));
        fwd.executeWithTokenPermit(i, owner, sig, p);
        assertEq(input.nonces(owner), 0);
        assertEq(input.allowance(owner, PERMIT2), 0);
        vm.prank(owner);
        input.approve(PERMIT2, PULL);
        vm.prank(RELAYER);
        fwd.executeWithTokenPermit(i, owner, sig, p);
        assertEq(input.nonces(owner), 0);
        _assertExecuted(i, owner, address(input), 1);
    }

    /// A front-runner submits the owner's permit first, so its nonce is spent: the forwarder's own permit call fails,
    /// the allowance the front-run set pays the pull, and the intent executes as it would have. The front-runner gains
    /// nothing.
    function test_executeWithTokenPermit_frontRunPermit_stillExecutes() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        IHookrForwarder.TokenPermit memory p = _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours);
        address frontRunner = makeAddr("frontRunner");
        vm.prank(frontRunner);
        input.permit(owner, PERMIT2, p.value, p.deadline, p.v, p.r, p.s);
        assertEq(input.nonces(owner), 1);
        assertEq(input.allowance(owner, PERMIT2), PULL);

        bytes memory sig = _sign(i, OWNER_PK);
        vm.expectCall(address(input), abi.encodeWithSelector(IERC20Permit.permit.selector), 1);
        vm.prank(RELAYER);
        (uint256 amountIn, uint256 amountOut) = fwd.executeWithTokenPermit(i, owner, sig, p);
        assertEq(amountIn, IN);
        assertEq(amountOut, OUT);
        assertEq(input.nonces(owner), 1, "spent once, by the front-run");
        assertEq(input.allowance(owner, PERMIT2), 0);
        assertEq(input.balanceOf(frontRunner), 0);
        assertEq(output.balanceOf(frontRunner), 0);
        _assertExecuted(i, owner, address(input), 1);
    }

    /// A valid permit with an intent the owner did not sign: Permit2 refuses the witness and the whole call reverts,
    /// so the permit's approval is rolled back with it.
    function test_executeWithTokenPermit_validPermitWithAForeignIntentSignature_grantsNothing() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        IHookrForwarder.TokenPermit memory p = _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours);
        bytes memory foreign = _sign(i, OTHER_PK);
        vm.prank(RELAYER);
        vm.expectRevert(INVALID_SIGNER);
        fwd.executeWithTokenPermit(i, owner, foreign, p);
        assertEq(input.nonces(owner), 0, "the permit rolled back");
        assertEq(input.allowance(owner, PERMIT2), 0);
        assertEq(input.balanceOf(owner), HELD);
    }

    /// A zero value skips the permit call; the intent then runs as `execute` on a standing allowance.
    function test_executeWithTokenPermit_zeroValueSkipsThePermit() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        IHookrForwarder.TokenPermit memory p = _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours);
        p.value = 0;
        vm.prank(owner);
        input.approve(PERMIT2, PULL);
        bytes memory sig = _sign(i, OWNER_PK);
        vm.expectCall(address(input), abi.encodeWithSelector(IERC20Permit.permit.selector), 0);
        vm.prank(RELAYER);
        fwd.executeWithTokenPermit(i, owner, sig, p);
        assertEq(input.nonces(owner), 0);
        _assertExecuted(i, owner, address(input), 1);
    }

    /// An input without EIP-2612 (its permit call reverts) and one whose fallback swallows the call (its permit
    /// "succeeds" and approves nothing): neither grants an allowance, so each intent still needs the owner's own
    /// Permit2 allowance, and executes with it.
    function test_executeWithTokenPermit_inputsWithoutPermit_needTheOwnersAllowance() public {
        GaslessToken plain = new GaslessToken();
        PhantomPermitToken phantom = new PhantomPermitToken();
        GaslessToken[2] memory tokens = [plain, GaslessToken(address(phantom))];
        for (uint256 k; k < 2; ++k) {
            GaslessToken t = tokens[k];
            root.setQuote(Currency.wrap(address(t)));
            t.mint(owner, HELD);
            IHookrForwarder.HookrSwapIntent memory i = _intent(address(t), 10 + k);
            bytes memory sig = _sign(i, OWNER_PK);
            IHookrForwarder.TokenPermit memory p = _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours);
            vm.prank(RELAYER);
            vm.expectRevert(bytes(TRANSFER_FROM_FAILED));
            fwd.executeWithTokenPermit(i, owner, sig, p);
            assertEq(t.allowance(owner, PERMIT2), 0);
            vm.prank(owner);
            t.approve(PERMIT2, PULL);
            vm.prank(RELAYER);
            fwd.executeWithTokenPermit(i, owner, sig, p);
            _assertExecuted(i, owner, address(t), k + 1);
        }
    }

    // ───────────────────────────── ERC-1271 signers ─────────────────────────────

    /// A smart wallet that answers ERC-1271 signs intents through Permit2, by `execute` and by
    /// `executeWithTokenPermit` with no permit; the wallet pays and its nonce is consumed.
    function test_erc1271Wallet_isAcceptedThroughPermit2() public {
        Erc1271Wallet wallet = _wallet();
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        bytes memory sig = _sign(i, OWNER_PK);
        vm.prank(RELAYER);
        fwd.execute(i, address(wallet), sig);
        _assertExecuted(i, address(wallet), address(input), 1);

        IHookrForwarder.HookrSwapIntent memory j = _intent(address(input), 2);
        IHookrForwarder.TokenPermit memory none;
        sig = _sign(j, OWNER_PK);
        vm.prank(RELAYER);
        fwd.executeWithTokenPermit(j, address(wallet), sig, none);
        assertTrue(fwd.isNonceUsed(address(wallet), 2));
        assertEq(input.balanceOf(address(wallet)), HELD - 2 * PULL);
    }

    /// A wallet that answers anything but the ERC-1271 magic value is refused by Permit2, and so is a signature its
    /// signer key did not make; nothing moves and the nonce stays unused.
    function test_erc1271Wallet_answeringTheWrongMagicIsRefused() public {
        Erc1271Wallet wallet = _wallet();
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        bytes memory sig = _sign(i, OWNER_PK);
        bytes4[3] memory answers = [bytes4(0), bytes4(0xffffffff), bytes4(keccak256("isValidSignature(bytes,bytes)"))];
        for (uint256 k; k < answers.length; ++k) {
            wallet.setAnswer(answers[k]);
            vm.prank(RELAYER);
            vm.expectRevert(INVALID_CONTRACT_SIGNATURE);
            fwd.execute(i, address(wallet), sig);
        }
        wallet.setAnswer(IERC1271.isValidSignature.selector);
        bytes memory foreign = _sign(i, OTHER_PK);
        vm.prank(RELAYER);
        vm.expectRevert(INVALID_CONTRACT_SIGNATURE);
        fwd.execute(i, address(wallet), foreign);
        assertFalse(fwd.isNonceUsed(address(wallet), 1));
        assertEq(input.balanceOf(address(wallet)), HELD);
        assertEq(output.balanceOf(RECIPIENT), 0);
    }

    /// An EIP-7702 account has code, so Permit2 checks its signature through ERC-1271, not ECDSA: through a delegate
    /// that answers ERC-1271 for the account's key its intent executes; through a delegate without ERC-1271 the same
    /// key's valid signature is refused.
    function test_eip7702Account_signsOnlyThroughItsDelegatesErc1271() public {
        uint256 pk = 0x7702;
        address account = vm.addr(pk);
        _delegate(account, pk, address(new Erc1271Delegate()));
        input.mint(account, HELD);
        vm.prank(account);
        input.approve(PERMIT2, type(uint256).max);
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 1);
        bytes memory sig = _sign(i, pk);
        vm.prank(RELAYER);
        fwd.execute(i, account, sig);
        _assertExecuted(i, account, address(input), 1);

        uint256 pk2 = 0x7703;
        address plain = vm.addr(pk2);
        _delegate(plain, pk2, address(new PlainDelegate()));
        input.mint(plain, HELD);
        vm.prank(plain);
        input.approve(PERMIT2, type(uint256).max);
        IHookrForwarder.HookrSwapIntent memory j = _intent(address(input), 1);
        sig = _sign(j, pk2);
        vm.prank(RELAYER);
        (bool ok, bytes memory err) = address(fwd).call(abi.encodeCall(fwd.execute, (j, plain, sig)));
        assertFalse(ok, "refused");
        assertEq(err.length, 0, "Permit2 got no ERC-1271 answer to read");
        assertFalse(fwd.isNonceUsed(plain, 1));
        assertEq(input.balanceOf(plain), HELD);
    }

    // ───────────────────────────── Permit2 unordered nonces ─────────────────────────────

    /// The owner cancels an intent before it is used by invalidating its Permit2 nonce (the word and bit `nonceWord`
    /// gives): `isNonceUsed` reports it and both entry points refuse the intent, a valid permit included, with nothing
    /// moved.
    function test_permit2NonceInvalidatedBeforeUse_refusesTheIntent() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 0x1ff);
        bytes memory sig = _sign(i, OWNER_PK);
        (uint256 wordPos, uint256 mask) = fwd.nonceWord(i.nonce);
        assertFalse(fwd.isNonceUsed(owner, i.nonce));
        vm.prank(owner);
        IPermit2Signature(PERMIT2).invalidateUnorderedNonces(wordPos, mask);
        assertTrue(fwd.isNonceUsed(owner, i.nonce));
        assertEq(IPermit2Signature(PERMIT2).nonceBitmap(owner, wordPos), mask);

        vm.prank(owner);
        input.approve(PERMIT2, PULL);
        vm.prank(RELAYER);
        vm.expectRevert(INVALID_NONCE);
        fwd.execute(i, owner, sig);
        vm.prank(owner);
        input.approve(PERMIT2, 0);
        IHookrForwarder.TokenPermit memory p = _permit(OWNER_PK, PERMIT2, PULL, vm.getBlockTimestamp() + 1 hours);
        vm.prank(RELAYER);
        vm.expectRevert(INVALID_NONCE);
        fwd.executeWithTokenPermit(i, owner, sig, p);
        assertEq(input.nonces(owner), 0, "the permit rolled back");
        assertEq(input.balanceOf(owner), HELD);
        assertEq(output.balanceOf(RECIPIENT), 0);
    }

    /// The Permit2 nonce is the forwarder's derivation, not the intent nonce itself: invalidating the raw intent nonce,
    /// or another bit of the derived word, leaves the intent valid. Once used, the same intent is refused as a replay.
    function test_permit2Nonce_onlyTheDerivedBitCancels_andAUsedIntentIsNotReplayed() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(address(input), 0x1ff);
        bytes memory sig = _sign(i, OWNER_PK);
        (uint256 wordPos, uint256 mask) = fwd.nonceWord(i.nonce);
        vm.startPrank(owner);
        IPermit2Signature(PERMIT2).invalidateUnorderedNonces(i.nonce >> 8, uint256(1) << (i.nonce & 0xff));
        IPermit2Signature(PERMIT2).invalidateUnorderedNonces(wordPos, ~mask);
        input.approve(PERMIT2, 2 * PULL);
        vm.stopPrank();
        assertFalse(fwd.isNonceUsed(owner, i.nonce));
        vm.prank(RELAYER);
        fwd.execute(i, owner, sig);
        _assertExecuted(i, owner, address(input), 1);
        vm.prank(RELAYER);
        vm.expectRevert(INVALID_NONCE);
        fwd.execute(i, owner, sig);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev An exact-input buy of IN from `token` (the pool's quote) to the GaslessToken output, relayed by RELAYER for
    ///      FEE of the input.
    function _intent(address token, uint256 nonce) internal view returns (IHookrForwarder.HookrSwapIntent memory i) {
        bool inputIs0 = token < address(output);
        (address c0, address c1) = inputIs0 ? (token, address(output)) : (address(output), token);
        i.key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0x800000, 60, IHooks(address(root)));
        i.zeroForOne = inputIs0;
        i.amountSpecified = -int128(int256(IN));
        i.amountBound = 1;
        i.recipient = RECIPIENT;
        i.relayer = RELAYER;
        i.relayerFee = FEE;
        i.nonce = nonce;
        i.deadline = vm.getBlockTimestamp() + 60;
    }

    /// @dev The Permit2 witness signature of `i` by `pk` over the forwarder's pull.
    function _sign(IHookrForwarder.HookrSwapIntent memory i, uint256 pk) internal view returns (bytes memory) {
        (address token, uint256 amount,) = fwd.pullOf(i);
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                fwd.WITNESS_TYPE_STRING()
            )
        );
        bytes32 permitted =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 structHash = keccak256(
            abi.encode(typeHash, permitted, address(fwd), fwd.permit2Nonce(i.nonce), i.deadline, fwd.hashIntent(i))
        );
        bytes32 domain = IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev An EIP-2612 permit of `value` from `pk`'s address to `spender` on the permit token, at its current nonce.
    function _permit(uint256 pk, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (IHookrForwarder.TokenPermit memory p)
    {
        address holder = vm.addr(pk);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, input.nonces(holder), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", input.DOMAIN_SEPARATOR(), structHash));
        (p.v, p.r, p.s) = vm.sign(pk, digest);
        p.value = value;
        p.deadline = deadline;
    }

    /// @dev A smart wallet signed for by OWNER_PK, holding HELD of the input and approving Permit2.
    function _wallet() internal returns (Erc1271Wallet wallet) {
        wallet = new Erc1271Wallet(owner);
        input.mint(address(wallet), HELD);
        wallet.approveToken(address(input), PERMIT2);
    }

    /// @dev Points `account` (key `pk`) at `delegate` through an EIP-7702 authorization applied by the next call.
    function _delegate(address account, uint256 pk, address delegate) internal {
        vm.signAndAttachDelegation(delegate, pk);
        (bool ok,) = account.call("");
        assertTrue(ok);
        assertEq(account.code.length, 23);
        assertEq(uint24(bytes3(account.code)), 0xef0100);
    }

    /// @dev The first intent of `token`, signed by `payer`, executed as the test's `executed`-th: the payer paid the
    ///      pull, the relayer got its fee, the router the input, the recipient OUT per executed intent, and the
    ///      forwarder holds nothing and allows the router nothing.
    function _assertExecuted(IHookrForwarder.HookrSwapIntent memory i, address payer, address token, uint256 executed)
        internal
        view
    {
        ERC20 t = ERC20(token);
        assertTrue(fwd.isNonceUsed(payer, i.nonce), "nonce consumed");
        assertEq(t.balanceOf(payer), HELD - PULL, "the signer paid the input and the fee");
        assertEq(t.balanceOf(RELAYER), FEE, "the relayer's fee");
        assertEq(t.balanceOf(address(router)), IN, "the router's input");
        assertEq(output.balanceOf(RECIPIENT), executed * OUT, "the recipient's output");
        assertEq(t.balanceOf(address(fwd)), 0, "nothing left in the forwarder");
        assertEq(t.allowance(address(fwd), address(router)), 0, "the router allowance is reset");
    }
}
