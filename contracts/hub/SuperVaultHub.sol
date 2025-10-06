// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title SuperVaultHub
/// @notice Canonical meta-accounting & coordination for Superchain vaults.
/// @dev All privileged operations should be routed through a TimelockController (off-chain configured).
contract SuperVaultHub is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    // --- Roles ---
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    // --- Feature flags ---
    bool public bridgeEnabled;

    // --- Storage ---
    mapping(uint256 => address) public spokeOf; // chainId => spoke
    mapping(bytes32 => bool) public usedNonce; // replay guard
    uint256 public totalAssetsCanonical;
    address public baseAsset;
    address public adapter; // SuperchainAdapter

    // --- Events ---
    event SpokeRegistered(uint256 indexed chainId, address indexed spoke);
    event RemoteDepositCredited(uint256 indexed srcChainId, address indexed spoke, address indexed user, address asset, uint256 assets, uint256 shares, uint256 nonce, bytes32 actionId);
    event RemoteWithdrawalRequested(uint256 indexed dstChainId, address indexed spoke, address indexed user, address asset, uint256 assets, bytes32 actionId);
    event RebalanceRequested(uint256 indexed fromChainId, uint256 indexed toChainId, address asset, uint256 assets, bytes data, bytes32 actionId);
    event ControllerCalled(bytes data);
    event BridgePaused(bool paused);
    event BaseAssetSet(address indexed asset);

    // --- Errors ---
    error BridgeDisabled();
    error InvalidSpoke();
    error NonceUsed();
    error ZeroAddress();

    /// @notice Initializer
    function initialize(address _baseAsset, address _adapter, address governor, address relayer) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        if (_baseAsset == address(0) || _adapter == address(0) || governor == address(0) || relayer == address(0)) revert ZeroAddress();
        baseAsset = _baseAsset;
        adapter = _adapter;
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(RELAYER_ROLE, relayer);
        bridgeEnabled = true;
        emit BaseAssetSet(_baseAsset);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    /// @notice Enable/disable bridge operations.
    function setBridgeEnabled(bool enabled) external onlyRole(GOVERNOR_ROLE) {
        bridgeEnabled = enabled;
        emit BridgePaused(!enabled);
    }

    /// @notice Registers a spoke vault address for a given chainId.
    function registerSpoke(uint256 chainId, address spoke) external onlyRole(GOVERNOR_ROLE) {
        if (spoke == address(0)) revert ZeroAddress();
        spokeOf[chainId] = spoke;
        emit SpokeRegistered(chainId, spoke);
    }

    /// @notice Credits a remote deposit, idempotent via nonce.
    function creditRemoteDeposit(
        uint256 srcChainId,
        address srcSpoke,
        address user,
        uint256 assets,
        uint256 shares,
        bytes32 nonce
    ) external onlyRole(RELAYER_ROLE) whenNotPaused {
        if (!bridgeEnabled) revert BridgeDisabled();
        if (spokeOf[srcChainId] != srcSpoke) revert InvalidSpoke();
        if (usedNonce[nonce]) revert NonceUsed();
        usedNonce[nonce] = true;
    // Update canonical accounting (example implementation)
        unchecked {
            totalAssetsCanonical += assets;
        }
    bytes32 actionId = keccak256(abi.encode("RemoteDeposit", uint256(1), srcChainId, srcSpoke, block.chainid, address(this), user, baseAsset, assets, uint256(nonce)));
    emit RemoteDepositCredited(srcChainId, srcSpoke, user, baseAsset, assets, shares, uint256(nonce), actionId);
    }

    /// @notice Requests a remote withdrawal on destination chain.
    function requestRemoteWithdrawal(uint256 dstChainId, address user, uint256 assets) external onlyRole(RELAYER_ROLE) whenNotPaused {
        if (!bridgeEnabled) revert BridgeDisabled();
        bytes32 actionId = keccak256(abi.encode("RemoteWithdrawal", uint256(1), block.chainid, address(this), dstChainId, spokeOf[dstChainId], user, baseAsset, assets, uint256(block.number)));
        emit RemoteWithdrawalRequested(dstChainId, spokeOf[dstChainId], user, baseAsset, assets, actionId);
    }

    /// @notice Requests a rebalance between chains.
    function requestRebalance(uint256 fromChain, uint256 toChain, uint256 assets, bytes calldata data) external onlyRole(GOVERNOR_ROLE) whenNotPaused {
        bytes32 actionId = keccak256(abi.encode("Rebalance", uint256(1), fromChain, spokeOf[fromChain], toChain, spokeOf[toChain], address(this), baseAsset, assets, uint256(block.number)));
        emit RebalanceRequested(fromChain, toChain, baseAsset, assets, data, actionId);
    }

    /// @notice Reserved controller hook; currently no-op.
    function controllerCall(bytes calldata data) external onlyRole(CONTROLLER_ROLE) {
        emit ControllerCalled(data);
    }

    // --- View checkers for invariants ---
    /// @notice Returns whether a nonce has been used.
    function isNonceUsed(bytes32 nonce) external view returns (bool) {
        return usedNonce[nonce];
    }

    /// @notice Returns the registered spoke for a chain.
    function getSpoke(uint256 chainId) external view returns (address) {
        return spokeOf[chainId];
    }

    uint256[50] private __gap;
}
