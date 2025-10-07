// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20Mock {
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

contract SeizeSink {
    event Seized(address user, uint256 shares, address to);

    uint256 public lastShares;

    function onSeizeShares(address user, uint256 shares, address to) external {
        lastShares = shares;
        emit Seized(user, shares, to);
    }
}

contract ControllerHubBranchesTest is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20Mock asset;
    ERC20Mock lst;
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
        asset = new ERC20Mock("ASSET", "AST");
        lst = new ERC20Mock("LST", "LST");
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

    function testBorrowAtCapBoundaryThenRevertOnPlusOne() public {
        vm.prank(user);
        hub.borrow(address(asset), 100 ether, 0);
        vm.expectRevert(abi.encodeWithSignature("ExceedsBorrowCap()"));
        vm.prank(user);
        hub.borrow(address(asset), 1, 0);
    }

    function testSeizeRoundingUpNonZero() public {
        // Borrow up to the cap to make liquidation possible after a price drop
        vm.prank(user);
        hub.borrow(address(asset), 100 ether, 0);
        // Drop LST price significantly to push account above liquidation threshold
        aggLst.setAnswer(1e7); // 0.1
        // Repay a minimal amount to trigger ceilDiv path in share calc and ensure non-zero seize
        hub.liquidate(user, address(asset), 1, address(lst), address(this));
        assertGt(sink.lastShares(), 0, "seized shares should be > 0 due to ceilDiv rounding up");
    }
}
