// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdapterRegistry} from "../../contracts/strategy/AdapterRegistry.sol";

contract AdapterRegistryTest is Test {
    AdapterRegistry reg;
    address gov = address(0xBEEF);

    function setUp() public {
        reg = new AdapterRegistry();
        reg.initialize(gov);
    }

    function testSetAdapterAndViews() public {
        address adapter = address(0xA);
        vm.prank(gov);
        reg.setAdapter(adapter, true, 123);
        assertTrue(reg.isAllowed(adapter));
        assertEq(reg.capOf(adapter), 123);
    }

    function testPauseBlocksSet() public {
        address adapter = address(0xA);
        vm.prank(gov);
        reg.pause();
        vm.prank(gov);
        vm.expectRevert();
        reg.setAdapter(adapter, true, 123);
    }
}
