// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VelodromeLPAdapter} from "contracts/strategy/VelodromeLPAdapter.sol";

contract MockERC20Velo {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        emit Transfer(msg.sender, to, a);
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "ALW");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        emit Transfer(f, t, a);
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }
}

contract VelodromeAdapterTest is Test {
    VelodromeLPAdapter adapter;
    MockERC20Velo token;
    address gov = address(this);
    address vault = address(0xCAFE);

    function setUp() public {
        token = new MockERC20Velo("U", "U");
        adapter = new VelodromeLPAdapter();
        adapter.initialize(vault, address(token), gov);
    }

    function testDepositWithdrawHarvestAndTimestamp() public {
        // deposit via onlyVault
        vm.prank(vault);
        adapter.deposit(10 ether, bytes(""));
        // mint funds and withdraw to vault
        token.mint(address(adapter), 10 ether);
        vm.prank(vault);
        adapter.withdraw(5 ether, bytes(""));
        assertEq(token.balanceOf(vault), 5 ether);
        // harvest emits, updates nothing but is callable
        vm.prank(vault);
        adapter.harvest(bytes(""));
        // cooldown timestamp touched on deposit
        assertGt(adapter.lastAddTimestamp(), 0);
    }

    function testCooldownEnforcedOnWithdraw() public {
        // set a cooldown window
        vm.prank(gov);
        adapter.setCooldown(1 hours);
        // deposit via vault and mint funds into adapter
        vm.prank(vault);
        adapter.deposit(5 ether, bytes(""));
        token.mint(address(adapter), 5 ether);
        // attempt withdraw immediately should revert on cooldown
        vm.prank(vault);
        vm.expectRevert(bytes("COOLDOWN"));
        adapter.withdraw(1 ether, bytes(""));
        // warp past cooldown and withdraw succeeds
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(vault);
        adapter.withdraw(1 ether, bytes(""));
        assertEq(token.balanceOf(vault), 1 ether);
    }

    function testSlippageExceededBranch() public {
        // No cooldown: withdraw with minOut higher than withdrawn should revert
        vm.prank(vault);
        adapter.deposit(2 ether, bytes(""));
        token.mint(address(adapter), 2 ether);
        bytes memory minOutTooHigh = abi.encode(uint256(3 ether));
        vm.prank(vault);
        vm.expectRevert();
        adapter.withdraw(2 ether, minOutTooHigh);
    }
}
