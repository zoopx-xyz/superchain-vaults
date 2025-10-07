Simulation Report

Overview
Agent-based simulations explore borrow/withdraw concurrency, unwind+bridge clawbacks, and adversarial delivery patterns under varying caps, buffers, and IRM parameters.

Scenarios
- S1–S3: Baseline flows (deposit, borrow, repay, withdraw) sanity checks.
- S4: Prioritization under caps with whale withdraws vs retail borrows; verify pause signals and KPIs.
- S5: UNWIND+BRIDGE clawback latency vs buffers and bridge delays.
- S6: Duplicates/out-of-order delivery; idempotency and replay acceptance.
- S7: Sequencer-down behavior; queue-only withdrawals.

Methodology
- Deterministic time control with per-route delays.
- Parameter sweeps across:
  - borrowCap, withdrawalBufferBps
  - IRM: base, slope1, slope2, kinkBps
  - Oracle heartbeats and deviation thresholds
  - Bridge/messenger delays and duplication rates

KPIs Collected
- BorrowRequested, BorrowDecision, IRMRateUpdated, BorrowPaused
- WithdrawQueued/Fulfilled, RemoteLiquidityServed, BorrowPayout

Findings (preliminary)
- System prioritizes safety when caps are approached; borrows throttled as expected.
- Clawback timelines scale with bridge latency; larger local buffers reduce user-facing delay.
- Idempotency and replay guards eliminate overfills and duplicate effects.

Recommended Parameters (initial)
- kinkBps: 8000–9000; reserveFactorBps: 1000–3000; liqThresholdBps: ≥ LTV+1000.
- withdrawalBufferBps: 500–1500 depending on bridge latency.
- oracle heartbeat: ≤ 24h; maxDeviationBps: 300–700; sequencer grace: ≥ 900s.

Next Steps
- Automate scenario runs under /sim with CSV outputs.
- Calibrate parameters per target chain and liquidity profiles.
