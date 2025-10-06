// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SuperchainAdapter} from "../../contracts/messaging/SuperchainAdapter.sol";

contract SuperchainAdapterTest is Test {
    SuperchainAdapter adapter;
    address gov = address(0x1);

    function setUp() public {
        adapter = new SuperchainAdapter();
        vm.prank(gov);
        adapter.initialize(address(0x1111), gov);
        vm.prank(gov);
        adapter.setAllowedSelector(bytes4(keccak256("foo()")), true);
        vm.prank(gov);
        adapter.setAllowedSender(block.chainid, address(this), true);
    // grant relayer for acceptIncoming tests
    bytes32 rel = adapter.RELAYER_ROLE();
    vm.prank(gov);
    adapter.grantRole(rel, address(this));
    }

    function testAuthIncoming() public view {
        bool ok = adapter.authIncoming(block.chainid, address(this), bytes4(keccak256("foo()")), bytes32(0));
        assertTrue(ok);
    }

    function testAcceptIncomingReplay() public {
        bytes4 sel = bytes4(keccak256("foo()"));
        adapter.acceptIncoming(block.chainid, address(this), sel, 1, bytes32("a"));
        vm.expectRevert(abi.encodeWithSignature("Replay()"));
        adapter.acceptIncoming(block.chainid, address(this), sel, 1, bytes32("a"));
    }
}
