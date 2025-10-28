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
        // Cover enumeration paths
        vm.prank(gov);
        reg.addAdapter(adapter, 123, 2);
        address[] memory list = reg.adapters();
        assertEq(list.length, 1);
        assertEq(list[0], adapter);
        assertEq(reg.withdrawPriority(adapter), 2);
        // Remove and re-add via config update
        vm.prank(gov);
        reg.removeAdapter(adapter);
        vm.prank(gov);
        reg.setAdapterConfig(adapter, true, 456, 5);
        list = reg.adapters();
        assertEq(list.length, 1);
        assertEq(reg.capOf(adapter), 456);
        assertEq(reg.withdrawPriority(adapter), 5);
    }

    function testPauseBlocksSet() public {
        address adapter = address(0xA);
        vm.prank(gov);
        reg.pause();
        vm.prank(gov);
        vm.expectRevert();
        reg.setAdapter(adapter, true, 123);
        // Also cover unpause path
        vm.prank(gov);
        reg.unpause();
    }

    function testEnumerationAndPriorityAndRemoval() public {
        address a1 = address(0xA1);
        address a2 = address(0xA2);
        // add adapters with priorities
        vm.prank(gov);
        reg.addAdapter(a1, 1000, 2);
        vm.prank(gov);
        reg.addAdapter(a2, 2000, 1);
        // views
        address[] memory list = reg.adapters();
        assertEq(list.length, 2);
        // priority set
        assertEq(reg.withdrawPriority(a1), 2);
        assertEq(reg.withdrawPriority(a2), 1);
        // removal
        vm.prank(gov);
        reg.removeAdapter(a1);
        list = reg.adapters();
        assertEq(list.length, 1);
        assertEq(list[0], a2);
        // config update should re-add if missing and update priority
        vm.prank(gov);
        reg.setAdapterConfig(a1, true, 3000, 5);
        list = reg.adapters();
        assertEq(list.length, 2);
        assertTrue(reg.isAllowed(a1));
        assertEq(reg.capOf(a1), 3000);
        assertEq(reg.withdrawPriority(a1), 5);
    }
}
