# Allova

**Give your agent an allowance, not your wallet.** Onchain USDC spending limits for AI agents, built on Arc.

Allova is the new name of Allowance. The v1 build that is live on Arc mainnet keeps its original links:
**Live app (v1):** https://allowance-agents.vercel.app · **v1 source:** https://github.com/erhnysr/allowance · **Video:** https://youtu.be/aWAhs6EGqHw

This repository is **v2**: it fixes the three issues found in v1 review, adds a minimum interval between payments, and ships an audit export and an MCP server for agents. See [CHANGELOG.md](CHANGELOG.md).

## What it is

Allova lets you give an AI agent a USDC budget with hard onchain limits. Each agent key gets its own policy: a per-payment cap, a refilling period budget, a lifetime cap, an expiry date, and an optional payee allowlist. The limits are enforced by a smart contract, not by the agent itself — an agent with a leaked key can only spend what the policy allows.

## The problem

AI agent keys get embedded in infrastructure, passed between services, and often stored in places you can't fully audit. If a key leaks or the agent misbehaves, the only control you have is how much it can spend. Allowance puts that control onchain, where neither the agent nor any other party can override it without owner credentials.

## How a policy works

Each policy is attached to an agent key (Ethereum address) and lives inside an AllowanceAccount contract you own.

**Per-payment cap.** No single payment can exceed this amount. Splitting a payment into several smaller ones is still bounded by the period budget and the lifetime cap.

**Period budget (token bucket).** The budget refills continuously at periodLimit / periodSeconds per second, up to periodLimit. The bucket starts full, so the agent can spend up to periodLimit at once and then has to wait for it to refill. Refill and burst are the same number. Because a full bucket can be spent and refilled within the same window, a single window of periodSeconds can see up to about 2x periodLimit; over longer horizons the average is periodLimit per period. The lifetime cap is the hard ceiling.

**Lifetime cap.** A hard ceiling on total spending across the policy's entire lifespan. Once `totalSpent` reaches `totalLimit`, no further payments are possible.

**Expiry.** Policies can have an expiry timestamp. After that date the agent is treated as inactive and all payments are rejected.

**Payee rules.** In open mode the agent can pay any address that is not blocked for it. In allowlist mode it can pay only addresses the owner allowed for it. Blocks and payee caps are set per agent; a payee cap is cumulative across all payments to that payee.

**Freeze.** The account owner or a designated guardian can freeze the account at any time. A freeze stops all agents immediately — no payments go through while frozen.

## check() reason codes

| Code | Meaning |
|------|---------|
| 0 | OK — payment goes through |
| 1 | Amount is zero |
| 2 | Account is frozen |
| 3 | Agent not registered |
| 4 | Agent is revoked |
| 5 | Agent has expired |
| 6 | Invalid payee (zero address or the account itself) |
| 7 | Payee not allowed or blocked |
| 8 | Over per-payment cap |
| 9 | Over period budget |
| 10 | Over lifetime cap |
| 11 | Over payee cap |
| 12 | Insufficient account balance |

## Signed intents and relayers

Instead of calling the contract directly, an agent signs a `PaymentIntent` struct off-chain using EIP-712 typed data. The struct contains the agent address, payee, amount, a random 256-bit nonce, a deadline, and a `bytes32` reference (memo). Anyone can relay the signed intent by calling `payWithSig` — the contract verifies the signature and nonce, then applies the policy checks. The relayer pays gas but cannot alter the intent.

## Deployed addresses

