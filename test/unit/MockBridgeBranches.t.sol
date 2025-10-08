// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockBridge} from "contracts/mocks/MockBridge.sol";

contract ERC20MB {
    string public name = "T"; string public symbol = "T"; mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 v); event Approval(address indexed o,address indexed s,uint256 v);
    function decimals() external pure returns(uint8){return 18;}
    function transfer(address to,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; emit Transfer(msg.sender,to,a); return true; }
    function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; emit Approval(msg.sender,s,a); return true; }
    function transferFrom(address f,address t,uint256 a) external returns(bool){ uint256 al=allowance[f][msg.sender]; require(al>=a,"ALW"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; balanceOf[f]-=a; balanceOf[t]+=a; emit Transfer(f,t,a); return true; }
    function mint(address to,uint256 a) external { balanceOf[to]+=a; emit Transfer(address(0),to,a);}    
}

contract MockBridgeBranches is Test {
    MockBridge bridge; ERC20MB tok; address user=address(0xBEEF);

    function setUp() public { bridge = new MockBridge(); tok = new ERC20MB(); }

    function testEmptyAndNotReadyReverts() public {
        vm.expectRevert(bytes("EMPTY")); bridge.deliverNext();
        bridge.setToken(address(tok), true);
        bridge.setDelay(address(tok), 5);
        bridge.send(address(tok), user, 1 ether, false);
        vm.expectRevert(bytes("NOT_READY")); bridge.deliverNext();
    }

    function testDeliverSuccessAndFailPaths() public {
        bridge.setToken(address(tok), true);
        bridge.setDelay(address(tok), 0);
        // fund bridge for success path
        tok.mint(address(bridge), 3 ether);
        // enqueue success then fail entries
        bridge.send(address(tok), user, 1 ether, false);
        bridge.send(address(tok), user, 2 ether, true);
        // first deliver transfers
        bridge.deliverNext();
        assertEq(tok.balanceOf(user), 1 ether);
        // second deliver does not transfer on fail=true
        bridge.deliverNext();
        assertEq(tok.balanceOf(user), 1 ether);
    }

    function testDeliverAllStopsWhenNotReady() public {
        bridge.setToken(address(tok), true);
        bridge.setDelay(address(tok), 2);
        tok.mint(address(bridge), 1 ether);
        bridge.send(address(tok), user, 1 ether, false);
        // not ready yet; deliverAll should not revert and should leave queue intact
        bridge.deliverAll();
        // advance blocks to become ready and deliver
        vm.roll(block.number + 3);
        bridge.deliverAll();
        assertEq(tok.balanceOf(user), 1 ether);
    }
}
