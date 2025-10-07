// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAdapter} from "./BaseAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AaveV3Adapter (MockOnly)
/// @notice MockOnly — NOT for production deployments.
/// Treats idle balance as managed assets. This is NOT a real Aave integration and must remain disabled in prod.
contract AaveV3Adapter is BaseAdapter {
    using SafeERC20 for IERC20;

    function initialize(address _vault, address _underlying, address governor) external initializer {
        if (_vault == address(0) || _underlying == address(0) || governor == address(0)) revert("ZERO_ADDR");
        baseAdapterInit(_vault, _underlying, governor);
    }

    function totalAssets() external view override returns (uint256) {
        // Minimal implementation: treat idle underlying held by this adapter as managed assets.
        return IERC20(underlying).balanceOf(address(this));
    }

    function _deposit(uint256 assets, bytes calldata /*data*/ ) internal pure override returns (uint256 shares) {
        // Minimal no-op: underlying is already held by adapter from the vault transfer allowance.
        // Real implementation would supply to Aave.
        return assets;
    }

    function _withdraw(uint256 assets, bytes calldata data) internal override returns (uint256 withdrawn) {
        uint256 minOut = 0;
        if (data.length >= 32) {
            minOut = abi.decode(data, (uint256));
        }
        // Transfer underlying back to the vault
        IERC20(underlying).safeTransfer(vault, assets);
        withdrawn = assets;
        if (withdrawn < minOut) revert SlippageExceeded(withdrawn, minOut);
    }

    function _harvest(bytes calldata /*data*/ ) internal pure override returns (uint256 harvested) {
        // No rewards in minimal implementation
        return 0;
    }
}
