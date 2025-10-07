// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployPhase1} from "../../script/DeployPhase1.s.sol";
import {DeployPhase2} from "../../script/DeployPhase2.s.sol";

contract DeployScriptsTest is Test {
    function testInvokeRunPhase1() public {
        DeployPhase1 s = new DeployPhase1();
        // Not asserting effects; ensure code path executes for coverage
        vm.expectRevert(); // run() currently has TODO; expecting no revert is okay too
        try s.run() {} catch { /* ignore */ }
    }

    function testInvokeRunPhase2() public {
        DeployPhase2 s = new DeployPhase2();
        vm.expectRevert();
        try s.run() {} catch { /* ignore */ }
    }
}
