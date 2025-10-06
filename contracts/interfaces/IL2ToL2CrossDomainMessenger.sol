// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IL2ToL2CrossDomainMessenger
/// @notice Minimal interface for an L2-to-L2 cross-domain messenger.
interface IL2ToL2CrossDomainMessenger {
    /// @notice Sends a message to a target contract on a remote chain.
    /// @param target The address of the target contract on the destination chain.
    /// @param message The calldata to be executed on the target.
    function sendMessage(address target, bytes calldata message) external;
}
