// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EmissionsController} from "contracts/rewards/EmissionsController.sol";
import {PerChainRewardsDistributor} from "contracts/rewards/PerChainRewardsDistributor.sol";

contract MockERC20 {
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

contract MockShareToken {
    mapping(address => uint256) public balanceOf;
    uint256 public ts;

    function totalSupply() external view returns (uint256) {
        return ts;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        ts += a;
    }
}

contract EmissionsAndRewardsTest is Test {
    EmissionsController ec;
    PerChainRewardsDistributor rd;
    MockERC20 zpx;
    MockShareToken lst;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    function setUp() public {
        ec = new EmissionsController();
        ec.initialize(gov);
        rd = new PerChainRewardsDistributor();
        zpx = new MockERC20("ZPX", "ZPX");
        lst = new MockShareToken();
        rd.initialize(address(zpx), address(lst), gov);
        vm.prank(gov);
        ec.setEpochCap(1_000 ether);
        vm.prank(gov);
        ec.setPerChainCap(block.chainid, 700 ether);
        // Fund governor and approve distributor
        zpx.mint(gov, 1000 ether);
        vm.prank(gov);
        zpx.approve(address(rd), type(uint256).max);
        lst.mint(user, 100 ether);
    }

    function testEmissionsCapsAndDistribute() public {
        vm.expectEmit(true, true, false, true);
        emit EmissionsController.InstructDistribute(block.chainid, address(this), 500 ether, hex"");
        vm.prank(gov);
        ec.instructDistribute(block.chainid, address(this), 500 ether, hex"");
        // Cover epoch reset and per-chain caps in the same suite
        vm.prank(gov);
        ec.setEpochStart(block.timestamp + 1);
        uint256 otherChain = block.chainid + 1;
        vm.prank(gov);
        ec.setPerChainCap(otherChain, 300 ether);
        vm.prank(gov);
        ec.instructDistribute(otherChain, address(this), 200 ether, hex"01");
        vm.prank(gov);
        ec.instructDistribute(otherChain, address(this), 100 ether, hex"02");
    }

    function testEpochStartReset() public {
        // Move epoch start forward and ensure counters reset
        vm.prank(gov);
        ec.setEpochStart(block.timestamp + 1);
        // After reset, distributing on a different chain should start fresh accounting
        uint256 otherChain = block.chainid + 1;
        vm.prank(gov);
        ec.setPerChainCap(otherChain, 300 ether);
        vm.prank(gov);
        ec.instructDistribute(otherChain, address(this), 200 ether, hex"01");
        // second distribute within cap should pass
        vm.prank(gov);
        ec.instructDistribute(otherChain, address(this), 100 ether, hex"02");
    }

    function testRewardsAccrualAndClaim() public {
        // add rewards and accrue for user
        vm.prank(gov);
        rd.addRewards(100 ether);
        rd.checkpoint(user);
        uint256 acc = rd.accrued(user);
        assertGt(acc, 0);
        // claim to user
        uint256 before = zpx.balanceOf(user);
        vm.prank(user);
        rd.claim(user);
        assertEq(zpx.balanceOf(user) - before, acc);
    }
}
