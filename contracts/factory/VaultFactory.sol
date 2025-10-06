// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SuperchainERC20} from "../tokens/SuperchainERC20.sol";

/// @title VaultFactory
/// @notice Deploys SpokeYieldVaults and their LST ERC20 via minimal proxies.
contract VaultFactory is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    using Clones for address;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    address public vaultImpl;
    address public tokenImpl;

    event VaultCreated(address indexed vault, address indexed lst, address asset, string name, string symbol);

    function initialize(address governor, address _vaultImpl, address _tokenImpl) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        vaultImpl = _vaultImpl;
        tokenImpl = _tokenImpl;
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    function setImplementations(address _vaultImpl, address _tokenImpl) external onlyRole(GOVERNOR_ROLE) {
        vaultImpl = _vaultImpl;
        tokenImpl = _tokenImpl;
    }

    struct CreateParams { address asset; string name; string symbol; address hub; address governor; address rebalancer; address adapterRegistry; address feeRecipient; uint16 performanceFeeBps; address lst; }

    /// @notice Creates a new vault and its LST token via minimal proxies.
    function create(CreateParams memory p) external onlyRole(GOVERNOR_ROLE) returns (address vault, address lst) {
        address v = vaultImpl.clone();
        address t = address(new SuperchainERC20(p.name, p.symbol));
        // grant MINTER_ROLE to vault after initialize; interface IDs known
        // Initialize vault via UUPS initializer selector: see vault signature
        (bool ok,) = v.call(abi.encodeWithSignature(
            "initialize(address,string,string,address,address,address,address,address,uint16,address)",
            p.asset, p.name, p.symbol, p.hub, p.governor, p.rebalancer, p.adapterRegistry, p.feeRecipient, p.performanceFeeBps, t
        ));
        require(ok, "VAULT_INIT_FAIL");
        // grant MINTER_ROLE
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        (ok,) = t.call(abi.encodeWithSignature("grantRole(bytes32,address)", MINTER_ROLE, v));
        require(ok, "GRANT_MINTER_FAIL");
        emit VaultCreated(v, t, p.asset, p.name, p.symbol);
        return (v, t);
    }
}
