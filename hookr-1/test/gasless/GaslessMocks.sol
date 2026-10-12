// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IPermit2Signature} from "../../src/interfaces/external/IPermit2Signature.sol";

contract GaslessToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 18;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract MockRegistry {
    mapping(address => bool) public isRoot;

    function set(address r) external {
        isRoot[r] = true;
    }
}

contract MockRoot {
    Currency public quote;
    address public advisory;

    function setQuote(Currency q) external {
        quote = q;
    }

    function setAdvisory(address a) external {
        advisory = a;
    }

    function poolRoute(bytes32) external view returns (Currency, address) {
        return (quote, advisory);
    }

    function poolConfig(bytes32) external view returns (HookrTypes.PoolConfig memory pc) {
        pc.quote = quote;
    }
}

/// @notice Permit2 stand-in: records the witness and nonce, enforces single use, moves tokens (no signature check).
contract MockPermit2 {
    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;
    bytes32 public lastWitness;
    string public lastType;

    function permitWitnessTransferFrom(
        IPermit2Signature.PermitTransferFrom calldata permit,
        IPermit2Signature.SignatureTransferDetails calldata details,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata
    ) external {
        uint256 word = permit.nonce >> 8;
        uint256 bit = 1 << (permit.nonce & 0xff);
        require(nonceBitmap[owner][word] & bit == 0, "nonce");
        nonceBitmap[owner][word] |= bit;
        lastWitness = witness;
        lastType = witnessTypeString;
        GaslessToken(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount - short);
    }

    /// @dev Units each pull delivers short of the requested amount, as a fee-on-transfer token would.
    uint256 public short;

    function setShort(uint256 units) external {
        short = units;
    }

    function invalidateUnorderedNonces(uint256 word, uint256 mask) external {
        nonceBitmap[msg.sender][word] |= mask;
    }
}

/// @notice Router stand-in for swapFor: pulls amountIn from the caller, pays output minus fee to recipient, fee to feeRecipient.
contract MockRouter {
    uint256 public useIn;
    uint256 public payOut;
    address public lastPayer;
    uint256 public lastFee;
    address public lastFeeRecipient;

    function set(uint256 amountIn, uint256 amountOut) external {
        useIn = amountIn;
        payOut = amountOut;
    }

    function swapFor(
        IHookrRouter.Swap calldata p,
        address payer,
        uint256 outputFee,
        address feeRecipient,
        address,
        uint256[] calldata
    ) external returns (uint256, uint256) {
        lastPayer = payer;
        lastFee = outputFee;
        lastFeeRecipient = feeRecipient;
        PoolKey calldata k = p.key;
        address input = Currency.unwrap(p.zeroForOne ? k.currency0 : k.currency1);
        address output = Currency.unwrap(p.zeroForOne ? k.currency1 : k.currency0);
        GaslessToken(input).transferFrom(msg.sender, address(this), useIn);
        GaslessToken(output).mint(p.recipient, payOut - outputFee);
        if (outputFee != 0) GaslessToken(output).mint(feeRecipient, outputFee);
        return (useIn, payOut);
    }
}

contract MockEntryPoint {
    mapping(address => uint256) public balanceOf;

    function depositTo(address a) external payable {
        balanceOf[a] += msg.value;
    }

    function withdrawTo(address payable to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        to.transfer(a);
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
}

contract MockRulesLedger {
    mapping(address => mapping(address => uint256)) public paid;

    function set(address p, address q, uint256 v) external {
        paid[p][q] = v;
    }

    function protocolFeePaid(address p, address q) external view returns (uint256) {
        return paid[p][q];
    }
}
