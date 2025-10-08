// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20StubDecB { function decimals() external pure returns (uint8) { return 8; } }

contract PriceOracleRouterBounds is Test {
    PriceOracleRouter router; address gov=address(0xA11CE); ERC20StubDecB asset;

    function setUp() public { router = new PriceOracleRouter(); router.initialize(gov); asset = new ERC20StubDecB(); }

    function testPrimaryOutOfBoundsUsesSecondary() public {
        MockAggregator primary = new MockAggregator(100e8, block.timestamp);
        MockAggregator secondary = new MockAggregator(50e8, block.timestamp);
        vm.prank(gov); router.setFeed(address(asset), address(primary), address(secondary), 8, 1 days, 1_000);
        vm.prank(gov); router.setFeedBounds(address(asset), 1, 90e8); // primary 100e8 is out of bounds; secondary 50e8 is in bounds
        (uint256 px,,) = router.getPrice(address(asset));
        assertEq(px, 50e8);
    }

    function testBothOutOfBoundsReverts() public {
        MockAggregator primary = new MockAggregator(0, block.timestamp); // below min
        MockAggregator secondary = new MockAggregator(0, block.timestamp);
        vm.prank(gov); router.setFeed(address(asset), address(primary), address(secondary), 8, 0, 1_000);
        vm.prank(gov); router.setFeedBounds(address(asset), 1, type(int256).max);
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        router.getPrice(address(asset));
    }
}
