// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";

// Minimal ERC20 stub for asset
contract AssetStub {
	string public name = "AST"; string public symbol = "AST";
	mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
	event Transfer(address indexed from,address indexed to,uint256 v); event Approval(address indexed o,address indexed s,uint256 v);
	function decimals() external pure returns(uint8){return 18;}
	function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; emit Approval(msg.sender,s,a); return true; }
	function transfer(address to,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; emit Transfer(msg.sender,to,a); return true; }
	function transferFrom(address f,address t,uint256 a) external returns(bool){ uint256 al=allowance[f][msg.sender]; require(al>=a,"ALW"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; balanceOf[f]-=a; balanceOf[t]+=a; emit Transfer(f,t,a); return true; }
}

// A token that rejects grantRole calls to force GRANT_MINTER_FAIL
contract RevertingToken {
	string public name; string public symbol;
	constructor(string memory n, string memory s){ name=n; symbol=s; }
	function grantRole(bytes32, address) external pure returns (bool) { return false; }
}

// Implementation that matches SpokeYieldVault.initialize signature but reverts
contract ImplRevert {
	function initialize(
		address,
		string memory,
		string memory,
		address,
		address,
		address,
		address,
		address,
		uint16,
		address
	) external pure {
		revert("NOPE");
	}
}

contract VaultFactoryGrantMinterFailTest is Test {
	VaultFactory factory; address gov = address(this);

	function setUp() public {
		factory = new VaultFactory();
		ProxyDeployer pd = new ProxyDeployer();
		factory.initialize(gov, address(new SpokeYieldVault()), address(0), address(pd));
	}

	function testCreate_RevertsWhenVaultInitFails() public {
		// Set the vault implementation to one that reverts during initialize
		vm.prank(gov);
		factory.setImplementations(address(new ImplRevert()), address(0));

		VaultFactory.CreateParams memory p = VaultFactory.CreateParams({
			asset: address(new AssetStub()),
			name: "V",
			symbol: "V",
			hub: address(0xB0B),
			governor: gov,
			rebalancer: address(0xBEEF),
			adapterRegistry: address(this),
			feeRecipient: address(this),
			performanceFeeBps: 0,
			lst: address(0) // not used by VaultFactory; present in struct for compatibility
		});
	vm.prank(gov);
	vm.expectRevert();
		factory.create(p);
	}
}

