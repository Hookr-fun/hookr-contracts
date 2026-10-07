// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {HookrFeeConversionTypes} from "../types/HookrFeeConversionTypes.sol";
import {IHookrFeeRouteRegistry} from "../interfaces/IHookrFeeRouteRegistry.sol";
import {IHookrFeeSwapAdapter} from "../interfaces/IHookrFeeSwapAdapter.sol";
import {IHookrFeeSwapExecutor} from "../interfaces/IHookrFeeSwapExecutor.sol";
import {IHookrStraySweep} from "../interfaces/IHookrStraySweep.sol";
import {HookrAsset} from "../libraries/HookrAsset.sol";

/// @title HookrFeeSwapExecutor
/// @notice Signed, replay-protected exact-input conversion of queued tax, a Hookr 1 port of the V2-lineage
///         `HookrFeeSwapExecutorV1` with two tightenings: the adapter bytes must equal the route's frozen
///         `routeDataHash`, so a signature can choose the amount and price bound but never the venue; and the plan
///         carries a signed `caller` that the strategy enforces, so a signer can name who may run it.
/// @dev Immutable and ownerless. It calls only an active route's code-hash-pinned adapter, measures input and output
///      by balance delta and returns the output to the calling strategy. No swap on any pool depends on it. It holds
///      nothing between conversions, so any balance it has then is a stray that only the route registry, for its owner
///      after the timelock, can send on (`sweepStray`); a sweep cannot run during a conversion.
contract HookrFeeSwapExecutor is IHookrFeeSwapExecutor, IHookrStraySweep {
    bytes32 public constant PLAN_TYPEHASH = keccak256(
        "FeeExecutionPlan(bytes32 routeId,address strategy,uint128 amountIn,uint128 minAmountOut,uint64 maxBlock,uint64 deadline,uint64 nonce,bytes32 routeDataHash,address caller)"
    );
    bytes32 internal constant NAME_HASH = keccak256("Hookr Fee Swap Executor");
    /// @dev "2": the plan gained `caller`, so a signature over the lineage's version-1 plan never verifies here.
    bytes32 internal constant VERSION_HASH = keccak256("2");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev Gas stipend for the ERC-1271 check. The authorizer does one ECDSA recovery.
    uint256 internal constant AUTHORIZER_GAS = 100_000;

    /// @notice The route registry every plan is checked against, and the only caller of `sweepStray`.
    IHookrFeeRouteRegistry public immutable override(IHookrFeeSwapExecutor, IHookrStraySweep) routeRegistry;
    IERC1271 public immutable routeAuthorizer;
    bytes32 public immutable routeAuthorizerCodeHash;
    uint256 public immutable initialChainId;
    bytes32 public immutable initialDomainSeparator;

    /// @notice Whether `strategy` has consumed `nonce`.
    mapping(address strategy => mapping(uint64 nonce => bool used)) public nonceUsed;
    uint256 private _lock = 1;

    event FeeSwapExecuted(
        bytes32 indexed routeId,
        address indexed strategy,
        bytes32 indexed planDigest,
        uint256 amountIn,
        uint256 amountOut,
        uint256 adapterReportedAmountOut,
        uint64 nonce
    );

    error ZeroAddress();
    error ReentrantCall();
    error InvalidPlan();
    error DeadlineExpired();
    error BlockExpired();
    error NonceAlreadyUsed();
    error RouteDataMismatch();
    error RouteUnavailable(bytes32 routeId);
    error InvalidSignature();
    error InvalidNativeValue(uint256 expected, uint256 received);
    error InputNotFullyConsumed(uint256 remaining);
    error TooLittleReceived(uint256 minimum, uint256 received);
    error UnexpectedNative();

    modifier nonReentrant() {
        if (_lock != 1) revert ReentrantCall();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @param routeRegistry_ The route registry whose active, code-pinned routes this executor runs.
    /// @param routeAuthorizer_ The ERC-1271 signer boundary; its code hash is pinned.
    constructor(IHookrFeeRouteRegistry routeRegistry_, IERC1271 routeAuthorizer_) {
        if (address(routeRegistry_).code.length == 0 || address(routeAuthorizer_).code.length == 0) {
            revert ZeroAddress();
        }
        routeRegistry = routeRegistry_;
        routeAuthorizer = routeAuthorizer_;
        routeAuthorizerCodeHash = address(routeAuthorizer_).codehash;
        initialChainId = block.chainid;
        initialDomainSeparator = _domainSeparator();
    }

    /// @notice Accepts native output from the PoolManager only while a conversion is running.
    receive() external payable {
        if (_lock != 2) revert UnexpectedNative();
    }

    /// @notice Returns the EIP-712 domain separator for the current chain.
    function domainSeparator() public view returns (bytes32) {
        return block.chainid == initialChainId ? initialDomainSeparator : _domainSeparator();
    }

    /// @inheritdoc IHookrFeeSwapExecutor
    function hashPlan(HookrFeeConversionTypes.ExecutionPlan calldata plan) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PLAN_TYPEHASH,
                plan.routeId,
                plan.strategy,
                plan.amountIn,
                plan.minAmountOut,
                plan.maxBlock,
                plan.deadline,
                plan.nonce,
                plan.routeDataHash,
                plan.caller
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @inheritdoc IHookrFeeSwapExecutor
    function execute(
        HookrFeeConversionTypes.ExecutionPlan calldata plan,
        bytes calldata signature,
        bytes calldata routeData
    ) external payable nonReentrant returns (uint256 amountOut, bytes32 planDigest) {
        if (
            plan.routeId == bytes32(0) || plan.strategy != msg.sender || msg.sender.code.length == 0
                || plan.amountIn == 0 || plan.minAmountOut == 0
        ) revert InvalidPlan();
        if (block.timestamp > plan.deadline) revert DeadlineExpired();
        if (block.number > plan.maxBlock) revert BlockExpired();
        if (nonceUsed[msg.sender][plan.nonce]) revert NonceAlreadyUsed();
        bytes32 dataHash = keccak256(routeData);
        HookrFeeConversionTypes.Route memory r = routeRegistry.route(plan.routeId);
        if (dataHash != plan.routeDataHash || dataHash != r.routeDataHash) revert RouteDataMismatch();
        if (!routeRegistry.isActive(plan.routeId, r.tokenIn, r.tokenOut)) revert RouteUnavailable(plan.routeId);
        planDigest = hashPlan(plan);
        if (!_authorized(planDigest, signature)) revert InvalidSignature();
        nonceUsed[msg.sender][plan.nonce] = true;

        uint256 amountIn = plan.amountIn;
        uint256 inputBefore;
        if (r.tokenIn == address(0)) {
            if (msg.value != amountIn) revert InvalidNativeValue(amountIn, msg.value);
            inputBefore = address(this).balance - msg.value;
        } else {
            if (msg.value != 0) revert InvalidNativeValue(0, msg.value);
            inputBefore = HookrAsset.balanceOf(r.tokenIn, address(this));
            HookrAsset.pullExact(r.tokenIn, msg.sender, amountIn);
            HookrAsset.approveExact(r.tokenIn, r.adapter, amountIn);
        }
        uint256 outputBefore = HookrAsset.balanceOf(r.tokenOut, address(this));
        uint256 reported = IHookrFeeSwapAdapter(r.adapter)
        .executeExactInput{value: r.tokenIn == address(0) ? amountIn : 0}(
            r.tokenIn, r.tokenOut, amountIn, plan.minAmountOut, address(this), routeData
        );
        if (r.tokenIn != address(0)) HookrAsset.approveExact(r.tokenIn, r.adapter, 0);
        uint256 inputAfter = HookrAsset.balanceOf(r.tokenIn, address(this));
        if (inputAfter != inputBefore) {
            revert InputNotFullyConsumed(inputAfter > inputBefore ? inputAfter - inputBefore : 0);
        }
        uint256 outputAfter = HookrAsset.balanceOf(r.tokenOut, address(this));
        amountOut = outputAfter > outputBefore ? outputAfter - outputBefore : 0;
        if (amountOut < plan.minAmountOut) revert TooLittleReceived(plan.minAmountOut, amountOut);
        HookrAsset.send(r.tokenOut, msg.sender, amountOut);
        emit FeeSwapExecuted(plan.routeId, msg.sender, planDigest, amountIn, amountOut, reported, plan.nonce);
    }

    /// @inheritdoc IHookrStraySweep
    function sweepStray(address asset, uint256 amount, address to) external nonReentrant {
        if (msg.sender != address(routeRegistry)) revert StraySweepUnauthorized(msg.sender);
        uint256 held = HookrAsset.balanceOf(asset, address(this));
        if (amount == 0 || to == address(0) || amount > held) revert InvalidStraySweep(asset, amount, held);
        HookrAsset.send(asset, to, amount);
        emit StraySwept(asset, to, amount);
    }

    /// @dev Bounded ERC-1271 check against the pinned authorizer. Any failure, malformed return or code change is
    ///      an invalid signature.
    function _authorized(bytes32 digest, bytes calldata signature) private view returns (bool) {
        address authorizer = address(routeAuthorizer);
        if (authorizer.codehash != routeAuthorizerCodeHash) return false;
        bytes memory input = abi.encodeCall(IERC1271.isValidSignature, (digest, signature));
        bool ok;
        bytes32 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(AUTHORIZER_GAS, authorizer, add(input, 32), mload(input), 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            word := mload(0)
        }
        return ok && bytes4(word) == IERC1271.isValidSignature.selector && uint256(word) << 32 == 0;
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }
}
