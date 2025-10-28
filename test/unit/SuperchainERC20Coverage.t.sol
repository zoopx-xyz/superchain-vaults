// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract SuperchainERC20CoverageTest is Test {
    SuperchainERC20 token;
    address admin = address(this);
    address vault = address(0xBEEF);
    address notAdmin = address(0xBAD);

    function setUp() public {
        token = new SuperchainERC20("LST", "LST");
    }

    function testDecimalsIs18() public {
        assertEq(token.decimals(), 18);
    }

    function testOnlyAdminCanGrantRevokeMinter() public {
        vm.prank(notAdmin);
        vm.expectRevert();
        token.grantMinter(vault);
        vm.prank(notAdmin);
        vm.expectRevert();
        token.revokeMinter(vault);

        // Admin succeeds
        token.grantMinter(vault);
        token.revokeMinter(vault);
    }

    function testMinterSetEvents() public {
        vm.expectEmit(true, false, false, true);
        emit SuperchainERC20.MinterSet(vault, true);
        token.grantMinter(vault);

        vm.expectEmit(true, false, false, true);
        emit SuperchainERC20.MinterSet(vault, false);
        token.revokeMinter(vault);
    }
}
