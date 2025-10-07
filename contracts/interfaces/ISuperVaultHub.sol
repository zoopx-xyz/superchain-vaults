// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISuperVaultHub
/// @notice Canonical meta-accounting & coordination hub interface.
interface ISuperVaultHub {
    function registerSpoke(uint256 chainId, address spoke) external;
    function creditRemoteDeposit(
        uint256 srcChainId,
        address srcSpoke,
        address user,
        uint256 assets,
        uint256 shares,
        bytes32 nonce
    ) external;
    function requestRemoteWithdrawal(uint256 dstChainId, address user, uint256 assets) external;
    function requestRebalance(uint256 fromChain, uint256 toChain, uint256 assets, bytes calldata data) external;
}
