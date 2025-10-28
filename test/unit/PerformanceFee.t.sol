// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";
import {MockERC20Decimals} from "contracts/mocks/MockERC20Decimals.sol";
import {MockAdapter} from "contracts/mocks/MockAdapter.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

interface IERC4626Like2 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToShares(uint256 assets) external view returns (uint256);
}

contract PerformanceFeeTest is Test {
    VaultFactory factory;
    ProxyDeployer proxyDeployer;
    SpokeYieldVault impl;
    AdapterRegistry registry;
    MockERC20Decimals asset;
    address vault;
    address lst;

    address governor = address(this);
    address feeRecipient = address(0xFEE);

    MockAdapter a;

    function setUp() public {
        asset = new MockERC20Decimals("USDC", "USDC", 6);
        registry = new AdapterRegistry();
        registry.initialize(governor);
        impl = new SpokeYieldVault();
        proxyDeployer = new ProxyDeployer();
        factory = new VaultFactory();
        factory.initialize(governor, address(impl), address(0), address(proxyDeployer));

        (vault, lst) = factory.create(VaultFactory.CreateParams({
            asset: address(asset),
            name: "SYV USDC",
            symbol: "syvUSDC",
            hub: address(this),
            governor: governor,
            rebalancer: address(this),
            adapterRegistry: address(registry),
            feeRecipient: feeRecipient,
            performanceFeeBps: 1000, // 10%
            lst: address(0)
        }));

        a = new MockAdapter(address(asset));
        vm.prank(governor);
        registry.addAdapter(address(a), type(uint256).max, 1);

        // Seed vault and allocate to adapter
        asset.mint(address(this), 1_000_000_000);
        asset.approve(vault, type(uint256).max);
        IERC4626Like2(vault).deposit(1_000_000_000, address(this));
        SpokeYieldVault(vault).allocateToAdapter(address(a), 800_000_000, "");

        // Simulate rewards by transferring extra tokens to adapter
        asset.mint(address(a), 200_000_000);
    }

    function test_PerformanceFeeAccruesOnHarvest() public {
        uint256 feeRecipientSharesBefore = SpokeYieldVault(vault).balanceOf(feeRecipient);
        uint256 lstBefore = SuperchainERC20(lst).balanceOf(feeRecipient);
        // Compute expected fee shares BEFORE harvest (avoids circular supply effects after minting fee shares)
        // MockAdapter will send 10% of its balance to vault; adapter has 800+200=1,000, so 100 realized
        uint256 expectedFeeShares = IERC4626Like2(vault).convertToShares(10_000_000); // 10 USDC (6 decimals)
        // Harvest now
        vm.prank(governor);
        SpokeYieldVault(vault).harvestAdapter(address(a), "");
        uint256 feeRecipientSharesAfter = SpokeYieldVault(vault).balanceOf(feeRecipient);
        uint256 lstAfter = SuperchainERC20(lst).balanceOf(feeRecipient);
        assertEq(feeRecipientSharesAfter - feeRecipientSharesBefore, expectedFeeShares, "fee shares");
        assertEq(lstAfter - lstBefore, expectedFeeShares, "lst fee mint");
    }
}
