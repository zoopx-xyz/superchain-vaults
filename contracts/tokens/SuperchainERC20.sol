// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title SuperchainERC20
/// @notice Non-upgradeable ERC20 with AccessControl mint/burn via MINTER_ROLE.
contract SuperchainERC20 is ERC20, ERC20Permit, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    event MinterSet(address indexed vault, bool enabled);

    /// @notice Constructs the token.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC20Permit(name_) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Grants MINTER_ROLE and emits MinterSet for indexers.
    function grantMinter(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, vault);
        emit MinterSet(vault, true);
    }

    /// @notice Revokes MINTER_ROLE and emits MinterSet for indexers.
    function revokeMinter(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, vault);
        emit MinterSet(vault, false);
    }

    /// @notice Mints tokens to an account. Only MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burns tokens from an account. Only MINTER_ROLE (vault controls burns upon redeem).
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
}
