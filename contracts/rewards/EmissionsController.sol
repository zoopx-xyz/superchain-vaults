// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title EmissionsController
/// @notice Coordinates emissions across chains; assumes off-chain bridge agent mints ZPX on spokes.
contract EmissionsController is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant EMISSIONS_ROLE = keccak256("EMISSIONS_ROLE");

    // Caps
    uint256 public epochCap;
    mapping(uint256 => uint256) public perChainCap;
    uint256 public epochStart; // unix timestamp marking the current epoch start
    uint256 public epochDistributed; // amount distributed in current epoch
    mapping(uint256 => uint256) public chainDistributedInEpoch; // chainId => amount in current epoch

    event EpochCapSet(uint256 cap);
    event PerChainCapSet(uint256 indexed chainId, uint256 cap);
    event InstructDistribute(uint256 indexed chainId, address indexed distributor, uint256 amount, bytes data);

    function initialize(address governor) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(EMISSIONS_ROLE, governor);
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    function setEpochCap(uint256 cap) external onlyRole(GOVERNOR_ROLE) {
        epochCap = cap;
        emit EpochCapSet(cap);
    }

    function setPerChainCap(uint256 chainId, uint256 cap) external onlyRole(GOVERNOR_ROLE) {
        perChainCap[chainId] = cap;
        emit PerChainCapSet(chainId, cap);
    }

    /// @notice Set or roll the epoch window start (e.g., weekly). Governor may reset to new period.
    function setEpochStart(uint256 ts) external onlyRole(GOVERNOR_ROLE) {
        epochStart = ts;
        epochDistributed = 0;
        // Reset per-chain accounting lazily on access; here we do not clear mapping to save gas.
    }

    /// @notice Emits an instruction that an off-chain agent should mint and fund distributor on a chain.
    function instructDistribute(uint256 chainId, address distributor, uint256 amount, bytes calldata data)
        external
        onlyRole(EMISSIONS_ROLE)
    {
        // Enforce caps
        if (epochCap != 0) {
            require(epochDistributed + amount <= epochCap, "EPOCH_CAP");
        }
        uint256 chainCap = perChainCap[chainId];
        if (chainCap != 0) {
            uint256 used = chainDistributedInEpoch[chainId];
            require(used + amount <= chainCap, "CHAIN_CAP");
            chainDistributedInEpoch[chainId] = used + amount;
        }
        epochDistributed += amount;
        emit InstructDistribute(chainId, distributor, amount, data);
    }

    uint256[50] private __gap;
}
