// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IL2ToL2CrossDomainMessenger} from "../interfaces/IL2ToL2CrossDomainMessenger.sol";

/// @title SuperchainAdapter
/// @notice Wrapper over IL2ToL2CrossDomainMessenger for Hub↔Spoke messages.
/// @dev All privileged operations should be routed through a TimelockController (off-chain configured).
contract SuperchainAdapter is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    // --- Roles ---
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // --- Feature flags ---
    bool public bridgeEnabled;

    // --- Storage ---
    mapping(bytes32 => uint256) public nonceOf; // channel => next nonce
    mapping(bytes32 => bool) private _consumed; // acceptance replay guard
    mapping(uint256 => address) public allowedSender; // chainId => sender
    mapping(bytes4 => bool) public allowedSelector; // selector => allowed

    // --- External dependencies ---
    IL2ToL2CrossDomainMessenger public messenger;

    // --- Events ---
    event MessageSent(
        uint256 indexed srcChainId,
        address indexed src,
        uint256 indexed dstChainId,
        address dst,
        bytes4 selector,
        bytes data,
        uint256 nonce,
        bytes32 actionId
    );
    event SenderAllowed(uint256 indexed chainId, address indexed sender, bool allowed);
    event SelectorAllowed(bytes4 indexed selector, bool allowed);
    event MessageAccepted(
        uint256 indexed srcChainId, address indexed src, bytes4 selector, uint256 nonce, bytes32 actionId
    );
    event BridgeFlagUpdated(bool enabled);

    // --- Errors ---
    error NotAllowedSender();
    error NotAllowedSelector();
    error Replay();
    error BridgeDisabled();

    /// @notice Initializer
    /// @param _messenger L2 to L2 messenger address
    /// @param governor Governor address
    function initialize(address _messenger, address governor) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        messenger = IL2ToL2CrossDomainMessenger(_messenger);
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        bridgeEnabled = true;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    /// @notice Set whether bridge operations are enabled.
    function setBridgeEnabled(bool enabled) external onlyRole(GOVERNOR_ROLE) {
        bridgeEnabled = enabled;
        emit BridgeFlagUpdated(enabled);
    }

    /// @notice Allow or disallow a source sender for a chain.
    function setAllowedSender(uint256 chainId, address sender, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        allowedSender[chainId] = allowed ? sender : address(0);
        emit SenderAllowed(chainId, sender, allowed);
    }

    /// @notice Allow or disallow a function selector for inbound messages.
    function setAllowedSelector(bytes4 selector, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        allowedSelector[selector] = allowed;
        emit SelectorAllowed(selector, allowed);
    }

    /// @notice Send a cross-chain message.
    /// @param dstChainId Destination chain id.
    /// @param dst Destination contract address on dst chain.
    /// @param data Calldata to forward to destination.
    function send(uint256 dstChainId, address dst, bytes calldata data)
        external
        onlyRole(GOVERNOR_ROLE)
        whenNotPaused
    {
        if (!bridgeEnabled) revert BridgeDisabled();
        // Extract selector from bytes calldata payload
        if (data.length < 4) revert NotAllowedSelector();
        bytes4 selector;
        assembly {
            selector := calldataload(data.offset)
        }
        if (!allowedSelector[selector]) revert NotAllowedSelector();
        bytes32 channel = keccak256(abi.encodePacked(uint256(block.chainid), address(this), dstChainId, dst));
        uint256 nonce = nonceOf[channel];
        unchecked {
            // Safe: monotonic increment bounded by uint256
            nonceOf[channel] = nonce + 1;
        }
        messenger.sendMessage(dst, abi.encodePacked(data, bytes32(nonce)));
        bytes32 actionId = keccak256(
            abi.encode(
                "Message",
                uint256(1),
                block.chainid,
                address(this),
                dstChainId,
                dst,
                msg.sender,
                address(0),
                uint256(0),
                nonce
            )
        );
        emit MessageSent(block.chainid, address(this), dstChainId, dst, selector, data, nonce, actionId);
    }

    /// @notice Accept an incoming message prior to executing state changes on the receiver.
    /// @dev Receivers MUST call this function before mutating state in response to a cross-chain message.
    function acceptIncoming(uint256 srcChainId, address src, bytes4 selector, uint256 nonce, bytes32 actionId)
        external
        onlyRole(RELAYER_ROLE)
        whenNotPaused
    {
        if (!bridgeEnabled) revert BridgeDisabled();
        if (allowedSender[srcChainId] != src) revert NotAllowedSender();
        if (!allowedSelector[selector]) revert NotAllowedSelector();
        bytes32 key = keccak256(abi.encode(srcChainId, src, selector, nonce));
        if (_consumed[key]) revert Replay();
        _consumed[key] = true;
        emit MessageAccepted(srcChainId, src, selector, nonce, actionId);
    }

    /// @notice Authorize incoming message. Used by hubs/spokes to pre-check relayed calls.
    /// @param srcChainId Source chain id.
    /// @param src Source contract on source chain.
    /// @param selector Function selector of the target call.
    /// @return ok True if authorized.
    function authIncoming(uint256 srcChainId, address src, bytes4 selector, bytes32 msgNonce)
        external
        view
        returns (bool ok)
    {
        if (allowedSender[srcChainId] != src) revert NotAllowedSender();
        if (!allowedSelector[selector]) revert NotAllowedSelector();
        // Note: view function cannot emit; acceptance should be emitted by the caller using the same actionId derivation.
        msgNonce; // silence
        return true;
    }

    uint256[50] private __gap;
}
