// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";

contract AdapterRegistryMoreTest is Test {
    AdapterRegistry registry;
    address gov = address(this);

    address a1 = address(0xA1);
    address a2 = address(0xA2);
    address a3 = address(0xA3);

    function setUp() public {
        registry = new AdapterRegistry();
        registry.initialize(gov);
    }

    function testPauseUnpauseEmits() public {
        vm.expectEmit(true, false, false, true);
        emit AdapterRegistry.RegistryPaused(true);
        registry.pause();
        vm.expectEmit(true, false, false, true);
        emit AdapterRegistry.RegistryPaused(false);
        registry.unpause();
    }

    function testDuplicateConfigDoesNotDuplicateArray() public {
        registry.addAdapter(a1, 100, 1);
        registry.setAdapterConfig(a1, true, 200, 5);
        address[] memory arr = registry.adapters();
        assertEq(arr.length, 1);
        assertEq(arr[0], a1);
        // repeat config again
        registry.setAdapterConfig(a1, true, 300, 6);
        arr = registry.adapters();
        assertEq(arr.length, 1);
    }

    function testRemoveMiddleSwaps() public {
        registry.addAdapter(a1, 100, 1);
        registry.addAdapter(a2, 100, 2);
        registry.addAdapter(a3, 100, 3);
        // remove a2 (middle)
        registry.removeAdapter(a2);
        address[] memory arr = registry.adapters();
        assertEq(arr.length, 2);
        // Remaining should be a1 and a3 in some order; ensure a2 gone
        assertTrue(arr[0] != a2 && arr[1] != a2);
    }

    function testRemoveNonExistentNoop() public {
        // removing before add -> noop
        registry.removeAdapter(a1);
        address[] memory arr = registry.adapters();
        assertEq(arr.length, 0);
    }
}
