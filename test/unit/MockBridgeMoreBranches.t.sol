// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockBridge} from "contracts/mocks/MockBridge.sol";

contract ERC20Simple {
    string public name = "T"; string public symbol = "T";
    mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 v); event Approval(address indexed o,address indexed s,uint256 v);
    function decimals() external pure returns(uint8){return 18;}
    function mint(address to,uint256 a) external { balanceOf[to]+=a; emit Transfer(address(0),to,a); }
    function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; emit Approval(msg.sender,s,a); return true; }
    function transfer(address to,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; emit Transfer(msg.sender,to,a); return true; }
    function transferFrom(address f,address t,uint256 a) external returns(bool){ uint256 al=allowance[f][msg.sender]; require(al>=a,"ALW"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; balanceOf[f]-=a; balanceOf[t]+=a; emit Transfer(f,t,a); return true; }
}

contract MockBridgeMoreBranches is Test {
    MockBridge bridge; ERC20Simple token; address user=address(0xBEEF);

    function setUp() public {
        bridge = new MockBridge();
        token = new ERC20Simple();
        // Bridge sends tokens from its own balance in this mock
        token.mint(address(bridge), 100 ether);
        bridge.setToken(address(token), true);
        bridge.setDelay(address(token), 1); // one block delay
        // approve not required; transfers are from bridge to user directly
    }

    function testDeliverFailPath_NoTransfer() public {
        // enqueue with fail=true to exercise branch that skips transfer
        bridge.send(address(token), user, 10 ether, true);
        // advance one block to be deliverable
        vm.roll(block.number + 1);
        uint256 before = token.balanceOf(user);
        bridge.deliverNext();
        assertEq(token.balanceOf(user), before); // no transfer on fail path
    }

    function testDeliverAllLoopsAndStops() public {
        // enqueue multiple with mixed availabilities
        bridge.send(address(token), user, 1 ether, false); // avail at +1
        bridge.send(address(token), user, 2 ether, false); // avail at +1
        // not yet deliverable
        vm.expectRevert(bytes("NOT_READY"));
        bridge.deliverNext();
        // now make deliverable
        vm.roll(block.number + 1);
        bridge.deliverAll();
        // queue should be empty
        // can't easily query queue length; check user balance increased by total
        assertEq(token.balanceOf(user), 3 ether);
    }
}
