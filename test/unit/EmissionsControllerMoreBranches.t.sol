// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EmissionsController} from "contracts/rewards/EmissionsController.sol";

contract EmissionsControllerMoreBranches is Test {
    EmissionsController ctl;
    address gov = address(0xA11CE);

    function setUp() public {
        ctl = new EmissionsController();
        ctl.initialize(gov);
    }

    function testNoCapsSkipChecks() public {
        // With both caps unset (0), instructDistribute should not check/revert
        vm.prank(gov);
        ctl.setEpochStart(block.timestamp);
        // EMISSIONS_ROLE is granted to governor in initialize
        vm.prank(gov);
        ctl.instructDistribute(10, address(0xD1), 1_000 ether, hex"");
        // Set only epoch cap and ensure small amount does not revert
        vm.prank(gov);
        ctl.setEpochCap(2_000 ether);
        vm.prank(gov);
        ctl.instructDistribute(10, address(0xD1), 1_000 ether, hex"");
        // Reset epoch window to clear epochDistributed before testing per-chain cap branch
        vm.prank(gov);
        ctl.setEpochStart(block.timestamp);
        // Set per-chain cap but leave generous; ensure not hit
        vm.prank(gov);
        ctl.setPerChainCap(10, 5_000 ether);
        vm.prank(gov);
        ctl.instructDistribute(10, address(0xD1), 1_000 ether, hex"");
    }
}
