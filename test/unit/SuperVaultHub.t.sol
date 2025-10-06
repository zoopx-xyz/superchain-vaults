// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SuperVaultHub} from "../../contracts/hub/SuperVaultHub.sol";

contract SuperVaultHubTest is Test {
    SuperVaultHub hub;
    address gov = address(0x1);
    address relayer = address(0x2);

    function setUp() public {
        hub = new SuperVaultHub();
        vm.prank(gov);
        hub.initialize(address(0xdead), address(0xbeef), gov, relayer);
    }

    function testRegisterSpokeAndCredit() public {
        uint256 chainId = 10;
        address spoke = address(0x99);
        vm.prank(gov);
        hub.registerSpoke(chainId, spoke);
        assertEq(hub.getSpoke(chainId), spoke);

        bytes32 nonce = keccak256("n");
        vm.prank(relayer);
        hub.creditRemoteDeposit(chainId, spoke, address(0x123), 100, 100, nonce);
        assertTrue(hub.isNonceUsed(nonce));
        assertEq(hub.totalAssetsCanonical(), 100);

        vm.prank(relayer);
        vm.expectRevert(SuperVaultHub.NonceUsed.selector);
        hub.creditRemoteDeposit(chainId, spoke, address(0x123), 100, 100, nonce);
    }
}
