// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SuperchainERC20} from "../tokens/SuperchainERC20.sol";
import {ProxyDeployer} from "../proxy/ProxyDeployer.sol";

/// @title VaultFactory
/// @notice Deploys SpokeYieldVaults and their LST ERC20 via minimal proxies.
contract VaultFactory is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    using Clones for address;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address public vaultImpl;
    address public tokenImpl;
    address public proxyDeployer;

    /// @notice Emitted when a new vault proxy is deployed.
    /// @param proxy The deployed ERC1967 proxy address for the vault.
    /// @param implementation The UUPS implementation the proxy points to.
    /// @param lst The LST token address paired with the vault.
    /// @param salt Keccak of the initializer used for emit-only traceability (not CREATE2).
    event VaultDeployed(address indexed proxy, address indexed implementation, address indexed lst, bytes32 salt);

    /// @notice Initialize the factory.
    /// @param governor Admin with GOVERNOR_ROLE and DEFAULT_ADMIN_ROLE.
    /// @param _vaultImpl UUPS implementation for SpokeYieldVault.
    /// @param _tokenImpl Ignored for now (non-upgradeable token template kept for compatibility).
    /// @param _proxyDeployer Address of ProxyDeployer contract used to deploy ERC1967 proxies.
    function initialize(address governor, address _vaultImpl, address _tokenImpl, address _proxyDeployer) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        vaultImpl = _vaultImpl;
        tokenImpl = _tokenImpl;
        proxyDeployer = _proxyDeployer;
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}

    /// @notice Update implementation references.
    function setImplementations(address _vaultImpl, address _tokenImpl) external onlyRole(GOVERNOR_ROLE) {
        vaultImpl = _vaultImpl;
        tokenImpl = _tokenImpl;
    }

    /// @notice Update ProxyDeployer address.
    function setProxyDeployer(address _proxyDeployer) external onlyRole(GOVERNOR_ROLE) {
        proxyDeployer = _proxyDeployer;
    }

    struct CreateParams {
        address asset;
        string name;
        string symbol;
        address hub;
        address governor;
        address rebalancer;
        address adapterRegistry;
        address feeRecipient;
        uint16 performanceFeeBps;
        address lst;
    }

    /// @notice Creates a new vault and its LST token via minimal proxies.
    function create(CreateParams memory p) external onlyRole(GOVERNOR_ROLE) returns (address vault, address lst) {
        // Deploy LST token (non-upgradeable)
        address t = address(new SuperchainERC20(p.name, p.symbol));

        // Build initializer for the vault implementation
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,string,string,address,address,address,address,address,uint16,address)",
            p.asset,
            p.name,
            p.symbol,
            p.hub,
            p.governor,
            p.rebalancer,
            p.adapterRegistry,
            p.feeRecipient,
            p.performanceFeeBps,
            t
        );

        // Deploy ERC1967 proxy pointing to UUPS implementation
        address pd = proxyDeployer;
        require(pd != address(0), "NO_PROXY_DEPLOYER");
        (bool ok, bytes memory ret) = pd.call(abi.encodeWithSelector(ProxyDeployer.deployUUPS.selector, vaultImpl, initData));
        require(ok && ret.length == 32, "PROXY_DEPLOY_FAIL");
        address v;
        assembly { v := mload(add(ret, 32)) }

        // grant MINTER_ROLE to vault
        (ok,) = t.call(abi.encodeWithSignature("grantRole(bytes32,address)", MINTER_ROLE, v));
        require(ok, "GRANT_MINTER_FAIL");

        emit VaultDeployed(v, vaultImpl, t, keccak256(initData));
        return (v, t);
    }
}
