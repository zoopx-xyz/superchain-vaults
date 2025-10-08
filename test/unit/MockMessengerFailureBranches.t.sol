// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockL2ToL2Messenger} from "contracts/mocks/MockL2ToL2Messenger.sol";

contract ReceiverStub {
    bool public shouldRevert;
    event Called(bytes data);
    function setRevert(bool v) external { shouldRevert = v; }
    fallback() external payable {
        if (shouldRevert) revert("FAIL");
        emit Called(msg.data);
    }
}

contract MockMessengerFailureBranches is Test {
    MockL2ToL2Messenger m; ReceiverStub r;

    function setUp() public {
        m = new MockL2ToL2Messenger();
        r = new ReceiverStub();
    }

    function testDeliverFailureReverts() public {
        m.setDelay(block.chainid, 0, 0);
        r.setRevert(true);
        m.sendMessage(address(r), abi.encodeWithSignature("x()"));
        vm.expectRevert(bytes("DELIVER_FAIL"));
        m.deliverNext();
    }

    function testAllowOutOfOrderPopsNonLastIndex() public {
        // configure one with delay so index 1 becomes deliverable first
        m.setDelay(block.chainid, 0, 1);
        m.sendMessage(address(r), abi.encodeWithSignature("x()")); // idx 0, avail = +1
        m.setDelay(block.chainid, 0, 0);
        m.sendMessage(address(r), abi.encodeWithSignature("y()")); // idx 1, avail = now
        m.setToggles(false, true); // allowOutOfOrder = true
        // Should pick idx 1 and pop non-last branch
        m.deliverNext();
        // Now roll to allow the first
        vm.roll(block.number + 1);
        m.deliverNext();
    }
}
