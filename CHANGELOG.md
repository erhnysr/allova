# Changelog

## 2.0.0 (unreleased, Arc Testnet first)

Fixes for the three findings reported against v1, plus burst control and agent tooling.

### Contracts
- **Intent epochs.** A `PaymentIntent` nonce carries the agent's epoch in its upper 64 bits.
  `revokeAgent`, `removeAgent` and the new `invalidateIntents` bump the epoch, so an intent
  signed before any of them can never be relayed afterwards (`StaleIntent`).
- **Payee rules reset on removal.** `removeAgent` starts a new payee-rule generation:
  allowlist entries and per-payee caps no longer carry over to a re-added key.
- **Explicit deny in open mode.** `setPayee(agent, payee, false, cap)` now denies the payee in
  open mode too. Blocks set with `setPayeeBlocked` stay sticky: `setPayee(..., true, ...)`
  never clears them.
- **Min interval.** `configureAgent(agent, AgentPolicy)` sets the whole policy in one call,
  including `minInterval`, the minimum seconds between two payments. `check()` returns
  `13` (`TooSoon`) when a payment comes too early.
- New views: `intentEpoch(agent)`, `nonceFor(agent, seq)`, `version()`.
- `setAgent` (8 arguments) is unchanged and keeps an existing `minInterval`.

### Agent tooling
- Client detects v1 or v2 per account; v1 (the live mainnet account) keeps working.
- `audit`: every payment (Paid events) as CSV or JSON: time, agent, payee, amount, memo,
  relayer, explorer link.
- `invalidate`: an agent cancels all of its pending signed intents.
- MCP server (`bun run mcp`): `allowance_status`, `allowance_check`, `allowance_pay`,
  `allowance_audit`, `allowance_invalidate_intents`.

### Tests
- 5 regression tests that reproduce the v1 findings (they fail on v1, pass on v2).
- 18 v2 feature and fuzz tests.
- 2 new invariants (no stale intent is ever relayed; no two payments closer than
  `minInterval`), each checked against a mutant contract that removes the guard.

## 1.0.0 — 2026-10-18

Arc mainnet build: AllowanceFactory `0xa48fdee3cc6ec2909da8fbec0d2f14032e92c5ec`, 144 tests.
