// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";

contract DummyVault {
    event Inited(address asset, string name, string symbol, address hub, address governor, address rebalancer, address adapterRegistry, address feeRecipient, uint16 perfFeeBps, address lst);
    function initialize(address asset, string memory name, string memory symbol, address hub, address governor, address rebalancer, address adapterRegistry, address feeRecipient, uint16 perfFeeBps, address lst) external {
        emit Inited(asset, name, symbol, hub, governor, rebalancer, adapterRegistry, feeRecipient, perfFeeBps, lst);
    }
}

contract VaultFactoryBranchesTest is Test {
    VaultFactory factory;
    address gov = address(0xA11CE);

    function setUp() public {
        factory = new VaultFactory();
        ProxyDeployer pd = new ProxyDeployer();
        factory.initialize(gov, address(new DummyVault()), address(0), address(pd));
    }

    function testSetImplementationsAndCreate() public {
        address vimpl = address(new DummyVault());
        vm.prank(gov);
        factory.setImplementations(vimpl, address(0));
        VaultFactory.CreateParams memory p = VaultFactory.CreateParams({
            asset: address(0xA),
            name: "LST",
            symbol: "LST",
            hub: address(0xB),
            governor: gov,
            rebalancer: address(0xC),
            adapterRegistry: address(0xD),
            feeRecipient: address(0xE),
            performanceFeeBps: 0,
            lst: address(0)
        });
        vm.prank(gov);
        (address v, address t) = factory.create(p);
        assertTrue(v != address(0));
        assertTrue(t != address(0));
    }
}
