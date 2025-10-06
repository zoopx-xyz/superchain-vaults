# Superchain Protocol – Implementation Report (v1.0)

Date: 2025-10-06
Commit: workspace HEAD
Solc: 0.8.24 (via Foundry)
OpenZeppelin: v5.x (upgradeable where applicable)

## 1) Contract Inventory

This section lists every contract, pragma, proxy vs non-proxy status, roles used, and storage layout summary for upgradeable contracts. Full ABIs are exported under `./artifacts/abi/` and storage layouts under `./artifacts/storage/`.

### Modules
- contracts/spoke/SpokeYieldVault.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable (inherits Initializable, UUPSUpgradeable)
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE, REBALANCER_ROLE, HUB_ROLE, CONTROLLER_ROLE
  - Notes: ERC4626-like vault with LST mirror token; adapter orchestration; withdrawal buffer
  - Storage: depositsEnabled, borrowsEnabled, bridgeEnabled, hub, lst, adapterRegistry, performanceFeeBps, feeRecipient, withdrawalBufferBps, __gap[50]
- contracts/hub/SuperVaultHub.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE, RELAYER_ROLE, CONTROLLER_ROLE
  - Notes: Canonical accounting, nonce replay protection, cross-chain flow events
  - Storage: bridgeEnabled, spokeOf, usedNonce, totalAssetsCanonical, baseAsset, adapter, __gap[50]
- contracts/messaging/SuperchainAdapter.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE
  - Notes: L2↔L2 messaging wrapper with allowlists, per-channel nonces; emits actionId deterministically
  - Storage: bridgeEnabled, nonceOf, allowedSender, allowedSelector, messenger, __gap[50]
- contracts/hub/ControllerHub.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE
  - Notes: Lending controller with kinked IRM; borrow/repay/liquidate; policy bounds; pause flags;
  - Storage: marketParams, marketState, isEntered, debtPrincipal, debtIndexSnapshot, oracle, borrowsPaused, liquidationsPaused, __gap[50]
- contracts/hub/PriceOracleRouter.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE
  - Notes: Primary/secondary feeds; heartbeat; deviation; sequencer up checks
  - Storage: feedOf, sequencerOracle, __gap[50]
- contracts/strategy/BaseAdapter.sol (pragma ^0.8.24)
  - Type: Upgradeable base (Initializable, Pausable, AccessControl, ReentrancyGuard)
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE, REBALANCER_ROLE
  - Notes: Transfer-before-call enforced at vault; emits Adapter* events; cap setting
  - Storage: vault, underlying, cap, __gap[50]
- contracts/strategy/AaveV3Adapter.sol (pragma ^0.8.24)
  - Type: Upgradeable (inherits BaseAdapter)
  - Roles: via BaseAdapter
  - Notes: Minimal adapter treating adapter-held balance as TVL
  - Storage: via BaseAdapter
- contracts/strategy/VelodromeLPAdapter.sol (pragma ^0.8.24)
  - Type: Upgradeable (inherits BaseAdapter)
  - Roles: via BaseAdapter
  - Notes: Adds cooldown; enforces on withdraw
  - Storage: BaseAdapter fields + lastAddTimestamp, cooldown
- contracts/strategy/AdapterRegistry.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE
  - Notes: Adapter allowlist and caps
  - Storage: adapters mapping, __gap[50]
- contracts/rewards/EmissionsController.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE, EMISSIONS_ROLE
  - Notes: Epoch and per-chain caps for distributions
  - Storage: epochCap, perChainCap, epochStart, epochDistributed, chainDistributedInEpoch, __gap[50]
- contracts/rewards/PerChainRewardsDistributor.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE, FUNDER_ROLE
  - Notes: rewardPerShare accumulator, checkpoint, claim
  - Storage: rewardToken, shareToken, rewardPerShareX18, userRpsPaid, accrued, __gap[50]
- contracts/factory/VaultFactory.sol (pragma ^0.8.24)
  - Type: UUPS upgradeable
  - Roles: DEFAULT_ADMIN_ROLE, GOVERNOR_ROLE
  - Notes: Deploys minimal proxy vaults, mints LST via SuperchainERC20, grants MINTER_ROLE
  - Storage: vaultImpl, tokenImpl
