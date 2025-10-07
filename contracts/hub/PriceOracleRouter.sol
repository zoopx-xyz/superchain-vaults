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
        int256 minAnswer; // minimum allowed answer (signed to match CL interface)
        int256 maxAnswer; // maximum allowed answer
    }

    mapping(address => Feed) public feedOf;
    address public sequencerOracle; // optional sequencer uptime feed

    event FeedSet(
        address indexed asset, address indexed primary, address secondary, uint256 heartbeatSec, uint256 maxDeviationBps
    );
    event SequencerOracleSet(address indexed oracle);
    event GovernorProposed(address indexed currentGovernor, address indexed pendingGovernor);
    event GovernorAccepted(address indexed previousGovernor, address indexed newGovernor);

    error StalePrice();
    error ZeroAddress();
    error OutOfBounds();

    address public governor;

    function initialize(address initialGovernor) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialGovernor);
        _grantRole(GOVERNOR_ROLE, initialGovernor);
        governor = initialGovernor;
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    function setFeed(
        address asset,
        address primary,
        address secondary,
        uint8 decimals,
        uint256 heartbeat,
        uint256 maxDeviationBps
    ) external onlyRole(GOVERNOR_ROLE) {
        if (asset == address(0) || primary == address(0)) revert ZeroAddress();
        feedOf[asset] = Feed({
            primary: primary,
            secondary: secondary,
            decimals: decimals,
            heartbeat: heartbeat,
            maxDeviationBps: maxDeviationBps,
            minAnswer: 0,
            maxAnswer: type(int256).max
        });
        emit FeedSet(asset, primary, secondary, heartbeat, maxDeviationBps);
    }

    function setFeedBounds(address asset, int256 minAnswer, int256 maxAnswer) external onlyRole(GOVERNOR_ROLE) {
        Feed storage f = feedOf[asset];
        if (f.primary == address(0)) revert ZeroAddress();
        f.minAnswer = minAnswer;
        f.maxAnswer = maxAnswer;
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
        bool pFresh = a1 > 0 && (f.heartbeat == 0 || block.timestamp - u1 <= f.heartbeat);
        bool pBounds = a1 >= f.minAnswer && a1 <= f.maxAnswer;
        uint256 p1u;
        if (pFresh && pBounds) {
            p1u = uint256(a1);
        }
        if (f.secondary != address(0)) {
            (, int256 a2,, uint256 u2,) = IAggregatorV3Like(f.secondary).latestRoundData();
            bool sFresh = a2 > 0 && (f.heartbeat == 0 || block.timestamp - u2 <= f.heartbeat);
            bool sBounds = a2 >= f.minAnswer && a2 <= f.maxAnswer;
            if (sFresh && sBounds) {
                if (p1u != 0) {
                    // both fresh and in-bounds: enforce deviation both directions
                    uint256 p2u = uint256(a2);
                    uint256 dev = p1u > p2u ? ((p1u - p2u) * 10_000) / p2u : ((p2u - p1u) * 10_000) / p1u;
                    if (dev > f.maxDeviationBps) revert StalePrice();
                } else {
                    // primary unusable; use secondary
                    return (uint256(a2), f.decimals, u2);
                }
            }
        }
        if (p1u == 0) revert StalePrice();
        return (p1u, f.decimals, u1);
    }

    // --- Two-step governor ---
    address public pendingGovernor;

    function proposeGovernor(address newGov) external onlyRole(GOVERNOR_ROLE) {
        if (newGov == address(0)) revert ZeroAddress();
        pendingGovernor = newGov;
        emit GovernorProposed(governor, newGov);
    }

    function acceptGovernor() external {
        require(msg.sender == pendingGovernor, "NOT_PENDING");
        address prev = governor;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNOR_ROLE, msg.sender);
        _revokeRole(GOVERNOR_ROLE, prev);
        _revokeRole(DEFAULT_ADMIN_ROLE, prev);
        governor = msg.sender;
        pendingGovernor = address(0);
        emit GovernorAccepted(prev, msg.sender);
    }

    uint256[50] private __gap;
}
