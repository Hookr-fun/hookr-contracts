// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";

/// @notice A fee-free advisory, to show a profile's advisory subset and an owned root's copied advisories.
contract OwnedZeroAdvisory is IHookrAdvisory {
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.owned.zero-advisory");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external pure returns (HookrTypes.Advice memory a) {
        return a;
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory a)
    {
        return a;
    }
}

/// @notice A gate as the registry and the factory see it: code the registry pins and never calls.
contract OwnedGateStub {
    function version() external pure returns (uint256) {
        return 1;
    }
}

/// @notice A treasury target that refuses native currency, burns the forward's gas, or tries to re-enter the factory's
///         `deploy` with what it gets.
contract OwnedFeeTarget {
    enum Mode {
        ACCEPT,
        REFUSE,
        REENTER,
        BURN
    }

    Mode public mode;
    IHookrOwnedRootFactory public factory;
    bool public reentered;
    bytes4 public reentryError;

    function set(Mode mode_, IHookrOwnedRootFactory factory_) external {
        (mode, factory) = (mode_, factory_);
    }

    receive() external payable {
        Mode m = mode;
        if (m == Mode.REFUSE) revert("refused");
        if (m == Mode.BURN) {
            while (true) {}
        }
        if (m == Mode.REENTER) {
            IHookrOwnedRootFactory.RootSelections memory sel;
            sel.owner = address(this);
            (bool ok, bytes memory err) =
                address(factory).call{value: msg.value}(abi.encodeCall(IHookrOwnedRootFactory.deploy, ("", "", sel, 0)));
            reentered = ok;
            if (err.length >= 4) reentryError = bytes4(err);
        }
    }
}

/// @notice A contract that answers `trustedRoot()` with a root it names and, when asked, poses as a Rules source that
///         pays the treasury: what a spoofed owned-root companion looks like.
contract OwnedFakeCompanion {
    address public trustedRoot;
    address public protocolRecipient;
    IPoolManager public poolManager;
    uint256 public owed;

    constructor(address root_, address recipient_, IPoolManager manager_) {
        (trustedRoot, protocolRecipient, poolManager) = (root_, recipient_, manager_);
    }

    function setOwed(uint256 owed_) external payable {
        owed = owed_;
    }

    function claimable(Currency, address) external view returns (uint256) {
        return owed;
    }

    function claimTo(Currency, address to) external returns (uint256 paid) {
        paid = owed;
        owed = 0;
        (bool ok,) = to.call{value: paid}("");
        require(ok, "pay");
    }
}

/// @notice A registry and a registrar that vouch for whatever they are told: what a forged owned-root registry looks
///         like to the treasury.
contract OwnedForgedRegistry {
    mapping(address => bool) public isOwnedRoot;
    mapping(address => address) public ownedRegistrarForRoot;
    mapping(address => address) public rulesOf;

    function vouch(address root, address registrar, address companion) external {
        isOwnedRoot[root] = true;
        ownedRegistrarForRoot[root] = registrar;
        OwnedForgedRegistry(registrar).setRules(root, companion);
    }

    function setRules(address root, address companion) external {
        rulesOf[root] = companion;
    }
}
