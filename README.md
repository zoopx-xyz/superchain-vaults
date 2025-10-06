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
