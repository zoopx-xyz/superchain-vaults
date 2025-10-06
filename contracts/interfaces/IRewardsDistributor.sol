// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRewardsDistributor
/// @notice Per-chain rewards distributor interface.
interface IRewardsDistributor {
    function addRewards(uint256 amount) external;
    function checkpoint(address user) external;
    function claim(address to) external returns (uint256 amount);
}
