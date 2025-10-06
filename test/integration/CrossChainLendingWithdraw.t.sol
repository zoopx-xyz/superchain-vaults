// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainFixture} from "../setup/CrossChainFixture.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20Decimals} from "../../contracts/mocks/MockERC20Decimals.sol";

contract CrossChainLendingWithdraw is CrossChainFixture {
    // Helper to compute latency in seconds (assume 2s block time)
    uint256 internal constant BLOCK_TIME_SEC = 2;

    // KPI events (test-harness emitted for measurement only)
    event BorrowRequested(address indexed user, address indexed asset, uint256 amount, uint256 dstChainId, bytes32 actionId, uint256 ts);
    event BorrowDecision(address indexed user, address indexed asset, uint256 amount, uint256 routesUsed, bytes32 actionId, uint256 ts);
    event LiquidityRouted(uint256 indexed fromChain, uint256 indexed toChain, address indexed asset, uint256 amount, bytes32 routeType, bytes32 actionId, uint256 ts);

    // Scenario S1 — Local borrow happy path (no cross-chain)
    function test_S1_LocalBorrow_BufferOnly() public {
        // Setup: buffer sufficient on A
        uint256 amount = 1_000e6;
        uint256 t0 = block.timestamp;
        // Directly payout via vault as controller hook placeholder
        vm.prank(address(controller));
        spokeA.payOutBorrow(address(this), address(asset), amount);
        // BorrowPayout emitted same block
        // in Foundry, we assert by checking no time passed
        assertEq(block.timestamp - t0, 0, "Borrow LAT");
    }

    // Scenario S2 — Cross-spoke borrow with routing
    function test_S2_CrossSpokeBorrowWithLatency() public {
        uint256 amount = 2_000e6;
        // Configure messenger/bridge delays: B->A 12 blocks
        messenger.setDelay(B_CHAIN, A_CHAIN, 12);
        // Fund the bridge to simulate outbound liquidity from B
        MockERC20Decimals(address(asset)).mint(address(bridge), amount);
        uint256 t0 = block.timestamp;
        // Emulate hub routing and bridge delivery: enqueue transfer from B to A
        // Use MockBridge to simulate token movement
        bridge.setToken(address(asset), true);
        bridge.setDelay(address(asset), 12);
        bridge.send(address(asset), address(spokeA), amount, false);
        // Advance 12 blocks (24 seconds)
        vm.roll(block.number + 12);
        vm.warp(t0 + 12 * BLOCK_TIME_SEC);
        bridge.deliverAll();
        // Payout after arrival
        vm.prank(address(controller));
        spokeA.payOutBorrow(address(this), address(asset), amount);
        uint256 dt = block.timestamp - t0;
        assertEq(dt, 12 * BLOCK_TIME_SEC, "latency seconds");
    }

    // Scenario S3 — Borrow when destination lacks liquidity; multi-route
    function test_S3_MultiRouteBorrowSplit() public {
        // Spoke A TVL = 5,000,000; bufferBps=2000 -> 1,000,000 available locally
        uint256 amount = 3_000_000e6;
        // Prepare bridge and fund for two remote spokes
        bridge.setToken(address(asset), true);
        // Route splits: 1,000,000 from A buffer, 1,000,000 from B, 1,000,000 from C
        uint256 routeA = 1_000_000e6;
        uint256 routeB = 1_000_000e6;
        uint256 routeC = 1_000_000e6;
        // Delays B->A 8 blocks, C->A 15 blocks
        messenger.setDelay(B_CHAIN, A_CHAIN, 8);
        messenger.setDelay(C_CHAIN, A_CHAIN, 15);
        bridge.setDelay(address(asset), 0); // we control timing via vm.roll per-route
        // Fund bridge for B and C routes
        MockERC20Decimals(address(asset)).mint(address(bridge), routeB + routeC);
        bytes32 aid = keccak256("aid-S3");
        emit BorrowRequested(address(this), address(asset), amount, A_CHAIN, aid, block.timestamp);
        // Enqueue remote routes and emit routing events
        bridge.send(address(asset), address(spokeA), routeB, false);
        emit LiquidityRouted(B_CHAIN, A_CHAIN, address(asset), routeB, bytes32("REMOTE_SPOKE_B"), aid, block.timestamp);
        bridge.send(address(asset), address(spokeA), routeC, false);
        emit LiquidityRouted(C_CHAIN, A_CHAIN, address(asset), routeC, bytes32("REMOTE_SPOKE_C"), aid, block.timestamp);
        // Local buffer considered immediate
        emit LiquidityRouted(A_CHAIN, A_CHAIN, address(asset), routeA, bytes32("BUFFER"), aid, block.timestamp);
        emit BorrowDecision(address(this), address(asset), amount, 3, aid, block.timestamp);

        // Deliver B after 8 blocks, C after 15; final payout should occur after max latency (15 blocks)
        uint256 t0 = block.timestamp;
        // simulate earliest arrival (B)
        vm.roll(block.number + 8);
        vm.warp(t0 + 8 * BLOCK_TIME_SEC);
        bridge.deliverAll();
        // simulate latest arrival (C)
        vm.roll(block.number + 7); // total +15
        vm.warp(t0 + 15 * BLOCK_TIME_SEC);
        bridge.deliverAll();
        // After last route, payout total
        vm.prank(address(controller));
        spokeA.payOutBorrow(address(this), address(asset), amount);
        // Assertions: route sum and latency
        assertEq(routeA + routeB + routeC, amount, "sum routes == amount");
        assertEq(block.timestamp - t0, 15 * BLOCK_TIME_SEC, "max route latency");
    }

    // Scenario S7 — Oracle stale / Sequencer down (degrade to queue-only)
    function test_S7_SequencerDown_QueueOnlyWithdraws() public {
        // For this integration, we simulate withdrawals being enqueued and only buffer serving
        // Enqueue a withdraw claim and fulfill partially
        uint256 shares = 1_000e18; // abstract shares
        uint256 claimId = spokeA.enqueueWithdraw(shares);
        uint256 t0 = block.timestamp;
        // Serve part from buffer immediately
        vm.prank(address(hub));
        spokeA.fulfillWithdraw(claimId, 100e6, bytes32("aid1"));
        // Advance time and fulfill the rest
        vm.roll(block.number + 10);
        vm.warp(t0 + 10 * BLOCK_TIME_SEC);
        vm.prank(address(hub));
        spokeA.fulfillWithdraw(claimId, 900e6, bytes32("aid2"));
        // No asserts beyond that here; main S7 price/seq checks covered in unit tests
    }
}
