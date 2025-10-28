// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

contract Echidna_PriceOracleRouterProps {
    PriceOracleRouter public router;
    MockAggregator public primary;
    MockAggregator public secondary;
    address public asset;

    constructor() {
        router = new PriceOracleRouter();
        router.initialize(address(this));
        primary = new MockAggregator(1e8, block.timestamp);
        secondary = new MockAggregator(1e8, block.timestamp);
        asset = address(0xBEEF);
        router.setFeed(asset, address(primary), address(secondary), 8, 1 days, 500); // 5% max dev
        router.setFeedBounds(asset, 1, type(int256).max);
    }

    // Mutators for Echidna
    function setPrimary(int256 ans, uint256 ts) public {
        primary.setAnswer(ans);
        primary.setUpdatedAt(ts);
    }

    function setSecondary(int256 ans, uint256 ts) public {
        secondary.setAnswer(ans);
        secondary.setUpdatedAt(ts);
    }

    function setSequencer(address oracle) public {
        // allow fuzz to toggle sequencer oracle; if unset, sequencer checks are skipped
        router.setSequencerOracle(oracle);
    }

    // Properties
    function echidna_primary_used_when_fresh_in_bounds() public returns (bool) {
        // Ensure primary fresh and in bounds; getPrice should not revert and return primary
        primary.setAnswer(1e8);
        primary.setUpdatedAt(block.timestamp);
        // secondary slightly deviates within 5%
        secondary.setAnswer(int256(97_000_000));
        secondary.setUpdatedAt(block.timestamp);
        (uint256 p,,) = router.getPrice(asset);
        return p == 1e8;
    }

    function echidna_secondary_fallback_when_primary_bad() public returns (bool) {
        // Make primary stale; ensure secondary fresh and used
        primary.setAnswer(1e8);
        primary.setUpdatedAt(block.timestamp - 10 days);
        secondary.setAnswer(90_000_000);
        secondary.setUpdatedAt(block.timestamp);
        (uint256 p,,) = router.getPrice(asset);
        return p == 90_000_000;
    }
}
