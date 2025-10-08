// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseAdapter} from "contracts/strategy/BaseAdapter.sol";
import {AaveV3Adapter} from "contracts/strategy/AaveV3Adapter.sol";

contract MockERC20Simple {
    string public name = "TOK";
    string public symbol = "TOK";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);
    function mint(address to, uint256 a) external { balanceOf[to] += a; emit Transfer(address(0), to, a); }
    function transfer(address to, uint256 a) external returns (bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; emit Transfer(msg.sender,to,a); return true; }
}

contract AdapterExtraBranches is Test {
    AaveV3Adapter adapter;
    MockERC20Simple token;
    address gov = address(0xA11CE);
    address vault = address(0xBEEF);

    function setUp() public {
        token = new MockERC20Simple();
        adapter = new AaveV3Adapter();
        adapter.initialize(vault, address(token), gov);
    }

    function testOnlyVaultModifierRevertsOnExternalCaller() public {
        // deposit/withdraw/harvest are onlyVault; calling from non-vault should revert
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        adapter.deposit(1, "");
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        adapter.withdraw(1, "");
        vm.expectRevert(abi.encodeWithSignature("OnlyVault()"));
        adapter.harvest("");
    }

    function testEmergencyWithdrawCapsToBalance() public {
        // Pause and call emergencyWithdraw larger than balance; it should cap to balance and emit event
        // Grant GOVERNOR_ROLE to this test to be able to pause
        vm.prank(gov);
        adapter.pause();
        // No balance held; should transfer 0 without revert
        vm.prank(gov);
        adapter.emergencyWithdraw(1 ether);
    }

    function testInitializeZeroAddressReverts() public {
        AaveV3Adapter a = new AaveV3Adapter();
        vm.expectRevert(bytes("ZERO_ADDR"));
        a.initialize(address(0), address(token), gov);
    }
}
