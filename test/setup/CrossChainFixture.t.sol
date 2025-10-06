// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockL2ToL2Messenger} from "../../contracts/mocks/MockL2ToL2Messenger.sol";
import {MockBridge} from "../../contracts/mocks/MockBridge.sol";
import {ControllerHub} from "../../contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "../../contracts/hub/PriceOracleRouter.sol";
import {SuperVaultHub} from "../../contracts/hub/SuperVaultHub.sol";
import {SuperchainAdapter} from "../../contracts/messaging/SuperchainAdapter.sol";
import {SpokeYieldVault} from "../../contracts/spoke/SpokeYieldVault.sol";
import {AdapterRegistry} from "../../contracts/strategy/AdapterRegistry.sol";
import {AaveV3Adapter} from "../../contracts/strategy/AaveV3Adapter.sol";
import {VelodromeLPAdapter} from "../../contracts/strategy/VelodromeLPAdapter.sol";
import {SuperchainERC20} from "../../contracts/tokens/SuperchainERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20Decimals} from "../../contracts/mocks/MockERC20Decimals.sol";

contract CrossChainFixture is Test {
    // Mocks
    MockL2ToL2Messenger public messenger;
    MockBridge public bridge;

    // Core
    SuperVaultHub public hub;
    ControllerHub public controller;
    PriceOracleRouter public oracle;
    SuperchainAdapter public adapter;

    // Spokes
    SpokeYieldVault public spokeA;
    SpokeYieldVault public spokeB;
    SpokeYieldVault public spokeC;

    // LSTs and assets (mocked as ERC20 balances tracked by vm)
    SuperchainERC20 public lstA;
    SuperchainERC20 public lstB;
    SuperchainERC20 public lstC;

    IERC20 public asset; // base asset from SuperVaultHub

    address public governor = address(0xBEEF);
    address public relayer = address(0xC0FFEE);

    uint256 public constant A_CHAIN = 1000;
    uint256 public constant B_CHAIN = 2000;
    uint256 public constant C_CHAIN = 3000;

    function setUp() public virtual {
        vm.warp(1_000_000);
        vm.roll(1_000);
        messenger = new MockL2ToL2Messenger();
        bridge = new MockBridge();
        oracle = new PriceOracleRouter();
        oracle.initialize(governor);
        controller = new ControllerHub();
        controller.initialize(governor, address(oracle));
        adapter = new SuperchainAdapter();
        adapter.initialize(address(messenger), governor);
    // Deploy base asset as a proper ERC20 with 6 decimals (USDC-like)
    MockERC20Decimals base = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
    asset = IERC20(address(base));

        // Deploy LSTs
    lstA = new SuperchainERC20("LSTA", "LSTA");
    lstB = new SuperchainERC20("LSTB", "LSTB");
    lstC = new SuperchainERC20("LSTC", "LSTC");

        // Adapter registry
        AdapterRegistry reg = new AdapterRegistry();
        reg.initialize(governor);

    // Spokes
        spokeA = new SpokeYieldVault();
        spokeB = new SpokeYieldVault();
        spokeC = new SpokeYieldVault();
        spokeA.initialize(asset, "VA", "VA", address(hub), governor, governor, address(reg), governor, 0, address(lstA));
        spokeB.initialize(asset, "VB", "VB", address(hub), governor, governor, address(reg), governor, 0, address(lstB));
        spokeC.initialize(asset, "VC", "VC", address(hub), governor, governor, address(reg), governor, 0, address(lstC));
    // Grant minter to spokes
    lstA.grantMinter(address(spokeA));
    lstB.grantMinter(address(spokeB));
    lstC.grantMinter(address(spokeC));
        // setup flags
        vm.prank(governor);
        spokeA.setWithdrawalBufferBps(2000);
        vm.prank(governor);
        spokeB.setWithdrawalBufferBps(2000);
        vm.prank(governor);
        spokeC.setWithdrawalBufferBps(2000);

        // Hub
        hub = new SuperVaultHub();
        hub.initialize(address(asset), address(adapter), governor, relayer);
        vm.prank(governor);
        hub.registerSpoke(A_CHAIN, address(spokeA));
        vm.prank(governor);
        hub.registerSpoke(B_CHAIN, address(spokeB));
        vm.prank(governor);
        hub.registerSpoke(C_CHAIN, address(spokeC));

    // Roles: grant hub role to hub for each spoke, and controller role
    bytes32 HUB_ROLE_ID = spokeA.HUB_ROLE();
    bytes32 CONTROLLER_ROLE_ID = spokeA.CONTROLLER_ROLE();
    vm.startPrank(governor);
    spokeA.grantRole(HUB_ROLE_ID, address(hub));
    spokeB.grantRole(HUB_ROLE_ID, address(hub));
    spokeC.grantRole(HUB_ROLE_ID, address(hub));
    spokeA.grantRole(CONTROLLER_ROLE_ID, address(controller));
    spokeB.grantRole(CONTROLLER_ROLE_ID, address(controller));
    spokeC.grantRole(CONTROLLER_ROLE_ID, address(controller));
    vm.stopPrank();

        // Seed balances
        deal(address(asset), address(spokeA), 5_000_000e6, true);
        deal(address(asset), address(spokeB), 5_000_000e6, true);
        deal(address(asset), address(spokeC), 5_000_000e6, true);
    }
}
