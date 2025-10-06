// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IControllerHub
/// @notice Lending & borrowing controller hub interface.
interface IControllerHub {
    // Market admin
    function listMarket(address asset, bytes calldata params) external;
    function setParams(address asset, bytes calldata params) external;

    // Collateral
    function enterMarket(address lst) external;
    function exitMarket(address lst) external;

    // Accrual
    function accrue(address asset) external;

    // Borrow/Repay
    function borrow(address asset, uint256 amount, uint256 dstChainId) external;
    function repay(address asset, uint256 amount, uint256 srcChainId) external;

    // Liquidation
    function liquidate(address user, address repayAsset, uint256 repayAmount, address seizeLst, address to) external;
}
