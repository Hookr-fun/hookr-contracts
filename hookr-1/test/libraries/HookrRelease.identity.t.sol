// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRelease} from "../../src/libraries/HookrRelease.sol";
import {HookrReleased} from "../../src/base/HookrReleased.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";

/// @notice Every deployed contract in the set reports the same release, and its storage ids carry role names only.
contract ReleaseIdentityTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testEveryCoreContractReportsTheSameRelease() public view {
        address[6] memory set =
            [address(registry), address(rules), address(root), address(router), address(quoter), address(launcher)];
        for (uint256 i; i < set.length; ++i) {
            assertEq(HookrReleased(set[i]).releaseId(), HookrRelease.ID);
        }
        assertEq(HookrRelease.ID, 1);
    }

    /// The Rules' schema id is RulesConfig's type string, a role name with no version label, and it names the 16-word
    /// layout: it moved off keccak256("hookr.rules.config"), the id of the 15-word layout, so a reader built for that
    /// layout fails closed. It is defined once, as HookrTypes.RULES_CONFIG_SCHEMA, which the Rules answer and
    /// HookrFeeAdvisory reads.
    function testRulesSchemaIdCarriesNoVersionLabel() public {
        string memory typeString =
            "RulesConfig(uint40 guardEndBlock,uint24 maxFeePips,uint24 snipeTaxPips,uint24 snipeFloorPips,uint16 snipeDecaySeconds,uint16 dynamicFeeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint16 protocolShareBps,uint32 potEveryNBuys,uint128 maxBuyQuoteAmount,uint128 potMinBuyQuote,address royaltyTo,address integrator)";
        assertEq(HookrTypes.RULES_CONFIG_SCHEMA, keccak256(bytes(typeString)), "the one constant is the type string's");
        assertEq(rules.configSchemaHash(), keccak256(bytes(typeString)));
        assertTrue(rules.configSchemaHash() != keccak256("hookr.rules.config"), "not the 15-word layout's id");
        HookrSessionAdvisory calendar = new HookrSessionAdvisory(address(this), 1 days);
        HookrFeeAdvisory fee =
            new HookrFeeAdvisory(address(this), 1 days, IHookrRegistry(address(registry)), address(calendar));
        assertEq(fee.RULES_SCHEMA(), rules.configSchemaHash(), "the fee advisory reads the same id");
        HookrTypes.RulesConfig memory c;
        uint256 fields = 1;
        bytes memory t = bytes(typeString);
        for (uint256 i; i < t.length; ++i) {
            if (t[i] == ",") ++fields;
        }
        assertEq(abi.encode(c).length, fields * 32, "one type-string field per config word");
        assertEq(fields, 16);
    }
}
