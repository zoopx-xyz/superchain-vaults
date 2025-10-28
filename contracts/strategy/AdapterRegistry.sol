// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title AdapterRegistry
/// @notice Registry for strategy adapters and caps.
contract AdapterRegistry is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    struct AdapterInfo {
        bool allowed;
        uint256 cap;
    }

    mapping(address => AdapterInfo) private _adapterInfo;

    // --- Enumeration & withdraw priority ---
    address[] private _adapters;
    mapping(address => bool) public isAdapter;
    mapping(address => uint256) public withdrawPriority;

    event AdapterUpdated(address indexed adapter, bool allowed, uint256 cap);
    event RegistryPaused(bool paused);
    event AdapterAdded(address indexed adapter, uint256 cap, uint256 priority);
    event AdapterRemoved(address indexed adapter);
    event AdapterConfigUpdated(address indexed adapter, bool allowed, uint256 cap, uint256 priority);

    /// @notice Initializer
    function initialize(address governor) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    function setAdapter(address adapter, bool allowed, uint256 cap) external onlyRole(GOVERNOR_ROLE) whenNotPaused {
        _adapterInfo[adapter] = AdapterInfo({allowed: allowed, cap: cap});
        emit AdapterUpdated(adapter, allowed, cap);
    }

    function isAllowed(address adapter) external view returns (bool) {
        return _adapterInfo[adapter].allowed;
    }

    function capOf(address adapter) external view returns (uint256) {
        return _adapterInfo[adapter].cap;
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
        emit RegistryPaused(true);
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
        emit RegistryPaused(false);
    }

    /// @notice Add an adapter to enumeration and set its cap/priority.
    /// @param adapter Adapter address.
    /// @param cap Allocation cap in underlying units.
    /// @param priority Lower values are withdrawn first.
    function addAdapter(address adapter, uint256 cap, uint256 priority) external onlyRole(GOVERNOR_ROLE) whenNotPaused {
        require(adapter != address(0), "ADAPTER_ZERO");
        if (!isAdapter[adapter]) {
            isAdapter[adapter] = true;
            _adapters.push(adapter);
        }
        _adapterInfo[adapter] = AdapterInfo({allowed: true, cap: cap});
        withdrawPriority[adapter] = priority;
        emit AdapterAdded(adapter, cap, priority);
        emit AdapterUpdated(adapter, true, cap);
    }

    /// @notice Remove an adapter from enumeration; keeps its config but marks not listed.
    function removeAdapter(address adapter) external onlyRole(GOVERNOR_ROLE) whenNotPaused {
        if (!isAdapter[adapter]) return;
        isAdapter[adapter] = false;
        // remove from array in O(n)
        uint256 len = _adapters.length;
        for (uint256 i = 0; i < len; i++) {
            if (_adapters[i] == adapter) {
                if (i != len - 1) _adapters[i] = _adapters[len - 1];
                _adapters.pop();
                break;
            }
        }
        emit AdapterRemoved(adapter);
    }

    /// @notice Set adapter config including allowed flag, cap and priority.
    function setAdapterConfig(address adapter, bool allowed, uint256 cap, uint256 priority)
        external
        onlyRole(GOVERNOR_ROLE)
        whenNotPaused
    {
        _adapterInfo[adapter] = AdapterInfo({allowed: allowed, cap: cap});
        if (!isAdapter[adapter]) {
            isAdapter[adapter] = true;
            _adapters.push(adapter);
        }
        withdrawPriority[adapter] = priority;
        emit AdapterConfigUpdated(adapter, allowed, cap, priority);
        emit AdapterUpdated(adapter, allowed, cap);
    }

    /// @notice Enumerate all listed adapters.
    function adapters() external view returns (address[] memory) {
        return _adapters;
    }

    uint256[50] private __gap;
}
