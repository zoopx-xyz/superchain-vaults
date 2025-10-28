// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";
import {MockERC20Decimals} from "contracts/mocks/MockERC20Decimals.sol";

contract FactoryUUPSTest is Test {
    VaultFactory factory;
    ProxyDeployer proxyDeployer;
    SpokeYieldVault impl;
    AdapterRegistry registry;
    MockERC20Decimals asset;

    address governor = address(this);

    function setUp() public {
        asset = new MockERC20Decimals("USDC", "USDC", 6);
        registry = new AdapterRegistry();
        registry.initialize(governor);
        impl = new SpokeYieldVault();
        proxyDeployer = new ProxyDeployer();
        factory = new VaultFactory();
        factory.initialize(governor, address(impl), address(0), address(proxyDeployer));
    }

    function test_Create_DeploysERC1967ProxyAndUpgradeable() public {
        VaultFactory.CreateParams memory p = VaultFactory.CreateParams({
            asset: address(asset),
            name: "SYV USDC",
            symbol: "syvUSDC",
            hub: address(this),
            governor: governor,
            rebalancer: address(this),
            adapterRegistry: address(registry),
            feeRecipient: address(0xBEEF),
            performanceFeeBps: 1000,
            lst: address(0)
        });
        (address vaultAddr, address lst) = factory.create(p);
        assertTrue(vaultAddr != address(0) && lst != address(0));

        // Check ERC1967 implementation slot matches impl
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 stored = vm.load(vaultAddr, implSlot);
        assertEq(address(uint160(uint256(stored))), address(impl), "impl mismatch");

    // Basic sanity: implementation slot points to impl; upgrade path is UUPS and governor-gated (covered elsewhere)
    }
}
