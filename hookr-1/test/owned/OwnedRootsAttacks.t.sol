// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice What a hostile subject calls back into from inside its own transfers.
interface IOwnedHostileCallback {
    function onHostileTransfer() external;
}

/// @notice An ERC-20 subject that, once armed, calls a callback before every transfer (one level deep): a token a
///         creator can launch on any owned root, whose transfers run inside the PoolManager's unlock on every swap.
contract OwnedHostileSubject {
    string public constant name = "Hostile";
    string public constant symbol = "HST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public callback;
    bool public armed;
    bool internal inside;

    constructor(uint256 supply, address holder) {
        totalSupply = supply;
        balanceOf[holder] = supply;
    }

    function arm(address callback_, bool armed_) external {
        (callback, armed) = (callback_, armed_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _hook();
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _hook();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _hook() internal {
        if (!armed || inside) return;
        inside = true;
        IOwnedHostileCallback(callback).onHostileTransfer();
        inside = false;
    }
}

/// @notice The owned-roots attack pass. Here: reentrancy through a hostile subject on an owned root, into the
///         treasury's collection by provenance and into the factory, from inside a swap. Elsewhere: cap exhaustion with
///         the fee and its cost (OwnedRootsFee.test_capExhaustionCostWithTheFee), a re-entering fee target
///         (OwnedRootsFee.test_aReenteringTargetIsRefused), front-running a mined salt
///         (OwnedRootFactory.test_frontRunningAMinedSaltCannotTakeTheAddress), the runtime identity check
///         (OwnedRootFactory.test_runtimeIdentityRefusesOtherWiring,
///         OwnedRootsRegistrationLimits.test_pin_curatedZeroIdentityDependsOnAddressZeroState), provenance spoofing
///         (HookrTreasuryOwnedRoots.test_fakeCompanionsAreRefused, test_forgedRegistryIsNeverAsked,
///         test_everyAnswerFailsClosed), unconsented ownership
///         (OwnedRootsRegistrationLimits.test_attack_cannotAssignARootToABrandWithoutConsent) and a stranger opening
///         an owner-only root (OwnedRootFactory.test_registryRootOpenForAsksTheFactory).
contract OwnedRootsAttacksTest is OwnedRootsFixture, IOwnedHostileCallback {
    using PoolIdLibrary for PoolKey;

    HookrRoot internal owned;
    HookrRules internal companion;
    OwnedHostileSubject internal hostile;
    PoolKey internal key;
    bool internal nestedCollectOk;
    bytes internal nestedCollectError;
    bool internal nestedDeployOk;
    address internal nestedRoot;
    uint256 internal callbacks;

    function setUp() public {
        _setUpOwned();
        (owned, companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        hostile = new OwnedHostileSubject(1e30, address(this));
        hostile.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory ms = _members(_nativeMember(address(companion), _rc(), 0));
        (bytes32 family,) = launcher.launch{value: ms[0].amount0Max}(
            IHookrLauncher.Token(address(hostile), "", "", 0, bytes32(0)), address(owned), ms, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        hostile.approve(address(router), type(uint256).max);
    }

    /// @notice A hostile subject re-enters from inside the swap's transfers: the treasury's collection fails (the
    ///         companion pays only through its own PoolManager unlock, refused inside another), the factory deploys a
    ///         new owned root that cannot touch the pool in flight, and the outer trades execute as quoted, with the
    ///         companion's ledger backed and the treasury paid exactly its claim afterwards.
    function test_attack_hostileSubjectReentersTheTreasuryAndTheFactoryFromASwap() public {
        _swap(true, 2 ether);
        assertGt(companion.claimable(ETH, address(hookrTreasury)), 0, "the companion owes the treasury");
        hostile.arm(address(this), true);
        IHookrRouter.Swap memory p = _hostileSwap(true, 1 ether);
        HookrTypes.ExecutionReceipt memory q = quoter.quote(p, address(this));
        (uint256 amountIn, uint256 amountOut) = router.swap{value: 1 ether}(p, address(0), new uint256[](0));
        assertEq(amountIn, q.inputAmount);
        assertEq(amountOut, q.outputAmount);
        assertGt(callbacks, 0, "the subject called back from inside the swap");
        assertFalse(nestedCollectOk, "the collection inside the swap failed");
        assertEq(bytes4(nestedCollectError), IPoolManager.AlreadyUnlocked.selector);
        assertTrue(nestedDeployOk, "the factory deployed from inside the swap");
        assertTrue(IHookrOwnedRoots(address(registry)).isOwnedRoot(nestedRoot));
        assertTrue(factory.runtimeMatchesTemplate(nestedRoot));
        // A sell, with the callback still armed.
        uint256 held = hostile.balanceOf(address(this));
        p = _hostileSwap(false, held / 1000);
        q = quoter.quote(p, address(this));
        (amountIn, amountOut) = router.swap(p, address(0), new uint256[](0));
        assertEq(amountIn, q.inputAmount);
        assertEq(amountOut, q.outputAmount);
        assertTrue(companion.accountingInvariant(ETH));
        hostile.arm(address(this), false);
        uint256 owed = companion.claimable(ETH, address(hookrTreasury));
        uint256 before = TARGET.balance;
        assertEq(hookrTreasury.collect(address(companion), ETH), owed);
        assertEq(TARGET.balance - before, owed, "the treasury was paid exactly its claim");
        assertEq(address(hookrTreasury).balance, 0);
        assertEq(address(factory).balance, 0);
    }

    /// @inheritdoc IOwnedHostileCallback
    function onHostileTransfer() external {
        require(msg.sender == address(hostile));
        ++callbacks;
        try hookrTreasury.collect(address(companion), ETH) {
            nestedCollectOk = true;
        } catch (bytes memory err) {
            nestedCollectError = err;
        }
        if (nestedRoot != address(0)) return;
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(address(this), F.ALL_FEATURES);
        bytes32 salt = _mineFor(address(factory), address(this), 1 << 100);
        uint256 fee = factory.deployFee();
        try factory.deploy{value: fee}(type(HookrRoot).creationCode, type(HookrRules).creationCode, sel, salt) returns (
            address r
        ) {
            (nestedDeployOk, nestedRoot) = (true, r);
        } catch {}
    }

    function _hostileSwap(bool buy, uint256 amount) internal view returns (IHookrRouter.Swap memory) {
        return IHookrRouter.Swap(
            key, buy, -int128(int256(amount)), 1, buy ? MIN_PRICE : MAX_PRICE, address(this), vm.getBlockTimestamp()
        );
    }

    function _swap(bool buy, uint256 amount) internal returns (uint256 amountOut) {
        (, amountOut) = router.swap{value: buy ? amount : 0}(_hostileSwap(buy, amount), address(0), new uint256[](0));
    }
}
