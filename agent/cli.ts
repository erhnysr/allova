#!/usr/bin/env bun
/**
 * Allova agent CLI
 *
 * Usage: bun run agent/cli.ts <command> [args]
 *
 * Environment:
 *   AGENT_PRIVATE_KEY      required — the agent's private key (0x...)
 *   ALLOWANCE_ACCOUNT      required — the AllowanceAccount contract address
 *   RELAYER_PRIVATE_KEY    optional — if set, relay uses this key; otherwise agent key is used
 *   NETWORK                optional — "testnet" (default) or "mainnet"
 *
 * Commands:
 *   status
 *   check <payee> <amount>
 *   sign <payee> <amount> [memo] [--out <file>]
 *   relay <file.json>
 *   pay <payee> <amount> [memo]
 *   audit [--format csv|json] [--out <file>] [--all-agents] [--from-block <n>]
 *   invalidate                (v2) cancel every signed-but-unrelayed intent of this agent
 *
 * All logs and headers go to stderr. Only the JSON output of "sign" goes to stdout,
 * so you can safely pipe: bun run agent sign ... > intent.json
 */

import { readFileSync, writeFileSync } from 'fs'
import { privateKeyToAccount } from 'viem/accounts'
import type { Hex, Address } from 'viem'
import {
  auditToCsv,
  createAllowanceClient,
  decodeContractError,
  type NetworkName,
  type SignedIntent,
} from './client'

// ── Helpers ───────────────────────────────────────────────────────────────────

/** All logs, headers and progress go to stderr so stdout stays clean for JSON. */
function log(...a: unknown[]): void  { console.error(...a) }
function logn(): void                { console.error('') }

function die(msg: string): never {
  console.error(`\nError: ${msg}\n`)
  // eslint-disable-next-line n/no-process-exit
  process.exit(1)
}

function envVar(name: string, required = true): string {
  const v = process.env[name]
  if (!v && required) die(`${name} is not set`)
  return v ?? ''
}

function requireHex(v: string, name: string): Hex {
  if (!v.startsWith('0x')) die(`${name} must start with 0x`)
  return v as Hex
}

