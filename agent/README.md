# Allova — agent client

A small viem-only module for interacting with an AllowanceAccount from any agent framework.

## Setup

Copy `.env.example` (or set these environment variables directly):

```
AGENT_PRIVATE_KEY=0x...        # the key registered as the agent in the account
ALLOWANCE_ACCOUNT=0x...        # the AllowanceAccount contract address
RELAYER_PRIVATE_KEY=0x...      # optional: separate relayer; defaults to AGENT_PRIVATE_KEY
NETWORK=testnet                 # testnet (default) | mainnet (requires --mainnet flag)
```

**Never commit private keys.**

## CLI commands

### status

Print the agent policy and current availability.

```bash
bun run agent status
```

```
Agent:    0xABC...
Account:  0xDEF...
Network:  testnet

Label:          my-agent
Active:         true
Expires at:     2027-01-01T00:00:00.000Z
Max/payment:    0.5 USDC
Period limit:   5.0 USDC / 86400s
Lifetime cap:   50.0 USDC
Total spent:    1.25 USDC
Payee mode:     open

Available now:  3.75 USDC (period)   48.75 USDC (lifetime)
```

---

### check

Check whether a payment would go through right now, without sending anything.

```bash
bun run agent check 0xPayeeAddress 0.40
```

```
✓  Goes through  (0.40 USDC to 0xPayeeAddress)
```

If it would be rejected, exits with code 1 and prints the reason.

---

### sign

Sign a payment intent and print the JSON. No transaction is sent.

```bash
bun run agent sign 0xPayeeAddress 0.40 "invoice-42"
```

Prints a JSON object with `account`, `network`, `intent` (bigints as decimal strings), and `signature`. Save this to a file to relay separately:

```bash
# stdout is pure JSON — pipe or redirect safely
bun run agent sign 0xPayeeAddress 0.40 "invoice-42" > intent.json

# or use --out to write the file and keep stdout clean
bun run agent sign 0xPayeeAddress 0.40 "invoice-42" --out intent.json
```

---

### relay

Submit a previously signed intent to the chain. The relayer key is used (defaults to `AGENT_PRIVATE_KEY`).

```bash
bun run agent relay intent.json
```

```
✓  Relayed: https://explorer.testnet.arc.io/tx/0x...
```

---

### pay

Check, sign, and relay in one step.

```bash
bun run agent pay 0xPayeeAddress 0.40 "invoice-42"
```

```
✓  Paid 0.40 USDC to 0xPayeeAddress
   https://explorer.testnet.arc.io/tx/0x...
```

## Programmatic use

```ts
import { createAllowanceClient } from './agent/client'

const client = createAllowanceClient('testnet')

// Check
const result = await client.check(account, agentAddress, payee, '0.40')
if (!result.ok) throw new Error(result.message)

// Sign
const signed = await client.signIntent(account, agentKey, payee, '0.40', 'invoice-42')

// Relay (separate relayer key optional)
const { hash, explorerUrl } = await client.relay(signed, relayerKey)
console.log(explorerUrl)

// Or all-in-one
const { hash } = await client.pay(account, agentKey, payee, '0.40', 'invoice-42')
```

## Memo encoding

The `memo` / `ref` field is a `bytes32` on-chain. The CLI and client encode it as the UTF-8 bytes of the string, right-padded with zeros to 32 bytes. Maximum 32 UTF-8 bytes (not characters).

---

## v2 commands

### audit

Every payment of the account as CSV (default) or JSON, oldest first.

```bash
bun run agent audit                          # this agent, CSV to stdout
bun run agent audit --all-agents --out payments.csv
bun run agent audit --format json
```

Columns: `timestamp_utc, block, tx_hash, agent, payee, amount_usdc, memo, relayer, explorer_url`.

### invalidate (AllowanceAccount v2)

Cancel every intent this agent has signed but that has not been relayed yet.

```bash
bun run agent invalidate
```

## MCP server

`agent/mcp.ts` exposes the agent's policy as MCP tools over stdio, so any MCP-capable agent
can check its budget and pay. The limits stay onchain: the server cannot raise them.

| Tool | Read-only | What it does |
|---|---|---|
| `allova_status` | yes | Policy, budget left, min interval, intent epoch |
| `allova_check` | yes | Dry-run a payment; returns ok or the exact reason |
| `allova_pay` | no | Check, sign, relay; returns tx hash and explorer link |
| `allova_audit` | yes | Payment history, newest first |
| `allova_invalidate_intents` | no | Cancel pending signed intents (v2) |

MCP client config:

```json
{
  "mcpServers": {
    "allova": {
      "command": "bun",
      "args": ["run", "/path/to/allova/agent/mcp.ts"],
      "env": {
        "AGENT_PRIVATE_KEY": "0x...",
        "ALLOWANCE_ACCOUNT": "0x...",
        "NETWORK": "testnet"
      }
    }
  }
}
```

Mainnet needs `NETWORK=mainnet` **and** `ALLOWANCE_ALLOW_MAINNET=1`.
