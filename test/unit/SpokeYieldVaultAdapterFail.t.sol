// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract ERC20Stub2 {
    string public name = "AST"; string public symbol = "AST";
    mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 value); event Approval(address indexed owner,address indexed spender,uint256 value);
    function decimals() external pure returns(uint8){return 18;}
    function mint(address to,uint256 a) external { balanceOf[to]+=a; emit Transfer(address(0),to,a);}    
    function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; emit Approval(msg.sender,s,a); return true; }
    function transfer(address to,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; emit Transfer(msg.sender,to,a); return true; }
    function transferFrom(address f,address t,uint256 a) external returns(bool){ uint256 al=allowance[f][msg.sender]; require(al>=a,"ALW"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; balanceOf[f]-=a; balanceOf[t]+=a; emit Transfer(f,t,a); return true; }
}

// Adapter missing deposit/withdraw/harvest, but has totalAssets so prechecks pass
contract HalfAdapter { function totalAssets() external pure returns (uint256) { return 0; } }

contract SpokeYieldVaultAdapterFail is Test {
    SpokeYieldVault vault; ERC20Stub2 asset; SuperchainERC20 lst;
    address gov = address(0xA11CE);
    address hub = address(0xB0B);
    address rebal = address(0xBEEF);

    function setUp() public {
        asset = new ERC20Stub2();
        vm.startPrank(gov);
        lst = new SuperchainERC20("LST","LST");
        lst.grantMinter(gov);
        vault = new SpokeYieldVault();
        vault.initialize(IERC20(address(asset)), "Vault", "vAST", hub, gov, rebal, address(this), gov, 0, address(lst));
        lst.grantMinter(address(vault));
        vm.stopPrank();
        asset.mint(address(this), 10 ether);
        asset.approve(address(vault), type(uint256).max);
    }

    // AdapterRegistry hooks expected by vault
    function isAllowed(address) external pure returns (bool) { return true; }
    function capOf(address) external pure returns (uint256) { return type(uint256).max; }

    function testAllocateFailsWhenAdapterMissingDeposit() public {
        HalfAdapter bad = new HalfAdapter();
        // deposit to give vault assets to transfer to adapter
        vault.deposit(1 ether, address(this));
        vm.prank(rebal);
        vm.expectRevert(bytes("ADAPTER_DEPOSIT_FAIL"));
        vault.allocateToAdapter(address(bad), 1 ether, hex"");
    }

    function testDeallocateFailsWhenAdapterMissingWithdraw() public {
        HalfAdapter bad = new HalfAdapter();
        vm.prank(rebal);
        vm.expectRevert(bytes("ADAPTER_WITHDRAW_FAIL"));
        vault.deallocateFromAdapter(address(bad), 1, hex"");
    }

    function testHarvestFailsWhenAdapterMissingHarvest() public {
        HalfAdapter bad = new HalfAdapter();
        vm.prank(rebal);
        vm.expectRevert(bytes("ADAPTER_HARVEST_FAIL"));
        vault.harvestAdapter(address(bad), hex"");
    }
}
