// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

contract ExportScenarios is Test {
    function test_WriteCSV() public {
        // Minimal CSV with headers and one row as a placeholder for CI artifact
        // Ensure directory exists (relative to project root)
        vm.createDir("artifacts/econsec", true);
        string memory path = "artifacts/econsec/sim-results.csv";
        vm.writeFile(path, "scenario,metric,value\n");
        vm.writeLine(path, "S4,borrow_throttled,1");
    }
}
