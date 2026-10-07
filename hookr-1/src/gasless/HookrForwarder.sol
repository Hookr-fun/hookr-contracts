// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrForwarder} from "../interfaces/IHookrForwarder.sol";
import {IHookrRouter} from "../interfaces/IHookrRouter.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRootRoute} from "../interfaces/IHookrRootRoute.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IPermit2Signature} from "../interfaces/external/IPermit2Signature.sol";
import {HookrRelease} from "../libraries/HookrRelease.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title HookrForwarder
/// @notice Relays Permit2-witness signed swap intents into HookrRouter.swapFor with the signer as the identity.
/// @dev Stateless: no storage, no owner, no admin, no receive. One transient lock. The only allowance it ever grants
///      is `maxIn` of the input token to the router, reset to zero in the same call. It holds no balance between
///      calls and has no sweep: tokens sent to it directly are permanently unrecoverable, and they never count
///      toward any intent (every execution restores the balance it started with).
///      It enforces the signed output bound itself from the recipient's balance of the output currency, never from
///      the router's return values, so code at the router address that is not HookrRouter cannot keep the input,
///      unless the recipient has given the router address an allowance of the output token: such code can pay the
///      bound from its own balance and take it back in the same transaction. The primary control is custody of the
///      deployer key, which alone decides what code the router's CREATE3 address holds.
contract HookrForwarder is IHookrForwarder {
    using PoolIdLibrary for PoolKey;

    /// @notice keccak256 of the PoolKey type string.
    bytes32 public constant POOL_KEY_TYPEHASH =
        keccak256("PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)");

    string private constant INTENT_TYPE =
        "HookrSwapIntent(PoolKey key,bool zeroForOne,int128 amountSpecified,uint128 amountBound,uint160 sqrtPriceLimitX96,address recipient,address relayer,uint256 relayerFee,address engagement,uint256[] campaigns,uint256 nonce,uint256 deadline)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";

    /// @inheritdoc IHookrForwarder
    bytes32 public constant override INTENT_TYPEHASH = keccak256(bytes(INTENT_TYPE));

    string private constant WITNESS_TYPE =
        "HookrSwapIntent witness)HookrSwapIntent(PoolKey key,bool zeroForOne,int128 amountSpecified,uint128 amountBound,uint160 sqrtPriceLimitX96,address recipient,address relayer,uint256 relayerFee,address engagement,uint256[] campaigns,uint256 nonce,uint256 deadline)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)TokenPermissions(address token,uint256 amount)";

    /// @dev keccak256("hookr.forwarder.nonce")
    bytes32 internal constant NONCE_DOMAIN = 0xf5d994b9eda9ee3aa7b9f18e6bf8b1b54390265fdd0bac8a3b32c52ae5f1ba15;
    /// @dev keccak256("hookr.forwarder.transient.lock")
    bytes32 internal constant LOCK = 0x85359bd0d503c26d341a8e9133f0f0fdd9da2e88000cf3565582941dbb00e550;
    uint256 internal constant MAX_CAMPAIGNS = 8;

    address internal immutable PERMIT2;
    address internal immutable REGISTRY;
    address internal immutable ROUTER;

    /// @param permit2_ Permit2 (must have code).
    /// @param registry_ HookrRegistry (must have code).
    /// @param router_ The PREDICTED HookrRouter address (no code yet; not checked).
    constructor(address permit2_, address registry_, address router_) {
        if (permit2_.code.length == 0) revert NoCode(permit2_);
        if (registry_.code.length == 0) revert NoCode(registry_);
        PERMIT2 = permit2_;
        REGISTRY = registry_;
        ROUTER = router_;
    }

    /// @inheritdoc IHookrForwarder
    function execute(HookrSwapIntent calldata intent, address owner, bytes calldata signature)
        external
        override
        returns (uint256 amountIn, uint256 amountOut)
    {
        return _execute(intent, owner, signature);
    }

    /// @inheritdoc IHookrForwarder
    function executeWithTokenPermit(
        HookrSwapIntent calldata intent,
        address owner,
        bytes calldata signature,
        TokenPermit calldata tokenPermit
    ) external override returns (uint256 amountIn, uint256 amountOut) {
        if (tokenPermit.value != 0) {
            address input = Currency.unwrap(intent.zeroForOne ? intent.key.currency0 : intent.key.currency1);
            // A front-run permit is harmless: Permit2 enforces the allowance and the signature.
            try IERC20Permit(input)
                .permit(
                    owner, PERMIT2, tokenPermit.value, tokenPermit.deadline, tokenPermit.v, tokenPermit.r, tokenPermit.s
                ) {}
                catch {}
        }
        return _execute(intent, owner, signature);
    }

    /// @dev Runs the nine steps numbered in the body: lock, field checks, pull plan and output bound, exact Permit2
    ///      witness pull, approve-swap-reset, unused-input refund, input-side relayer fee, no residual balance.
    function _execute(HookrSwapIntent calldata intent, address owner, bytes calldata signature)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        // 1. lock
        bool locked;
        assembly ("memory-safe") {
            locked := tload(LOCK)
        }
        if (locked) revert Reentered();
        assembly ("memory-safe") {
            tstore(LOCK, 1)
        }

        // 2. fields
        _checkFields(intent, owner);

        // 3-4. pool, input, fee side, pull amount; the output bound and the recipient's output balance
        (address input, uint256 pull, bool feeFromInput, uint256 maxIn) = _pull(intent);
        (address output, uint256 minimumOut, uint256 heldBefore) = _outputBound(intent, feeFromInput);

        // 5. exact Permit2 witness pull
        bytes32 intentHash = _hashIntent(intent);
        uint256 before = _balanceOf(input, address(this));
        IPermit2Signature(PERMIT2)
            .permitWitnessTransferFrom(
                IPermit2Signature.PermitTransferFrom({
                permitted: IPermit2Signature.TokenPermissions({token: input, amount: pull}),
                nonce: _permit2Nonce(intent.nonce),
                deadline: intent.deadline
            }),
                IPermit2Signature.SignatureTransferDetails({to: address(this), requestedAmount: pull}),
                owner,
                intentHash,
                WITNESS_TYPE,
                signature
            );
        {
            uint256 received = _balanceOf(input, address(this)) - before;
            if (received != pull) revert InexactPull(input, pull, received);
        }

        // 6. approve, swap, reset; the recipient must then hold at least the signed output bound more
        _approve(input, ROUTER, maxIn);
        (amountIn, amountOut) = IHookrRouter(ROUTER)
            .swapFor(
                IHookrRouter.Swap({
                key: intent.key,
                zeroForOne: intent.zeroForOne,
                amountSpecified: intent.amountSpecified,
                amountBound: intent.amountBound,
                sqrtPriceLimitX96: intent.sqrtPriceLimitX96,
                recipient: intent.recipient,
                deadline: intent.deadline
            }),
                owner,
                feeFromInput ? 0 : intent.relayerFee,
                (feeFromInput || intent.relayerFee == 0) ? address(0) : msg.sender,
                intent.engagement,
                intent.campaigns
            );
        _approve(input, ROUTER, 0);
        {
            uint256 heldAfter = _holding(output, intent.recipient);
            uint256 received = heldAfter > heldBefore ? heldAfter - heldBefore : 0;
            if (received < minimumOut) revert OutputShort(output, minimumOut, received);
        }

        // 7. refund unused input
        if (amountIn < maxIn) _transfer(input, owner, maxIn - amountIn);
        // 8. input-side relayer fee
        if (feeFromInput && intent.relayerFee != 0) _transfer(input, msg.sender, intent.relayerFee);

        // 9. no residual
        {
            uint256 afterwards = _balanceOf(input, address(this));
            if (afterwards != before) revert ResidualBalance(input, before, afterwards);
        }
        emit IntentExecuted(
            intentHash, owner, msg.sender, intent.key.toId(), amountIn, amountOut, intent.relayerFee, feeFromInput
        );
        assembly ("memory-safe") {
            tstore(LOCK, 0)
        }
    }

    /// @dev Step 2: the intent's own fields (deadline, relayer, relayer fee, amounts, recipient, campaigns, signer).
    function _checkFields(HookrSwapIntent calldata intent, address owner) private view {
        if (block.timestamp > intent.deadline) revert IntentExpired(intent.deadline, block.timestamp);
        if (intent.relayer != address(0) && intent.relayer != msg.sender) {
            revert WrongRelayer(intent.relayer, msg.sender);
        }
        // A fee payable to whoever submits first gives every submitter a free timing option.
        if (intent.relayer == address(0) && intent.relayerFee != 0) revert InvalidIntent(6);
        if (intent.amountSpecified == 0 || intent.amountSpecified == type(int128).min) revert InvalidIntent(1);
        if (intent.amountBound == 0) revert InvalidIntent(2);
        address recipient = intent.recipient;
        if (recipient == address(0) || recipient == address(this) || recipient == ROUTER) revert InvalidIntent(3);
        uint256 n = intent.campaigns.length;
        if (n > MAX_CAMPAIGNS || (intent.engagement == address(0)) != (n == 0)) revert InvalidIntent(4);
        if (owner == address(0)) revert InvalidIntent(5);
    }

    /// @dev Steps 3-4: the pool, input, fee side and pull amount. Reverts UnsupportedPool / NativeInputUnsupported /
    ///      OutputFeeOnAdvisedPool.
    ///      An output-side fee on an advised pool would pay pool output to the relayer, whom the advisory never
    ///      screens, so it is refused.
    function _pull(HookrSwapIntent calldata intent)
        private
        view
        returns (address input, uint256 pull, bool feeFromInput, uint256 maxIn)
    {
        address root = address(intent.key.hooks);
        if (!IHookrRegistry(REGISTRY).isRoot(root)) revert UnsupportedPool(root);
        (address quote, address advisory) = _route(root, intent.key.toId());
        input = Currency.unwrap(intent.zeroForOne ? intent.key.currency0 : intent.key.currency1);
        if (input == address(0)) revert NativeInputUnsupported();
        feeFromInput = input == quote;
        if (!feeFromInput && intent.relayerFee != 0 && advisory != address(0)) revert OutputFeeOnAdvisedPool(advisory);
        maxIn = intent.amountSpecified < 0 ? uint256(uint128(-intent.amountSpecified)) : uint256(intent.amountBound);
        pull = maxIn + (feeFromInput ? intent.relayerFee : 0);
    }

    /// @dev The output currency, the least the recipient must receive and its balance now. Exact input: the signed
    ///      net minimum. Exact output: the gross output less an output-side relayer fee, as HookrRouter pays it; a fee
    ///      above the gross output is refused (InvalidIntent(7)).
    function _outputBound(HookrSwapIntent calldata intent, bool feeFromInput)
        private
        view
        returns (address output, uint256 minimum, uint256 held)
    {
        output = Currency.unwrap(intent.zeroForOne ? intent.key.currency1 : intent.key.currency0);
        if (intent.amountSpecified < 0) {
            minimum = intent.amountBound;
        } else {
            minimum = uint256(uint128(intent.amountSpecified));
            uint256 fee = feeFromInput ? 0 : intent.relayerFee;
            if (fee > minimum) revert InvalidIntent(7);
            minimum -= fee;
        }
        held = _holding(output, intent.recipient);
    }

    /// @inheritdoc IHookrForwarder
    function hashIntent(HookrSwapIntent calldata intent) external pure override returns (bytes32) {
        return _hashIntent(intent);
    }

    /// @inheritdoc IHookrForwarder
    function pullOf(HookrSwapIntent calldata intent)
        external
        view
        override
        returns (address token, uint256 amount, bool feeFromInput)
    {
        (token, amount, feeFromInput,) = _pull(intent);
    }

    /// @inheritdoc IHookrForwarder
    function permit2Nonce(uint256 intentNonce) external view override returns (uint256) {
        return _permit2Nonce(intentNonce);
    }

    /// @inheritdoc IHookrForwarder
    function nonceWord(uint256 intentNonce) public view override returns (uint256 wordPos, uint256 mask) {
        uint256 n = _permit2Nonce(intentNonce);
        wordPos = n >> 8;
        mask = uint256(1) << (n & 0xff);
    }

    /// @inheritdoc IHookrForwarder
    function isNonceUsed(address owner, uint256 intentNonce) external view override returns (bool) {
        (uint256 wordPos, uint256 mask) = nonceWord(intentNonce);
        return IPermit2Signature(PERMIT2).nonceBitmap(owner, wordPos) & mask != 0;
    }

    /// @inheritdoc IHookrForwarder
    function WITNESS_TYPE_STRING() external pure override returns (string memory) {
        return WITNESS_TYPE;
    }

    /// @inheritdoc IHookrForwarder
    function permit2() external view override returns (address) {
        return PERMIT2;
    }

    /// @inheritdoc IHookrForwarder
    function router() external view override returns (address) {
        return ROUTER;
    }

    /// @inheritdoc IHookrForwarder
    function registry() external view override returns (address) {
        return REGISTRY;
    }

    /// @inheritdoc IHookrForwarder
    function releaseId() external pure override returns (uint256) {
        return HookrRelease.ID;
    }

    function _hashIntent(HookrSwapIntent calldata intent) private pure returns (bytes32) {
        PoolKey calldata key = intent.key;
        bytes32 keyHash =
            keccak256(abi.encode(POOL_KEY_TYPEHASH, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        bytes memory head = abi.encode(
            INTENT_TYPEHASH,
            keyHash,
            intent.zeroForOne,
            intent.amountSpecified,
            intent.amountBound,
            intent.sqrtPriceLimitX96,
            intent.recipient,
            intent.relayer
        );
        return keccak256(
            abi.encodePacked(
                head,
                abi.encode(
                    intent.relayerFee,
                    intent.engagement,
                    keccak256(abi.encodePacked(intent.campaigns)),
                    intent.nonce,
                    intent.deadline
                )
            )
        );
    }

    /// @dev The pool's quote and advisory, from the root's narrow read or, for a root without it, from poolConfig.
    function _route(address root, PoolId id) private view returns (address quote, address advisory) {
        try IHookrRootRoute(root).poolRoute(id) returns (Currency q, address a) {
            return (Currency.unwrap(q), a);
        } catch {
            try IHookrRoot(root).poolConfig(id) returns (HookrTypes.PoolConfig memory pc) {
                return (Currency.unwrap(pc.quote), pc.advisory);
            } catch {
                revert UnsupportedPool(root);
            }
        }
    }

    function _permit2Nonce(uint256 intentNonce) private view returns (uint256) {
        uint248 word = uint248(uint256(keccak256(abi.encode(NONCE_DOMAIN, address(this), intentNonce >> 8))));
        return (uint256(word) << 8) | (intentNonce & 0xff);
    }

    function _balanceOf(address token, address account) private view returns (uint256 amount) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!ok || data.length < 32) revert TokenCallFailed(token, 0x70a08231);
        amount = abi.decode(data, (uint256));
    }

    /// @dev Native or ERC-20 balance of `account`.
    function _holding(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : _balanceOf(token, account);
    }

    function _transfer(address token, address to, uint256 amount) private {
        _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    /// @dev forceApprove: tries approve(v); on failure resets to 0 first (USDT-style tokens).
    function _approve(address token, address spender, uint256 amount) private {
        bytes memory data = abi.encodeWithSelector(0x095ea7b3, spender, amount);
        if (!_try(token, data)) {
            _call(token, abi.encodeWithSelector(0x095ea7b3, spender, 0));
            _call(token, data);
        }
    }

    function _call(address token, bytes memory data) private {
        if (!_try(token, data)) revert TokenCallFailed(token, bytes4(data));
    }

    function _try(address token, bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(data);
        return ok && (ret.length == 0 ? token.code.length != 0 : (ret.length >= 32 && abi.decode(ret, (bool))));
    }
}
