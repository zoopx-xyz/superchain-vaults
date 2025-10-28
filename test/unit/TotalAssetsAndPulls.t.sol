// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";
import {ProxyDeployer} from "contracts/proxy/ProxyDeployer.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";
import {MockERC20Decimals} from "contracts/mocks/MockERC20Decimals.sol";
import {MockAdapter} from "contracts/mocks/MockAdapter.sol";

interface IERC4626Like {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
}

contract TotalAssetsAndPullsTest is Test {
    VaultFactory factory;
    ProxyDeployer proxyDeployer;
    SpokeYieldVault impl;
    AdapterRegistry registry;
    MockERC20Decimals asset;
    address vault;
    address lst;

    address governor = address(this);
    address user = address(0xB0B);

    MockAdapter a;
    MockAdapter b;

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
            feeRecipient: address(0xFEE),
            performanceFeeBps: 1000,
            lst: address(0)
        }));

        a = new MockAdapter(address(asset));
        b = new MockAdapter(address(asset));

        vm.startPrank(governor);
        registry.addAdapter(address(a), type(uint256).max, 1); // higher priority (withdraw first)
        registry.addAdapter(address(b), type(uint256).max, 10);
        vm.stopPrank();

        // Fund user and deposit
        asset.mint(user, 1_000_000_000); // 1000 USDC (6 decimals)
        vm.startPrank(user);
        asset.approve(vault, type(uint256).max);
        IERC4626Like(vault).deposit(1_000_000_000, user);
        vm.stopPrank();

        // Allocate 600 to A, 300 to B, leaving 100 idle
        vm.prank(governor);
        SpokeYieldVault(vault).allocateToAdapter(address(a), 600_000_000, "");
        vm.prank(governor);
        SpokeYieldVault(vault).allocateToAdapter(address(b), 300_000_000, "");
    }

    function test_TotalAssetsAggregates() public {
        uint256 tvl = IERC4626Like(vault).totalAssets();
        assertEq(tvl, 1_000_000_000, "TVL mismatch");
    }

    function test_WithdrawPullsFromPriorityOrder() public {
        // user withdraws 150 -> idle 100 + pull 50 from A (priority 1)
        uint256 userBalBefore = asset.balanceOf(user);
        vm.startPrank(user);
        uint256 sharesBurned = IERC4626Like(vault).withdraw(150_000_000, user, user);
        vm.stopPrank();
        assertGt(asset.balanceOf(user) - userBalBefore, 0, "no assets out");
        // shares burned must be > 0
        assertGt(sharesBurned, 0, "no shares burned");
        // Adapter A should have decreased by ~50
        assertApproxEqAbs(a.totalAssets(), 550_000_000, 1, "A not pulled");
    }

    function test_InsufficientLiquidityQueues() public {
        // Try to withdraw more than available (tvl), should enqueue and return 0
        vm.startPrank(user);
        uint256 burned = IERC4626Like(vault).withdraw(2_000_000_000, user, user);
        vm.stopPrank();
        assertEq(burned, 0);
    }
}