function requireAddress(v: string, name: string): Address {
  if (!/^0x[0-9a-fA-F]{40}$/.test(v)) die(`${name} is not a valid Ethereum address`)
  return v as Address
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args    = process.argv.slice(2)
  const command = args[0]

  if (!command || command === '--help' || command === '-h') {
    // Help goes to stdout as it is the intended output
    console.log(`
Allova agent CLI

Commands:
  status                               Print the agent policy and current availability
  check <payee> <amount>               Check whether a payment would go through
  sign <payee> <amount> [memo]         Sign a payment intent; prints JSON to stdout
       [--out <file>]                  Also write the JSON to <file>
  relay <file.json>                    Relay a previously signed intent file
  pay <payee> <amount> [memo]          Check → sign → relay in one step
  audit [--format csv|json]            Export every payment (Paid events) of the account
        [--out <file>] [--all-agents]  Default: this agent only, CSV to stdout
        [--from-block <n>]
  invalidate                           v2: cancel all of this agent's pending signed intents

Environment:
  AGENT_PRIVATE_KEY      Agent private key (0x...)
  ALLOWANCE_ACCOUNT      AllowanceAccount contract address
  RELAYER_PRIVATE_KEY    Optional relayer key; defaults to agent key
  NETWORK                testnet (default) | mainnet (requires --mainnet flag)
`.trim())
    process.exit(0)
  }

  // Mainnet guard
  const rawNetwork = process.env['NETWORK'] ?? 'testnet'
  if (rawNetwork === 'mainnet' && !args.includes('--mainnet')) {
    die('Mainnet requires the --mainnet flag. Double-check your NETWORK setting.')
  }
  const network: NetworkName = rawNetwork === 'mainnet' ? 'mainnet' : 'testnet'

  const agentKeyRaw = envVar('AGENT_PRIVATE_KEY')
  const accountRaw  = envVar('ALLOWANCE_ACCOUNT')
  const agentKey    = requireHex(agentKeyRaw, 'AGENT_PRIVATE_KEY')
  const account     = requireAddress(accountRaw, 'ALLOWANCE_ACCOUNT')

  const agentAddress = privateKeyToAccount(agentKey).address
  const client       = createAllowanceClient(network)

  // Header always goes to stderr so stdout stays clean for JSON output
  log(`Agent:    ${agentAddress}`)
  log(`Account:  ${account}`)
  log(`Network:  ${network}`)
  logn()

  switch (command) {

    // ── status ──────────────────────────────────────────────────────────────
    case 'status': {
      const [policy, avail] = await Promise.all([
        client.getPolicy(account, agentAddress),
        client.getAvailability(account, agentAddress),
      ])

      log(`Label:          ${policy.label || '(none)'}`)
      log(`Active:         ${policy.active}`)
      log(`Expires at:     ${policy.expiresAt === 0 ? 'never' : new Date(policy.expiresAt * 1000).toISOString()}`)
      log(`Max/payment:    ${policy.maxPerPaymentUsdc} USDC`)
      log(`Period limit:   ${policy.periodLimitUsdc} USDC / ${policy.periodSeconds}s`)
      log(`Lifetime cap:   ${policy.totalLimitUsdc} USDC`)
      log(`Total spent:    ${policy.totalSpentUsdc} USDC`)
      log(`Payee mode:     ${policy.payeeRestricted ? 'allowlist' : 'open'}`)
      log(`Contract:       v${policy.version}`)
      if (policy.version === 2) {
        log(`Min interval:   ${policy.minIntervalSeconds ? `${policy.minIntervalSeconds}s between payments` : 'off'}`)
        log(`Intent epoch:   ${policy.intentEpoch}`)
      }
      logn()
      log(`Available now:  ${avail.periodAvailableUsdc} USDC (period)   ${avail.totalRemainingUsdc} USDC (lifetime)`)
      break
    }

    // ── check ───────────────────────────────────────────────────────────────
    case 'check': {
      const payee  = requireAddress(args[1] ?? die('payee required'), 'payee')
      const amount = args[2] ?? die('amount required')

      const result = await client.check(account, agentAddress, payee, amount)
      if (result.ok) {
        log(`✓  Goes through  (${amount} USDC to ${payee})`)
      } else {
        log(`✗  Rejected: ${result.message}  (reason code ${result.reason})`)
        process.exit(1)
      }
      break
    }

    // ── sign ─────────────────────────────────────────────────────────────────
    case 'sign': {
      // Parse --out <file> from args (can appear anywhere after the command)
      const outIdx  = args.indexOf('--out')
      const outFile = outIdx !== -1 ? (args[outIdx + 1] ?? die('--out requires a filename')) : null

      // Positional args after 'sign': <payee> <amount> [memo]
      // Strip --out and its value so they don't land in positional slots
      const positional: string[] = args.slice(1).filter(
        (a: string, i: number, arr: string[]) => a !== '--out' && (i === 0 || arr[i - 1] !== '--out')
      )
      const payee  = requireAddress(positional[0] ?? die('payee required'), 'payee')
      const amount: string = positional[1] ?? die('amount required')
      const memo:   string = positional[2] ?? ''

      log('Reminder: keep AGENT_PRIVATE_KEY secret.')
      logn()

      const signed = await client.signIntent(account, agentKey, payee, amount, memo)

      // Serialise bigints as decimal strings so JSON.parse round-trips cleanly
      const out = JSON.stringify({
        account: signed.account,
        network: signed.network,
        intent: {
          agent:    signed.intent.agent,
          payee:    signed.intent.payee,
          amount:   signed.intent.amount.toString(),
          nonce:    signed.intent.nonce.toString(),
          deadline: signed.intent.deadline.toString(),
          ref:      signed.intent.ref,
        },
        signature: signed.signature,
      }, null, 2)

      // JSON goes to stdout only — the header/reminder above is already on stderr
      console.log(out)

      if (outFile) {
        writeFileSync(outFile, out + '\n', 'utf8')
        log(`Wrote intent to ${outFile}`)
      }
      break
    }

    // ── relay ─────────────────────────────────────────────────────────────────
    case 'relay': {
      log('Reminder: keep RELAYER_PRIVATE_KEY secret.')
      logn()

      const file = args[1] ?? die('file.json required')
      let raw: {
        account:   string
        network:   string
        intent: {
          agent: string; payee: string; amount: string
          nonce: string; deadline: string; ref: string
        }
        signature: string
      }
      try {
        raw = JSON.parse(readFileSync(file, 'utf8')) as typeof raw
      } catch (e) {
        die(`Could not read ${file}: ${(e as Error).message}`)
      }

      // Network guard: refuse if the file's network does not match NETWORK
      const fileNetwork: NetworkName = raw.network === 'mainnet' ? 'mainnet' : 'testnet'
      if (fileNetwork !== network) {
        die(
          `Network mismatch: intent file is for "${fileNetwork}" but NETWORK is "${network}". ` +
          `Set NETWORK=${fileNetwork} or use the correct intent file.`
        )
      }

      // Deadline guard: refuse before sending
      const deadlineSec = Number(raw.intent.deadline)
      const nowSec      = Math.floor(Date.now() / 1000)
      if (deadlineSec <= nowSec) {
        die(
          `Intent has expired (deadline ${new Date(deadlineSec * 1000).toISOString()}, ` +
          `now ${new Date(nowSec * 1000).toISOString()}). Sign a new intent.`
        )
      }

      const signed: SignedIntent = {
        account:  requireAddress(raw.account,       'account'),
        network:  fileNetwork,
        intent: {
          agent:    requireAddress(raw.intent.agent, 'agent'),
          payee:    requireAddress(raw.intent.payee, 'payee'),
          amount:   BigInt(raw.intent.amount),
          nonce:    BigInt(raw.intent.nonce),
          deadline: BigInt(raw.intent.deadline),
          ref:      requireHex(raw.intent.ref,       'ref'),
        },
        signature: requireHex(raw.signature, 'signature'),
      }

      const relayKeyRaw = process.env['RELAYER_PRIVATE_KEY'] ?? agentKeyRaw
      const relayerKey  = requireHex(relayKeyRaw, 'RELAYER_PRIVATE_KEY')

      try {
        const result = await client.relay(signed, relayerKey)
        log(`✓  Relayed: ${result.explorerUrl}`)
      } catch (err) {
        die(decodeContractError(err))
      }
      break
    }

    // ── pay ──────────────────────────────────────────────────────────────────
    case 'pay': {
      log('Reminder: keep AGENT_PRIVATE_KEY secret.')
      logn()

      const payee:  Address = requireAddress(args[1] ?? die('payee required'), 'payee')
      const amount: string  = args[2] ?? die('amount required')
      const memo:   string  = args[3] ?? ''

      const relayKeyRaw = process.env['RELAYER_PRIVATE_KEY'] ?? agentKeyRaw
      const relayerKey  = requireHex(relayKeyRaw, 'RELAYER_PRIVATE_KEY')

      // check first
      const checkResult = await client.check(account, agentAddress, payee, amount)
      if (!checkResult.ok) {
        die(`Payment would fail: ${checkResult.message} (reason ${checkResult.reason})`)
      }
      log(`✓  Check passed`)

      // sign
      const signed = await client.signIntent(account, agentKey, payee, amount, memo)
      log(`✓  Intent signed`)

      // relay
      try {
        const result = await client.relay(signed, relayerKey)
        log(`✓  Paid ${amount} USDC to ${payee}`)
        log(`   ${result.explorerUrl}`)
      } catch (err) {
        die(decodeContractError(err))
      }
      break
    }

    // ── audit ─────────────────────────────────────────────────────────────────
    case 'audit': {
      const flag = (name: string): string | null => {
        const i = args.indexOf(name)
        return i === -1 ? null : (args[i + 1] ?? die(`${name} requires a value`))
      }
      const format   = flag('--format') ?? 'csv'
      const outFile  = flag('--out')
      const fromRaw  = flag('--from-block')
      if (format !== 'csv' && format !== 'json') die('--format must be csv or json')

      log('Reading Paid events…')
      const rows = await client.audit(account, {
        agent:     args.includes('--all-agents') ? undefined : agentAddress,
        fromBlock: fromRaw ? BigInt(fromRaw) : undefined,
      })
      const out = format === 'csv'
        ? auditToCsv(rows, network)
        : JSON.stringify(rows.map(r => ({ ...r, blockNumber: r.blockNumber.toString() })), null, 2) + '\n'

      process.stdout.write(out)
      if (outFile) {
        writeFileSync(outFile, out, 'utf8')
        log(`Wrote ${rows.length} payment(s) to ${outFile}`)
      } else {
        log(`${rows.length} payment(s)`)
      }
      break
    }

    // ── invalidate (v2) ───────────────────────────────────────────────────────
    case 'invalidate': {
      try {
        const result = await client.invalidateIntents(account, agentAddress, agentKey)
        log(`✓  All pending intents of ${agentAddress} invalidated`)
        log(`   ${result.explorerUrl}`)
      } catch (err) {
        die(decodeContractError(err))
      }
      break
    }

    default:
      die(`Unknown command: ${command}. Run with --help for usage.`)
  }
}

main().catch((err: unknown) => {
  console.error(`\nFatal: ${err instanceof Error ? err.message : String(err)}`)
  process.exit(1)
})