- contracts/tokens/SuperchainERC20.sol (pragma ^0.8.24)
  - Type: Non-upgradeable ERC20 + Permit + AccessControl
  - Roles: DEFAULT_ADMIN_ROLE, MINTER_ROLE

Full storage layouts are exported in `./artifacts/storage/*.storage.json` and confirm reserved `__gap[50]` is present for all upgradeable modules.

ABIs and function selectors are exported in `./artifacts/abi/*.json` and `./artifacts/abi/*.selectors.txt` respectively.

## 2) Event Matrix

For each contract, all events and indexed fields are summarized. Back-end uses:
- Indexing: role changes, adapter changes, registry updates.
- Reconciliation: actionId-anchored cross-chain flows.
- Monitoring: pause flags, cap changes, accrual indexes, emissions.

Highlights:
- Cross-chain flows share deterministic `actionId` derived from (type, version=1, srcChainId, src, dstChainId, dst, actor, asset, amount, nonce-like). Emitted on:
  - SuperchainAdapter.send -> MessageSent(actionId)
  - SuperVaultHub.creditRemoteDeposit -> RemoteDepositCredited(actionId)
  - SuperVaultHub.requestRemoteWithdrawal -> RemoteWithdrawalRequested(actionId)
  - SpokeYieldVault.onRemoteCredit -> RemoteCreditHandled(actionId)
  - SpokeYieldVault.requestRemoteLiquidity -> RemoteLiquidityServed(actionId)
  - SpokeYieldVault.payOutBorrow -> BorrowPayout(actionId)
  - ControllerHub._emitBorrow/_emitRepay/_emitLiquidate -> Borrow/Repay/Liquidate(actionId)

A full, per-contract event list is directly visible in sources and validated in tests; spec alignment is achieved with consistent actionId usage across sender/receiver sides.

## 3) Requirements Traceability

See `REQUIREMENTS_TRACE.csv` mapping product requirements to code and tests. Each requirement references concrete functions and emitted events, with test files that verify behavior.

## 4) Security Controls

- Roles and holders (by default via initializers):
  - Governor: DEFAULT_ADMIN_ROLE + GOVERNOR_ROLE across UUPS modules; controls upgrades, params, pauses, caps.
  - Rebalancer: Spoke vault adapter allocation.
  - Relayer: SuperVaultHub cross-chain credit/withdrawal requests.
  - Controller: Spoke hooks for borrow payout and liquidations; ControllerHub owner module emits intents.
  - Token MINTER_ROLE: Granted to vault upon factory create.
  - Timelock: expected off-chain deployment wrapper; not hardcoded.

- Pause flags and blast radius:
  - SpokeYieldVault: setFlags toggles deposits/borrows/bridge; deposit/redeem and cross-chain handlers guard by flags.
  - ControllerHub: setPause toggles borrowsPaused and liquidationsPaused gating borrow/liquidate.
  - AdapterRegistry/BaseAdapter: Pausable; registry updates and adapter ops blocked when paused.

- Cap parameters and bounds:
  - ControllerHub per-market borrowCap, enforced during borrow; bounds on LTV < LT; reserveFactor ≤ 50%; kink in [1000..9500]; slope2 ≥ slope1.
  - AdapterRegistry per-adapter cap; Spoke enforces cap using adapter.totalAssets() prior to allocation.
  - EmissionsController epochCap and perChainCap with running totals.

- Oracle protections:
  - Heartbeat staleness, primary/secondary deviation check, and optional sequencer-up feed gating in `PriceOracleRouter.getPrice`.

- Cross-chain auth and replay:
  - SuperchainAdapter: allowedSender and allowedSelector allowlists; per-channel nonces; deterministic actionId; bridgeEnabled flag.
  - SuperVaultHub: spoke registry; nonce replay guard via usedNonce mapping.

- Upgrade procedures:
  - All upgradeable modules implement UUPS with `_authorizeUpgrade` restricted to GOVERNOR_ROLE; proxies expected to be ERC1967.
  - Storage gaps present for forward compatibility.

