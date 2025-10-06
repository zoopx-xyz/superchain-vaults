// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseAdapter} from "./BaseAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VelodromeLPAdapter
/// @notice Minimal adapter for Velodrome LP; currently treats idle balance as managed assets and records cooldown.
contract VelodromeLPAdapter is BaseAdapter {
    using SafeERC20 for IERC20;
    uint64 public lastAddTimestamp;
    uint64 public cooldown; // seconds between deposits and withdrawals to reduce MEV games

    function initialize(address _vault, address _underlying, address governor) external initializer {
        if (_vault == address(0) || _underlying == address(0) || governor == address(0)) revert("ZERO_ADDR");
        __BaseAdapter_init(_vault, _underlying, governor);
    }

    function totalAssets() external view override returns (uint256) {
        // Minimal implementation: treat idle underlying as managed assets.
        return IERC20(underlying).balanceOf(address(this));
    }

    function _deposit(uint256 assets, bytes calldata /*data*/ ) internal override returns (uint256 shares) {
        lastAddTimestamp = uint64(block.timestamp);
        return assets;
    }

    function _withdraw(uint256 assets, bytes calldata data) internal override returns (uint256 withdrawn) {
        // Basic cooldown to prevent immediate LP in/out sandwiching
        require(block.timestamp >= lastAddTimestamp + cooldown, "COOLDOWN");
        uint256 minOut = 0;
        if (data.length >= 32) {
            minOut = abi.decode(data, (uint256));
        }
        IERC20(underlying).safeTransfer(vault, assets);
        withdrawn = assets;
        if (withdrawn < minOut) revert SlippageExceeded(withdrawn, minOut);
    }

    function _harvest(bytes calldata /*data*/ ) internal override returns (uint256 harvested) {
        return 0;
    }

    function setCooldown(uint64 seconds_) external onlyRole(GOVERNOR_ROLE) {
        cooldown = seconds_;
    }
}
