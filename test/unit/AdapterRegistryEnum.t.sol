// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";

contract AdapterRegistryEnumTest is Test {
    AdapterRegistry registry;
    address gov = address(this);

    address a1 = address(0xA1);
    address a2 = address(0xA2);

    function setUp() public {
        registry = new AdapterRegistry();
        registry.initialize(gov);
    }

    function test_AddEnumerateRemove() public {
        registry.addAdapter(a1, 1_000 ether, 1);
        registry.addAdapter(a2, 2_000 ether, 2);

        address[] memory arr = registry.adapters();
        assertEq(arr.length, 2);
        assertTrue(registry.isAdapter(a1));
        assertTrue(registry.isAdapter(a2));
        assertEq(registry.withdrawPriority(a1), 1);
        assertEq(registry.withdrawPriority(a2), 2);
        assertTrue(registry.isAllowed(a1));
        assertTrue(registry.isAllowed(a2));

        registry.removeAdapter(a1);
        arr = registry.adapters();
        assertEq(arr.length, 1);
        assertEq(arr[0], a2);
        assertTrue(!registry.isAdapter(a1));
    }

    function test_SetConfig() public {
        registry.setAdapterConfig(a1, true, 3_000 ether, 5);
        assertTrue(registry.isAdapter(a1));
        assertTrue(registry.isAllowed(a1));
        assertEq(registry.capOf(a1), 3_000 ether);
        assertEq(registry.withdrawPriority(a1), 5);
    }
}
