// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {SuperVaultHub} from "../../contracts/hub/SuperVaultHub.sol";

contract NoncesInvariant is StdInvariant, Test {
    SuperVaultHub hub;

    function setUp() public {
        hub = new SuperVaultHub();
        // can't initialize upgradeable without proxy in this simple harness; just target the address for invariant infra
        targetContract(address(hub));
    }

    function invariant_noop() public {}
}
