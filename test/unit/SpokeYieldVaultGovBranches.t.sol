// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract ERC20Stub {
    string public name = "AST";
    string public symbol = "AST";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function decimals() external pure returns (uint8) { return 18; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; emit Transfer(address(0), to, a); }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; emit Transfer(msg.sender, to, a); return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender]; require(al >= a, "ALW"); if (al != type(uint256).max) allowance[f][msg.sender] = al - a; balanceOf[f] -= a; balanceOf[t] += a; emit Transfer(f, t, a); return true;
    }
}

contract SpokeYieldVaultGovBranchesTest is Test {
    SpokeYieldVault vault; ERC20Stub asset; SuperchainERC20 lst;
    address gov = address(0xA11CE);
    address hub = address(0xB0B);
    address rebal = address(0xBEEF);

    function setUp() public {
        asset = new ERC20Stub();
        vm.startPrank(gov);
        lst = new SuperchainERC20("LST", "LST");
        lst.grantMinter(gov);
        vault = new SpokeYieldVault();
        vault.initialize(IERC20(address(asset)), "Vault", "vAST", hub, gov, rebal, address(this), gov, 0, address(lst));
        lst.grantMinter(address(vault));
        vm.stopPrank();
        asset.mint(address(this), 100 ether);
        asset.approve(address(vault), type(uint256).max);
    }

    // AdapterRegistry minimal surface used by vault
    function isAllowed(address) external pure returns (bool) { return true; }
    function capOf(address) external pure returns (uint256) { return type(uint256).max; }

    function testProposeGovernorZeroAddressReverts() public {
        vm.prank(gov);
        vm.expectRevert(bytes("ZERO_GOV"));
        vault.proposeGovernor(address(0));
    }

    function testAcceptGovernorNotPendingReverts() public {
        // No proposal yet
        vm.expectRevert(bytes("NOT_PENDING"));
        vault.acceptGovernor();
    }

    function testGovernorTransferHappyPath() public {
        address newGov = address(0xCAFE);
        // propose by current governor
        vm.prank(gov);
        vault.proposeGovernor(newGov);
        // accept by pending
        vm.prank(newGov);
        vault.acceptGovernor();
        // new governor can set flags; old governor cannot
        vm.prank(newGov);
        vault.setFlags(true, true, true);
        vm.prank(gov);
        vm.expectRevert();
        vault.setFlags(true, true, true);
    }

    function testEnqueueZeroSharesReverts() public {
        vm.expectRevert(bytes("ZERO_SHARES"));
        vault.enqueueWithdraw(0);
    }

    function testEnqueueWithActionIdZeroSharesReverts() public {
        vm.expectRevert(bytes("ZERO_SHARES"));
        vault.enqueueWithdraw(0, bytes32("aid"));
    }
}
