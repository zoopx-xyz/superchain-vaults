// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SuperVaultHub} from "contracts/hub/SuperVaultHub.sol";

contract Hub_CanonicalAccounting is Test {
    SuperVaultHub hub;
    address gov = address(0xA11CE);
    address relayer = address(0xBEEF);
    address spoke1 = address(0x111);

    function setUp() public {
        vm.startPrank(gov);
        hub = new SuperVaultHub();
        hub.initialize(address(0x999), address(0xAAA), gov, relayer);
        hub.registerSpoke(1, spoke1);
        vm.stopPrank();
    }

    function testCreditAndWithdrawalAdjustsCounters() public {
        // Credit a remote deposit
        bytes32 nonce = keccak256("n");
        // Without setters, pendingInbound adjusts inside creditRemoteDeposit; so we first bump it with requestRemoteWithdrawal negative test
        vm.prank(relayer);
        hub.requestRemoteWithdrawal(1, address(0x123), 100);
        // now pendingOutbound increased and canonical decreased
        (uint256 tvl1,, uint256 out1,) = hub.canonicalSnapshot();
        assertEq(out1, 100);
        // simulate inbound credit
        vm.prank(relayer);
        hub.creditRemoteDeposit(1, spoke1, address(0x123), 50, 0, nonce);
        (uint256 tvl2, uint256 inb2, uint256 out2,) = hub.canonicalSnapshot();
        // tvl increased by 50, pendingInbound not increased (it decreased if it was set before), pendingOutbound remains 100
        assertEq(out2, 100);
        assertEq(tvl2, tvl1 + 50);
        assertEq(inb2, 0);
    }

    function testControllerCallReverts() public {
        vm.expectRevert();
        // function is pure and reverts NotImplemented
        bytes memory payload = hex"deadbeef";
        // any caller should revert
        hub.controllerCall(payload);
    }
}
