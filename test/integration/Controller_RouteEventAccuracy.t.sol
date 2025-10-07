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

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

contract Controller_RouteEventAccuracy is Test {
    ControllerHub hub;
    PriceOracleRouter router;
    ERC20Mock asset;
    ERC20Mock lst;
    address gov = address(0xA11CE);

    event BorrowDecision(
        address indexed user, address indexed asset, uint256 amount, uint8 routesUsed, bytes32 actionId, uint256 ts
    );

    function setUp() public {
        vm.startPrank(gov);
        router = new PriceOracleRouter();
        router.initialize(gov);
        hub = new ControllerHub();
        hub.initialize(gov, address(router));
        asset = new ERC20Mock("ASSET", "AST");
        lst = new ERC20Mock("LST", "LST");
        router.setFeed(address(asset), address(new AggregatorMock(1e18)), address(0), 18, 0, 10_000);
        router.setFeed(address(lst), address(new AggregatorMock(1e18)), address(0), 18, 0, 10_000);
        ControllerHub.MarketParams memory p = ControllerHub.MarketParams({
            ltvBps: 6000,
            liqThresholdBps: 8000,
            reserveFactorBps: 1000,
            borrowCap: 1e36,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 1e15,
            lst: address(lst),
            vault: address(0)
        });
        hub.listMarket(address(asset), abi.encode(p));
        vm.stopPrank();
        hub.enterMarket(address(lst));
        lst.mint(address(this), 100 ether);
    }

    function testBorrowDecisionReportsSingleRoute() public {
        // Only check user, asset, amount, and routesUsed; actionId and ts are dynamic
        vm.expectEmit(true, true, true, false);
        emit BorrowDecision(address(this), address(asset), 10 ether, 1, bytes32(0), 0);
        hub.borrow(address(asset), 10 ether, block.chainid);
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
