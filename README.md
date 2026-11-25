# Chaser

A concentrated liquidity position on Uniswap v4 earns nothing once the price leaves its range. After a trend, it can
sit there for days. Chaser watches the pool with a Reactive contract and, when a trend has left the range behind,
moves the tokens the position holds into a new range next to the price. It never swaps.

Status: in development for the Reactive Omni Buildathon.

## Repository

- `contracts/`: Solidity contracts (Foundry).
- `web/`: the interface (Next.js).
- `config/networks/`: addresses for each supported network.

## Build and test

Requirements: Foundry 1.9.0, Node 24 and pnpm 11.

```bash
git clone --recurse-submodules <repo-url>
cd contracts && forge build && forge test
cd ../web && pnpm install --frozen-lockfile && pnpm lint && pnpm typecheck && pnpm build
```

## License

MIT. See `LICENSE`.
