// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";

/// @notice Simple test adapter that just holds the asset and returns on withdraw; supports optional harvest rewards.
contract MockAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public immutable override asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(uint256 assets, bytes calldata) external override returns (uint256 shares) {
        // Assume assets have already been transferred to this adapter by the vault
        // Just acknowledge the deposit and return 1:1 shares for simplicity
        uint256 bal = IERC20(asset).balanceOf(address(this));
        require(bal >= assets, "ADAPTER_DEPOSIT_FAIL");
        return assets; // 1:1 shares mapping for simplicity
    }

    function withdraw(uint256 assets, bytes calldata data) external override returns (uint256 withdrawn) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) return 0;
        uint256 minOut = 0;
        if (data.length >= 32) {
            minOut = abi.decode(data, (uint256));
        }
        withdrawn = assets > bal ? bal : assets;
        require(withdrawn >= minOut, "SLIPPAGE");
        IERC20(asset).safeTransfer(msg.sender, withdrawn);
    }

    function harvest(bytes calldata) external override returns (uint256 harvested) {
        // If adapter holds extra tokens, send them to caller (vault) as "harvested"
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) return 0;
        // keep a tiny dust to avoid edge cases
        harvested = bal / 10; // realize 10% as rewards for tests
        if (harvested > 0) {
            IERC20(asset).safeTransfer(msg.sender, harvested);
        }
    }
}
