// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SuperVaultHub} from "contracts/hub/SuperVaultHub.sol";

contract SuperVaultHubBranches is Test {
    SuperVaultHub hub;
    address gov = address(0xA11CE);
    address relayer = address(0xCAFE);
    address base = address(0xBEEF);
    address adapter = address(0xF00D);

    function setUp() public {
        hub = new SuperVaultHub();
        hub.initialize(base, adapter, gov, relayer);
    }

    function testBridgeDisabledRevertsOnRelayerCalls() public {
        vm.prank(gov); hub.setBridgeEnabled(false);
        vm.prank(relayer); vm.expectRevert(abi.encodeWithSignature("BridgeDisabled()"));
        hub.creditRemoteDeposit(1, address(0x1), address(this), 1, 1, bytes32("n"));
        vm.prank(relayer); vm.expectRevert(abi.encodeWithSignature("BridgeDisabled()"));
        hub.requestRemoteWithdrawal(1, address(this), 1);
    }

    function testInvalidSpokeRevertsOnCredit() public {
        vm.prank(gov); hub.setBridgeEnabled(true);
        vm.prank(gov); hub.registerSpoke(1, address(0xBADA));
        vm.prank(relayer); vm.expectRevert(abi.encodeWithSignature("InvalidSpoke()"));
        hub.creditRemoteDeposit(1, address(0xDEAD), address(this), 1, 1, bytes32("n2"));
    }

    function testNonceUsedRevertsOnReplayCredit() public {
        vm.prank(gov); hub.registerSpoke(1, address(0xBADA));
        vm.prank(relayer); hub.creditRemoteDeposit(1, address(0xBADA), address(this), 1, 1, bytes32("N"));
        vm.prank(relayer); vm.expectRevert(abi.encodeWithSignature("NonceUsed()"));
        hub.creditRemoteDeposit(1, address(0xBADA), address(this), 1, 1, bytes32("N"));
    }

    function testProposeGovernorZeroAddressReverts() public {
        vm.prank(gov); vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        hub.proposeGovernor(address(0));
    }
}
