// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

interface IAggregatorV3Like {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface ISequencerUptimeOracleLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title PriceOracleRouter
/// @notice Price router with per-asset feeds, decimals, and heartbeat staleness checks.
contract PriceOracleRouter is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    struct Feed {
        address primary; // chainlink-style aggregator
        address secondary; // optional fallback aggregator
        uint8 decimals; // feed decimals (usually 8)
        uint256 heartbeat; // max age in seconds
        uint256 maxDeviationBps; // acceptable deviation between primary/secondary
    }

    mapping(address => Feed) public feedOf;
    address public sequencerOracle; // optional sequencer uptime feed

    event FeedSet(address indexed asset, address indexed primary, address secondary, uint256 heartbeatSec, uint256 maxDeviationBps);
    event SequencerOracleSet(address indexed oracle);

    error StalePrice();
    error ZeroAddress();

    function initialize(address governor) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    function setFeed(address asset, address primary, address secondary, uint8 decimals, uint256 heartbeat, uint256 maxDeviationBps) external onlyRole(GOVERNOR_ROLE) {
        if (asset == address(0) || primary == address(0)) revert ZeroAddress();
        feedOf[asset] = Feed({primary: primary, secondary: secondary, decimals: decimals, heartbeat: heartbeat, maxDeviationBps: maxDeviationBps});
        emit FeedSet(asset, primary, secondary, heartbeat, maxDeviationBps);
    }

    function setSequencerOracle(address oracle_) external onlyRole(GOVERNOR_ROLE) {
        sequencerOracle = oracle_;
        emit SequencerOracleSet(oracle_);
    }

    function getPrice(address asset) external view returns (uint256 price, uint8 decimals, uint256 lastUpdate) {
        (price, decimals, lastUpdate) = _checkedPrice(asset);
    }

    function _checkedPrice(address asset) internal view returns (uint256 price, uint8 decimals, uint256 lastUpdate) {
        // Sequencer up check if configured (OP chains)
        if (sequencerOracle != address(0)) {
            (, int256 up,, uint256 seqUpdated,) = ISequencerUptimeOracleLike(sequencerOracle).latestRoundData();
            if (up == 0) revert StalePrice();
            if (block.timestamp - seqUpdated > 1 hours) revert StalePrice();
        }
        Feed memory f = feedOf[asset];
        (, int256 a1,, uint256 u1,) = IAggregatorV3Like(f.primary).latestRoundData();
        if (a1 <= 0) revert StalePrice();
        if (f.heartbeat != 0 && block.timestamp - u1 > f.heartbeat) revert StalePrice();
        if (f.secondary != address(0) && f.maxDeviationBps > 0) {
            (, int256 a2,, uint256 u2,) = IAggregatorV3Like(f.secondary).latestRoundData();
            if (a2 > 0 && f.heartbeat != 0 && block.timestamp - u2 <= f.heartbeat) {
                uint256 p1 = uint256(a1);
                uint256 p2 = uint256(a2);
                uint256 dev = p1 > p2 ? ((p1 - p2) * 10_000) / p2 : ((p2 - p1) * 10_000) / p1;
                if (dev > f.maxDeviationBps) revert StalePrice();
            }
        }
        return (uint256(a1), f.decimals, u1);
    }

    uint256[50] private __gap;
}
