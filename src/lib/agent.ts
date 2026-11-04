/**
 * Agent normalizer — converts the raw wagmi/viem readContract result for getAgent()
 * into a stable AgentInfo type with all fields as bigint.
 *
 * viem returns uint32 as JS number and uint64 as bigint, but we need all numeric
 * fields as bigint for safe arithmetic in computeAvailable / AgentCard.
 */

export interface AgentInfo {
  address: `0x${string}`
  label: string
  active: boolean
  expiresAt: bigint        // uint64 → bigint
  maxPerPayment: bigint    // uint128 → bigint
  periodLimit: bigint      // uint128 → bigint
  periodSeconds: bigint    // uint32  → bigint (normalised here)
  totalLimit: bigint       // uint128 → bigint
  bucket: bigint           // uint128 → bigint
  lastRefill: bigint       // uint64  → bigint
  totalSpent: bigint       // uint128 → bigint
  payeeRestricted: boolean
  /** v2 only: minimum seconds between payments (0n = off, and always 0n on v1) */
  minInterval: bigint
  /** v2 only: timestamp of the agent's last payment (0n on v1) */
  lastPaidAt: bigint
}

/**
 * The raw shape that viem/wagmi returns from getAgent().
 * periodSeconds is uint32 → number; expiresAt and lastRefill are uint64 → bigint;
 * everything else is uint128 → bigint.
 */
export interface RawAgentResult {
  label: string
  active: boolean
  expiresAt: bigint
  maxPerPayment: bigint
  periodLimit: bigint
  periodSeconds: number    // uint32 comes back as JS number
  totalLimit: bigint
  bucket: bigint
  lastRefill: bigint
  totalSpent: bigint
  payeeRestricted: boolean
  /** present on AllowanceAccount v2 only */
  minInterval?: number
  lastPaidAt?: bigint
}

/**
 * Convert a raw wagmi result to AgentInfo.
 * Safely widens periodSeconds (number) to bigint so arithmetic never mixes types.
 */
export function toAgentInfo(address: `0x${string}`, raw: RawAgentResult): AgentInfo {
  return {
    address,
    label:           raw.label,
    active:          raw.active,
    expiresAt:       raw.expiresAt,
    maxPerPayment:   raw.maxPerPayment,
    periodLimit:     raw.periodLimit,
    periodSeconds:   BigInt(raw.periodSeconds),   // uint32 number → bigint
    totalLimit:      raw.totalLimit,
    bucket:          raw.bucket,
    lastRefill:      raw.lastRefill,
    totalSpent:      raw.totalSpent,
    payeeRestricted: raw.payeeRestricted,
    minInterval:     BigInt(raw.minInterval ?? 0),
    lastPaidAt:      raw.lastPaidAt ?? 0n,
  }
}
