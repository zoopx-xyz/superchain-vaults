// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20Mini {
    string public name; string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function decimals() external pure returns (uint8) { return 18; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; emit Transfer(address(0), to, a); }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function transfer(address t, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[t] += a; emit Transfer(msg.sender, t, a); return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) { uint256 al = allowance[f][msg.sender]; require(al >= a, "ALW"); if (al != type(uint256).max) allowance[f][msg.sender] = al - a; balanceOf[f] -= a; balanceOf[t] += a; emit Transfer(f, t, a); return true; }
}

contract ControllerHubEdgeBranches is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20Mini asset;
    ERC20Mini lst;
    MockAggregator aggAsset;
    MockAggregator aggLst;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    // minimal vault sink to allow liquidations
    event Seized(address indexed user, uint256 shares, address indexed to);
    uint256 public lastSeizedShares;
    function onSeizeShares(address u, uint256 sh, address to) external { lastSeizedShares = sh; emit Seized(u, sh, to); }

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new ERC20Mini("ASSET", "AST");
        lst = new ERC20Mini("LST", "LST");
        aggAsset = new MockAggregator(1e8, block.timestamp); // price = 1 with 8 decimals
        aggLst = new MockAggregator(1e8, block.timestamp);   // price = 1 with 8 decimals
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
        lst.mint(user, 1_000 ether);
    }

    function testBorrowWithoutEnteringMarketReverts() public {
        // user did not call enterMarket; should fail _isBorrowAllowed gate
        vm.expectRevert(abi.encodeWithSignature("InsufficientCollateral()"));
        vm.prank(user);
        hub.borrow(address(asset), 1 ether, 0);
    }

    function testBorrowAboveLTVRevertsInsufficientCollateral() public {
        // enter market but try to borrow above LTV cap
        vm.prank(user); hub.enterMarket(address(lst));
        // With 1000 LST and LTV 50%, max borrow value is 500; ask for 600
        vm.expectRevert(abi.encodeWithSignature("InsufficientCollateral()"));
        vm.prank(user);
        hub.borrow(address(asset), 600 ether, 0);
    }

    function testLiquidationCapsAtCloseFactorAndRoundsUpShares() public {
        vm.prank(user); hub.enterMarket(address(lst));
        // Borrow within LTV (500), then make user unhealthy by dropping LST price
        vm.prank(user); hub.borrow(address(asset), 500 ether, 0);
        // Drop LST price to 0.4 so liq condition holds (liqLimit = 1000*0.4*0.6 = 240 < debt 1000)
        aggLst.setAnswer(4e7);
        // repayAmount >> closeFactor to force ar=min(path) => 50% of 500 = 250
        uint256 debtBefore = hub.currentDebt(user, address(asset));
        hub.liquidate(user, address(asset), 1_000_000 ether, address(lst), address(this));
        uint256 debtAfter = hub.currentDebt(user, address(asset));
        // Close factor applied: repaid should be ~250 (ignore interest as rate is zero)
        assertEq(debtBefore - debtAfter, 250 ether);
        // Shares seized should be non-zero and rounded up via ceilDiv path
        assertGt(lastSeizedShares, 0);
    }

    function testGovernorTwoStepAcceptSuccess() public {
        address newGov = address(0xCAFE);
        vm.prank(gov); hub.proposeGovernor(newGov);
        vm.prank(newGov); hub.acceptGovernor();
        // New governor should have permission to call governor-only function
        vm.prank(newGov); hub.setBorrowCap(address(asset), 123 ether);
        // Old governor should no longer have the role
        vm.expectRevert();
        vm.prank(gov); hub.setBorrowCap(address(asset), 1 ether);
    }

    function testSetParamsHappyPathUpdates() public {
        // Read current params via marketStateExtended
        ( , ControllerHub.MarketParams memory pBefore, ) = hub.marketStateExtended(address(asset));
        ControllerHub.MarketParams memory p = pBefore;
        // Slightly tweak a few values within bounds to traverse all guard "false" branches
        p.reserveFactorBps = 2000;
        p.kinkBps = 8500;
        p.baseRateRay = 1e15; // non-zero
        p.slope1Ray = 1e16;
        p.slope2Ray = 2e16; // slope2 >= slope1
        p.borrowCap = type(uint128).max;
        vm.prank(gov);
        hub.setParams(address(asset), abi.encode(p));
        // Verify a value updated
        ( , ControllerHub.MarketParams memory pAfter, ) = hub.marketStateExtended(address(asset));
        assertEq(pAfter.reserveFactorBps, 2000);
        assertEq(pAfter.kinkBps, 8500);
    }

    function testAccountLiquidityPerAsset_ShortfallZeroAndPositive() public {
        vm.prank(user); hub.enterMarket(address(lst));
        // With 1000 LST at price 1, LT=60%, borrow 300 => below liq threshold so no shortfall
        vm.prank(user); hub.borrow(address(asset), 300 ether, 0);
        (uint256 coll, uint256 debt, uint256 shortfall) = hub.accountLiquidity(user, address(asset));
        assertGt(coll, 0);
        assertGt(debt, 0);
        assertEq(shortfall, 0);
        // Now drop LST price to 0.4 so shortfall becomes positive
        aggLst.setAnswer(4e7);
        ( , , uint256 shortfall2) = hub.accountLiquidity(user, address(asset));
        assertGt(shortfall2, 0);
    }
}
