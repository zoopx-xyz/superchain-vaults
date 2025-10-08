// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EmissionsController} from "contracts/rewards/EmissionsController.sol";

contract EmissionsControllerEqualityCaps is Test {
    EmissionsController ctrl; address gov = address(this);

    function setUp() public {
        ctrl = new EmissionsController();
        ctrl.initialize(gov);
    }

    function testEpochCapAllowsExactEquality() public {
        ctrl.setEpochCap(100);
        ctrl.setEpochStart(block.timestamp);
        // First instruct amount exactly equal to cap should pass since starting at 0
        ctrl.instructDistribute(10, address(0xD1), 100, bytes("x"));
        // Further 1 wei should now fail
        vm.expectRevert(bytes("EPOCH_CAP"));
        ctrl.instructDistribute(10, address(0xD1), 1, bytes("y"));
    }

    function testPerChainCapAllowsExactEquality() public {
        ctrl.setEpochStart(block.timestamp);
        ctrl.setPerChainCap(111, 50);
        // First distribute exactly at cap for chain 111
        ctrl.instructDistribute(111, address(0xD1), 50, bytes("x"));
        // Additional should fail for that chain
        vm.expectRevert(bytes("CHAIN_CAP"));
        ctrl.instructDistribute(111, address(0xD1), 1, bytes("y"));
    }
}
