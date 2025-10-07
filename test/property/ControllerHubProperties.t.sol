// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

interface IERC20Simple {
    function balanceOf(address) external view returns (uint256);
}

contract ERC20MockSimple {
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

contract SeizeSinkProp {
    event Seized(address user, uint256 shares, address to);

    uint256 public lastShares;

    function onSeizeShares(address user, uint256 shares, address to) external {
        lastShares = shares;
        emit Seized(user, shares, to);
    }
}

contract ControllerHubProperties is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20MockSimple asset;
    ERC20MockSimple lst;
    SeizeSinkProp sink;
    MockAggregator aggAsset;
    MockAggregator aggLst;
    address gov = address(0xA11CE);
    address user = address(0xBEEF);

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new ERC20MockSimple("ASSET", "AST");
        lst = new ERC20MockSimple("LST", "LST");
        sink = new SeizeSinkProp();
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
        lst.mint(user, 1_000 ether);
        vm.prank(user);
        hub.enterMarket(address(lst));
    }

    // Property: setParams/listMarket respect policy bounds across fuzzed inputs
    function testFuzz_ParamsPolicyBounds(uint16 ltv, uint16 lt, uint16 kink, uint16 rf, uint128 s1, uint128 s2)
        public
    {
        // Constrain to valid ranges
        vm.assume(lt > ltv);
        vm.assume(kink >= 1000 && kink <= 9500);
        vm.assume(rf <= 5000);
        vm.assume(s2 >= s1);
        ControllerHub.MarketParams memory p = ControllerHub.MarketParams({
            ltvBps: ltv,
            liqThresholdBps: lt,
            reserveFactorBps: rf,
            borrowCap: 1_000 ether,
            kinkBps: kink,
            slope1Ray: s1,
            slope2Ray: s2,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(sink)
        });
        // listMarket with valid params should succeed
        vm.prank(gov);
        hub.listMarket(address(asset), abi.encode(p));
        // setParams with the same should also succeed
        vm.prank(gov);
        hub.setParams(address(asset), abi.encode(p));
    }

    // Property: borrow cap cannot be bypassed via multiple borrows
    function testFuzz_BorrowCapEnforced(uint128 capRaw, uint128 a1, uint128 a2) public {
        uint256 cap = 1 + (uint256(capRaw) % (200 ether));
        vm.prank(gov);
        hub.setBorrowCap(address(asset), cap);
        // Scale borrow amounts into a reasonable range
        uint256 b1 = uint256(a1 % cap);
        uint256 b2 = uint256(a2 % cap);
        // Ensure sufficient collateral
        vm.startPrank(user);
        // Borrow b1 and b2 if they fit; both should not exceed cap combined
        if (b1 > 0 && b1 <= cap) {
            hub.borrow(address(asset), b1, 0);
        }
        uint256 used = b1;
        if (b2 > 0 && used + b2 <= cap) {
            hub.borrow(address(asset), b2, 0);
            used += b2;
        } else if (b2 > 0 && used < cap) {
            // Next borrow that would exceed cap must revert
            vm.expectRevert(abi.encodeWithSignature("ExceedsBorrowCap()"));
            hub.borrow(address(asset), cap - used + 1, 0);
        }
        vm.stopPrank();
    }

    // Property: liquidation value/seizure conservation with bonus and rounding up
    function testFuzz_LiquidationConservation(uint128 repayRaw) public {
        // Setup: borrow at cap to ensure unhealthy after price shock
        vm.prank(user);
        hub.borrow(address(asset), 100 ether, 0);
        // Apply stronger price shock to make user liquidatable reliably
        aggLst.setAnswer(1e7); // price = 0.1
        // Choose repay amount up to close factor. Ensure non-zero repay.
        uint256 debt = hub.currentDebt(user, address(asset));
        uint256 maxRepay = (debt * hub.CLOSE_FACTOR_BPS()) / hub.BPS();
        vm.assume(maxRepay > 0);
        uint256 repay = 1 + (uint256(repayRaw) % maxRepay);
        // Observe debt before/after
        uint256 debtBefore = hub.currentDebt(user, address(asset));
        hub.liquidate(user, address(asset), repay, address(lst), address(this));
        uint256 debtAfter = hub.currentDebt(user, address(asset));
        uint256 actualRepaid = debtBefore - debtAfter;
        // actual repaid cannot exceed close factor of debt
        assertLe(actualRepaid, maxRepay);
        // seized shares must be non-zero due to ceilDiv when repay>0
        assertGt(sink.lastShares(), 0);
        // Value conserved with bonus: seizeValue >= repayValue * (1 + bonus)
        // Use router to get normalized prices
        (uint256 pAsset,,) = router.getPrice(address(asset));
        (uint256 pLst,,) = router.getPrice(address(lst));
        // normalize to 1e18
        uint256 pA18 = pAsset * 1e10;
        uint256 pL18 = pLst * 1e10;
        uint256 repayValue = (actualRepaid * pA18) / 1e18;
        uint256 seizeValue = (sink.lastShares() * pL18) / 1e18;
        uint256 minSeize = (repayValue * (10_000 + hub.LIQ_BONUS_BPS())) / hub.BPS();
        assertGe(seizeValue, minSeize);
    }
}
