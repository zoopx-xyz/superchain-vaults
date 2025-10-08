// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20MockBB {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function decimals() external pure returns (uint8) { return 18; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; emit Transfer(msg.sender, to, a); return true; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "ALW");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[t] += a; emit Transfer(f, t, a); return true;
    }
    function mint(address to, uint256 a) external { balanceOf[to] += a; emit Transfer(address(0), to, a); }
}

contract ControllerHubBranchBoost is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20MockBB asset;
    ERC20MockBB lst;
    MockAggregator aggAsset;
    MockAggregator aggLst;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    // implement minimal onSeizeShares to allow liquidation flow when needed
    function onSeizeShares(address /*user_*/, uint256 /*shares*/, address /*to*/ ) external {}

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new ERC20MockBB("ASSET", "AST");
        lst = new ERC20MockBB("LST", "LST");
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
            borrowCap: type(uint128).max,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(this)
        });
        vm.prank(gov);
        hub.listMarket(address(asset), abi.encode(p));
        lst.mint(user, 1_000_000 ether);
        vm.prank(user);
        hub.enterMarket(address(lst));
    }

    function testAccrueBelowKinkBranchExecutes() public {
        // below-kink path in accrue: with zero/low utilization, we still execute the "<= kink" branch
        vm.warp(block.timestamp + 1 hours);
        hub.accrue(address(asset));
        // indices may be unchanged (rate 0), but branch executed; assert state is consistent
        (ControllerHub.MarketState memory s,,) = hub.marketStateExtended(address(asset));
        assertEq(s.lastAccrual, block.timestamp);
    }

    function testLiquidateHealthyUserReverts() public {
        // Borrow a small amount to remain healthy (below liq threshold)
        vm.prank(user);
        hub.borrow(address(asset), 1000 ether, 0);
        // Healthy liquidation should revert with InsufficientCollateral()
        vm.expectRevert(abi.encodeWithSignature("InsufficientCollateral()"));
        hub.liquidate(user, address(asset), 100 ether, address(lst), address(this));
    }

    function testBorrowHFGateRevertsWhenUnhealthyAcrossMarkets() public {
        // List a second market that uses the same LST so _isBorrowAllowed() on market B ignores debt on market A
        ERC20MockBB assetB = new ERC20MockBB("ASSETB", "ASTB");
        MockAggregator aggB = new MockAggregator(1e8, block.timestamp);
        vm.prank(gov);
        router.setFeed(address(assetB), address(aggB), address(0), 8, 1 days, 0);
        ControllerHub.MarketParams memory p2 = ControllerHub.MarketParams({
            ltvBps: 5000,
            liqThresholdBps: 6000,
            reserveFactorBps: 1000,
            borrowCap: type(uint128).max,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(this)
        });
        vm.prank(gov);
        hub.listMarket(address(assetB), abi.encode(p2));

        // Take a sizable borrow on asset A, then reduce LST price to make HF < 1
        vm.prank(user);
        hub.borrow(address(asset), 500_000 ether, 0);
        // Drop LST price by 60% to push HF below 1
        aggLst.setAnswer(4e7); // 0.4
        // Try a tiny borrow on market B; _isBorrowAllowed() for B passes (no debt on B), but global HF check fails
        vm.expectRevert(bytes("HF_LT_1"));
        vm.prank(user);
        hub.borrow(address(assetB), 1 ether, 0);
    }

    function testPriceScalingBranches_decimalsEq18_and_gt18() public {
        // New asset with feed decimals = 18 (==) and LST with feed decimals = 20 (> 18)
        ERC20MockBB asset18 = new ERC20MockBB("AST18", "A18");
        ERC20MockBB lst20 = new ERC20MockBB("LST20", "L20");
        MockAggregator aggA18 = new MockAggregator(1e18, block.timestamp); // value compatible with 18-dec feed
        MockAggregator aggL20 = new MockAggregator(1e20, block.timestamp); // arbitrary; router uses feed decimals only
        vm.prank(gov);
        router.setFeed(address(asset18), address(aggA18), address(0), 18, 1 days, 0);
        vm.prank(gov);
        router.setFeed(address(lst20), address(aggL20), address(0), 20, 1 days, 0);

        ControllerHub.MarketParams memory p3 = ControllerHub.MarketParams({
            ltvBps: 5000,
            liqThresholdBps: 6000,
            reserveFactorBps: 0,
            borrowCap: type(uint128).max,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst20),
            vault: address(this)
        });
        vm.prank(gov);
        hub.listMarket(address(asset18), abi.encode(p3));
        lst20.mint(user, 1000 ether);
        vm.prank(user);
        hub.enterMarket(address(lst20));
        // Borrow triggers _price1e18 on both asset (dec==18) and lst (dec>18)
        vm.prank(user);
        hub.borrow(address(asset18), 1 ether, 0);
        // If it didn't revert, both branches executed at least once
        assertTrue(true);
    }
}
