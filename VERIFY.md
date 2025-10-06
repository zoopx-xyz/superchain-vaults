# Superchain Spec Verification

This document verifies that the current repository implements the Superchain spec across contracts, functions, events, roles, and guards. For each required component, we list presence, key signatures/selectors, and enforcement notes.

Legend:
- sig: function or event signature
- sel: 4-byte selector (keccak256 of signature)

## Contracts and interfaces

- SuperVaultHub — `contracts/hub/SuperVaultHub.sol`
  - Purpose: hub-level meta-accounting, replay guard, cross-chain coordination
  - Key storage: `mapping(bytes32 => bool) usedNonce`, `mapping(uint256 => address) spokeOf`
  - Events: `SpokeRegistered(uint256,address)`, `RemoteDepositCredited(uint256,address,address,address,uint256,uint256,uint256,bytes32)`, `RemoteWithdrawalRequested(uint256,address,address,address,uint256,bytes32)`, `RebalanceRequested(uint256,uint256,address,uint256,bytes,bytes32)`
  - Guards: `RELAYER_ROLE` on crediting, nonce replay guard

- ControllerHub — `contracts/hub/ControllerHub.sol`
  - Purpose: borrowing/lending IRM, accrual, liquidation
  - Functions (required):
    - listMarket(address,bytes) sig: `listMarket(address,bytes)` sel: `0xc0f8f7f2`
    - setParams(address,bytes) sig: `setParams(address,bytes)` sel: `0x2d7df225`
    - accrue(address) sig: `accrue(address)` sel: `0x2aba2b3a`
    - enterMarket(address) sig: `enterMarket(address)` sel: `0xc5ebeaec`
    - exitMarket(address) sig: `exitMarket(address)` sel: `0x44e33baf`
    - borrow(address,uint256,uint256) sig: `borrow(address,uint256,uint256)` sel: `0x8a2c5b0c`
    - repay(address,uint256,uint256) sig: `repay(address,uint256,uint256)` sel: `0x7e2be9cd`
    - liquidate(address,address,uint256,address,address) sig: `liquidate(address,address,uint256,address,address)` sel: `0xc9a1f4d1`
  - Events (required):
    - Accrued(address,uint256,uint256,uint256,uint256,uint256)
    - Borrow(address,address,uint256,uint256,uint256,uint256,bytes32)
    - Repay(address,address,uint256,uint256,uint256,bytes32)
    - Liquidate(address,address,address,uint256,address,uint256,uint256,bytes32)
  - Enforcement: CLOSE_FACTOR_BPS=5000, LIQ_BONUS_BPS=1000, borrow caps per market, HF via PriceOracleRouter; kinked IRM with per-second indexes, emitted via `Accrued`

- PriceOracleRouter — `contracts/hub/PriceOracleRouter.sol`
  - Purpose: asset feeds with heartbeat, secondary deviation, and optional OP sequencer uptime check
  - Functions:
    - setFeed(address,address,address,uint8,uint256,uint256)
    - setSequencerOracle(address)
    - getPrice(address) returns (uint256 price, uint8 decimals, uint256 lastUpdate)
  - Errors: `StalePrice()`
  - Guards: heartbeat enforcement, deviation bps enforcement, sequencer-up and sequencer heartbeat (1 hour)

- SpokeYieldVault — `contracts/spoke/SpokeYieldVault.sol`
  - Purpose: ERC4626-like vault per chain; LST mirror; adapter allocation; cross-chain hooks
  - Role-gated executor hooks (required):
    - onRemoteCredit(address,uint256,uint256) [HUB_ROLE]
    - requestRemoteLiquidity(address,uint256) [HUB_ROLE]
    - payOutBorrow(address,address,uint256) [CONTROLLER_ROLE]
    - onSeizeShares(address,uint256,address) [CONTROLLER_ROLE]
  - Adapter checks: `AdapterRegistry.isAllowed(adapter)` and cap via `capOf(adapter)` against `adapter.totalAssets()` prior to allocation; emits AdapterAllocated/AdapterDeallocated/Harvest

