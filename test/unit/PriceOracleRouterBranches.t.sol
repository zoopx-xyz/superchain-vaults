// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract ERC20StubDec { function decimals() external pure returns (uint8) { return 18; } }

contract PriceOracleRouterBranches is Test {
    PriceOracleRouter router;
    ERC20StubDec asset;
    address gov = address(0xA11CE);

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        asset = new ERC20StubDec();
    }

    function testSecondaryFallbackUsedWhenPrimaryUnusable() public {
        // Primary returns stale (heartbeat small and timestamp far in past), Secondary fresh -> should return secondary
    // Ensure current timestamp is sufficiently large before subtracting
    vm.warp(block.timestamp + 5 days);
    MockAggregator primary = new MockAggregator(1e8, block.timestamp);
    MockAggregator secondary = new MockAggregator(2e8, block.timestamp);
        vm.prank(gov);
        router.setFeed(address(asset), address(primary), address(secondary), 8, 1 days, 500);
    // Make primary stale explicitly
    primary.setUpdatedAt(block.timestamp - 3 days);
    (uint256 px,,) = router.getPrice(address(asset));
    assertEq(px, 2e8);
    }

    function testDeviationTooHighReverts() public {
        MockAggregator primary = new MockAggregator(100e8, block.timestamp);
        MockAggregator secondary = new MockAggregator(200e8, block.timestamp);
        vm.prank(gov);
        router.setFeed(address(asset), address(primary), address(secondary), 8, 1 days, 50); // 0.5% max dev
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        router.getPrice(address(asset));
    }
}