| Network | Factory | Explorer |
|---------|---------|----------|
| Arc Mainnet | `0xa48fdee3cc6ec2909da8fbec0d2f14032e92c5ec` (verified) | [explorer.arc.io](https://explorer.arc.io/address/0xa48fdee3cc6ec2909da8fbec0d2f14032e92c5ec) |
| Arc Testnet | `0xd4018d487861eb513e8a756a4e2693d55daff95a` (verified) | [explorer.testnet.arc.io](https://explorer.testnet.arc.io/address/0xd4018d487861eb513e8a756a4e2693d55daff95a) |

## Live on Arc Mainnet

Everything below is on Arc Mainnet (chain 5042) and can be checked on explorer.arc.io.

| What | Link |
|------|------|
| Factory (verified) | [`0xa48fdee3cc6ec2909da8fbec0d2f14032e92c5ec`](https://explorer.arc.io/address/0xa48fdee3cc6ec2909da8fbec0d2f14032e92c5ec) |
| Example account (verified) | [`0x88C0D09696f4c2D508db442349a5592F8b8DA7ab`](https://explorer.arc.io/address/0x88C0D09696f4c2D508db442349a5592F8b8DA7ab) |
| Agent payment: 0.05 USDC through `payWithSig`, memo `first-mainnet-payment` | [`0xa073ed4c…1b5d`](https://explorer.arc.io/tx/0xa073ed4c454b72633bc9cf67c001335d8072f63851849647187857bc75121b5d) |
| Over-limit attempt: 1.10 USDC rejected onchain with `OverPerPayment()` | [`0x1671a612…52a9`](https://explorer.arc.io/tx/0x1671a612898038459bd5d7066a0e9cf0336872ac701e37046119edb4001552a9) |
| Factory deployment | [`0x929438a3…7139`](https://explorer.arc.io/tx/0x929438a3bca3794ec9ffc45d2b42cce9820d4ed5bf7e0a21857c993491907139) |

The agent key signed the payment intent and a separate wallet relayed it and paid gas. The account contract checked the policy (0.10 USDC per payment, 1 USDC per day, 3 USDC lifetime) before moving any USDC.

## How it was built with Arc Studio

- **Contracts.** `AllowanceFactory` and `AllowanceAccount` were written in Arc Studio and tested there with Foundry: 144 tests, including fuzz properties, invariants, EIP-712 signature and nonce-replay tests, and reentrancy tests.
- **App.** The React + wagmi app was built in Arc Studio against those contracts, then reviewed and refined over several passes in Studio.
- **Testnet.** Arc Studio deployed the factory to Arc Testnet, where the full flow was exercised: signed payments, an onchain overspend rejection, and freeze/unfreeze.
- **Mainnet.** The mainnet factory was deployed with Foundry from the same Studio build (scripts below). `forge inspect contracts/AllowanceFactory.sol:AllowanceFactory bytecode` reproduces the exact creation code, and both factories are verified on the explorers from the same sources.

Arc Studio project: https://studio.arc.io/app/eb41e5a9-08b0-4700-b95c-c073f49e9045

## Mainnet scripts

`scripts/mainnet/` holds the two scripts used for the mainnet run. Both read keys from encrypted Foundry keystores (`cast wallet import` or `cast wallet new`), print what they are about to do, and ask for confirmation before sending anything.

- `deploy-factory.sh [keystore]` checks that the chain is Arc Mainnet (5042), shows the deployer balance and a fee estimate, deploys `AllowanceFactory(usdc)`, and checks `usdc()` afterwards. Generate its input first:

  ```bash
  forge inspect contracts/AllowanceFactory.sol:AllowanceFactory bytecode > scripts/mainnet/AllowanceFactory.bin
  ```

- `agent-pay.sh <account> <payee> <amount> [memo]` has the agent sign an EIP-712 `PaymentIntent` with its own key, runs `check()` and simulates `payWithSig`, then a relayer wallet submits it. If the policy would reject the payment, it stops unless you type `force`, which records the rejection onchain.

## Test suite

144 tests: fuzz properties, invariants, and reentrancy protection.

```bash
bun install
forge test
```

Test files:
- `Factory.t.sol` — 45 tests: account creation, ownership
- `Spend.t.sol` — 47 tests: policy enforcement, pay, payWithSig
- `TokenBucket.t.sol` — 16 tests: bucket math and refill edge cases
- `Signatures.t.sol` — 13 tests: EIP-712 signing, nonce replay
- `CheckAgreement.t.sol` — 16 tests: check() reason codes match payWithSig behaviour
- `Invariant.t.sol` — 5 invariants: balance accounting, spent totals
- `Reentrancy.t.sol` — 2 tests: reentrancy guards

## Known limitations

The v1 review findings are fixed in v2 (details and tests in [SECURITY.md](SECURITY.md)):

| v1 limitation | v2 |
|---|---|
| Re-enabling a revoked or removed key could revive old signed intents | Intents carry the agent's epoch; revoke, remove and `invalidateIntents` make older intents unusable |
| `removeAgent` kept payee rules and counters | Removal starts a fresh set of payee rules |
| `setPayee(..., false, ...)` did not block in open mode | An explicit `false` now denies the payee in both modes |
| The period budget could be spent in one burst | `minInterval` sets the minimum time between two payments |

Still true in v2: the token bucket can release up to about 2× the period limit within one period (a full bucket plus one period of refill); the lifetime cap is the hard ceiling. The contracts are unaudited: keep balances small.

## Security notes

The contracts are unaudited. The Arc Mainnet deployment is live; keep balances small until an independent audit is complete.

**Owner trust.** The account owner can change any policy, add or remove agents, and withdraw all funds. There is no timelock. The owner is the root of trust.

**Open mode.** When an agent's policy is not in allowlist mode, it can pay any non-blocked Ethereum address, subject to the limits. The policy limits are the only bound on where funds can go.

**Guardian.** A guardian can freeze the account but cannot modify policies, withdraw funds, or transfer ownership. It is meant for a monitoring bot or a hardware key held separately.

## Running the app

```bash
bun install
bun run dev
```

Open http://localhost:5173. The app works on Arc Mainnet and Arc Testnet. Connect a wallet on either network, then create an account and add agent policies. The Playground tab is testnet-only. Get testnet USDC from https://faucet.circle.com.

## Using the agent client

See [agent/README.md](agent/README.md) for full usage.

Quick example:

```bash
export AGENT_PRIVATE_KEY=0x...
export ALLOWANCE_ACCOUNT=0x...
bun run agent pay 0xPayeeAddress 0.40 "invoice-42"
```

---

Built on Arc  
Built with Arc Studio — https://studio.arc.io/app/eb41e5a9-08b0-4700-b95c-c073f49e9045
