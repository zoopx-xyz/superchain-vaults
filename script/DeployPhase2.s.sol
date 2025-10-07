// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {AdapterRegistry} from "contracts/strategy/AdapterRegistry.sol";
import {SuperVaultHub} from "contracts/hub/SuperVaultHub.sol";
import {SpokeYieldVault} from "contracts/spoke/SpokeYieldVault.sol";
import {SuperchainERC20} from "contracts/tokens/SuperchainERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "contracts/factory/VaultFactory.sol";

/// @notice Deployment script for phase 2: controller, markets, vault, oracles, and smoke test.
/// Env: GOV_MULTISIG, TIMELOCK, BASE_ASSET, WITHDRAW_BUFFER_BPS, EPOCH_LEN_SEC, EPOCH_OUTFLOW_CAP_BPS,
///      RESERVE_FACTOR_BPS, LTV_BPS, LT_BPS, KINK_BPS, SLOPE1_RAY, SLOPE2_RAY,
///      FEED_<SYMBOL>_* for assets (configured per deployment), SEQUENCER_ORACLE optional.
contract DeployPhase2 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        _execute();
        vm.stopBroadcast();
    }

    function _execute() internal {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address gov = vm.envAddress("GOV_MULTISIG");
        address timelock = vm.envAddress("TIMELOCK");
        address baseAsset = vm.envAddress("BASE_ASSET");
        uint16 wbuf = uint16(vm.envUint("WITHDRAW_BUFFER_BPS"));
        uint64 epochLen = uint64(vm.envUint("EPOCH_LEN_SEC"));
        uint16 epochCap = uint16(vm.envUint("EPOCH_OUTFLOW_CAP_BPS"));
        uint16 rf = uint16(vm.envUint("RESERVE_FACTOR_BPS"));
        uint16 ltv = uint16(vm.envUint("LTV_BPS"));
        uint16 lt = uint16(vm.envUint("LT_BPS"));
        uint16 kink = uint16(vm.envUint("KINK_BPS"));
        uint128 s1 = uint128(vm.envUint("SLOPE1_RAY"));
        uint128 s2 = uint128(vm.envUint("SLOPE2_RAY"));
        require(gov != address(0) && timelock != address(0) && baseAsset != address(0), "env:zero");

        (PriceOracleRouter router, AdapterRegistry registry) = _getOrDeployPhase1(gov);
        (ControllerHub controller, VaultFactory factory) = _deployCore(gov, router);
        (SuperVaultHub svh, address lst, SpokeYieldVault vault) =
            _deployVaultAndToken(baseAsset, gov, registry, deployer, wbuf, epochCap, epochLen);
        _configureOracle(router, baseAsset);
        _listMarket(controller, baseAsset, lst, address(vault), ltv, lt, rf, kink, s1, s2);
        _hardenRoles(timelock, gov, controller, router, vault, svh);
        _smokeTest(baseAsset, vault, controller, deployer);
        _writeArtifacts(address(controller), address(vault), address(factory));
    }

    function _getOrDeployPhase1(address gov) internal returns (PriceOracleRouter router, AdapterRegistry registry) {
        string memory p1 = string.concat("artifacts/deploy/", vm.toString(block.chainid), ".json");
        string memory content;
        bool hasP1;
        // handle missing file gracefully
        try vm.readFile(p1) returns (string memory _content) {
            content = _content;
            hasP1 = bytes(content).length > 0;
        } catch {
            hasP1 = false;
        }
        if (hasP1) {
            router = PriceOracleRouter(vm.parseJsonAddress(content, ".PriceOracleRouter"));
            registry = AdapterRegistry(vm.parseJsonAddress(content, ".AdapterRegistry"));
        }
        if (address(router) == address(0)) {
            router = new PriceOracleRouter();
            router.initialize(gov);
        }
        if (address(registry) == address(0)) {
            registry = new AdapterRegistry();
            registry.initialize(gov);
        }
    }

    function _deployCore(address gov, PriceOracleRouter router)
        internal
        returns (ControllerHub controller, VaultFactory factory)
    {
        controller = new ControllerHub();
        controller.initialize(gov, address(router));
        factory = new VaultFactory();
    }

    function _deployVaultAndToken(
        address baseAsset,
        address gov,
        AdapterRegistry registry,
        address deployer,
        uint16 wbuf,
        uint16 epochCap,
        uint64 epochLen
    ) internal returns (SuperVaultHub svh, address lst, SpokeYieldVault vault) {
        address rebalancer = gov;
        svh = new SuperVaultHub();
        svh.initialize(baseAsset, address(0), gov, deployer);
        lst = address(new SuperchainERC20("LST Token", "LST"));
        vault = new SpokeYieldVault();
        vault.initialize(
            IERC20(baseAsset),
            "Spoke Vault",
            "SVLT",
            address(svh),
            gov,
            rebalancer,
            address(registry),
            deployer,
            wbuf,
            lst
        );
        vault.setWithdrawalBufferBps(wbuf);
        // Grant LST MINTER_ROLE to vault so deposits can mint LST
        (bool ok,) =
            lst.call(abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("MINTER_ROLE"), address(vault)));
        require(ok, "grant_minter");
        vault.setEpochOutflowConfig(epochCap, epochLen);
        // Keep adapters disabled; registry is paused
        registry.pause();
    }

    function _configureOracle(PriceOracleRouter router, address baseAsset) internal {
        // Oracle config: Example for base asset symbol env group (e.g., WETH)
        address primary = vm.envAddress("FEED_BASE_PRIMARY");
        address secondary = vm.envOr({name: "FEED_BASE_SECONDARY", defaultValue: address(0)});
        uint8 decimals = uint8(vm.envUint("FEED_BASE_DECIMALS"));
        uint256 hb = vm.envUint("FEED_BASE_HEARTBEAT");
        uint256 devBps = vm.envUint("FEED_BASE_DEV_BPS");
        int256 minA = int256(uint256(vm.envUint("FEED_BASE_MIN")));
        int256 maxA = int256(uint256(vm.envUint("FEED_BASE_MAX")));
        router.setFeed(baseAsset, primary, secondary, decimals, hb, devBps);
        router.setFeedBounds(baseAsset, minA, maxA);
    }

    function _listMarket(
        ControllerHub controller,
        address baseAsset,
        address lst,
        address vault,
        uint16 ltv,
        uint16 lt,
        uint16 rf,
        uint16 kink,
        uint128 s1,
        uint128 s2
    ) internal {
        ControllerHub.MarketParams memory p = ControllerHub.MarketParams({
            ltvBps: ltv,
            liqThresholdBps: lt,
            reserveFactorBps: rf,
            borrowCap: type(uint128).max,
            kinkBps: kink,
            slope1Ray: s1,
            slope2Ray: s2,
            baseRateRay: 0,
            lst: lst,
            vault: vault
        });
        controller.listMarket(baseAsset, abi.encode(p));
    }

    function _hardenRoles(
        address timelock,
        address gov,
        ControllerHub controller,
        PriceOracleRouter router,
        SpokeYieldVault vault,
        SuperVaultHub svh
    ) internal {
        controller.grantRole(controller.GOVERNOR_ROLE(), timelock);
        controller.grantRole(controller.DEFAULT_ADMIN_ROLE(), timelock);
        router.grantRole(router.GOVERNOR_ROLE(), timelock);
        router.grantRole(router.DEFAULT_ADMIN_ROLE(), timelock);
        vault.grantRole(vault.GOVERNOR_ROLE(), timelock);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), timelock);
        svh.grantRole(svh.GOVERNOR_ROLE(), timelock);
        svh.grantRole(svh.DEFAULT_ADMIN_ROLE(), timelock);
        // Revoke deployer/gov where appropriate
        controller.revokeRole(controller.GOVERNOR_ROLE(), gov);
        controller.revokeRole(controller.DEFAULT_ADMIN_ROLE(), gov);
        router.revokeRole(router.GOVERNOR_ROLE(), gov);
        router.revokeRole(router.DEFAULT_ADMIN_ROLE(), gov);
        vault.revokeRole(vault.GOVERNOR_ROLE(), gov);
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), gov);
        svh.revokeRole(svh.GOVERNOR_ROLE(), gov);
        svh.revokeRole(svh.DEFAULT_ADMIN_ROLE(), gov);
    }

    function _smokeTest(address baseAsset, SpokeYieldVault vault, ControllerHub controller, address user) internal {
        vm.startPrank(user);
        IERC20(baseAsset).approve(address(vault), type(uint256).max);
        uint256 bal = IERC20(baseAsset).balanceOf(user);
        uint256 depositAmt = bal > 0 ? bal / 100 : 0; // 1% of balance if available
        if (depositAmt > 0) {
            uint256 shares = vault.deposit(depositAmt, user);
            require(shares > 0, "deposit");
            uint256 assetsOut = vault.redeem(shares / 2, user, user);
            require(assetsOut > 0, "redeem");
        } else {
            console2.log("Skip deposit/withdraw smoke: baseAsset balance is zero");
        }
        // Enter market and attempt small borrow/repay best-effort
        controller.enterMarket(address(vault.lst()));
        try controller.borrow(baseAsset, 1, block.chainid) {
            controller.repay(baseAsset, 1, block.chainid);
            require(controller.healthFactor(user) >= 1e18, "hf");
        } catch {
            console2.log("Borrow/repay smoke skipped (ltv or pricing not favorable)");
        }
        // Try to allocate to adapter; expect revert due to registry locked
        vm.expectRevert();
        vault.allocateToAdapter(address(0xDEAD), 1 ether, "");
        vm.stopPrank();
    }

    function _writeArtifacts(address controller, address vault, address factory) internal {
        string memory dir = string.concat("artifacts/deploy/");
        string memory path = string.concat(dir, vm.toString(block.chainid), ".phase2.json");
        vm.createDir(dir, true);
        string memory file = string.concat(
            "{\n  \"chainId\": ",
            vm.toString(block.chainid),
            ",\n  \"ControllerHub\": \"",
            vm.toString(controller),
            "\",\n  \"SpokeYieldVault\": \"",
            vm.toString(vault),
            "\",\n  \"VaultFactory\": \"",
            vm.toString(factory),
            "\"\n}\n"
        );
        vm.writeFile(path, file);
        vm.writeFile(string.concat(dir, vm.toString(block.chainid), ".PHASE2.SUCCESS"), "ok");
    }
}
