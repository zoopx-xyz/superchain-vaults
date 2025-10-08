// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20Mini {
    mapping(address => uint256) public balanceOf;
    function decimals() public pure returns (uint8) { return 18; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

contract ControllerHubExtraBranchesTest is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20Mini asset;
    ERC20Mini lst;
    MockAggregator aggAsset;
    MockAggregator aggLst;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new ERC20Mini();
        lst = new ERC20Mini();
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
            borrowCap: 1_000_000 ether,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(this)
        });
        vm.prank(gov);
        hub.listMarket(address(asset), abi.encode(p));
        lst.mint(user, 1000 ether);
        vm.prank(user);
        hub.enterMarket(address(lst));
    }

    function testPauseFlagsBorrowAndLiquidation() public {
        vm.prank(gov);
        hub.setPause(true, true);
        vm.expectRevert();
        vm.prank(user);
        hub.borrow(address(asset), 1 ether, 0);
        vm.expectRevert();
        vm.prank(user);
        hub.liquidate(user, address(asset), 1, address(lst), address(this));
        // unpause borrows and test accrue same timestamp no-change path implicitly via borrow fail due to LTV later
        vm.prank(gov);
        hub.setPause(false, false);
    }

    function testProposeAndAcceptGovernor() public {
        vm.prank(gov);
        hub.proposeGovernor(user);
        vm.prank(user);
        hub.acceptGovernor();
    }
}
