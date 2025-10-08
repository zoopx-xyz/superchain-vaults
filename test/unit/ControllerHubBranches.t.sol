// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract TinyERC20 {
    mapping(address => uint256) public balanceOf;
    function decimals() public pure returns (uint8) { return 18; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

contract SeizeSink {
    uint256 public lastShares;
    function onSeizeShares(address, uint256 shares, address) external { lastShares = shares; }
}

contract ControllerHubBranchesTest is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    TinyERC20 asset;
    TinyERC20 lst;
    SeizeSink sink;
    MockAggregator aggAsset;
    MockAggregator aggLst;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new TinyERC20();
        lst = new TinyERC20();
        sink = new SeizeSink();
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
            borrowCap: 100 ether,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(sink)
        });
        vm.prank(gov);
        hub.listMarket(address(asset), abi.encode(p));
        lst.mint(user, 1000 ether);
        vm.prank(user);
        hub.enterMarket(address(lst));
    }

    function testBorrowCapBoundary() public {
        vm.prank(user);
        hub.borrow(address(asset), 100 ether, 0);
        vm.expectRevert(abi.encodeWithSignature("ExceedsBorrowCap()"));
        vm.prank(user);
        hub.borrow(address(asset), 1, 0);
    }

    function testLiquidationSeizeNonZero() public {
        vm.prank(user);
        hub.borrow(address(asset), 100 ether, 0);
        aggLst.setAnswer(1e7);
        hub.liquidate(user, address(asset), 1, address(lst), address(this));
        assertGt(sink.lastShares(), 0);
    }

    function testRepayWhenNoDebtEarlyReturn() public {
        // no debt yet
        hub.repay(address(asset), 1 ether, 0);
        // should not revert and debt stays zero
        assertEq(hub.currentDebt(address(this), address(asset)), 0);
    }

    function testExitMarketUnhealthyReverts() public {
        // Borrow up to cap, then shock price to become unhealthy
        vm.prank(user);
        hub.borrow(address(asset), 100 ether, 0);
        // extreme drop in LST price to push HF well below 1
        aggLst.setAnswer(1); // ~1e-8 with 8 decimals
        vm.prank(user);
        vm.expectRevert(bytes("UNHEALTHY"));
        hub.exitMarket(address(lst));
    }

    function testLiquidateInvalidParamsWrongSeizeLst() public {
        vm.prank(user);
        hub.borrow(address(asset), 10 ether, 0);
        // wrong LST address should revert InvalidParams
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        hub.liquidate(user, address(asset), 1 ether, address(0xB0B), address(this));
    }

    function testLiquidateNoDebtReverts() public {
        // user has no debt
        vm.expectRevert(abi.encodeWithSignature("InsufficientCollateral()"));
        hub.liquidate(user, address(asset), 1 ether, address(lst), address(this));
    }

    function testLiquidateNotEnteredMarketReverts() public {
        // borrow small while entered
        vm.prank(user);
        hub.borrow(address(asset), 1 ether, 0);
        // keep healthy and exit market to flip isEntered=false
        vm.prank(user);
        hub.exitMarket(address(lst));
        // Now liquidation should revert with NotEnteredMarket()
        vm.expectRevert(abi.encodeWithSignature("NotEnteredMarket()"));
        hub.liquidate(user, address(asset), 1 ether, address(lst), address(this));
    }

    function testRepayCapsPrincipalAndTotalBorrows() public {
        vm.prank(user);
        hub.borrow(address(asset), 5 ether, 0);
        // overpay repay amount; should cap at outstanding and zero the debt
        vm.prank(user);
        hub.repay(address(asset), 1_000_000 ether, block.chainid);
        assertEq(hub.currentDebt(user, address(asset)), 0);
    }

    function testMarketStateExtendedUtilizationBranches() public {
        // zero borrows => utilization 0
        (,,uint256 util0) = hub.marketStateExtended(address(asset));
        assertEq(util0, 0);
        // with borrows => utilization > 0
        vm.prank(user);
        hub.enterMarket(address(lst));
        vm.prank(user);
        hub.borrow(address(asset), 1 ether, 0);
        (,,uint256 util1) = hub.marketStateExtended(address(asset));
        assertGt(util1, 0);
    }
}
