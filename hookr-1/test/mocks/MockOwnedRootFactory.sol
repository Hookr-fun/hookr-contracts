// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrRootRegistrar} from "../../src/interfaces/IHookrRootRegistrar.sol";

/// @notice A root registrar as the registry sees it: it registers roots a test deployed, records each root's owner,
///         opening policy and Rules, and answers `mayOpen` from them; a test can pause a root, or make every answer
///         bad (a revert, a short, long or dirty word, or a call that burns all its gas).
contract MockOwnedRootFactory is IHookrRootRegistrar {
    enum Answer {
        POLICY,
        REVERT,
        SHORT,
        LONG,
        DIRTY,
        BURN
    }

    IHookrOwnedRoots public immutable registry;
    Answer public answer;
    mapping(address root => address) public override rulesOf;
    mapping(address root => address) public ownerOf;
    mapping(address root => bool) public ownerOnly;
    mapping(address root => bool) public paused;

    constructor(IHookrOwnedRoots registry_) {
        registry = registry_;
    }

    function register(
        address root,
        address template,
        address templateRules,
        IHookrRegistry.Admission calldata rules,
        address[] calldata copies,
        address owner,
        bool ownerOnly_
    ) external {
        rulesOf[root] = rules.implementation;
        ownerOf[root] = owner;
        ownerOnly[root] = ownerOnly_;
        registry.registerOwnedRoot(root, template, templateRules, rules, copies);
    }

    function setPaused(address root, bool value) external {
        paused[root] = value;
    }

    function setAnswer(Answer next) external {
        answer = next;
    }

    /// @inheritdoc IHookrRootRegistrar
    function mayOpen(address root, address opener) external view returns (bool) {
        Answer a = answer;
        if (a == Answer.REVERT) revert("closed");
        if (a == Answer.BURN) {
            while (true) {}
        }
        bool open = !paused[root] && (!ownerOnly[root] || opener == ownerOf[root]);
        if (a == Answer.SHORT) {
            assembly ("memory-safe") {
                mstore(0, open)
                return(1, 31)
            }
        }
        if (a == Answer.LONG) {
            assembly ("memory-safe") {
                mstore(0, open)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (a == Answer.DIRTY) {
            assembly ("memory-safe") {
                mstore(0, or(open, shl(8, 1)))
                return(0, 32)
            }
        }
        return open;
    }
}
