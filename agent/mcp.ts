#!/usr/bin/env bun
/**
 * Allova MCP server
 *
 * Exposes an agent's Allova policy as Model Context Protocol tools, so any
 * MCP-capable agent framework can check its budget and pay in USDC. The limits are
 * enforced by the AllowanceAccount contract onchain: this server cannot raise them,
 * and neither can the agent.
 *
 * Transport: stdio. Every log line goes to stderr; stdout carries MCP messages only.
 *
 * Environment:
 *   AGENT_PRIVATE_KEY        required — the agent key registered in the account
 *   ALLOWANCE_ACCOUNT        required — the AllowanceAccount address
 *   RELAYER_PRIVATE_KEY      optional — pays gas for payWithSig; defaults to the agent key
 *   NETWORK                  optional — testnet (default) | mainnet
 *   ALLOWANCE_ALLOW_MAINNET  must be "1" when NETWORK=mainnet (explicit opt-in)
 */

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { z } from 'zod'
import { privateKeyToAccount } from 'viem/accounts'
import type { Address, Hex } from 'viem'
import { createAllowanceClient, decodeContractError, type NetworkName } from './client'

const VERSION = '2.0.0'

function fail(msg: string): never {
  console.error(`allova-mcp: ${msg}`)
  process.exit(1)
}

function env(name: string): string {
  const v = process.env[name]
  if (!v) fail(`${name} is not set`)
  return v
}

const isAddress = (v: string): v is Address => /^0x[0-9a-fA-F]{40}$/.test(v)
const isKey = (v: string): v is Hex => /^0x[0-9a-fA-F]{64}$/.test(v)

// ── Config ────────────────────────────────────────────────────────────────────

const networkRaw = process.env['NETWORK'] ?? 'testnet'
if (networkRaw !== 'testnet' && networkRaw !== 'mainnet') fail('NETWORK must be testnet or mainnet')
if (networkRaw === 'mainnet' && process.env['ALLOWANCE_ALLOW_MAINNET'] !== '1') {
  fail('NETWORK=mainnet needs ALLOWANCE_ALLOW_MAINNET=1 (explicit opt-in for real funds)')
}
const network: NetworkName = networkRaw

const agentKey = env('AGENT_PRIVATE_KEY')
if (!isKey(agentKey)) fail('AGENT_PRIVATE_KEY must be a 0x-prefixed 32-byte hex key')
const account = env('ALLOWANCE_ACCOUNT')
if (!isAddress(account)) fail('ALLOWANCE_ACCOUNT is not a valid address')
const relayerKey = process.env['RELAYER_PRIVATE_KEY'] ?? agentKey
if (!isKey(relayerKey)) fail('RELAYER_PRIVATE_KEY must be a 0x-prefixed 32-byte hex key')

const agentAddress = privateKeyToAccount(agentKey).address
const client = createAllowanceClient(network)

// ── Helpers ───────────────────────────────────────────────────────────────────

const json = (value: unknown) => ({
  content: [{
    type: 'text' as const,
    text: JSON.stringify(value, (_k, v) => (typeof v === 'bigint' ? v.toString() : v), 2),
  }],
})

const error = (message: string) => ({
  isError: true,
  content: [{ type: 'text' as const, text: message }],
})

const usdcAmount = z
  .string()
  .regex(/^\d+(\.\d{1,6})?$/, 'USDC amount as a decimal string, up to 6 decimals, e.g. "0.25"')
  .describe('Amount in USDC, as a decimal string (e.g. "0.25")')

const payeeAddress = z
  .string()
  .regex(/^0x[0-9a-fA-F]{40}$/, 'EVM address')
  .describe('Recipient address (0x…)')

// ── Server ────────────────────────────────────────────────────────────────────

const server = new McpServer({ name: 'allova', version: VERSION })

