// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";
import {SuperVaultHub} from "contracts/hub/SuperVaultHub.sol";
import {AaveV3Adapter} from "contracts/strategy/AaveV3Adapter.sol";
import {VelodromeLPAdapter} from "contracts/strategy/VelodromeLPAdapter.sol";
import {SuperchainAdapter} from "contracts/messaging/SuperchainAdapter.sol";

/// @notice Deployment script for phase 1: core registries and base hubs/registry/oracle.
/// Env (required): GOV_MULTISIG, TIMELOCK, BASE_ASSET
/// Optional: SEQUENCER_ORACLE
contract DeployPhase1 is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address gov = vm.envAddress("GOV_MULTISIG");
        address timelock = vm.envAddress("TIMELOCK");
        address baseAsset = vm.envAddress("BASE_ASSET");
        address seq = vm.envOr("SEQUENCER_ORACLE", address(0));
        require(gov != address(0) && timelock != address(0) && baseAsset != address(0), "env:zero");

        vm.startBroadcast(deployerPk);

        // Ensure artifacts directory exists for address book outputs
        vm.createDir("artifacts/deploy", true);

        // Deploy core contracts
        PriceOracleRouter router = new PriceOracleRouter();
        router.initialize(gov);
        AdapterRegistry registry = new AdapterRegistry();
        registry.initialize(gov);
        // Deploy a basic SuperchainAdapter (messenger optional/zero for now)
        SuperchainAdapter scAdapter = new SuperchainAdapter();
        scAdapter.initialize(address(0), gov);
        SuperVaultHub hub = new SuperVaultHub();
        hub.initialize(baseAsset, address(scAdapter), gov, deployer);

        if (seq != address(0)) {
            router.setSequencerOracle(seq);
        }

        // Deploy mock adapters (MockOnly) and lock them by default
        AaveV3Adapter mockAave = new AaveV3Adapter();
        VelodromeLPAdapter mockVelo = new VelodromeLPAdapter();
        // Keep registry paused until allowlist finalized
        registry.pause();
        // Register adapters as disallowed with cap 0
        registry.setAdapter(address(mockAave), false, 0);
        registry.setAdapter(address(mockVelo), false, 0);
        console2.log("Mock adapter registered: allowed=false, cap=0", address(mockAave));
        console2.log("Mock adapter registered: allowed=false, cap=0", address(mockVelo));

        // Governance: grant roles to TIMELOCK and revoke from deployer where applicable
        hub.grantRole(hub.GOVERNOR_ROLE(), timelock);
        hub.grantRole(hub.DEFAULT_ADMIN_ROLE(), timelock);
        router.grantRole(router.GOVERNOR_ROLE(), timelock);
        router.grantRole(router.DEFAULT_ADMIN_ROLE(), timelock);
        registry.grantRole(registry.GOVERNOR_ROLE(), timelock);
        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), timelock);
        // Revoke deployer
        hub.revokeRole(hub.GOVERNOR_ROLE(), gov);
        hub.revokeRole(hub.DEFAULT_ADMIN_ROLE(), gov);
        router.revokeRole(router.GOVERNOR_ROLE(), gov);
        router.revokeRole(router.DEFAULT_ADMIN_ROLE(), gov);
        registry.revokeRole(registry.GOVERNOR_ROLE(), gov);
        registry.revokeRole(registry.DEFAULT_ADMIN_ROLE(), gov);

        // Address book artifact
        string memory path = string.concat("artifacts/deploy/", vm.toString(block.chainid), ".json");
        string memory adaptersJson = string.concat(
            "[{\"name\":\"MockAave\",\"addr\":\"",
            vm.toString(address(mockAave)),
            "\",\"allowed\":false,\"cap\":\"0\"},",
            "{\"name\":\"MockVelodrome\",\"addr\":\"",
            vm.toString(address(mockVelo)),
            "\",\"allowed\":false,\"cap\":\"0\"}]"
        );
        string memory file = string.concat(
            "{\n  \"chainId\": ",
            vm.toString(block.chainid),
            ",\n  \"governor\": \"",
            vm.toString(gov),
            "\",\n  \"timelock\": \"",
            vm.toString(timelock),
            "\",\n  \"PriceOracleRouter\": \"",
            vm.toString(address(router)),
            "\",\n  \"SuperVaultHub\": \"",
            vm.toString(address(hub)),
            "\",\n  \"AdapterRegistry\": \"",
            vm.toString(address(registry)),
            "\",\n  \"SuperchainAdapter\": \"",
            vm.toString(address(scAdapter)),
            "\",\n  \"adapters\": ",
            adaptersJson,
            "\n}\n"
        );
        vm.writeFile(path, file);

        // Optional: create a SUCCESS marker
        vm.writeFile(string.concat("artifacts/deploy/", vm.toString(block.chainid), ".SUCCESS"), "ok");

        vm.stopBroadcast();
    }
}
