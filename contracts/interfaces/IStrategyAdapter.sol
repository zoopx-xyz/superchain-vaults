// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategyAdapter
/// @notice Strategy adapter interface for vault integrations.
interface IStrategyAdapter {
    /// @notice Returns the underlying asset managed by this adapter.
    function asset() external view returns (address);

    /// @notice Returns the total assets currently managed by this adapter.
    function totalAssets() external view returns (uint256);

    /// @notice Deposits assets into the underlying protocol.
    /// @param assets Amount of assets to deposit.
    /// @param data ABI-encoded adapter-specific params.
    /// @return shares Amount of adapter shares received, if any.
    function deposit(uint256 assets, bytes calldata data) external returns (uint256 shares);

    /// @notice Withdraws assets from the underlying protocol.
    /// @param assets Amount of assets to withdraw.
    /// @param data ABI-encoded adapter-specific params.
    /// @return withdrawn Amount of assets actually withdrawn.
    function withdraw(uint256 assets, bytes calldata data) external returns (uint256 withdrawn);

    /// @notice Harvests any pending rewards, performing accounting or swaps as needed.
    /// @param data ABI-encoded adapter-specific params.
    /// @return harvested Amount of assets realized from harvest.
    function harvest(bytes calldata data) external returns (uint256 harvested);
}
