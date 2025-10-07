// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";

contract ERC20Mock is Test {
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
        require(balanceOf[msg.sender] >= a, "bal");
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
        require(balanceOf[f] >= a, "bal");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        emit Transfer(f, t, a);
        return true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function totalSupply() external view returns (uint256) {
        return 0;
    }
}

contract AggregatorMock {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 a) {
        answer = a;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract Controller_MultiMarketHF is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20Mock asset1;
    ERC20Mock asset2;
    ERC20Mock lst1;
    ERC20Mock lst2;
    AggregatorMock aggA1;
    AggregatorMock aggA2;
    AggregatorMock aggL1;
    AggregatorMock aggL2;
    address gov = address(0xA11CE);

    function setUp() public {
        vm.startPrank(gov);
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset1 = new ERC20Mock("A1", "A1");
        asset2 = new ERC20Mock("A2", "A2");
        lst1 = new ERC20Mock("L1", "L1");
        lst2 = new ERC20Mock("L2", "L2");
        aggA1 = new AggregatorMock(1e18);
        aggA2 = new AggregatorMock(2e18);
        aggL1 = new AggregatorMock(1e18);
        aggL2 = new AggregatorMock(3e18);
        router.setFeed(address(asset1), address(aggA1), address(0), 18, 0, 10_000);
        router.setFeed(address(asset2), address(aggA2), address(0), 18, 0, 10_000);
        router.setFeed(address(lst1), address(aggL1), address(0), 18, 0, 10_000);
        router.setFeed(address(lst2), address(aggL2), address(0), 18, 0, 10_000);
        ControllerHub.MarketParams memory p1 = ControllerHub.MarketParams({
            ltvBps: 6000,
            liqThresholdBps: 8000,
            reserveFactorBps: 1000,
            borrowCap: 1e36,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 1e15,
            lst: address(lst1),
            vault: address(0)
        });
        ControllerHub.MarketParams memory p2 = ControllerHub.MarketParams({
            ltvBps: 5000,
            liqThresholdBps: 7500,
            reserveFactorBps: 1000,
            borrowCap: 1e36,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 1e15,
            lst: address(lst2),
            vault: address(0)
        });
        hub.listMarket(address(asset1), abi.encode(p1));
        hub.listMarket(address(asset2), abi.encode(p2));
        vm.stopPrank();
        // user enters both
        hub.enterMarket(address(lst1));
        hub.enterMarket(address(lst2));
        lst1.mint(address(this), 100 ether);
        lst2.mint(address(this), 50 ether);
    }

    function testHF_BasicAndShocks() public {
        // baseline: no debt => HF=1e18
        assertEq(hub.healthFactor(address(this)), 1e18);
        // borrow small amount within HF
        vm.prank(address(this));
        hub.borrow(address(asset1), 10 ether, block.chainid);
        uint256 hfAfterBorrow1 = hub.healthFactor(address(this));
        assertGe(hfAfterBorrow1, 1e18);
        // price shock down on collateral
        aggL1.set(5e17); // -50%
        uint256 hfAfterShock1 = hub.healthFactor(address(this));
        // HF should decrease vs post-borrow baseline
        assertLt(hfAfterShock1, hfAfterBorrow1);
        // shock up restores
        aggL1.set(1e18);
        assertGe(hub.healthFactor(address(this)), hfAfterBorrow1);
        // borrow more on asset2
        vm.prank(address(this));
        hub.borrow(address(asset2), 10 ether, block.chainid);
        // price shock up on debt
        // make debt much more expensive to force HF < 1
        aggA2.set(50e18);
        assertLt(hub.healthFactor(address(this)), 1e18);
    }

    function testExitBlockedWhenUnhealthy() public {
        // make HF < 1 by borrowing then shocking collateral down and debt up
        vm.prank(address(this));
        hub.borrow(address(asset1), 10 ether, block.chainid);
        // Strong collateral shocks across both LSTs
        aggL1.set(1e17); // -90%
        aggL2.set(5e17); // -83% from 3e18 -> 0.5e18
        // Increase debt asset price substantially
        aggA1.set(5e18);
        vm.expectRevert(bytes("UNHEALTHY"));
        hub.exitMarket(address(lst1));
    }
}
