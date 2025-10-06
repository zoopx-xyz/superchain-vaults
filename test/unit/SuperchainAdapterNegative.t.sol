// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SuperchainAdapter} from "contracts/messaging/SuperchainAdapter.sol";

contract MockMessengerNeg {
    event Message(address to, bytes data);
    function sendMessage(address to, bytes calldata data) external { emit Message(to, data); }
}

contract SuperchainAdapterNegativeTest is Test {
    SuperchainAdapter ad; MockMessengerNeg msgr;
    address gov = address(0xA11CE);

    function setUp() public {
        msgr = new MockMessengerNeg();
        ad = new SuperchainAdapter();
        ad.initialize(address(msgr), gov);
        vm.prank(gov);
        ad.setAllowedSelector(bytes4(keccak256("foo()")), true);
        vm.prank(gov);
        ad.setAllowedSender(block.chainid, address(this), true);
    }

    function testBridgeDisabledBlocksSend() public {
        vm.prank(gov); ad.setBridgeEnabled(false);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSignature("BridgeDisabled()"));
        ad.send(block.chainid, address(this), abi.encodeWithSelector(bytes4(keccak256("foo()"))));
    }

    function testNotAllowedSelectorRevertsSend() public {
        // disable selector
        vm.prank(gov); ad.setAllowedSelector(bytes4(keccak256("foo()")), false);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSignature("NotAllowedSelector()"));
        ad.send(block.chainid, address(this), abi.encodeWithSelector(bytes4(keccak256("foo()"))));
    }

    function testAuthIncomingNotAllowedSenderAndSelector() public {
        // wrong sender
        vm.expectRevert(abi.encodeWithSignature("NotAllowedSender()"));
        ad.authIncoming(block.chainid, address(0xBEEF), bytes4(keccak256("foo()")), bytes32(0));
        // wrong selector
        vm.expectRevert(abi.encodeWithSignature("NotAllowedSelector()"));
        ad.authIncoming(block.chainid, address(this), bytes4(keccak256("bar()")), bytes32(0));
    }

    function testNonceMonotonicPerChannel() public {
        vm.prank(gov);
        ad.setBridgeEnabled(true);
        bytes4 sel = bytes4(keccak256("foo()"));
        // send twice to same channel
        vm.prank(gov); ad.send(10, address(0x1234), abi.encodeWithSelector(sel));
        vm.prank(gov); ad.send(10, address(0x1234), abi.encodeWithSelector(sel));
        // compute channel key and check nonce
        bytes32 channel = keccak256(abi.encodePacked(uint256(block.chainid), address(ad), uint256(10), address(0x1234)));
        uint256 n = ad.nonceOf(channel);
        assertEq(n, 2);
    }
}
