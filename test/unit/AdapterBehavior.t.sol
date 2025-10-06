// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AaveV3Adapter} from "contracts/strategy/AaveV3Adapter.sol";
import {BaseAdapter} from "contracts/strategy/BaseAdapter.sol";

contract MockERC20 {
    string public name; string public symbol; uint8 public immutable decimals = 18;
    mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    constructor(string memory n, string memory s){name=n;symbol=s;}
    function transfer(address to,uint256 a) external returns(bool){balanceOf[msg.sender]-=a;balanceOf[to]+=a;emit Transfer(msg.sender,to,a);return true;}
    function approve(address s,uint256 a) external returns(bool){allowance[msg.sender][s]=a;emit Approval(msg.sender,s,a);return true;}
    function transferFrom(address f,address t,uint256 a) external returns(bool){uint256 al=allowance[f][msg.sender];require(al>=a,"ALW");if(al!=type(uint256).max) allowance[f][msg.sender]=al-a;balanceOf[f]-=a;balanceOf[t]+=a;emit Transfer(f,t,a);return true;}
    function mint(address to,uint256 a) external {balanceOf[to]+=a;emit Transfer(address(0),to,a);}    
}

contract AdapterBehaviorTest is Test {
    AaveV3Adapter adapter; MockERC20 token;
    address gov = address(this);
    address vault = address(0xBEEF);

    function setUp() public {
        token = new MockERC20("U","U");
        adapter = new AaveV3Adapter();
        adapter.initialize(vault, address(token), gov);
    }

    function testCapPauseDepositWithdrawHarvestEmergency() public {
        // cap set by governor
        adapter.setCap(1_000 ether);
        assertEq(adapter.cap(), 1_000 ether);

        // deposit (onlyVault), emits event
        vm.prank(vault);
        adapter.deposit(50 ether, bytes(""));

        // ensure adapter has funds for withdraw path and emergency
        token.mint(address(adapter), 100 ether);

        // withdraw (onlyVault), transfers to vault
    vm.prank(vault);
    adapter.withdraw(20 ether, abi.encode(uint256(10 ether)));
        assertEq(token.balanceOf(vault), 20 ether);

        // harvest (onlyVault), no-op but emits event
        vm.prank(vault);
        adapter.harvest(bytes(""));

        // pause/unpause events and emergencyWithdraw when paused
        adapter.pause();
        adapter.emergencyWithdraw(10 ether);
        assertEq(token.balanceOf(vault), 30 ether);
        adapter.unpause();
    }

    function testSlippageRevert() public {
        // mint funds and try to withdraw with too high minOut
        token.mint(address(adapter), 5 ether);
        vm.prank(vault);
        vm.expectRevert();
        adapter.withdraw(4 ether, abi.encode(uint256(5 ether)));
    }
}
