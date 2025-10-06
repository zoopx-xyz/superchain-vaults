// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SuperchainAdapter} from "contracts/messaging/SuperchainAdapter.sol";

contract MockMessenger {
    event Message(address to, bytes data);
    function sendMessage(address to, bytes calldata data) external { emit Message(to, data); }
}

contract ReceiverMock {
    event Accepted(bytes4 sel, bytes32 nonce, bytes32 actionId);
    function handle(bytes32 nonce) external {
        // simulate acceptance event with same derivation scheme as per project docs
        bytes32 actionId = keccak256(abi.encode("Message", uint256(1), block.chainid, address(this), block.chainid, address(this), msg.sender, address(0), uint256(0), uint256(nonce)));
        emit Accepted(this.handle.selector, nonce, actionId);
    }
}

contract SuperchainAdapterFlowTest is Test {
    SuperchainAdapter ad;
    MockMessenger msgr; ReceiverMock recv;
    address gov = address(0xA11CE);

    function setUp() public {
        msgr = new MockMessenger(); recv = new ReceiverMock();
        ad = new SuperchainAdapter(); ad.initialize(address(msgr), gov);
        vm.prank(gov);
        ad.setAllowedSelector(ReceiverMock.handle.selector, true);
        vm.prank(gov);
        ad.setAllowedSender(block.chainid, address(this), true);
    }

    function testSendAndAuthIncoming() public {
        // send
        vm.prank(gov);
        ad.send(block.chainid, address(recv), abi.encodeWithSelector(ReceiverMock.handle.selector, bytes32(uint256(1234))));
        // auth incoming
        bool ok = ad.authIncoming(block.chainid, address(this), ReceiverMock.handle.selector, bytes32(uint256(1234)));
        assertTrue(ok);
    }
}
