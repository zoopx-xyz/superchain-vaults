# Economic & Math Security (ECONSEC)

This document records the threat model, math specifications, invariant set, and policy bounds for the Superchain Vaults protocol. It is meant to be reviewed alongside the code and tests to validate audit readiness.

## Scope
- Lending risk engine: `ControllerHub`
- Price safety: `PriceOracleRouter`
- Spoke vault orchestration: `SpokeYieldVault`
- Messaging & nonces: `SuperchainAdapter` and `SuperVaultHub`
- Strategy adapters: `BaseAdapter`, `AaveV3Adapter`, `VelodromeLPAdapter`

## Threat Model (non-exhaustive)
- Price/manipulation
  - Stale, deviating, or sequencer-downtime prices → Router enforces heartbeat/deviation/sequencer checks.
- Borrowing economics
  - Over-borrows due to parameter misconfiguration → Strict bounds in `listMarket`/`setParams` (LTV < LT, kink in [10%,95%], reserveFactor ≤ 50%, slope2 ≥ slope1, non-zero addresses).
  - Borrow caps → `setBorrowCap()` and enforced per market.
- Liquidations
  - Over-seize/under-seize → Close factor and liq bonus constants; seize computation uses consistent units and rounding via `Math.mulDiv`.
  - Liquidation while healthy → `_quoteAndValidateLiquidation` checks LT vs debt value.
- Reentrancy/adapter exploits
  - Adapters are `nonReentrant` and use `SafeERC20` transfers; vault transfers assets before external calls.
  - AMM cooldown to reduce sandwich/MEV round-trip on `VelodromeLPAdapter`.
- Messaging replay/idempotency
  - Per-channel nonces on `SuperchainAdapter`; `SuperVaultHub` nonce registry prevents replay.

## Math Specifications
- Fixed-point units
  - Ray: 1e27, Wad: 1e18, Bps: 1e4.
  - Indexes (`supplyIndexRay`, `debtIndexRay`) update linearly per second: idx ← idx × (1 + rate × dt).
- Utilization proxy
  - U = borrows / (borrows + 1) to avoid div-by-zero without cash accounting.
- IRM (kink model)
  - If U ≤ kink: rate = base + slope1 × U/kink
  - Else: rate = base + slope1 + slope2 × (U − kink)/(1 − kink)
- Health factor and liquidity
  - Account liquidity uses 1e18 prices and bps bounds; shortfall = max(0, debt − LT × collateral).
- Liquidation quote
  - ar = min(repayAmount, closeFactor × debt)
  - repayValue = ar × P(asset)
  - seizeValue = repayValue × (1 + liqBonus)
  - shares = seizeValue / P(lst)

## Invariants
- Indexes are monotonic non-decreasing over time when dt ≥ 0.
- `totalBorrows` respects borrow cap; never negative.
- Nonce uniqueness per messaging channel.
- Vault balances conserve except for controlled mint/burn events.
- Rewards accumulator is non-decreasing.

## Policy Bounds
- ltvBps < liqThresholdBps
- kinkBps ∈ [1000, 9500]
- reserveFactorBps ≤ 5000
- slope2Ray ≥ slope1Ray

## Implementation Defenses
- Reentrancy guards on adapters; SafeERC20 for all transfers.
- Spoke vault allocates by transfer-then-call; enforces adapter cap using `adapter.totalAssets() + delta ≤ cap`.
- Velodrome adapter enforces `cooldown` on withdraw.
- Controller parameters validated at list and set.
- Oracle validates heartbeat, deviation vs secondary, and L2 sequencer status.

## Testing & Coverage
- Unit tests cover:
  - Controller economics (borrow/LTV, liquidation, accrual, caps, pause flags).
  - Oracle failure modes (stale, deviation, sequencer).
  - Vault LST mint/burn, buffer serving, bridge flags.
  - Messaging allowlists and nonces.
  - Adapter flows and cooldown behavior.
- Coverage (lines): ≥ 90% per `forge coverage` summary.

## Operational Guidance
- Start with conservative borrow caps; adjust gradually.
- Monitor oracle feeds and set heartbeat/deviation consistent with asset liquidity.
- Set cooldown based on AMM conditions and governance risk appetite.

## Checklist (Go/No-Go)
- [x] All tests pass locally and in CI.
- [x] Coverage ≥ 90% lines, strong branches.
- [x] No high or medium Slither findings for protocol contracts.
- [x] Parameters within policy bounds.
- [x] Admin keys and upgradeability controls reviewed.
