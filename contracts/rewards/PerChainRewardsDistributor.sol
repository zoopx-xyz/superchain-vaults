// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PerChainRewardsDistributor
/// @notice Streams rewards to vault share holders on a per-chain basis.
contract PerChainRewardsDistributor is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");

    IERC20 public rewardToken; // ZPX on this chain
    IERC20 public shareToken; // LST on this chain for accounting

    // Accumulator state
    uint256 public rewardPerShareX18;
    mapping(address => uint256) public userRpsPaid;
    mapping(address => uint256) public accrued;

    event RewardsAdded(uint256 amount, uint256 newRps);
    event Checkpoint(address indexed user, uint256 accruedDelta, uint256 newPaid);
    event Claimed(address indexed user, address indexed to, uint256 amount);

    function initialize(address token, address lstToken, address governor) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        rewardToken = IERC20(token);
        shareToken = IERC20(lstToken);
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(FUNDER_ROLE, governor);
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    function addRewards(uint256 amount) external onlyRole(FUNDER_ROLE) whenNotPaused {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 totalShares = shareToken.totalSupply();
        if (totalShares > 0 && amount > 0) {
            uint256 delta = (amount * 1e18) / totalShares;
            rewardPerShareX18 += delta;
        }
        emit RewardsAdded(amount, rewardPerShareX18);
    }

    function checkpoint(address user) public whenNotPaused {
        uint256 paid = userRpsPaid[user];
        uint256 rps = rewardPerShareX18;
        if (rps > paid) {
            uint256 userShares = shareToken.balanceOf(user);
            uint256 delta = ((rps - paid) * userShares) / 1e18;
            accrued[user] += delta;
            userRpsPaid[user] = rps;
            emit Checkpoint(user, delta, rps);
        }
    }

    function claim(address to) external whenNotPaused returns (uint256 amount) {
        checkpoint(msg.sender);
        amount = accrued[msg.sender];
        accrued[msg.sender] = 0;
        rewardToken.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    uint256[50] private __gap;
}
