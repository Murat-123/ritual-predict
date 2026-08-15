# Ritual Predict
![Ritual Predict](/ritual-predict-preview.png)
> Autonomous prediction markets powered by Ritual.

Ritual Predict explores a self-resolving binary prediction market architecture built around Ritual-native infrastructure. Participants take YES or NO positions on a question; after the betting window closes, the contract obtains and processes configured external data through Ritual, then settles the market deterministically.

## Live Demo

**Application:** [ritual-predict.netlify.app](https://ritual-predict.netlify.app)

The Ritual public testnet is currently offline, so the hosted application runs in local simulation mode. Predictions shown in the interface do not currently create on-chain transactions. The production Solidity architecture and its Ritual integrations are implemented and locally tested.

## What is Ritual Predict?

Ritual Predict is a pari-mutuel binary market: users stake native RITUAL on either YES or NO. Its production contract is designed so resolution does not depend on a human operator, a backend cron job, or a manually submitted result.

At market creation, the resolution rule, oracle URL, JSON path, comparator, and block-based deadlines are fixed. At the scheduled resolution block, the flow is:

```mermaid
flowchart LR
    S[Ritual Scheduler] --> T[TEE-capable executor]
    T --> H[HTTP Precompile]
    H --> J[jq extraction]
    J --> O[Oracle value]
    O --> R[Automatic contract resolution]
```

This composition lets the contract retrieve external data through Ritual infrastructure, extract a numeric value deterministically, and settle a configured market rule on-chain.

## Interactive Markets

The current frontend includes independent local markets for:

- BTC/USD
- ETH/USD
- SOL/USD
- BNB/USD
- XRP/USD

Each market maintains its own simulated YES and NO pools, ratios, selected prediction, history, resolution state, and reset behavior during the browser session. The displayed oracle values are deterministic simulated values for the interface, not live prices.

## Architecture

### 1. Ritual Scheduler

`createMarket` books three scheduled callback attempts beginning at the market's `resolveBlock`, spaced 200 blocks apart. All lifecycle deadlines are block-based. The Scheduler calls `onScheduledResolve`, whose first parameter receives the execution index supplied by the Scheduler.

### 2. TEE Registry / TEE-capable Executor

For every attempt, the contract asks `TEEServiceRegistry` to select an executor with the `HTTP_CALL` capability. Selection is seeded with the market, execution index, contract address, and `block.prevrandao`; no executor is hardcoded.

### 3. HTTP Precompile

The selected executor is passed to Ritual's HTTP precompile at `0x0801`. The contract performs the configured GET request using the market's immutable oracle URL and decodes the returned asynchronous HTTP envelope.

### 4. jq

The synchronous jq precompile at `0x0803` receives the HTTP response body and the market's immutable JSON path. It must produce a `uint256` value for the oracle read to succeed.

### 5. Oracle Value

The extracted value is stored as `observedValue` when a terminal outcome is reached. HTTP errors, non-200 responses, malformed responses, decode failures, jq failures, and unavailable executors are failures—not NO outcomes.

### 6. Automatic Contract Resolution

The contract applies its immutable comparator to the observed value and target. It resolves YES or NO if the winning pool is non-empty, and attempts to cancel unused scheduled executions. Cancellation failure does not undo a terminal resolution.

## Smart Contract

[`hardhat/contracts/RitualPredict.sol`](hardhat/contracts/RitualPredict.sol) implements the production market logic.

- **Market creation:** validates question, oracle URL, JSON path, and duration bounds; records an immutable resolution rule; and schedules resolution.
- **Binary positions:** users place native-RITUAL YES or NO stakes while the block-based betting window is open.
- **Retries:** up to three resolution attempts use a fresh executor selection each time. A failed read is retried and is never interpreted as NO.
- **Invalidation and refunds:** after the final failed attempt—or if the winning side is empty—the market becomes `Invalid` and participants can reclaim their original stake.
- **Payouts:** winners claim a proportional pari-mutuel share: `stake × totalPool ÷ winningPool`.
- **Pull-style claims:** payouts and refunds are claimed per account; the contract never loops over all participants.
- **Authorization and idempotency:** only the Scheduler can invoke resolution, and terminal or repeated callbacks safely return without changing the market.
- **Execution funding:** `fundExecution` deposits native RITUAL into the RitualWallet for scheduled execution and precompile fees.

The canonical production references are centralized in [`hardhat/contracts/ritual/RitualChain.sol`](hardhat/contracts/ritual/RitualChain.sol): Scheduler, RitualWallet, TEEServiceRegistry, HTTP (`0x0801`), and jq (`0x0803`).

## Testing

The Solidity suite currently passes:

```text
18 passing
0 failing
```

For local testing, [`RitualMocks.sol`](hardhat/contracts/mocks/RitualMocks.sol) provides configurable mocks for the Scheduler, RitualWallet, TEE Registry, HTTP precompile, and jq precompile. The test harness installs their runtime code at the corresponding canonical Ritual addresses, so the production contract integration is exercised without changing its production addresses or logic.

[`RitualPredict.t.sol`](hardhat/contracts/RitualPredict.t.sol) covers:

- market creation, stored rules, emitted events, and validation
- Scheduler parameters and execution funding
- YES/NO betting, pool accounting, and closed/zero-stake rejections
- successful YES and NO resolutions
- retries with a fresh executor selection
- final invalidation and stake refunds
- empty winning-side invalidation
- proportional payouts and one-time claims
- Scheduler-only callback authorization and idempotency
- malformed HTTP responses, jq failures, and unavailable executors
- scheduler cancellation failures after terminal resolution

These tests validate local behavior only; they do not prove a live Ritual deployment.

## Frontend

[`web/`](web/) is a React, Vite, and TypeScript application using viem where appropriate for injected browser-wallet interaction.

- Connects an injected wallet such as MetaMask and retains the selected account for the browser session.
- Does not send wallet transactions, switch networks, generate transaction hashes, or request Ritual RPC data.
- Provides independent local BTC, ETH, SOL, BNB, and XRP markets with interactive YES/NO pools.
- Animates the Ritual resolution pipeline for the selected market and resolves it from deterministic simulated oracle values.
- Includes selected-market reset controls and responsive desktop/mobile styling.

## Run Locally

### Smart contracts

```bash
cd hardhat
pnpm install
pnpm exec hardhat compile
pnpm exec hardhat test
```

The local Solidity tests use the built-in simulated Hardhat network and do not require an RPC URL, private key, or funds.

### Frontend

```bash
cd web
pnpm install
pnpm dev
```

Vite prints the local URL, normally `http://localhost:5173`. To make a production build:

```bash
cd web
pnpm build
```

## Current Status

| Component | Status |
| --- | --- |
| Solidity contract | Implemented |
| Local Ritual mocks | Implemented |
| Solidity tests | 18/18 passing |
| Frontend | Hosted local-simulation interface |
| Wallet connection | Implemented; no transaction submission |
| Prediction transactions | Local simulation only |
| Live Ritual deployment | Pending public network availability |

## Built for Ritual

Ritual Predict demonstrates how Ritual's Scheduler, TEE execution, HTTP capability, and deterministic jq extraction can be composed into autonomous on-chain applications such as prediction markets.

- [Ritual documentation](https://docs.ritualfoundation.org)
- [Ritual on X](https://x.com/ritualnet)
- [Ritual Discord](https://discord.gg/ritual-net)
