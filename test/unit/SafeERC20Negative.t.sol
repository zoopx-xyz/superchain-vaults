// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20False} from "contracts/mocks/ERC20False.sol";

// minimal adapter registry
contract MockReg {
    function isAllowed(address) external pure returns (bool) {
        return true;
    }

    function capOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract SafeERC20NegativeTest is Test {
    SpokeYieldVault vault;
    ERC20False bad;
    SuperchainERC20 lst;
    address gov = address(0xA11CE);
    address hub = address(0xB0B);
    address rebal = address(0xBEEF);

    function setUp() public {
        vm.startPrank(gov);
        bad = new ERC20False("BAD", "BAD");
        lst = new SuperchainERC20("LST", "LST");
        lst.grantMinter(gov);
        SpokeYieldVault v = new SpokeYieldVault();
        v.initialize(
            IERC20(address(bad)), "Vault", "vBAD", hub, gov, rebal, address(new MockReg()), gov, 0, address(lst)
        );
        lst.grantMinter(address(v));
        vault = v;
        vm.stopPrank();
        // user mints tokens and approves
        bad.mint(address(this), 100 ether);
        // ERC20False doesn't support approvals failure; approve anyway for ERC4626 deposit path
        bad.approve(address(vault), type(uint256).max);
    }

    function testSafeTransferOutRevertsOnFalseReturn() public {
        // deposit should succeed because ERC4626 uses transferFrom; our token returns false on transferFrom -> vault should revert
        vm.expectRevert();
        vault.deposit(1 ether, address(this));
    }
}
