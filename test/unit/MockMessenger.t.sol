// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockL2ToL2Messenger} from "../../contracts/mocks/MockL2ToL2Messenger.sol";

contract Receiver {
    event Got(bytes data);

    function foo(uint256 x) external {
        emit Got(abi.encode(x));
    }

    fallback() external {
        emit Got(msg.data);
    }
}

contract MockMessengerTest is Test {
    MockL2ToL2Messenger messenger;
    Receiver recv;

    function setUp() public {
        messenger = new MockL2ToL2Messenger();
        recv = new Receiver();
    }

    function testSendAndDeliver() public {
        // zero delay for current chain -> dst(0)
        messenger.setDelay(block.chainid, 0, 0);
        messenger.setToggles(false, false);

        // enqueue message
        messenger.sendMessage(address(recv), abi.encodeWithSignature("foo(uint256)", 42));
        assertEq(messenger.size(), 1, "queued");

        // deliver immediately
        messenger.deliverNext();
        assertEq(messenger.size(), 0, "cleared");
    }

    function testDuplicatesThenClear() public {
        // zero delay, enable duplicates
        messenger.setDelay(block.chainid, 0, 0);
        messenger.setToggles(true, true);

        messenger.sendMessage(address(recv), abi.encodeWithSignature("foo(uint256)", 7));
        assertEq(messenger.size(), 1, "queued");

        // First delivery will re-enqueue the same message due to duplicates=true
        messenger.deliverNext();
        assertEq(messenger.size(), 1, "duplicate re-enqueued");

        // Turn off duplicates and drain remaining
        messenger.setToggles(false, true);
        messenger.deliverNext();
        assertEq(messenger.size(), 0, "drained");
    }
}
