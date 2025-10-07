// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract TestERC20 is Test {
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
        require(balanceOf[msg.sender] >= a, "bal");
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
        require(balanceOf[f] >= a, "bal");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        emit Transfer(f, t, a);
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function totalSupply() external view returns (uint256) {
        return 0;
    }
}

contract MockAdapterRegistry {
    function isAllowed(address) external pure returns (bool) {
        return true;
    }

    function capOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract EpochCapRolloverTest is Test {
    SpokeYieldVault vault;
    TestERC20 asset;
    SuperchainERC20 lst;
    address gov = address(0xA11CE);
    address hub = address(0xB0B);
    address rebal = address(0xBEEF);

    function setUp() public {
        vm.startPrank(gov);
        asset = new TestERC20("ASSET", "AST");
        lst = new SuperchainERC20("LST", "LST");
        lst.grantMinter(gov);
        vault = new SpokeYieldVault();
        vault.initialize(
            IERC20(address(asset)),
            "Vault",
            "vAST",
            hub,
            gov,
            rebal,
            address(new MockAdapterRegistry()),
            gov,
            0,
            address(lst)
        );
        lst.grantMinter(address(vault));
        vm.stopPrank();

        asset.mint(address(this), 1000 ether);
        asset.approve(address(vault), type(uint256).max);

        // deposit funds so local buffer can serve
        vault.deposit(200 ether, address(this));
        // set buffer to 100%, set epoch length and cap, and grant hub role under governor context
        vm.startPrank(gov);
        vault.setWithdrawalBufferBps(10_000);
        vault.setEpochOutflowConfig(1000, 1); // 10% cap, 1s epoch for fast rollover
        vault.grantRole(vault.HUB_ROLE(), hub);
        vm.stopPrank();
    }

    function testEpochCapEnforcedAndRollover() public {
        uint256 tvl = vault.totalAssets();
        uint256 cap = (tvl * 1000) / 10_000; // 10%
        vm.prank(hub);
        vault.requestRemoteLiquidity(address(this), cap);
        // next attempt within same epoch should revert
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSignature("CapExceeded()"));
        vault.requestRemoteLiquidity(address(this), 1);
        // advance to next epoch
        vm.warp(block.timestamp + 2);
        // now it should pass again
        vm.prank(hub);
        vault.requestRemoteLiquidity(address(this), 1);
    }
}
