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

    mapping(address => AdapterInfo) private adapters;

    event AdapterUpdated(address indexed adapter, bool allowed, uint256 cap);
    event RegistryPaused(bool paused);

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
        adapters[adapter] = AdapterInfo({allowed: allowed, cap: cap});
        emit AdapterUpdated(adapter, allowed, cap);
    }

    function isAllowed(address adapter) external view returns (bool) {
        return adapters[adapter].allowed;
    }

    function capOf(address adapter) external view returns (uint256) {
        return adapters[adapter].cap;
    }

    function pause() external onlyRole(GOVERNOR_ROLE) { _pause(); emit RegistryPaused(true); }

    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); emit RegistryPaused(false); }

    uint256[50] private __gap;
}
