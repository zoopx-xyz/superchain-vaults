# Superchain Vaults

Superchain Vaults is a cross-chain staking, yield and lending reference implementation and demo platform.
It combines ERC-4626 style spoke vaults, a ControllerHub for lending markets, and a SuperVaultHub / SuperchainAdapter messaging layer for cross-chain orchestration. The repository is designed for developers, auditors, and demonstrators who want a production-minded, testable framework to explore cross-chain liquidity and LST (liquid staking token) mechanics.

Key features
- Per-spoke ERC-4626 vaults that mint an LST mirror token on deposit.
- ControllerHub for multi-market lending with health factor checks and liquidation flows.
- SuperVaultHub and SuperchainAdapter primitives for cross-chain credit, routing and nonce-protected messages.
- AdapterRegistry and strategy adapters (mockable) for yield generation and allocation.
- Foundry-based test suite (unit/integration/property/invariant) with scenario harnesses and mocks.

This repository contains both production-grade patterns (two-step governance, role gating, replay guards) and test harnesses (MockBridge, MockL2ToL2Messenger, MockAggregators) to illustrate and stress cross-chain flows.

Quickstart (local)
1. Install Foundry: https://book.getfoundry.sh/
2. Build the project:

```bash
FOUNDRY_PROFILE=scripts forge build
```

3. Run tests (via-IR scripts profile used for complex deployments):

```bash
FOUNDRY_PROFILE=scripts forge test -vv
```

4. Deploy mock tokens for demo (local or testnet): see `scripts/DeployMocks.s.sol` and `README-MOCKS.md`.

How it works (high level)
- Vaults: `SpokeYieldVault` is an ERC-4626 vault that issues a separate `SuperchainERC20` LST token on deposit and burns it on redeem. Vaults hold adapters which can be allocated assets and harvested to produce yield.
- Lending: `ControllerHub` lists markets (linking underlying asset and LST) and allows borrowing constrained by LTV and protocol risk parameters. Liquidations call into vaults to seize user shares.
- Cross-chain: `SuperVaultHub` coordinates remote operations. In tests the `MockBridge` and `MockL2ToL2Messenger` simulate asynchronous token movement and messages. For demos, a keeper-assisted relayer can call privileged hooks (e.g., `onRemoteCredit`) to credit assets across chains.

Testnet demo notes
- For quick demos we recommend a keeper-assisted approach: a small off-chain relayer that mints demo yield tokens, triggers `onRemoteCredit`, and sets oracle feeds on testnets. This is faster and more reliable than relying on third-party testnet bridges for demo purposes.
- See `README-MOCKS.md` for instructions on deploying mock tokens and setting up `PriceOracleRouter` feeds.

Security & governance
- Roles are strictly used: `GOVERNOR_ROLE`, `REBALANCER_ROLE`, `HUB_ROLE`, `CONTROLLER_ROLE`, and deploy-time `DEFAULT_ADMIN_ROLE` are all enforced by AccessControl.
- Emergency controls: vaults expose `forceIdle()` and contracts are pausable where appropriate. For public testnets, grant critical roles to a secure multisig and maintain a runbook for emergency pause and role revocation.

License
- This project is licensed under the MIT License. See `LICENSE` for details.

Copyright & Trademark
- Copyright (c) 2025 ZoopX
- SUPERCHAIN and Superchain Vaults are trademarks of ZoopX (where applicable). If you wish to use the Superchain name or marks in public materials, please contact the ZoopX team for permission.

Contributing
- Please open issues and PRs. For significant changes, provide tests and update the Foundry test suite.

Contact & Support
- For demo help or operational questions, open an issue or reach out through the project's communication channels.
## Production deployment notes

- Mock adapters are disabled in production (allowlist=false, cap=0). They are marked MockOnly — NOT for production deployments.
- Required env vars (example .env):

	- GOV_MULTISIG, TIMELOCK, BASE_ASSET
	- RESERVE_FACTOR_BPS, LTV_BPS, LT_BPS, KINK_BPS, SLOPE1_RAY, SLOPE2_RAY
	- WITHDRAW_BUFFER_BPS, EPOCH_LEN_SEC, EPOCH_OUTFLOW_CAP_BPS
	- Per-asset oracle group (repeatable): FEED_<SYMBOL>_PRIMARY, FEED_<SYMBOL>_SECONDARY, FEED_<SYMBOL>_DECIMALS, FEED_<SYMBOL>_HEARTBEAT, FEED_<SYMBOL>_DEV_BPS, FEED_<SYMBOL>_MIN, FEED_<SYMBOL>_MAX
	- Optional sequencer oracle: SEQUENCER_ORACLE

- Post-deploy runbook:
	- Grant GOVERNOR_ROLE and DEFAULT_ADMIN_ROLE to the timelock; revoke from deployer and any EOAs.
	- Configure oracle feeds and bounds on `PriceOracleRouter`.
	- Set vault withdrawal buffer and epoch caps.
	- Keep `AdapterRegistry` paused until allowlist/caps are finalized; then selectively enable real adapters.
	- Validate invariants with the smoke section in the deploy scripts.

# Superchain Vaults

Production-grade Superchain vault system built with Solidity 0.8.24 and Foundry, using OpenZeppelin v5.

## Architecture
- SuperchainAdapter: cross-chain messenger wrapper with allowlists and nonces.
- SuperVaultHub: canonical accounting and coordination.
- SpokeYieldVault (ERC4626): user deposits/withdrawals, LST mint/burn, adapters.
- Strategy adapters: AaveV3Adapter, VelodromeLPAdapter via BaseAdapter and AdapterRegistry.
- Rewards: PerChainRewardsDistributor; EmissionsController.
- Oracles: PriceOracleRouter.
- Lending: ControllerHub.

## Dev
```bash
forge build
forge test -vvvv
forge coverage --report lcov
```

## Gas
Run tests with gas report:
```bash
forge test --gas-report
```

## Security
See SECURITY.md. Slither config in `.slither.json`.
