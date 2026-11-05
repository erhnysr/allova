# Allova (formerly Allowance) — Onchain Spending Limits for AI Agents

> Built with Arc Studio — money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app.

## What This App Does

Allova is a smart-contract system that gives every AI agent its own USDC spending policy enforced entirely onchain: no third party, including the factory, can move funds or change a policy; only the account owner can.

An owner deploys an `AllowanceAccount` through `AllowanceFactory`, funds it with USDC, and assigns each AI agent key a named policy. A policy specifies:

- **maxPerPayment** — the largest single transfer the agent can make.
- **periodLimit / periodSeconds** — a token-bucket rate limit. The bucket starts full and drains with each payment; it refills gradually at a rate of `periodLimit / periodSeconds` per second, capped at `periodLimit`. This means an agent allowed 1 USDC per day can burst up to 1 USDC immediately after being set, then only regain that capacity gradually. In any window of periodSeconds the agent can spend at most about 2x periodLimit (a full bucket plus one period of refill). Over longer horizons the average is periodLimit per period. totalLimit is the hard ceiling.
- **totalLimit** — hard cap on the agent's total cumulative spend across all time. Once reached, the agent is permanently blocked until the owner raises it.
- **expiresAt** — an expiry timestamp after which the agent's key is rejected with AgentExpired.
- **payeeRestricted** — when true, the agent can only pay addresses explicitly allowlisted by the owner. A payee can also be **blocked** individually (`setPayeeBlocked`) regardless of mode.
- **Per-payee caps** — optional per-destination spend limits.

Agents pay by calling `pay()` directly, or by signing a `PaymentIntent` EIP-712 struct off-chain and having anyone relay it via `payWithSig()`. A **guardian** address can freeze the account in emergencies; only the owner can unfreeze.

Ownership is two-step (`Ownable2Step`). The factory index is updated automatically on ownership transfer. `renounceOwnership` is disabled — losing the owner key would brick the account.

## Deployed Contracts (Arc Testnet — v3, post-review, current)

| Contract | Address | Explorer |
|---|---|---|
| AllowanceFactory v3 | `0xd4018d487861eb513e8a756a4e2693d55daff95a` | https://explorer.testnet.arc.io/address/0xd4018d487861eb513e8a756a4e2693d55daff95a |

This is the factory used by the frontend (`src/lib/networks.ts`). Deploy tx: `0x22e603d2b1f22e8b12f516ef5cbf4c0e57ffeb062a46032da402d375f3ac7a88`.

## Deployed Contracts (Arc Testnet — v2, superseded)

| Contract | Address | Explorer |
|---|---|---|
| AllowanceFactory v2 | `0x72159da6a1bb197c04632e7e61b5530b2c0159a2` | https://explorer.testnet.arc.io/address/0x72159da6a1bb197c04632e7e61b5530b2c0159a2 |
| AllowanceAccount demo v2 | `0xad361f8436a8130e8811c3c5c87761a04acd642f` | https://explorer.testnet.arc.io/address/0xad361f8436a8130e8811c3c5c87761a04acd642f |

## Demo Transactions (Arc Testnet — v2)

| Action | Tx Hash |
|---|---|
| Deploy factory | `0x8ab38e4bc7e801c2ba6fdf9568a36eaac5641de0e559e6c4e612503e4282840d` |
| createAccount | `0x055797d6e90dc8b9685d35d6cc7c6921b684029225e68df63044bcbf2ac2c6e6` |
| fund (5 USDC) | `0xe45fe325a0285bf72f570c6037b6516e8f4d71024a426aa4e3666fd202334419` |
| setAgent | `0xd26b294a0a38d6aab80bc4200a0383aec70fa09ddfddfa224994f10994bb7ceb` |
| **payWithSig (0.5 USDC → 0xdEaD)** | **`0x33c07f4d2b4e086f6f1437f0f71546eff9cf4304214b4ceb2e80a34173402aa9`** |

## Deployed Contracts (Arc Testnet — v1, pre-review, superseded)

| Contract | Address |
|---|---|
| AllowanceFactory v1 | `0x2D81436A9BC433498dB5B9B8bC7d09f33fd9504f` |
| AllowanceAccount v1 (demo) | `0x0e5a86b32ea12078f4fc31c33b3c441abaa30b72` |

## Source Files

- `contracts/AllowanceFactory.sol` — deploys AllowanceAccount instances; tracks owner index; handles ownership-transfer callbacks.
- `contracts/AllowanceAccount.sol` — holds funds, enforces agent policies, EIP-712 `payWithSig`, token-bucket period limits, `setPayeeBlocked`, `removeAgent`, `renounceOwnership` disabled.
- `contracts/test/TestHelpers.sol` — shared base and MockERC20.
- `contracts/test/Factory.t.sol` — factory, setAgent validation, removeAgent, renounceOwnership, ownership-transfer index (45 tests).
- `contracts/test/Spend.t.sol` — _spend error paths, freeze/unfreeze, blocked payee (47 tests).
- `contracts/test/TokenBucket.t.sol` — bucket maths, caps, burst documentation (16 tests).
- `contracts/test/Signatures.t.sol` — EIP-712 sig flows (13 tests).
- `contracts/test/CheckAgreement.t.sol` — fuzz: check() agrees with _spend (16 tests).
- `contracts/test/Invariant.t.sol` — 5 invariants × 256 runs × 500 calls each, including replay-never-succeeds and totalPaid mirror (5 invariants).
- `contracts/test/Reentrancy.t.sol` — ERC-1271 staticcall re-entry + reentrant ERC-20 payee (2 tests).

**Total: 144 tests, 0 failures.**

## Arc Testnet Chain Details

- Chain ID: 5042002
- RPC: https://rpc.testnet.arc.io
- USDC: 0x3600000000000000000000000000000000000000 (6 decimals)
- Explorer: https://explorer.testnet.arc.io
