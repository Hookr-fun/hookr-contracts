// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookrModuleTypesV1} from "hookr/libraries/HookrModuleTypesV1.sol";

import {ExampleModule} from "../src/ExampleModule.sol";

/// @dev The catalog's registration maxima for the live native block, from
///      deployments/robinhood-4663.v2.json `registrationCaps`. A module's own maxima must fit
///      under what its registration would declare; this template stays under these.
contract ExampleModuleTest is Test {
    uint24 internal constant CATALOG_MAX_LP_FEE_SURCHARGE_PIPS = 500_000;
    uint16 internal constant CATALOG_MAX_SPECIFIED_QUOTE_TAKE_BPS = 4_000;
    uint16 internal constant CATALOG_MAX_UNSPECIFIED_QUOTE_TAKE_BPS = 2_500;
    uint16 internal constant CATALOG_MAX_SUBJECT_TAKE_BPS = 1_000;

    ExampleModule internal module;

    bytes32 internal constant POOL_ID = keccak256("pool");
    address internal constant KERNEL = address(0xB3CA);
    address internal constant SUBJECT = address(0x5AB1);
    address internal constant QUOTE = address(0);
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        module = new ExampleModule();
    }

    function _config(uint24 surchargePips, uint16 takeBps, address recipient) internal pure returns (bytes memory) {
        return abi.encode(
            ExampleModule.Config({
                poolId: POOL_ID,
                kernel: KERNEL,
                subject: SUBJECT,
                quote: QUOTE,
                buySurchargePips: surchargePips,
                buyTakeBps: takeBps,
                claimRecipient: recipient
            })
        );
    }

    function _swap(bool isBuy, bool exactInput) internal pure returns (HookrModuleTypesV1.SwapContext memory c) {
        c.poolId = POOL_ID;
        c.subject = SUBJECT;
        c.quote = QUOTE;
        c.isBuy = isBuy;
        c.exactInput = exactInput;
        c.amountSpecified = exactInput ? -int256(1 ether) : int256(1 ether);
    }

    function test_identity() public view {
        assertEq(module.moduleKey(), keccak256("LABS_EXAMPLE_MODULE"));
        assertEq(module.moduleVersion(), 1);
        assertEq(module.configSchemaHash(), module.CONFIG_SCHEMA_HASH());
    }

    function test_moduleMaximaStayUnderTheCatalogCaps() public view {
        assertLe(module.MAX_BUY_SURCHARGE_PIPS(), CATALOG_MAX_LP_FEE_SURCHARGE_PIPS);
        assertLe(module.MAX_BUY_TAKE_BPS(), CATALOG_MAX_SPECIFIED_QUOTE_TAKE_BPS);
    }

    function test_validateStackReturnsCapsWithinTheCatalogCaps() public view {
        bytes memory config = _config(10_000, 50, RECIPIENT);
        HookrModuleTypesV1.ModuleConfigCaps memory caps = module.validateStack(POOL_ID, KERNEL, SUBJECT, QUOTE, config);
        assertEq(caps.configHash, keccak256(config));
        assertEq(caps.maxLpFeeSurchargePips, 10_000);
        assertEq(caps.maxSpecifiedQuoteTakeBps, 50);
        assertEq(caps.maxUnspecifiedQuoteTakeBps, 0);
        assertEq(caps.maxSubjectTakeBps, 0);
        assertLe(caps.maxLpFeeSurchargePips, CATALOG_MAX_LP_FEE_SURCHARGE_PIPS);
        assertLe(caps.maxSpecifiedQuoteTakeBps, CATALOG_MAX_SPECIFIED_QUOTE_TAKE_BPS);
        assertLe(caps.maxUnspecifiedQuoteTakeBps, CATALOG_MAX_UNSPECIFIED_QUOTE_TAKE_BPS);
        assertLe(caps.maxSubjectTakeBps, CATALOG_MAX_SUBJECT_TAKE_BPS);
    }

    function test_validateConfigCommitsToTheExactBytes() public view {
        bytes memory config = _config(10_000, 0, address(0));
        assertEq(module.validateConfig(config), keccak256(config));
    }

    function test_validateConfigRejectsASurchargeAboveTheModuleMaximum() public {
        bytes memory config = _config(module.MAX_BUY_SURCHARGE_PIPS() + 1, 0, address(0));
        vm.expectRevert(ExampleModule.InvalidConfig.selector);
        module.validateConfig(config);
    }

    function test_validateConfigRejectsATakeWithoutARecipient() public {
        bytes memory config = _config(0, 10, address(0));
        vm.expectRevert(ExampleModule.InvalidConfig.selector);
        module.validateConfig(config);
    }

    function test_validateConfigRejectsANonCanonicalEncoding() public {
        bytes memory config = bytes.concat(_config(10_000, 0, address(0)), hex"00");
        vm.expectRevert(ExampleModule.InvalidConfig.selector);
        module.validateConfig(config);
    }

    function test_validateStackRejectsAConfigForAnotherPool() public {
        bytes memory config = _config(10_000, 0, address(0));
        vm.expectRevert(ExampleModule.ConfigNotForThisStack.selector);
        module.validateStack(keccak256("other"), KERNEL, SUBJECT, QUOTE, config);
    }

    function test_exactInputBuyPaysTheSurchargeAndTheTake() public view {
        bytes memory config = _config(10_000, 50, RECIPIENT);
        HookrModuleTypesV1.ModuleResult memory r = module.beforeSwap(_swap(true, true), config);
        assertEq(r.lpFeeSurchargePips, 10_000);
        assertEq(r.quoteTakeBps, 50);
        assertEq(r.claimRecipient, RECIPIENT);
        assertEq(r.attributionKey, module.MODULE_KEY());
    }

    function test_exactOutputBuyPaysOnlyTheSurcharge() public view {
        bytes memory config = _config(10_000, 50, RECIPIENT);
        HookrModuleTypesV1.ModuleResult memory r = module.beforeSwap(_swap(true, false), config);
        assertEq(r.lpFeeSurchargePips, 10_000);
        assertEq(r.quoteTakeBps, 0);
        assertEq(r.claimRecipient, address(0));
    }

    function test_sellsPayNothingExtra() public view {
        bytes memory config = _config(10_000, 50, RECIPIENT);
        HookrModuleTypesV1.ModuleResult memory r = module.beforeSwap(_swap(false, true), config);
        assertEq(r.lpFeeSurchargePips, 0);
        assertEq(r.quoteTakeBps, 0);
        HookrModuleTypesV1.AfterSwapContext memory after_;
        HookrModuleTypesV1.ModuleResult memory a = module.afterSwap(after_, config);
        assertEq(a.lpFeeSurchargePips, 0);
        assertEq(a.quoteTakeBps, 0);
    }

    function testFuzz_resultNeverExceedsTheConfig(uint24 surchargePips, uint16 takeBps) public view {
        surchargePips = uint24(bound(surchargePips, 0, module.MAX_BUY_SURCHARGE_PIPS()));
        takeBps = uint16(bound(takeBps, 0, module.MAX_BUY_TAKE_BPS()));
        bytes memory config = _config(surchargePips, takeBps, takeBps == 0 ? address(0) : RECIPIENT);
        HookrModuleTypesV1.ModuleResult memory r = module.beforeSwap(_swap(true, true), config);
        assertLe(r.lpFeeSurchargePips, surchargePips);
        assertLe(r.quoteTakeBps, takeBps);
    }
}
