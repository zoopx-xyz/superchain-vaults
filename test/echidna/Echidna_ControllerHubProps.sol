// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ControllerHub} from "contracts/hub/ControllerHub.sol";
import {PriceOracleRouter} from "contracts/hub/PriceOracleRouter.sol";
import {MockAggregator} from "contracts/mocks/MockAggregator.sol";

// Minimal ERC20 stub compatible with ControllerHub expectations
contract ERC20Mini {
    mapping(address => uint256) public balanceOf;
    function decimals() external pure returns (uint8) { return 18; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

// Echidna property harness for ControllerHub
// - Uses simple wrappers so Echidna can fuzz borrow/repay and pause toggles
// - Ensures total borrows never exceed the configured borrowCap
// - Ensures pause flag prevents borrow growth
contract Echidna_ControllerHubProps {
    ControllerHub public hub;
    PriceOracleRouter public router;
    ERC20Mini public asset;
    ERC20Mini public lst;
    MockAggregator public aggAsset;
    MockAggregator public aggLst;

    constructor() {
        // governor is this harness contract so Echidna can call governor-only methods through wrappers
        router = new PriceOracleRouter();
        router.initialize(address(this));
        hub = new ControllerHub();
        hub.initialize(address(this), address(router));

        // set up assets and price feeds
        asset = new ERC20Mini();
        lst = new ERC20Mini();
        aggAsset = new MockAggregator(1e8, block.timestamp);
        aggLst = new MockAggregator(1e8, block.timestamp);
        router.setFeed(address(asset), address(aggAsset), address(0), 8, 1 days, 0);
        router.setFeed(address(lst), address(aggLst), address(0), 8, 1 days, 0);

        // list a market with sane parameters
        ControllerHub.MarketParams memory p = ControllerHub.MarketParams({
            ltvBps: 5000,
            liqThresholdBps: 6000,
            reserveFactorBps: 1000,
            borrowCap: 1_000_000 ether,
            kinkBps: 8000,
            slope1Ray: 1e16,
            slope2Ray: 2e16,
            baseRateRay: 0,
            lst: address(lst),
            vault: address(this)
        });
        hub.listMarket(address(asset), abi.encode(p));

        // enter market with some collateral
        lst.mint(address(this), 1_000_000 ether);
        hub.enterMarket(address(lst));
    }

    // Fuzz entrypoints (Echidna will generate sequences of these calls)
    function borrow(uint256 amt) public {
        uint256 a = amt % (10_000 ether);
        // swallow reverts to allow Echidna to explore invalid inputs too
        try hub.borrow(address(asset), a, 0) { } catch { }
    }

    function repay(uint256 amt) public {
        uint256 a = amt % (10_000 ether);
        try hub.repay(address(asset), a, 0) { } catch { }
    }

    function setPause(bool pauseBorrow, bool pauseLiq) public {
        // governor-only; ok since governor is this harness contract
        hub.setPause(pauseBorrow, pauseLiq);
    }

    // Properties
    function echidna_total_borrows_never_exceed_cap() public returns (bool) {
        (ControllerHub.MarketState memory s, ControllerHub.MarketParams memory p, ) = hub.marketStateExtended(address(asset));
        return s.totalBorrows <= p.borrowCap;
    }

    function echidna_pause_blocks_borrow_growth() public returns (bool) {
        // snapshot borrows, enable borrow pause, try to borrow, ensure not increased
        (ControllerHub.MarketState memory sBefore, , ) = hub.marketStateExtended(address(asset));
        hub.setPause(true, false);
        // attempt to increase borrows
        try hub.borrow(address(asset), 1 ether, 0) { } catch { }
        (ControllerHub.MarketState memory sAfter, , ) = hub.marketStateExtended(address(asset));
        // best-effort: unpause to not poison further sequences
        hub.setPause(false, false);
        return sAfter.totalBorrows <= sBefore.totalBorrows;
    }
}