server.registerTool(
  'allova_status',
  {
    title: 'Allova: policy and budget',
    description:
      'Return this agent\'s spending policy (per-payment cap, period budget, lifetime cap, expiry, ' +
      'payee mode, min interval) and what it can spend right now. Call this before planning paid work.',
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async () => {
    try {
      const [policy, availability] = await Promise.all([
        client.getPolicy(account, agentAddress),
        client.getAvailability(account, agentAddress),
      ])
      return json({ network, account, agent: agentAddress, policy, availability })
    } catch (err) {
      return error(decodeContractError(err))
    }
  },
)

server.registerTool(
  'allova_check',
  {
    title: 'Allova: dry-run a payment',
    description:
      'Check whether a payment would be accepted by the account contract right now, without sending ' +
      'anything. Returns ok=true or the exact reason it would be rejected.',
    inputSchema: { payee: payeeAddress, amount: usdcAmount },
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async ({ payee, amount }) => {
    try {
      const result = await client.check(account, agentAddress, payee as Address, amount)
      return json({ payee, amountUsdc: amount, ...result })
    } catch (err) {
      return error(decodeContractError(err))
    }
  },
)

server.registerTool(
  'allova_pay',
  {
    title: 'Allova: pay in USDC',
    description:
      'Pay `amount` USDC to `payee` from the shared account, within this agent\'s onchain policy. ' +
      'Runs check() first; if the policy would reject the payment nothing is sent. ' +
      'Returns the transaction hash and explorer link. The memo (max 32 bytes) is stored onchain.',
    inputSchema: {
      payee: payeeAddress,
      amount: usdcAmount,
      memo: z.string().max(32).optional().describe('Short reference stored onchain, max 32 bytes (e.g. an invoice id)'),
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
  },
  async ({ payee, amount, memo }) => {
    try {
      const pre = await client.check(account, agentAddress, payee as Address, amount)
      if (!pre.ok) return error(`Not sent: ${pre.message} (reason ${pre.reason})`)
      const signed = await client.signIntent(account, agentKey, payee as Address, amount, memo ?? '')
      const result = await client.relay(signed, relayerKey)
      return json({ paid: true, payee, amountUsdc: amount, memo: memo ?? '', ...result })
    } catch (err) {
      return error(err instanceof Error ? err.message : decodeContractError(err))
    }
  },
)

server.registerTool(
  'allova_audit',
  {
    title: 'Allova: payment history',
    description:
      'Return the onchain payment record (Paid events): time, payee, amount, memo, relayer and ' +
      'explorer link for each payment. Newest first.',
    inputSchema: {
      limit: z.number().int().min(1).max(500).optional().describe('Max rows, newest first (default 50)'),
      allAgents: z.boolean().optional().describe('Include payments by every agent of the account (default: this agent only)'),
    },
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async ({ limit, allAgents }) => {
    try {
      const rows = await client.audit(account, { agent: allAgents ? undefined : agentAddress })
      const newest = rows.slice().reverse().slice(0, limit ?? 50).map(r => ({
        ...r,
        timestampUtc: new Date(r.timestamp * 1000).toISOString(),
        explorerUrl: `${client.network.explorer}/tx/${r.txHash}`,
      }))
      return json({ count: rows.length, rows: newest })
    } catch (err) {
      return error(decodeContractError(err))
    }
  },
)

server.registerTool(
  'allova_invalidate_intents',
  {
    title: 'Allova: cancel pending signed payments',
    description:
      'Invalidate every payment intent this agent has signed but that has not been relayed yet ' +
      '(AllowanceAccount v2). Use it if a signed intent may have leaked.',
    inputSchema: {},
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  },
  async () => {
    try {
      const result = await client.invalidateIntents(account, agentAddress, agentKey)
      return json({ invalidated: true, ...result })
    } catch (err) {
      return error(err instanceof Error ? err.message : decodeContractError(err))
    }
  },
)

const transport = new StdioServerTransport()
await server.connect(transport)
console.error(`allova-mcp ${VERSION} ready — agent ${agentAddress} on ${network}, account ${account}`)
