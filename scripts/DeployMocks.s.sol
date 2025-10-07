// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {MockERC20Decimals} from "contracts/mocks/MockERC20Decimals.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";

contract DeployMocks is Script {
    /// @notice Deploys three mock tokens used for demos: tUSDC (6d), tWETH (18d) and tZPX (mintable L2-like)
    /// Usage: set PRIVATE_KEY env and run via `forge script` with rpc-url and --broadcast.
    function run() external returns (address, address, address) {
        uint256 deployer = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployer);

        MockERC20Decimals usdc = new MockERC20Decimals("Test USDC", "tUSDC", 6);
        MockERC20Decimals weth = new MockERC20Decimals("Test WETH", "tWETH", 18);
        SuperchainERC20 zpx = new SuperchainERC20("Test ZPX", "tZPX");

        vm.stopBroadcast();

        console.log("Deployed Test USDC at:", address(usdc));
        console.log("Deployed Test WETH at:", address(weth));
        console.log("Deployed Test ZPX at:", address(zpx));

        return (address(usdc), address(weth), address(zpx));
    }
}