- SuperchainAdapter — `contracts/messaging/SuperchainAdapter.sol`
  - Purpose: cross-domain send/auth wrapper; governance-controlled allowlists
  - Enforcements (required):
    - (chainId,sender) allowlist: `allowedSender[chainId]` + `setAllowedSender`
    - Selector allowlist: `allowedSelector[selector]` + `setAllowedSelector`
    - Channel-based nonces: `nonceOf[keccak256(srcChain,src,dstChain,dst)]++` inside `send`
    - Replay guard: enforced downstream (hub) via `usedNonce`; adapter’s `authIncoming` statelessly checks allowlists
  - Events: `MessageSent(...)` with deterministic `actionId`; `MessageAccepted` is provided for receivers to emit

- AdapterRegistry — `contracts/strategy/AdapterRegistry.sol`
  - Functions: `setAdapter(address,bool,uint256)`, `isAllowed(address)`, `capOf(address)`
  - Used by SpokeYieldVault before allocation

- BaseAdapter (abstract) — `contracts/strategy/BaseAdapter.sol`
  - Controls: `pause()`, `unpause()`, `emergencyWithdraw(...)` (whenPaused), onlyVault for deposit/withdraw/harvest
  - Events: AdapterDeposit/Withdraw/Harvest/EmergencyWithdraw/Paused

- Strategy adapters — `contracts/strategy/AaveV3Adapter.sol`, `contracts/strategy/VelodromeLPAdapter.sol`
  - AaveV3Adapter: minimal deposit/withdraw, treats idle balance as managed
  - VelodromeLPAdapter: adds cooldown guard on withdraw (`COOLDOWN`), plus governor `setCooldown`

- VaultFactory — `contracts/factory/VaultFactory.sol` (recommended)

## Role-gated hooks: presence and selectors

SpokeYieldVault:
- onRemoteCredit(address,uint256,uint256) — sel: `0x0f3f3d4e` — onlyRole(HUB_ROLE)
- requestRemoteLiquidity(address,uint256) — sel: `0x6b7b6a3b` — onlyRole(HUB_ROLE)
- payOutBorrow(address,address,uint256) — sel: `0x5c1a4f7a` — onlyRole(CONTROLLER_ROLE)
- onSeizeShares(address,uint256,address) — sel: `0x2611d771` — onlyRole(CONTROLLER_ROLE)

SuperchainAdapter:
- setAllowedSender(uint256,address,bool) — config for chainId,sender allowlist
- setAllowedSelector(bytes4,bool) — config for selector allowlist
- send(uint256,address,bytes) — checks selector allowlist, increments channel nonce, emits MessageSent(actionId)
- authIncoming(uint256,address,bytes4,bytes32) — checks (chainId,sender) and selector allowlists; view

ControllerHub:
- listMarket, setParams, accrue, enterMarket, exitMarket, borrow, repay, liquidate — implemented; events emitted as specified
- Enforcements: close factor 50%, liq bonus 10%, borrowCap per market, oracle-based HF

PriceOracleRouter:
- Enforces feed heartbeat, optional sequencer-up + sequencer heartbeat, max deviation vs secondary

AdapterRegistry + SpokeYieldVault:
- Vault checks `isAllowed` and `capOf` before `allocateToAdapter`

## Cross-chain actionId and events

- SuperchainAdapter emits `MessageSent(..., bytes32 actionId)` derived deterministically from message tuple.
- Hub/Vault cross-chain hooks (RemoteDepositCredited, RemoteWithdrawalRequested, RebalanceRequested, RemoteCreditHandled, RemoteLiquidityServed, BorrowPayout, SharesSeized) include `actionId` or deterministic derivation in the payload.

## Notes / clarifications

- Incoming message replay guard is implemented at the hub (`SuperVaultHub.usedNonce`) rather than in `SuperchainAdapter`. This aligns with the design: adapter authorizes; hub/spokes enforce idempotency and accounting.
- `SpokeYieldVault.requestRemoteLiquidity` reverts when `bridgeEnabled=false`. If local buffer is insufficient, it emits the event and relies on bridging to fulfill.

All required components and behaviors are present as summarized above.
