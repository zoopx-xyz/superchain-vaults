// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracleRouter
/// @notice Price oracle router interface.
interface IPriceOracleRouter {
    /// @notice Returns the latest price for an asset.
    /// @param asset The asset address.
    /// @return price The price value.
    /// @return decimals The decimals of the price feed.
    /// @return lastUpdate The timestamp of the last update.
    function getPrice(address asset) external view returns (uint256 price, uint8 decimals, uint256 lastUpdate);
}
