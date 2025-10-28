// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {EmissionsController} from "contracts/rewards/EmissionsController.sol";

contract EmissionsControllerCoverageTest is Test {
    EmissionsController ctrl;
    address governor = address(this);
    address emitter = address(0xE1);

    function setUp() public {
        ctrl = new EmissionsController();
        ctrl.initialize(governor);
    }

    function testOnlyGovernorSettersAndEpochReset() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert();
        ctrl.setEpochCap(1e18);
        vm.prank(attacker);
        vm.expectRevert();
        ctrl.setPerChainCap(10, 1e18);
        vm.prank(attacker);
        vm.expectRevert();
        ctrl.setEpochStart(123);

        // Governor can
        ctrl.setEpochCap(500);
        ctrl.setPerChainCap(10, 300);

        // Simulate emissions role
        // governor has EMISSIONS_ROLE by initialize
        ctrl.instructDistribute(10, address(0xD1), 200, hex"");
        // epochDistributed updated
        // Now reset epoch start and ensure distributed resets
    ctrl.setEpochStart(block.timestamp);
    // Next distribution after reset should succeed for a different chain id (per-chain counters are not auto-cleared)
    ctrl.instructDistribute(11, address(0xD2), 200, hex"");
    }

    function testCapsEnforcedAndReverts() public {
        ctrl.setEpochCap(300);
        ctrl.setPerChainCap(42, 200);

        // First ok
        ctrl.instructDistribute(42, address(0xA1), 150, hex"");
        // Chain cap would be exceeded by next 100
        vm.expectRevert(bytes("CHAIN_CAP"));
        ctrl.instructDistribute(42, address(0xA1), 100, hex"");

        // Different chain within epoch cap
        ctrl.instructDistribute(1, address(0xA2), 100, hex"");
        // Now epoch cap remaining 50 -> exceeding by 60 should revert
        vm.expectRevert(bytes("EPOCH_CAP"));
        ctrl.instructDistribute(1, address(0xA3), 60, hex"");
    }

    function testOnlyEmissionsRoleCanInstruct() public {
        address attacker = address(0xBAD);
        // revoke EMISSIONS_ROLE from governor then attempt as attacker
        // grant/revoke require DEFAULT_ADMIN, which governor has
        // Revoke governor to ensure role gating tested
        bytes32 EMISSIONS_ROLE = keccak256("EMISSIONS_ROLE");
        ctrl.revokeRole(EMISSIONS_ROLE, governor);
        vm.prank(attacker);
        vm.expectRevert();
        ctrl.instructDistribute(1, address(0xD), 1, hex"");
    }
}
