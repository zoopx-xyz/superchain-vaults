// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockL2ToL2Messenger} from "contracts/mocks/MockL2ToL2Messenger.sol";

contract Target {
    event Called(bytes data);
    function callMe(bytes calldata data) external { emit Called(data); }
}

contract MockMessengerBranches is Test {
    MockL2ToL2Messenger m; Target t;

    function setUp() public { m = new MockL2ToL2Messenger(); t = new Target(); }

    function testEmptyAndNotReadyBranches() public {
        vm.expectRevert(bytes("EMPTY")); m.deliverNext();
        m.setDelay(block.chainid, 0, 10);
        m.sendMessage(address(t), abi.encodeWithSignature("callMe(bytes)", bytes("x")));
        vm.expectRevert(bytes("NOT_READY")); m.deliverNext();
    }

    function testAllowOutOfOrderAndDuplicates() public {
        m.setDelay(block.chainid, 0, 0);
        m.sendMessage(address(t), abi.encodeWithSignature("callMe(bytes)", bytes("a")));
        m.setDelay(block.chainid, 0, 5);
        m.sendMessage(address(t), abi.encodeWithSignature("callMe(bytes)", bytes("b")));
        // enable out-of-order so the ready message can be delivered despite second not ready
        m.setToggles(false, true);
        // first deliver should deliver the ready one
        m.deliverNext();
        // enable duplicates and deliver again; will re-enqueue the delivered message
        m.setToggles(true, true);
        vm.roll(block.number + 10);
        m.deliverNext();
        // deliverAll should process any remaining without reverting
        m.deliverAll();
    }
}
