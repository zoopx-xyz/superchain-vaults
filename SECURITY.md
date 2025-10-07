## Governance and emergency procedures

- In production, GOVERNOR_ROLE and DEFAULT_ADMIN_ROLE must be held by a TimelockController-based multisig. EOAs should not hold permanent powers.
- All privileged contracts (ControllerHub, PriceOracleRouter, SpokeYieldVault, SuperVaultHub, AdapterRegistry) support two-step governor transfer.
- Emergency pause:
	- ControllerHub: pause borrows/liquidations via setPause.
	- SpokeYieldVault: toggle deposits/borrows/bridge via setFlags; withdrawal buffer and epoch caps can be used to rate-limit outflows.
	- AdapterRegistry: keep paused during onboarding; only unpause after allowlist is finalized.
- Oracle safety: use per-asset heartbeat, deviation bounds, and min/max answer limits. Configure optional sequencer oracle for L2s.

# Security Overview

This repository implements Superchain vaults and lending infrastructure with a strong focus on defense-in-depth.

## Roles
- DEFAULT_ADMIN_ROLE: multisig with ability to grant/revoke roles.
- GOVERNOR_ROLE: parameter and upgrade control.
- RELAYER_ROLE: cross-chain relay actions.
- REBALANCER_ROLE: adapter allocations/harvest.
- FUNDER_ROLE: rewards funding.
- CONTROLLER_ROLE: lending hooks.

## Pause Controls and Feature Flags
- Module pausing per contract via Pausable: bridge, adapters, rewards.
- Feature flags on vault: depositsEnabled, borrowsEnabled, bridgeEnabled.

## Upgrade Safety
- UUPS upgradeable contracts with _authorizeUpgrade() gated by GOVERNOR_ROLE.
- Storage gaps reserved and must not be re-ordered.
- Use proxiable UUID via UUPS standard for tooling compatibility.

## Invariants
- Nonce uniqueness: every cross-chain state change uses a unique nonce; replays are rejected.
- LST supply equals vault shares ± fees − seized.
- Adapter allocations must remain within caps.
- Monotonic indices: debtIndexRay/supplyIndexRay non-decreasing.
- Borrowing blocked if oracle stale or sequencer down.
- Health Factor ≥ 1e18 unless in liquidation path.

## Upgrade Procedure
1. Prepare and audit the new implementation.
2. Schedule via timelock governed by DEFAULT_ADMIN_ROLE/GOVERNOR_ROLE.
3. Execute upgrade through UUPS upgrade path.
4. Validate invariants, run smoke tests, and monitor after upgrade.

## Reporting
Please open a responsible disclosure via the security contact channel.
