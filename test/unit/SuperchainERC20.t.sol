// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract SuperchainERC20Test is Test {
    SuperchainERC20 token;
    address admin = address(this);
    address vault = address(0xBEEF);
    address user = address(0xCAFE);

    function setUp() public {
        token = new SuperchainERC20("LST", "LST");
    }

    function testGrantRevokeMinterAndMintBurn() public {
        token.grantMinter(vault);
        vm.prank(vault);
        token.mint(user, 100 ether);
        assertEq(token.balanceOf(user), 100 ether);
        vm.prank(vault);
        token.burn(user, 40 ether);
        assertEq(token.balanceOf(user), 60 ether);
        token.revokeMinter(vault);
        vm.expectRevert();
        vm.prank(vault);
        token.mint(user, 1);
        // Also cover decimals()
        assertEq(token.decimals(), 18);
    }
}
