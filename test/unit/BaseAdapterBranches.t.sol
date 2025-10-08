// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "contracts/strategy/BaseAdapter.sol";
import {AaveV3Adapter} from "contracts/strategy/AaveV3Adapter.sol";
import {MockERC20Decimals} from "contracts/mocks/MockERC20Decimals.sol";

contract BaseAdapterBranchesTest is Test {
    AaveV3Adapter adapter;
    MockERC20Decimals token;
    address gov = address(0xA11CE);
    address vault = address(0xBEEF);

    function setUp() public {
        token = new MockERC20Decimals("TK", "TK", 18);
        adapter = new AaveV3Adapter();
        adapter.initialize(vault, address(token), gov);
        token.mint(address(adapter), 1000 ether);
    }

    function testPauseUnpauseAndEmergencyWithdraw() public {
        vm.prank(gov);
        adapter.pause();
        // while paused, emergencyWithdraw allowed
        vm.prank(gov);
        adapter.emergencyWithdraw(200 ether);
        assertEq(token.balanceOf(vault), 200 ether);
        // request more than balance to hit cap-to-balance branch
        vm.prank(gov);
        adapter.emergencyWithdraw(10_000 ether);
        // remaining adapter balance moved to vault
        assertGt(token.balanceOf(vault), 200 ether);
        // unpause back
        vm.prank(gov);
        adapter.unpause();
    }

    function testSetCapAndWithdrawSlippageBranch() public {
        vm.prank(gov);
        adapter.setCap(1_000_000 ether);
        // simulate vault-only withdraw hitting slippage revert path
        bytes memory minOut = abi.encode(500 ether);
        vm.expectRevert();
        vm.prank(vault);
        adapter.withdraw(100 ether, minOut);
    }

    function testWithdrawNoMinOutPath() public {
        // withdraw without encoded minOut to take data.length < 32 branch
        vm.prank(vault);
        adapter.withdraw(50 ether, "");
        assertEq(token.balanceOf(vault), 50 ether);
    }
}
