// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EmissionsController} from "contracts/rewards/EmissionsController.sol";

contract EmissionsControllerBranches is Test {
    EmissionsController ec; address gov = address(0xA11CE);

    function setUp() public { ec = new EmissionsController(); ec.initialize(gov); }

    function testChainCapExceededRevertsAndEpochReset() public {
        vm.prank(gov); ec.setEpochCap(100 ether);
        vm.prank(gov); ec.setPerChainCap(block.chainid, 10 ether);
        // first distribution within cap
        vm.prank(gov); ec.instructDistribute(block.chainid, address(this), 10 ether, hex"");
        // exceeding per-chain cap now reverts
        vm.prank(gov); vm.expectRevert(bytes("CHAIN_CAP"));
        ec.instructDistribute(block.chainid, address(this), 1, hex"");
        // reset epoch and switch to a different chain id cap to demonstrate epoch reset (per-chain counters persist)
        vm.prank(gov); ec.setEpochStart(block.timestamp);
        uint256 otherChain = block.chainid + 1;
        vm.prank(gov); ec.setPerChainCap(otherChain, 10 ether);
        vm.prank(gov); ec.instructDistribute(otherChain, address(this), 5 ether, hex"");
    }
}
