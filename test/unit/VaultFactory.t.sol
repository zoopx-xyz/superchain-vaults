// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";

contract DummyVault is SpokeYieldVault {}

contract VaultFactoryTest is Test {
    VaultFactory fac;
    DummyVault impl;
    address gov = address(this);

    function setUp() public {
        fac = new VaultFactory();
        ProxyDeployer pd = new ProxyDeployer();
        fac.initialize(gov, address(new DummyVault()), address(new SuperchainERC20("TMP", "TMP")), address(pd));
    }

    function testCreateVaultAndToken() public {
        VaultFactory.CreateParams memory p = VaultFactory.CreateParams({
            asset: address(0xABCD),
            name: "vAST",
            symbol: "vAST",
            hub: address(0x1111),
            governor: gov,
            rebalancer: address(0x2222),
            adapterRegistry: address(0x3333),
            feeRecipient: address(0x4444),
            performanceFeeBps: 0,
            lst: address(0)
        });
        (address v, address t) = fac.create(p);
        assertTrue(v != address(0) && t != address(0));
        // Cover setters as part of this test (coverage runner includes this suite)
        fac.setImplementations(address(new DummyVault()), address(new SuperchainERC20("TMP2", "TMP2")));
        fac.setProxyDeployer(address(new ProxyDeployer()));
    }
}
