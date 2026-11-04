import { parseUnits, formatUnits, BaseError, ContractFunctionRevertedError } from 'viem'
import { USDC_DECIMALS } from './networks'

export { USDC_DECIMALS }

/** Format a raw 6-decimal bigint as a fixed-decimal string, e.g. 1500000n → "1.50" */
export function formatUsdc(raw: bigint | number, decimals = 2): string {
  const val = formatUnits(BigInt(raw), USDC_DECIMALS)
  const num = parseFloat(val)
  return num.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

/**
 * Parse a plain decimal string to 6-decimal bigint.
 * Rejects blank, NaN, negative, and anything with more than 6 decimal places.
 * Returns 0n on invalid input.
 */
export function parseUsdc(value: string): bigint {
  const trimmed = value.trim()
  if (!trimmed || trimmed === '.' || trimmed === '-') return 0n
  // Reject if more than 6 decimal places
  const dotIdx = trimmed.indexOf('.')
  if (dotIdx !== -1 && trimmed.length - dotIdx - 1 > 6) return 0n
  try {
    const raw = parseUnits(trimmed, 6)
    if (raw < 0n) return 0n
    return raw
  } catch {
    return 0n
  }
}

/**
 * Validate a USDC amount string. Returns an error string or undefined.
 */
export function validateUsdc(value: string, fieldName = 'Amount'): string | undefined {
  const trimmed = value.trim()
  if (!trimmed) return `${fieldName} is required`
  const dotIdx = trimmed.indexOf('.')
  if (dotIdx !== -1 && trimmed.length - dotIdx - 1 > 6) return `${fieldName} has too many decimal places (max 6)`
  try {
    const raw = parseUnits(trimmed, 6)
    if (raw <= 0n) return `${fieldName} must be greater than zero`
  } catch {
    return `${fieldName} is not a valid number`
  }
  return undefined
}

export function formatAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`
  if (seconds < 86400) return `${Math.round(seconds / 3600)}h`
  return `${Math.round(seconds / 86400)}d`
}

export function formatExpiryCountdown(expiresAt: number): string {
  const diff = expiresAt - Math.floor(Date.now() / 1000)
  if (diff <= 0) return 'Expired'
  const days = Math.floor(diff / 86400)
  const hours = Math.floor((diff % 86400) / 3600)
  if (days > 0) return `${days}d ${hours}h`
  const mins = Math.floor((diff % 3600) / 60)
  return `${hours}h ${mins}m`
}

export function formatTimestamp(ts: number): string {
  return new Date(ts * 1000).toLocaleString('en-US', {
    month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

/** Decode a bytes32 ref to a readable string, trimming null bytes */
export function decodeRef(ref: `0x${string}`): string {
  try {
    const hex = ref.slice(2)
    const bytes = new Uint8Array(hex.match(/.{1,2}/g)!.map(b => parseInt(b, 16)))
    const end = bytes.findIndex(b => b === 0)
    const trimmed = bytes.slice(0, end === -1 ? 32 : end)
    return new TextDecoder().decode(trimmed)
  } catch {
    return ''
  }
}

/** Encode a string to bytes32 */
export function encodeRef(memo: string): `0x${string}` {
  const bytes = new TextEncoder().encode(memo.slice(0, 32))
  const padded = new Uint8Array(32)
  padded.set(bytes)
  return `0x${Array.from(padded).map(b => b.toString(16).padStart(2, '0')).join('')}`
}

export function checkReasonText(code: number): string {
  const reasons: Record<number, string> = {
    0: 'Would succeed',
    1: 'Amount is zero',
    2: 'Account is frozen',
    3: 'Not a registered agent',
    4: 'Agent is revoked',
    5: 'Agent has expired',
    6: 'Invalid payee address',
    7: 'Payee blocked or not allowlisted',
    8: 'Exceeds per-payment limit',
    9: 'Exceeds period budget',
    10: 'Exceeds lifetime total',
    11: 'Exceeds payee cap',
    12: 'Account balance too low',
    13: 'Too soon after the last payment',
  }
  return reasons[code] ?? `Unknown code ${code}`
}

// Walk the cause chain to find a wallet error code (EIP-1193 / provider-specific).
// viem wraps wallet errors: writeContract → ContractFunctionExecutionError →
// TransactionExecutionError → ResourceUnavailableRpcError (code -32002).
// The top-level error has code=undefined; only the innermost cause has the real code.
const WALLET_CODES = [-32002, 4001, 4100, 4902]
function walletCode(error: unknown): number | undefined {
  let e: unknown = error
  for (let i = 0; i < 10 && e; i++) {
    const c = (e as { code?: unknown }).code
    if (typeof c === 'number' && WALLET_CODES.includes(c)) return c
    e = (e as { cause?: unknown }).cause
  }
  return undefined
}

/**
 * Decode a viem/wagmi error to a user-readable string.
 * Uses BaseError.walk + ContractFunctionRevertedError for onchain reverts.
 */
export function parseOnchainError(error: unknown): string {
  // Wallet-level error codes — walk the full cause chain first
  const code = walletCode(error)
  if (code === -32002) {
    return 'Your wallet has a pending request. Open your wallet and approve or reject it, then try again.'
  }
  if (code === 4001) {
    return 'Cancelled.'
  }
  if (code === 4100) {
    return 'Unlock your wallet or connect this site.'
  }
  if (code === 4902) {
    return 'Add this network to your wallet, then try again.'
  }

  // Check for user rejection first (not a BaseError)
  const anyMsg = (error as Error)?.message ?? String(error)
  const lower = anyMsg.toLowerCase()
  if (lower.includes('user rejected') || lower.includes('user denied') || lower.includes('rejected the request')) {
    return 'Cancelled.'
  }

  // Walk viem BaseError chain for contract revert data
  if (error instanceof BaseError) {
    const revert = error.walk(e => e instanceof ContractFunctionRevertedError)
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName ?? ''
      if (name) return decodeErrorName(name)
    }
    // Fallback: scan the full message
    return decodeByMessage(error.message) ?? (error.shortMessage ?? error.message).slice(0, 120)
  }

  return decodeByMessage(anyMsg) ?? (anyMsg.length > 120 ? anyMsg.slice(0, 120) + '…' : anyMsg)
}

function decodeErrorName(name: string): string {
  const map: Record<string, string> = {
    AccountFrozen: 'Account is frozen.',
    AgentRevoked: 'Agent is revoked.',
    AgentExpired: 'Agent has expired.',
    UnknownAgent: 'Not a registered agent.',
    OverPeriodLimit: 'Exceeds period budget.',
    OverTotalLimit: 'Exceeds lifetime total.',
    OverPerPayment: 'Exceeds per-payment limit.',
    OverPayeeCap: 'Exceeds payee cap.',
    PayeeNotAllowed: 'Payee blocked or not allowlisted.',
    InvalidPayee: 'Invalid payee address.',
    InsufficientBalance: 'Account balance too low.',
    ZeroAmount: 'Amount must be greater than zero.',
    ZeroAddress: 'Address cannot be zero.',
    NonceAlreadyUsed: 'Nonce already used.',
    DeadlinePassed: 'Signature deadline passed.',
    InvalidSignature: 'Invalid signature.',
    TooManyAgents: 'Maximum of 20 agents reached.',
    TotalLimitBelowSpent: 'New total limit is below amount already spent.',
    CapBelowSpent: 'New payee cap is below amount already spent.',
    InvalidLimits: 'Invalid limits: maxPerPayment ≤ periodLimit ≤ totalLimit required.',
    InvalidPeriodSeconds: 'Period must be between 60 s and 30 days.',
    InvalidExpiresAt: 'Expiry must be in the range (now, now + 365 days].',
    InvalidLabel: 'Label exceeds 32 bytes.',
    InvalidAgentAddress: 'Invalid agent address.',
    RenounceDisabled: 'Ownership renounce is disabled.',
    NotGuardianOrOwner: 'Only the guardian or owner can call this.',
  }
  return map[name] ?? `Reverted: ${name}`
}

function decodeByMessage(msg: string): string | undefined {
  const lower = msg.toLowerCase()
  if (lower.includes('accountfrozen')) return 'Account is frozen.'
  if (lower.includes('agentrevoked')) return 'Agent is revoked.'
  if (lower.includes('agentexpired')) return 'Agent has expired.'
  if (lower.includes('unknownagent')) return 'Not a registered agent.'
  if (lower.includes('overperiodlimit') || lower.includes('overperperiod')) return 'Exceeds period budget.'
  if (lower.includes('overtotallimit')) return 'Exceeds lifetime total.'
  if (lower.includes('overperpayment')) return 'Exceeds per-payment limit.'
  if (lower.includes('overpayeecap')) return 'Exceeds payee cap.'
  if (lower.includes('payeenotallowed')) return 'Payee blocked or not allowlisted.'
  if (lower.includes('invalidpayee')) return 'Invalid payee address.'
  if (lower.includes('insufficientbalance')) return 'Account balance too low.'
  if (lower.includes('zeroamount')) return 'Amount must be greater than zero.'
  if (lower.includes('zeroaddress')) return 'Address cannot be zero.'
  if (lower.includes('noncenotused') || lower.includes('noncealreadyused')) return 'Nonce already used.'
  if (lower.includes('deadlinepassed')) return 'Signature deadline passed.'
  if (lower.includes('invalidsignature')) return 'Invalid signature.'
  if (lower.includes('toomanyagents')) return 'Maximum of 20 agents reached.'
  if (lower.includes('totallimitbelowspent')) return 'New total limit is below amount already spent.'
  if (lower.includes('capbelowspent')) return 'New payee cap is below amount already spent.'
  if (lower.includes('invalidlimits')) return 'Invalid limits: maxPerPayment ≤ periodLimit ≤ totalLimit required.'
  if (lower.includes('invalidperiodseconds')) return 'Period must be between 60 s and 30 days.'
  if (lower.includes('invalidexpiresat')) return 'Expiry must be in the range (now, now + 365 days].'
  if (lower.includes('invalidlabel')) return 'Label exceeds 32 bytes.'
  if (lower.includes('invalidagentaddress')) return 'Invalid agent address.'
  if (lower.includes('insufficient funds')) return 'Insufficient gas. Your wallet needs USDC for gas.'
  if (lower.includes('reverted')) return 'Transaction reverted.'
  if (lower.includes('network') || lower.includes('timeout')) return 'Network error — please retry.'
  return undefined
}
