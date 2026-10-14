// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrReferralDistributor} from "../../src/engagement/HookrReferralDistributor.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// @dev Shared setup for the referral remediation regression tests (L-18..L-24, I-15..I-19, N-02).
abstract contract ReferralSecurityFixture is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrReferralRegistry internal referrals;
    HookrReferralDistributor internal distributor;
    PoolKey internal key;
    address internal referrer = address(0x2222);
    bytes32 internal constant COVERAGE = keccak256("pinned complete trade evidence");
    bytes32 internal constant COLLECTIONS = keccak256("actual collected cash reconciled once");

    function setUp() public virtual {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        referrals = new HookrReferralRegistry();
        distributor = _newDistributor();
        tokenA.approve(address(distributor), type(uint256).max);
        tokenB.approve(address(distributor), type(uint256).max);
    }

    function _newDistributor() internal returns (HookrReferralDistributor) {
        return new HookrReferralDistributor(address(referrals), address(registry), _pinnedAttestor());
    }

    /// @dev The distributor's one attestor (the operator); the test contract unless a suite overrides it.
    function _pinnedAttestor() internal view virtual returns (address) {
        return address(this);
    }

    function _terms() internal view returns (IHookrReferralDistributor.Terms memory t) {
        return _termsFor(key);
    }

    function _termsFor(PoolKey memory pool) internal view returns (IHookrReferralDistributor.Terms memory t) {
        HookrTypes.PoolConfig memory c = root.poolConfig(pool.toId());
        t.root = address(root);
        t.rules = address(rules);
        t.poolId = PoolId.unwrap(pool.toId());
        t.configHash = root.policyHash(pool.toId());
        t.currency = Currency.unwrap(c.quote);
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.referrerBps = 2000;
        t.cashbackBps = 1000;
        t.dailyBudget = 1000;
        t.walletFeeCap = 2000;
        t.attestor = distributor.attestor();
        t.reviewer = royalty;
        t.reviewDelay = distributor.MIN_REVIEW_DELAY();
        t.sourcePolicyHash = keccak256("collected protocol cash only; no principal or LP fee subsidy");
    }

    /// @dev Fund `creator` and create a campaign from it.
    function _createAs(address creator, IHookrReferralDistributor.Terms memory t) internal returns (uint256 id) {
        IERC20(t.currency).transfer(creator, uint256(t.dailyBudget) * ((t.end - t.start) / 1 days));
        vm.startPrank(creator);
        IERC20(t.currency).approve(address(distributor), type(uint256).max);
        id = distributor.createCampaign(t);
        vm.stopPrank();
    }

    function _enroll(uint256 id, address payer, address referrer_) internal returns (uint64 first) {
        bytes32 programKey = distributor.campaign(id).programKey;
        vm.prank(payer);
        referrals.register(programKey, referrer_, bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        first = uint64(vm.getBlockNumber());
    }

    function _leaf(uint256 id, uint256 day, address payer, address referrer_, uint64 first, uint128 fees)
        internal
        view
        returns (bytes32)
    {
        return _leafWith(id, day, payer, referrer_, first, fees, COVERAGE, COLLECTIONS);
    }

    /// @dev Independent leaf builder (mirrors the SDK's feeLeaf), never the contract's helper.
    function _leafWith(
        uint256 id,
        uint256 day,
        address payer,
        address referrer_,
        uint64 first,
        uint128 fees,
        bytes32 coverage,
        bytes32 collections
    ) internal view returns (bytes32) {
        IHookrReferralDistributor.Campaign memory c = distributor.campaign(id);
        uint64 end = distributor.dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(distributor),
                        id,
                        c.termsHash,
                        day,
                        uint64(end - 1 days),
                        end,
                        coverage,
                        collections,
                        payer,
                        referrer_,
                        first,
                        fees
                    )
                )
            )
        );
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _noProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _proposeAs(address attestor, uint256 id, uint256 day, bytes32 root_, uint256 fees) internal {
        vm.prank(attestor);
        distributor.proposeDay(id, day, root_, fees, COVERAGE, COLLECTIONS);
    }

    function _finalizeAfterDelay(uint256 id, uint256 day) internal {
        vm.warp(distributor.epoch(id, day).finalizeAfter);
        distributor.finalizeDay(id, day);
    }
}
