// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title BaseAdapter
/// @notice Base class for protocol adapters.
abstract contract BaseAdapter is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    /// @notice Vault that owns this adapter.
    address public vault;
    /// @notice Underlying asset managed by this adapter.
    address public underlying;
    /// @notice Allocation cap in underlying units.
    uint256 public cap;

    event AdapterDeposit(address indexed adapter, address indexed asset, uint256 assets);
    event AdapterWithdraw(address indexed adapter, address indexed asset, uint256 assetsOut);
    event AdapterHarvest(address indexed adapter, address indexed asset, uint256 harvested);
    event AdapterEmergencyWithdraw(address indexed adapter, address indexed asset, uint256 assetsOut);
    event AdapterPaused(address indexed adapter, bool paused);

    /// @notice Initializer
    function baseAdapterInit(address _vault, address _underlying, address governor) internal onlyInitializing {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        vault = _vault;
        underlying = _underlying;
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
    }

    /// @dev Error thrown when caller is not the vault.
    error OnlyVault();
    /// @dev Error thrown when withdrawal output is less than required minimum.
    error SlippageExceeded(uint256 actual, uint256 minOut);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @notice Sets the allocation cap for this adapter.
    /// @param _cap The new cap in underlying units.
    function setCap(uint256 _cap) external onlyRole(GOVERNOR_ROLE) {
        cap = _cap;
    }

    /// @notice Returns the underlying asset address.
    function asset() external view virtual returns (address) {
        return underlying;
    }

    /// @notice Returns the total assets managed by the adapter.
    function totalAssets() external view virtual returns (uint256);

    /// @notice Deposits assets into the underlying protocol.
    /// @param assets Amount of assets to deposit.
    /// @param data ABI-encoded adapter-specific parameters.
    /// @return shares Adapter share representation received, if applicable.
    function deposit(uint256 assets, bytes calldata data)
        external
        whenNotPaused
        onlyVault
        nonReentrant
        returns (uint256 shares)
    {
        shares = _deposit(assets, data);
        emit AdapterDeposit(address(this), underlying, assets);
    }

    /// @notice Withdraws assets from the underlying protocol.
    /// @param assets Amount of assets to withdraw.
    /// @param data ABI-encoded adapter-specific parameters.
    /// @return withdrawn Amount of assets returned to the vault.
    function withdraw(uint256 assets, bytes calldata data)
        external
        whenNotPaused
        onlyVault
        nonReentrant
        returns (uint256 withdrawn)
    {
        withdrawn = _withdraw(assets, data);
        emit AdapterWithdraw(address(this), underlying, withdrawn);
    }

    /// @notice Harvests rewards or realizes PnL for the position.
    /// @param data ABI-encoded adapter-specific parameters.
    /// @return harvested Amount of underlying realized.
    function harvest(bytes calldata data) external whenNotPaused onlyVault nonReentrant returns (uint256 harvested) {
        harvested = _harvest(data);
        emit AdapterHarvest(address(this), underlying, harvested);
    }

    /// @dev Internal hook to implement protocol deposit.
    function _deposit(uint256 assets, bytes calldata data) internal virtual returns (uint256 shares);
    /// @dev Internal hook to implement protocol withdraw.
    function _withdraw(uint256 assets, bytes calldata data) internal virtual returns (uint256 withdrawn);
    /// @dev Internal hook to implement protocol harvest.
    function _harvest(bytes calldata data) internal virtual returns (uint256 harvested);

    /// @notice Emergency withdraw of underlying to vault.
    function emergencyWithdraw(uint256 amount) external onlyRole(GOVERNOR_ROLE) whenPaused {
        uint256 bal = IERC20(underlying).balanceOf(address(this));
        if (amount > bal) amount = bal;
        IERC20(underlying).safeTransfer(vault, amount);
        emit AdapterEmergencyWithdraw(address(this), underlying, amount);
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
        emit AdapterPaused(address(this), true);
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
        emit AdapterPaused(address(this), false);
    }

    uint256[50] private __gap;
}