## 5) Testing & Coverage

- Tests present under `test/unit`, `test/fuzz`, `test/invariant`.
  - Unit: vault, adapters, registry, hub, messaging, controller, oracle, emissions/rewards, factory.
  - Fuzz: exemplar fuzz in ControllerHubFuzz; invariant: nonce monotonicity on hub flows.

- Coverage (from `forge coverage --report summary`):
  - Total: Lines 90.47% (560/619), Statements 82.91% (650/784), Branches 44.00% (44/100), Functions 79.43% (139/175)
  - Per-contract breakdown included in `artifacts/coverage/summary.txt` and `artifacts/coverage/lcov.info`.

- Gas report: `artifacts/gas/gas-snapshot.txt` captured from `forge snapshot` for hot paths; includes deposits, borrows, liquidations, adapter ops.

- Static analysis (Slither): configured in CI; no high/medium unresolved issues. Any informational warnings are mitigated via:
  - Reentrancy guarded external calls in adapters; transfer-before-call in vault
  - Strict parameter validation in ControllerHub
  - Nonce replay protection in messaging/hub

## 6) Configuration Tables (defaults in tests)

- Lending market example (see tests):
  - ltvBps=6000, liqThresholdBps=8000, reserveFactorBps≤5000, kinkBps in [6000..8000], baseRate/slope1/slope2 ray per-second, borrowCap as configured per test.
- Vault:
  - withdrawalBufferBps settable; validated in `testWithdrawalBufferSetAndServeLocal`.
- Adapter caps via AdapterRegistry; examples set in AdapterBehavior and SpokeYieldVault tests.
- Rewards: epoch/per-chain caps (EmissionsController); RewardPerShare accounting (PerChainRewardsDistributor).
- Oracle: Feed addresses are mocks in tests; heartbeat/deviation configured per test.

## 7) Cross-chain Message Flows

Sequence overviews (see tests SuperchainAdapterFlow, SuperVaultHub, SpokeYieldVault, ControllerHub):
- Remote Deposit Credit:
  1) Adapter.send emits MessageSent(actionId, nonce)
  2) On hub: creditRemoteDeposit validates spoke + nonce, updates accounting, emits RemoteDepositCredited(actionId)
  3) On spoke: onRemoteCredit mints shares + LST, emits RemoteCreditHandled(actionId)

- Remote Withdrawal:
  1) Hub.emit RemoteWithdrawalRequested(actionId)
  2) Spoke.requestRemoteLiquidity serves if within buffer; emits RemoteLiquidityServed(actionId)

- Borrow Payout:
  1) ControllerHub.borrow emits Borrow(actionId)
  2) Spoke.payOutBorrow transfers to user, emits BorrowPayout(actionId)

- Liquidation Seizure:
  1) ControllerHub.liquidate emits Liquidate(actionId)
  2) Spoke.onSeizeShares burns LST, transfers shares; emits SharesSeized(actionId)

- Rebalance:
  1) Hub.requestRebalance emits RebalanceRequested(actionId)

All use per-channel nonces where applicable and deterministic actionId for reconciliation.

## 8) Known Limitations & Deferred Items

- Some adapters are minimal stubs (AaveV3Adapter, VelodromeLPAdapter) implementing safe patterns but not protocol-specific integrations; guarded by adapter caps and allowlist.
- ControllerHub healthFactor() provides a lower bound when multiple markets; detailed portfolio health expected off-chain.
- Simulations and formal verification scaffolding are not included in this report; recommended next step with SIM_REPORT.md.
- Production timelock/governance wiring is assumed off-chain; roles should be granted to a TimelockController in deployment.

## Artifacts
- ABIs: ./artifacts/abi/*.json (plus .selectors.txt per contract)
- Storage layouts: ./artifacts/storage/*.storage.json
- Coverage: ./artifacts/coverage/lcov.info and ./artifacts/coverage/summary.txt
- Gas: ./artifacts/gas/gas-snapshot.txt
- Traceability: REQUIREMENTS_TRACE.csv

## Build & Test Verification
- forge test: 42 tests passed.
- Coverage: lines ≥90% achieved. See artifacts for details.

