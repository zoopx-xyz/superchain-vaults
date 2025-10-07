// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20MockSim {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }
}

contract ScenarioSweep is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20MockSim asset;
    ERC20MockSim lst;
    MockAggregator aggAsset;
    MockAggregator aggLst;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new ERC20MockSim("ASSET", "AST");
        lst = new ERC20MockSim("LST", "LST");
        aggAsset = new MockAggregator(1e8, block.timestamp);
        aggLst = new MockAggregator(1e8, block.timestamp);
        vm.prank(gov);
        router.setFeed(address(asset), address(aggAsset), address(0), 8, 1 days, 0);
        vm.prank(gov);
        router.setFeed(address(lst), address(aggLst), address(0), 8, 1 days, 0);
        ControllerHub.MarketParams memory p = ControllerHub.MarketParams({
            ltvBps: 5000,
            liqThresholdBps: 6000,
            reserveFactorBps: 1000,
            borrowCap: 1_000 ether,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(this)
        });
        vm.prank(gov);
        hub.listMarket(address(asset), abi.encode(p));
        lst.mint(user, 10_000 ether);
    }

    function onSeizeShares(address, uint256, address) external {}

    function test_ScenarioSweep_WriteCSV() public {
        vm.createDir("artifacts/econsec", true);
        string memory path = "artifacts/econsec/sim-sweep.csv";
        vm.writeFile(path, "scenario,ltvBps,liqBps,borrowCap,priceShock,hf_after,shortfall\n");
        // Sweep a tiny grid of params and shocks
        uint16[3] memory ltvs = [uint16(4000), uint16(5000), uint16(6000)];
        uint16[2] memory liqs = [uint16(6500), uint16(7000)];
        uint128[2] memory caps = [uint128(100 ether), uint128(500 ether)];
        uint256[3] memory shocks = [uint256(8e7), uint256(5e7), uint256(2e7)]; // 0.8, 0.5, 0.2

        for (uint256 i = 0; i < ltvs.length; i++) {
            for (uint256 j = 0; j < liqs.length; j++) {
                for (uint256 k = 0; k < caps.length; k++) {
                    // set params
                    ControllerHub.MarketParams memory p = ControllerHub.MarketParams({
                        ltvBps: ltvs[i],
                        liqThresholdBps: liqs[j],
                        reserveFactorBps: 1000,
                        borrowCap: caps[k],
                        kinkBps: 8000,
                        slope1Ray: 1e16,
                        slope2Ray: 2e16,
                        baseRateRay: 0,
                        lst: address(lst),
                        vault: address(this)
                    });
                    vm.prank(gov);
                    hub.setParams(address(asset), abi.encode(p));

                    // Reset price baseline and user state
                    aggLst.setAnswer(1e8);
                    // user enters market and borrows up to 80% of cap to leave room
                    vm.prank(user);
                    hub.enterMarket(address(lst));
                    vm.prank(user);
                    hub.borrow(address(asset), (caps[k] * 8) / 10, 0);
                    (,, uint256 shortfall0) = hub.accountLiquidity(user, address(asset));
                    assertEq(shortfall0, 0);

                    for (uint256 s = 0; s < shocks.length; s++) {
                        // apply shock to LST price
                        aggLst.setAnswer(int256(uint256(shocks[s])));
                        (,, uint256 shortfall) = hub.accountLiquidity(user, address(asset));
                        // Write row
                        string memory row = string(
                            abi.encodePacked(
                                "sweep,",
                                vm.toString(ltvs[i]),
                                ",",
                                vm.toString(liqs[j]),
                                ",",
                                vm.toString(uint256(caps[k])),
                                ",",
                                vm.toString(uint256(shocks[s])),
                                ",",
                                vm.toString(hub.healthFactor(user)),
                                ",",
                                vm.toString(shortfall)
                            )
                        );
                        vm.writeLine(path, row);
                    }
                    // Repay current debt before moving to next param combo to avoid cap accumulation
                    uint256 debt = hub.currentDebt(user, address(asset));
                    if (debt > 0) {
                        vm.prank(user);
                        hub.repay(address(asset), debt, 0);
                    }
                }
            }
        }
    }
}
