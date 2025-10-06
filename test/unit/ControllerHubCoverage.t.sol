// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20MockCheap {
    string public name; string public symbol; uint8 public immutable decimals = 18;
    mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    constructor(string memory n, string memory s){name=n;symbol=s;}
    function transfer(address to,uint256 a) external returns(bool){balanceOf[msg.sender]-=a;balanceOf[to]+=a;emit Transfer(msg.sender,to,a);return true;}
    function approve(address s,uint256 a) external returns(bool){allowance[msg.sender][s]=a;emit Approval(msg.sender,s,a);return true;}
    function transferFrom(address f,address t,uint256 a) external returns(bool){uint256 al=allowance[f][msg.sender];require(al>=a,"ALW");if(al!=type(uint256).max) allowance[f][msg.sender]=al-a;balanceOf[f]-=a;balanceOf[t]+=a;emit Transfer(f,t,a);return true;}
    function mint(address to,uint256 a) external {balanceOf[to]+=a;emit Transfer(address(0),to,a);}    
}

contract ControllerHubCoverageTest is Test {
    ControllerHub hub; PriceOracleRouter router;
    ERC20MockCheap asset; ERC20MockCheap lst;
    MockAggregator aggAsset; MockAggregator aggLST;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    function setUp() public {
        router = new PriceOracleRouter(); router.initialize(gov);
        hub = new ControllerHub(); hub.initialize(gov, address(router));
        asset = new ERC20MockCheap("ASSET","AST"); lst = new ERC20MockCheap("LST","LST");
        aggAsset = new MockAggregator(1e8, block.timestamp); aggLST = new MockAggregator(1e8, block.timestamp);
        vm.prank(gov); router.setFeed(address(asset), address(aggAsset), address(0), 8, 1 days, 0);
        vm.prank(gov); router.setFeed(address(lst), address(aggLST), address(0), 8, 1 days, 0);
        ControllerHub.MarketParams memory p = ControllerHub.MarketParams({
            ltvBps: 5000, liqThresholdBps: 6000, reserveFactorBps: 1000,
            borrowCap: 1_000_000 ether, kinkBps: 8000, slope1Ray: 1e16, slope2Ray: 2e16,
            baseRateRay: 0, lst: address(lst), vault: address(this)
        });
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
        lst.mint(user, 1_000_000 ether); vm.prank(user); hub.enterMarket(address(lst));
    }

    function testInvalidParamsOnListAndSet() public {
        ControllerHub.MarketParams memory bad1 = ControllerHub.MarketParams({ltvBps: 7000, liqThresholdBps: 6000, reserveFactorBps:0, borrowCap:0, kinkBps: 8000, slope1Ray:0, slope2Ray:0, baseRateRay:0, lst: address(lst), vault: address(this)});
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(0x1), abi.encode(bad1));
        ControllerHub.MarketParams memory bad2 = ControllerHub.MarketParams({ltvBps: 1000, liqThresholdBps: 2000, reserveFactorBps:0, borrowCap:0, kinkBps: 0, slope1Ray:0, slope2Ray:0, baseRateRay:0, lst: address(lst), vault: address(this)});
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.setParams(address(asset), abi.encode(bad2));
    }

    function testAccrueAboveKinkIncreasesIndexes() public {
        // borrow to set utilization > kink (borrow > 4 units)
        vm.prank(user); hub.borrow(address(asset), 6, 0);
        (ControllerHub.MarketState memory sBefore,,) = hub.marketStateExtended(address(asset));
        vm.warp(block.timestamp + 1 hours);
        hub.accrue(address(asset));
        (ControllerHub.MarketState memory sAfter,,) = hub.marketStateExtended(address(asset));
        assertGt(sAfter.debtIndexRay, sBefore.debtIndexRay);
        assertGt(sAfter.supplyIndexRay, sBefore.supplyIndexRay);
    }

    function testAccrueSameTimestampNoChange() public {
        (ControllerHub.MarketState memory sBefore,,) = hub.marketStateExtended(address(asset));
        hub.accrue(address(asset));
        (ControllerHub.MarketState memory sAfter,,) = hub.marketStateExtended(address(asset));
        assertEq(sAfter.debtIndexRay, sBefore.debtIndexRay);
        assertEq(sAfter.supplyIndexRay, sBefore.supplyIndexRay);
    }

    function testRepayReducesDebtAndBorrows() public {
        vm.prank(user); hub.borrow(address(asset), 1_000 ether, 0);
        uint256 debtBefore = hub.currentDebt(user, address(asset));
        (ControllerHub.MarketState memory sBefore,,) = hub.marketStateExtended(address(asset));
        vm.prank(user); hub.repay(address(asset), 100 ether, 0);
        uint256 debtAfter = hub.currentDebt(user, address(asset));
        (ControllerHub.MarketState memory sAfter,,) = hub.marketStateExtended(address(asset));
        assertLt(debtAfter, debtBefore);
        assertLt(uint256(sAfter.totalBorrows), uint256(sBefore.totalBorrows));
    }

    function testAccountLiquidityAndShortfall() public {
        // healthy
        (uint256 c, uint256 d, uint256 s) = hub.accountLiquidity(user, address(asset));
        assertEq(d, 0); assertEq(s, 0); assertGt(c, 0);
        // borrow near LTV then drop LST price to create shortfall
        vm.prank(user); hub.borrow(address(asset), 500_000 ether, 0);
        aggLST.setAnswer(5e7); // 0.5
        (, , uint256 shortfall) = hub.accountLiquidity(user, address(asset));
        assertGt(shortfall, 0);
    }

    function testMarketStateExtendedUtilization() public {
        (,, uint256 u0) = hub.marketStateExtended(address(asset));
        assertEq(u0, 0);
        vm.prank(user); hub.borrow(address(asset), 10 ether, 0);
        (,, uint256 u1) = hub.marketStateExtended(address(asset));
        assertGt(u1, 0);
    }

    function testHealthFactorDefaultMax() public view {
        uint256 hf = hub.healthFactor(address(0x1234));
        assertEq(hf, type(uint256).max);
    }
}
