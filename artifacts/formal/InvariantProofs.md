Invariant Proofs and Property Checks

This document summarizes encoded invariants, property tests, and their current status. It links test anchors and outlines any residual risks or assumptions.

Scope
- ControllerHub: IRM monotonicity, liquidation seize rounding-up, borrow cap enforcement, LTV < LT, utilization bounds, pause flags.
- SpokeYieldVault: nonce idempotency, withdraw queue no-overfill, bridge flags, local buffer semantics.
- SuperchainAdapter: replay protection, sender/selector allowlists, RELAYER_ROLE acceptance path.
- SuperVaultHub: nonce uniqueness, spoke registration integrity.
- Oracle Router: heartbeat, deviation, sequencer up checks.

Encoded Invariants (examples)
- NoncesInvariant: Nonces are unique and cannot be reused across hub/spoke/adapter paths. [test/invariant/NoncesInvariant.t.sol]
- SeizeRoundingUp: Liquidation seizes ceilDiv of shares; never under-seizes vs theoretical amount. [test/unit/ControllerHubPolicy.t.sol]
- IRM Rate Monotonicity: Borrow rate moves monotonically with utilization and respects kink constraints. [test/unit/ControllerHubPolicy.t.sol]
- No Overfill on Withdraw Fulfill: Duplicate or out-of-order fulfill cannot increase delivered assets beyond claim. [test/integration/CrossChainLendingWithdraw.t.sol]
- Oracle Guards: Heartbeat, deviation, and sequencer checks enforced centrally. [test/unit/PriceOracleRouter.t.sol]

Status
- Implemented tests passing with lines coverage ≥ 90%.
- Branch coverage gating introduced at 40% (to be raised progressively to 90%).

Residual Risks & Assumptions
- Economic parameters require per-chain calibration; see SimulationReport.md for recommended defaults.
- Bridge/messenger adversarial behavior modeled via mocks; real-world integrations may impose additional constraints.

Next Steps
- Add more property-based tests for fee/cap manipulation prevention and gas-compensation accounting conservation.
- Raise branch coverage threshold in CI as new tests land.
