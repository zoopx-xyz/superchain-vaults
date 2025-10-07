// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract SeizeMock {
    event Seized(address user, uint256 shares, address to);

    function onSeizeShares(address user, uint256 shares, address to) external {
        emit Seized(user, shares, to);
    }
}

contract TestERC20 {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        emit Transfer(msg.sender, to, a);
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "ALW");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        emit Transfer(f, t, a);
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }
}

contract ControllerHubPolicyTest is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    TestERC20 asset;
    TestERC20 lst;
    MockAggregator aggAsset;
    MockAggregator aggLst;
    SeizeMock seize;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new TestERC20("ASSET", "AST");
        lst = new TestERC20("LST", "LST");
        seize = new SeizeMock();
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
            borrowCap: 1000 ether,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(seize)
        });
        vm.prank(gov);
        hub.listMarket(address(asset), abi.encode(p));
        lst.mint(user, 1000 ether);
        vm.prank(user);
        hub.enterMarket(address(lst));
    }

    function testSetBorrowCapAndEnforcement() public {
        vm.prank(gov);
        hub.setBorrowCap(address(asset), 300 ether);
        vm.prank(user);
        hub.borrow(address(asset), 300 ether, 0);
        vm.expectRevert(abi.encodeWithSignature("ExceedsBorrowCap()"));
        vm.prank(user);
        hub.borrow(address(asset), 1, 0);
    }

    function testPauseFlags() public {
        vm.prank(gov);
        hub.setPause(true, false);
        vm.expectRevert(abi.encodeWithSignature("InsufficientCollateral()"));
        vm.prank(user);
        hub.borrow(address(asset), 1 ether, 0);
        vm.prank(gov);
        hub.setPause(false, true);
        // set up a borrow (at LTV limit) and then exit market to trigger NotEnteredMarket on liquidation when paused
        vm.prank(user);
        hub.borrow(address(asset), 500 ether, 0);
        vm.prank(user);
        hub.exitMarket(address(lst));
        vm.expectRevert(abi.encodeWithSignature("NotEnteredMarket()"));
        hub.liquidate(user, address(asset), 1 ether, address(lst), address(this));
        // unpause liquidations and allow
        vm.prank(gov);
        hub.setPause(false, false);
        // re-enter market and make user unhealthy
        vm.prank(user);
        hub.enterMarket(address(lst));
        aggLst.setAnswer(8e7); // 0.8 for liquidation condition: liq limit = 0.6 * 1000 * 0.8 = 480 < debt 500
        hub.liquidate(user, address(asset), 1 ether, address(lst), address(this));
    }
}
