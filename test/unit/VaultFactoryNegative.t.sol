// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";

contract NoopImpl { /* no functions */ }

contract VaultFactoryNegative is Test {
    VaultFactory factory; address gov=address(0xA11CE);

    function setUp() public {
        factory = new VaultFactory();
        ProxyDeployer pd = new ProxyDeployer();
        factory.initialize(gov, address(0x1), address(0x2), address(pd));
    }

    function testCreateRevertsWhenVaultInitializeMissing() public {
        NoopImpl impl = new NoopImpl();
    vm.prank(gov); factory.setImplementations(address(impl), address(0x2));
    vm.prank(gov); vm.expectRevert();
        factory.create(VaultFactory.CreateParams({
            asset: address(0xAAA),
            name: "V",
            symbol: "V",
            hub: address(0xBBB),
            governor: gov,
            rebalancer: address(0xCCC),
            adapterRegistry: address(0xDDD),
            feeRecipient: address(0xEEE),
            performanceFeeBps: 0,
            lst: address(0xF00)
        }));
    }
}
