Deploying mock tokens for the MVP demo
=====================================

This document describes how to deploy the mock tokens used in the demo and answers common questions about the PriceOracleRouter and the Superchain bridge.

What this script deploys
- tUSDC (Test USDC) — 6 decimals, `MockERC20Decimals`
- tWETH (Test WETH) — 18 decimals, `MockERC20Decimals`
- tZPX (Test ZPX) — 18 decimals, `SuperchainERC20` (mintable by deployer/admin)

How to run
----------
Set the `PRIVATE_KEY` environment variable to the deployer key (must have funds on the target network). Then run:

```bash
# example for Base testnet
FOUNDRY_PROFILE=scripts forge script scripts/DeployMocks.s.sol:DeployMocks \
  --rpc-url $RPC_BASE --private-key $PRIVATE_KEY --broadcast --verify-none

# example for OP testnet
FOUNDRY_PROFILE=scripts forge script scripts/DeployMocks.s.sol:DeployMocks \
  --rpc-url $RPC_OP --private-key $PRIVATE_KEY --broadcast --verify-none
```

PriceOracleRouter
------------------
The repository already includes a `PriceOracleRouter` contract and a simple `MockAggregator` used in tests. For testnet demo you can deploy the `PriceOracleRouter` per chain, then deploy one `MockAggregator` per token and register the feed with `router.setFeed(asset, agg, sequencer, decimals, heartbeat, deviationBps)` from a governor account.

For live demos you will typically:
- deploy `MockAggregator` instances for `tUSDC`, `tWETH`, and `tZPX` on each chain, then set initial prices.
- Later, the demo keeper can call `MockAggregator.setAnswer(...)` to change prices (simulate liquidity shocks and trigger liquidation flows).

Superchain Bridge
-----------------
The repo implements a `SuperchainAdapter` and uses `MockBridge` / `MockL2ToL2Messenger` in tests to simulate cross-chain messages and token transfers. There is no live production Superchain bridge deployed from this repo — you will need to either:

1. Use a real testnet bridge (if you want fully trust-minimized cross-chain transfers), or
2. Use the keeper-assisted demo approach where the keeper acts as a trusted relayer to call `onRemoteCredit(...)` or other privileged hooks on the destination chain to credit assets/LST. This is recommended for quick demos.

If you later integrate a production bridge, wire it to the `SuperVaultHub` and `SuperchainAdapter` per your bridging strategy.

Notes & gotchas
---------------
- Ensure the deployer/private key has testnet funds on both testnets you plan to use.
- For quick demos prefer the keeper-assisted bridging path to avoid bridge delays and third-party bridge restrictions.
- Record deployed addresses in an address book JSON per chain for your keeper and demo scripts to use.

Next steps
----------
- If you want, I can add a `tools/keeper` scaffold (Node.js) that will mint `tZPX` as yield, call `MockAggregator.setAnswer` to simulate price moves, and perform keeper-assisted cross-chain credits for the demo.
