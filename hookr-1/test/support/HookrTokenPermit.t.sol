// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrToken} from "../../src/interfaces/IHookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";

/// @dev OpenZeppelin's ERC20Permit, the reference the hand-written permit is checked against.
contract ReferencePermitToken is ERC20Permit {
    constructor(string memory name_) ERC20(name_, "REF") ERC20Permit(name_) {}
}

/// @notice HookrToken's EIP-2612 permit (N16), written without immutables, so every HookrToken keeps one runtime
///         codehash and HookrRules keeps recognising launched tokens. A known-answer vector, OpenZeppelin's
///         implementation as a reference, replay, expiry, signer, malleability and domain refusals, nonces, and the
///         Hookr minimum on a launched token's plain pool.
contract HookrTokenPermitTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    /// @dev secp256k1's n / 2: a signature with a larger s is the malleable twin of a valid one.
    uint256 internal constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SUPPLY = 1e24;

    uint256 internal ownerKey = 0xA11CE;
    address internal owner;
    address internal spender = address(0x5BE7);
    HookrToken internal token;

    function setUp() public {
        _setUpPeriphery();
        owner = vm.addr(ownerKey);
        token = new HookrToken("Hookr Permit", "HKP", SUPPLY, owner);
    }

    function _domain(address verifying, string memory name_) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name_)), keccak256("1"), block.chainid, verifying));
    }

    function _digest(address t, address o, address s, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, o, s, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", _domain(t, ERC20(t).name()), structHash));
    }

    function _sign(uint256 key, address t, address o, address s, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 sig)
    {
        return vm.sign(key, _digest(t, o, s, value, nonce, deadline));
    }

    // ------------------------------------------------------------------------------------------------ vectors

    /// @notice A known-answer vector computed outside Solidity (cast keccak, abi-encode and wallet sign --no-hash): the
    ///         domain separator of a token named "Hookr Permit Vector" at 0x1111...1111 on chain 4663, the digest of a
    ///         permit of 1e18 to 0x2222...2222 at nonce 0 and deadline 2,000,000,000 from the owner of key 0xa11ce,
    ///         and that key's RFC 6979 signature of it.
    function test_knownAnswerVector() public {
        address vectorToken = 0x1111111111111111111111111111111111111111;
        address to = 0x2222222222222222222222222222222222222222;
        vm.chainId(4663);
        deployCodeTo("HookrToken.sol:HookrToken", abi.encode("Hookr Permit Vector", "HPV", SUPPLY, owner), vectorToken);
        HookrToken t = HookrToken(vectorToken);
        assertEq(owner, 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7, "the vector's owner");
        assertEq(t.DOMAIN_SEPARATOR(), 0xac4e1599648ab8194a224e52f6a0d7ce3f5bdba2b8bf2dbf9dcfe9b8e69883ec, "domain");
        bytes32 digest = 0xebb8150c1eb05d7591be1be98b6b246c45fa466621a95824bb49bb27d08a9ded;
        assertEq(_digest(vectorToken, owner, to, 1e18, 0, 2_000_000_000), digest, "digest");
        bytes32 r = 0x40218c8f10ecdf270ce33c619a5ad72f3148b673cee8ddf9f3622186b842e423;
        bytes32 s = 0x0b43e4092273a37a40547b4af848c9655c47f9ee5d1f4b2e725f9fcf0839fe21;
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(ownerKey, digest);
        assertEq(v2, 28);
        assertEq(r2, r);
        assertEq(s2, s);
        vm.warp(1_999_999_999);
        t.permit(owner, to, 1e18, 2_000_000_000, 28, r, s);
        assertEq(t.allowance(owner, to), 1e18);
        assertEq(t.nonces(owner), 1);
    }

    /// @notice The domain separator follows EIP-712 with version "1", as OpenZeppelin's ERC20Permit computes it for a
    ///         token of the same name at its own address, and eip712Domain reports the same fields.
    function test_domainMatchesEip712AndOpenZeppelin() public {
        ReferencePermitToken ref = new ReferencePermitToken("Hookr Permit");
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), "Hookr Permit"));
        assertEq(ref.DOMAIN_SEPARATOR(), _domain(address(ref), "Hookr Permit"), "the same formula as OpenZeppelin");
        (
            bytes1 fields,
            string memory name_,
            string memory version,
            uint256 chainId,
            address verifying,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        (bytes1 refFields, string memory refName, string memory refVersion, uint256 refChainId,, bytes32 refSalt,) =
            ref.eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(fields, refFields);
        assertEq(name_, "Hookr Permit");
        assertEq(name_, refName);
        assertEq(version, "1");
        assertEq(version, refVersion);
        assertEq(chainId, block.chainid);
        assertEq(chainId, refChainId);
        assertEq(verifying, address(token));
        assertEq(salt, bytes32(0));
        assertEq(salt, refSalt);
        assertEq(extensions.length, 0);

        // The digest OpenZeppelin's token accepts is the same construction: sign it for each token at its own address.
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(ref), owner, spender, 5, 0, block.timestamp);
        ref.permit(owner, spender, 5, block.timestamp, v, r, s);
        (v, r, s) = _sign(ownerKey, address(token), owner, spender, 5, 0, block.timestamp);
        token.permit(owner, spender, 5, block.timestamp, v, r, s);
        assertEq(token.allowance(owner, spender), ref.allowance(owner, spender));
        assertEq(token.nonces(owner), ref.nonces(owner));
    }

    // ------------------------------------------------------------------------------------------------ permit

    /// @notice A permit, submitted by anyone, sets the allowance, uses the owner's nonce and lets the spender move the
    ///         tokens.
    function test_permitApprovesAndUsesTheNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(token), owner, spender, 1e20, 0, block.timestamp + 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(owner, spender, 1e20);
        vm.prank(address(0xD00D));
        token.permit(owner, spender, 1e20, block.timestamp + 1, v, r, s);
        assertEq(token.allowance(owner, spender), 1e20);
        assertEq(token.nonces(owner), 1);
        vm.prank(spender);
        token.transferFrom(owner, spender, 4e19);
        assertEq(token.balanceOf(spender), 4e19);
        assertEq(token.allowance(owner, spender), 6e19);
    }

    /// @notice The same signature never verifies twice: replayed, it recovers someone else under the next nonce.
    function test_replayRefused() public {
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(token), owner, spender, 1e18, 0, deadline);
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        address replayed = ECDSA.recover(_digest(address(token), owner, spender, 1e18, 1, deadline), v, r, s);
        vm.expectRevert(abi.encodeWithSelector(IHookrToken.ERC2612InvalidSigner.selector, replayed, owner));
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        assertEq(token.nonces(owner), 1);
    }

    /// @notice A deadline in the past is refused; one equal to block.timestamp is still good.
    function test_expiryRefused() public {
        vm.warp(1_000_000);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(token), owner, spender, 1, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IHookrToken.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, spender, 1, deadline, v, r, s);
        (v, r, s) = _sign(ownerKey, address(token), owner, spender, 1, 0, block.timestamp);
        token.permit(owner, spender, 1, block.timestamp, v, r, s);
        assertEq(token.allowance(owner, spender), 1);
    }

    /// @notice A signature by any key but the owner's is refused with the signer it recovers, and the owner's signature
    ///         does not carry over to another spender, value or deadline.
    function test_wrongSignerRefused() public {
        uint256 otherKey = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = _sign(otherKey, address(token), owner, spender, 1, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IHookrToken.ERC2612InvalidSigner.selector, vm.addr(otherKey), owner));
        token.permit(owner, spender, 1, block.timestamp, v, r, s);
        (v, r, s) = _sign(ownerKey, address(token), owner, spender, 1, 0, block.timestamp);
        vm.expectPartialRevert(IHookrToken.ERC2612InvalidSigner.selector);
        token.permit(owner, address(0xBAD), 1, block.timestamp, v, r, s);
        vm.expectPartialRevert(IHookrToken.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, 2, block.timestamp, v, r, s);
        vm.expectPartialRevert(IHookrToken.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, 1, block.timestamp + 1, v, r, s);
        assertEq(token.nonces(owner), 0);
        assertEq(token.allowance(owner, spender), 0);
    }

    /// @notice The malleable twin (s above n / 2), a bad v and a zero r are refused before any signer compares; the
    ///         zero address, which has no key, can never be permitted for.
    function test_malleableAndMalformedSignaturesRefused() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(token), owner, spender, 1, 0, block.timestamp);
        bytes32 twin = bytes32(N - uint256(s));
        assertGt(uint256(twin), HALF_N);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, twin));
        token.permit(owner, spender, 1, block.timestamp, v == 27 ? 28 : 27, r, twin);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, spender, 1, block.timestamp, 29, r, s);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, spender, 1, block.timestamp, v, bytes32(0), s);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, 1, block.timestamp, 27, bytes32(0), bytes32(0));
        token.permit(owner, spender, 1, block.timestamp, v, r, s);
        assertEq(token.nonces(owner), 1);
    }

    /// @notice Nonces count up by one per accepted permit, separately for every owner.
    function test_noncesPerOwner() public {
        uint256 otherKey = 0xC0FFEE;
        address other = vm.addr(otherKey);
        vm.prank(owner);
        token.transfer(other, 1e18);
        for (uint256 i; i < 3; ++i) {
            assertEq(token.nonces(owner), i);
            (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(token), owner, spender, i + 1, i, block.timestamp);
            token.permit(owner, spender, i + 1, block.timestamp, v, r, s);
        }
        assertEq(token.nonces(other), 0);
        (uint8 v2, bytes32 r2, bytes32 s2) = _sign(otherKey, address(token), other, spender, 7, 0, block.timestamp);
        token.permit(other, spender, 7, block.timestamp, v2, r2, s2);
        assertEq(token.nonces(other), 1);
        assertEq(token.nonces(owner), 3);
        assertEq(token.allowance(owner, spender), 3);
        assertEq(token.allowance(other, spender), 7);
    }

    /// @notice A permit is bound to its token and its chain: a token of the same name at another address does not take
    ///         it, nor does the same token once the chain id changes. The domain is computed on each use, so a fork's
    ///         chain id applies at once and the token's runtime holds no copy of it.
    function test_domainBindsTokenAndChain() public {
        HookrToken twin = new HookrToken("Hookr Permit", "HKP", SUPPLY, owner);
        assertTrue(twin.DOMAIN_SEPARATOR() != token.DOMAIN_SEPARATOR());
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(token), owner, spender, 1, 0, block.timestamp);
        vm.expectPartialRevert(IHookrToken.ERC2612InvalidSigner.selector);
        twin.permit(owner, spender, 1, block.timestamp, v, r, s);

        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "the domain follows block.chainid");
        assertEq(token.DOMAIN_SEPARATOR(), _domain(address(token), "Hookr Permit"));
        vm.expectPartialRevert(IHookrToken.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, 1, block.timestamp, v, r, s);
    }

    /// @notice Over keys, values and deadlines, a permit either sets exactly the signed allowance at the next nonce or
    ///         reverts without changing either.
    function testFuzz_permit(uint256 key, uint256 value, uint256 deadline, bool late) public {
        key = bound(key, 1, N - 1);
        address o = vm.addr(key);
        vm.warp(1_000_000);
        deadline = late ? bound(deadline, 0, block.timestamp - 1) : bound(deadline, block.timestamp, type(uint256).max);
        (uint8 v, bytes32 r, bytes32 s) = _sign(key, address(token), o, spender, value, 0, deadline);
        if (late) {
            vm.expectRevert(abi.encodeWithSelector(IHookrToken.ERC2612ExpiredSignature.selector, deadline));
            token.permit(o, spender, value, deadline, v, r, s);
            assertEq(token.nonces(o), 0);
            assertEq(token.allowance(o, spender), 0);
        } else {
            token.permit(o, spender, value, deadline, v, r, s);
            assertEq(token.nonces(o), 1);
            assertEq(token.allowance(o, spender), value);
        }
    }

    // ------------------------------------------------------------------------------------------------ codehash

    /// @notice Tokens with different names, symbols, supplies and holders, launched or deployed directly, share one
    ///         runtime: the compiled HookrToken runtime, with no immutable filled in. Each launched token takes a
    ///         permit under its own domain.
    function test_everyTokenSharesOneRuntimeCodehash() public {
        bytes32 runtime = keccak256(type(HookrToken).runtimeCode);
        HookrToken direct =
            new HookrToken("Another Name That Is Longer Than Thirty One Bytes", "LONGSYMBOL", 7, spender);
        assertEq(address(direct).codehash, runtime);
        assertEq(address(token).codehash, runtime);
        string[3] memory names = ["One", "A Second Token", "Third Token With A Long Name For Two Storage Words.."];
        string[3] memory symbols = ["ONE", "TWO", "THREE3"];
        uint256[3] memory supplies = [uint256(1e18), 1e27, 123_456_789];
        for (uint256 i; i < 3; ++i) {
            IHookrLauncher.Token memory t =
                IHookrLauncher.Token(address(0), names[i], symbols[i], supplies[i], bytes32(uint256(i + 1)));
            IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
            members[0] = _member(Currency.wrap(address(0)));
            members[0].amount0Max = 1e18;
            members[0].amount1Max = uint128(supplies[i]);
            members[0].liquidity = 1e7;
            (, address subject) = launcher.launch{value: 1e18}(t, address(root), members, vm.getBlockTimestamp());
            assertEq(subject.codehash, runtime, "a launched token");
            assertEq(HookrToken(subject).name(), names[i]);
            assertEq(HookrToken(subject).symbol(), symbols[i]);
            assertEq(HookrToken(subject).totalSupply(), supplies[i]);
            assertEq(HookrToken(subject).DOMAIN_SEPARATOR(), _domain(subject, names[i]));
            uint256 held = HookrToken(subject).balanceOf(address(this));
            assertGt(held, 0, "the creator holds the unplaced supply");
            // The creator is a contract: the launched token's permit binds an EOA owner, so move some to `owner`.
            HookrToken(subject).transfer(owner, held);
            (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, subject, owner, spender, held, 0, block.timestamp);
            HookrToken(subject).permit(owner, spender, held, block.timestamp, v, r, s);
            assertEq(HookrToken(subject).allowance(owner, spender), held);
        }
    }

    /// @notice HookrRules built from this tree still recognise a launched token by its codehash and bind the Hookr
    ///         minimum on its plain pool; another token's plain pool on the same Rules binds none.
    function test_rulesRecogniseALaunchedTokenAndBindTheHookrMinimum() public {
        HookrTreasury treasury = new HookrTreasury(address(this), address(0x7A7), manager);
        HookrRules r2 = new HookrRules(manager, registry, address(treasury), address(root), 2_000);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(r2),
            codeHash: address(r2).codehash,
            schemaHash: r2.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 400_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        treasury.admitSource(address(r2));
        treasury.proposeMinFee(false, 1_500);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptMinFee(false);

        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.rules = address(r2);
        members[0].config.caps = HookrTypes.Caps(600_000, 400_000, 1000);
        members[0].rules.lpBps = 0;
        members[0].rules.burnBps = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.protocolShareBps = 2_000;
        IHookrLauncher.Token memory t = IHookrLauncher.Token(address(0), "Minimum", "MIN", 1e24, bytes32(uint256(7)));
        (bytes32 family, address subject) =
            launcher.launch{value: 1e24}(t, address(root), members, vm.getBlockTimestamp());
        assertEq(subject.codehash, keccak256(type(HookrToken).runtimeCode));
        PoolKey memory key = launcher.position(family, 0).key;
        assertEq(IHookrRecaptureRules(address(r2)).minimumFee(key.toId()), 1_500, "the Hookr minimum binds");

        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(this), 1e24);
        other.approve(address(launcher), type(uint256).max);
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(other), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        assertEq(IHookrRecaptureRules(address(r2)).minimumFee(key.toId()), 0, "another token's pool binds none");
    }
}
