// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract MockSequencerOracle {
    int256 public up = 1;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setUp(int256 v) external {
        up = v;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        // Return updatedAt as the latest update timestamp
        return (0, up, 0, updatedAt, 0);
    }
}

contract PriceOracleRouterTest is Test {
    PriceOracleRouter router;
    address gov = address(0xA11CE);
    MockAggregator primary;
    MockAggregator secondary;

    function setUp() public {
        router = new PriceOracleRouter();
        router.initialize(gov);
        primary = new MockAggregator(1e8, block.timestamp);
        secondary = new MockAggregator(1e8, block.timestamp);
    }

    function testGetPriceBasic() public {
        vm.prank(gov);
        router.setFeed(address(0xAA), address(primary), address(0), 8, 1 days, 0);
        (uint256 p, uint8 dec, uint256 t) = router.getPrice(address(0xAA));
        assertEq(p, 1e8);
        assertEq(dec, 8);
        assertEq(t, block.timestamp);
    }

    function testHeartbeatStaleReverts() public {
        vm.prank(gov);
        router.setFeed(address(0xBB), address(primary), address(0), 8, 1 days, 0);
        vm.warp(block.timestamp + 3 days);
        primary.setUpdatedAt(block.timestamp - 2 days);
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        router.getPrice(address(0xBB));
    }

    function testSecondaryDeviationCheck() public {
        vm.prank(gov);
        router.setFeed(address(0xCC), address(primary), address(secondary), 8, 1 days, 500); // 5%
        // within deviation
        primary.setAnswer(100_00000000);
        secondary.setAnswer(102_00000000); // 2% higher
        router.getPrice(address(0xCC));
        // exceed deviation
        secondary.setAnswer(107_00000000); // 7% higher
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        router.getPrice(address(0xCC));
    }

    function testSequencerDownReverts() public {
        MockSequencerOracle seq = new MockSequencerOracle();
        vm.prank(gov);
        router.setSequencerOracle(address(seq));
        vm.prank(gov);
        router.setFeed(address(0xDD), address(primary), address(0), 8, 1 days, 0);
        seq.setUp(0); // sequencer down
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        router.getPrice(address(0xDD));
        // back up & stale sequencer -> should revert due to heartbeat
        seq.setUp(1);
        vm.warp(block.timestamp + 3 hours);
        seq.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        router.getPrice(address(0xDD));
        // healthy
        seq.setUpdatedAt(block.timestamp);
        router.getPrice(address(0xDD));
    }
}
