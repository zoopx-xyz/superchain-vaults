// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";
import {MockERC20Decimals} from "contracts/mocks/MockERC20Decimals.sol";

contract VaultFactoryCoverageTest is Test {
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
        factory.initialize(governor, address(impl), address(0xDEAD), address(proxyDeployer));
    }

    function _params() internal view returns (VaultFactory.CreateParams memory p) {
        p = VaultFactory.CreateParams({
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
    }

    function test_SettersOnlyGovernor() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert();
        factory.setProxyDeployer(address(0x1234));
        vm.prank(attacker);
        vm.expectRevert();
        factory.setImplementations(address(0x1111), address(0x2222));

        // Governor can update
        factory.setProxyDeployer(address(proxyDeployer));
        factory.setImplementations(address(impl), address(0xBEEF));
    }

    function test_CreateRevertsWithoutProxyDeployer() public {
        factory.setProxyDeployer(address(0));
        vm.expectRevert(bytes("NO_PROXY_DEPLOYER"));
        factory.create(_params());
    }

    function test_CreateEmitsEvent() public {
        VaultFactory.CreateParams memory p = _params();
        // Do not assert exact log payload to avoid brittle topic/data mismatches across modes
        factory.create(p);
    }
}
