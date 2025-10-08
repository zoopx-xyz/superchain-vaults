// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

// NOTE: This placeholder test intentionally avoids importing deployment scripts.
// Coverage disables via-IR, which makes those scripts hit stack-too-deep.
contract DeployScriptsTest is Test {
    function testPlaceholder() public {
        assertTrue(true);
    }
}
