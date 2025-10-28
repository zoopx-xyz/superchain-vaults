// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title ProxyDeployer
/// @notice Thin factory to deploy ERC1967 proxies pointing to UUPS implementations.
/// @dev The initData should be an abi-encoded call to the implementation's initialize(...).
contract ProxyDeployer {
    /// @notice Emitted when a proxy is deployed.
    /// @param proxy The deployed proxy address.
    /// @param implementation The UUPS implementation address behind the proxy.
    /// @param initDataHash Keccak256 hash of the initData passed to the proxy constructor.
    event ProxyDeployed(address indexed proxy, address indexed implementation, bytes32 initDataHash);

    /// @notice Deploy a new ERC1967 proxy pointing to a UUPS implementation.
    /// @param impl Address of the UUPS implementation contract.
    /// @param initData ABI-encoded initializer calldata to execute via delegatecall during construction.
    /// @return proxy The address of the deployed proxy.
    function deployUUPS(address impl, bytes memory initData) external returns (address proxy) {
        ERC1967Proxy p = new ERC1967Proxy(impl, initData);
        proxy = address(p);
        emit ProxyDeployed(proxy, impl, keccak256(initData));
    }
}
