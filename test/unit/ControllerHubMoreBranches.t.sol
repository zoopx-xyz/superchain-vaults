// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20MockMB {
    string public name; string public symbol;
    mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 amount); event Approval(address indexed owner,address indexed spender,uint256 amount);
    constructor(string memory n,string memory s){name=n;symbol=s;}
    function decimals() external pure returns(uint8){return 18;}
    function transfer(address to,uint256 a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; emit Transfer(msg.sender,to,a); return true; }
    function approve(address s,uint256 a) external returns(bool){ allowance[msg.sender][s]=a; emit Approval(msg.sender,s,a); return true; }
    function transferFrom(address f,address t,uint256 a) external returns(bool){ uint256 al=allowance[f][msg.sender]; require(al>=a,"ALW"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; balanceOf[f]-=a; balanceOf[t]+=a; emit Transfer(f,t,a); return true; }
    function mint(address to,uint256 a) external { balanceOf[to]+=a; emit Transfer(address(0),to,a);}    
}

contract ControllerHubMoreBranches is Test {
    ControllerHub hub; PriceOracleRouter router; ERC20MockMB asset; ERC20MockMB lst; MockAggregator aggAsset; MockAggregator aggLst;
    address gov = address(0xA11CE); address user = address(0xBEEF);

    function setUp() public {
        router = new PriceOracleRouter(); router.initialize(gov);
        hub = new ControllerHub(); hub.initialize(gov, address(router));
        asset = new ERC20MockMB("ASSET","AST"); lst = new ERC20MockMB("LST","LST");
        aggAsset = new MockAggregator(1e8, block.timestamp); aggLst = new MockAggregator(1e8, block.timestamp);
        vm.prank(gov); router.setFeed(address(asset), address(aggAsset), address(0), 8, 1 days, 0);
        vm.prank(gov); router.setFeed(address(lst), address(aggLst), address(0), 8, 1 days, 0);
    }

    function _params() internal view returns (ControllerHub.MarketParams memory p) {
        p = ControllerHub.MarketParams({
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
    }

    function testListMarket_InvalidParamsBranches() public {
        // asset zero
        ControllerHub.MarketParams memory p = _params();
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(0), abi.encode(p));
        // lst zero
        p.lst = address(0);
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
        // liqThreshold <= ltv
        p = _params(); p.liqThresholdBps = 5000; p.ltvBps = 5000;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
        // kink too low
        p = _params(); p.kinkBps = 999;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
        // kink too high
        p = _params(); p.kinkBps = 9501;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
        // reserve factor too high
        p = _params(); p.reserveFactorBps = 5001;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
        // slope2 < slope1
        p = _params(); p.slope1Ray = 2e16; p.slope2Ray = 1e16;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
    }

    function testSetParams_InvalidParamsBranches() public {
        // First list a valid market
        ControllerHub.MarketParams memory ok = _params();
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(ok));
        // Now attempt bad updates on setParams
        ControllerHub.MarketParams memory p;
        p = ok; p.lst = address(0);
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.setParams(address(asset), abi.encode(p));
        p = ok; p.liqThresholdBps = 4000; p.ltvBps = 4500;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.setParams(address(asset), abi.encode(p));
        p = ok; p.kinkBps = 999;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.setParams(address(asset), abi.encode(p));
        p = ok; p.kinkBps = 9501;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.setParams(address(asset), abi.encode(p));
        p = ok; p.reserveFactorBps = 5001;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.setParams(address(asset), abi.encode(p));
        p = ok; p.slope1Ray = 2e16; p.slope2Ray = 1e16;
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.setParams(address(asset), abi.encode(p));
    }

    function testAccrueAndBorrow_NotListedReverts() public {
        // accrue on not listed asset
        vm.expectRevert(abi.encodeWithSignature("MarketNotListed()"));
        hub.accrue(address(0xDEAD));
        // borrow on not listed asset
        vm.expectRevert(abi.encodeWithSignature("MarketNotListed()"));
        hub.borrow(address(asset), 1 ether, 0);
    }

    function testExitMarketHealthyPathAndProposeGovZeroReverts() public {
        // list and enter then exit when healthy
        ControllerHub.MarketParams memory p = _params();
        vm.prank(gov); hub.listMarket(address(asset), abi.encode(p));
        lst.mint(user, 100 ether);
        vm.prank(user); hub.enterMarket(address(lst));
        vm.prank(user); hub.exitMarket(address(lst));
        // propose zero governor should revert
        vm.expectRevert(abi.encodeWithSignature("InvalidParams()"));
        vm.prank(gov); hub.proposeGovernor(address(0));
    }

    function testAcceptGovernorNotPendingReverts() public {
        vm.expectRevert(bytes("NOT_PENDING"));
        hub.acceptGovernor();
    }
}
