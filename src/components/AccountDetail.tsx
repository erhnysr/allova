import { useReadContract } from 'wagmi'
import { useAccount } from 'wagmi'
import { AccountHeader } from './AccountHeader'
import { AgentsPanel } from './AgentsPanel'
import { PayeesPanel } from './PayeesPanel'
import { ActivityPanel } from './ActivityPanel'
import { CheckPlayground } from './CheckPlayground'
import { Playground } from './Playground'
import { Skeleton, Button } from './Ui'
import { type NavItem } from './Layout'
import { useNetwork } from '../hooks/useNetwork'
import { factoryAbi } from '../lib/abis'

interface Props {
  accountAddress: `0x${string}`
  activeNav: NavItem
  onBack: () => void
}

export function AccountDetail({ accountAddress, activeNav, onBack }: Props) {
  const { chain: walletChain } = useAccount()
  const { net, chainId } = useNetwork()
  const isTestnet = net?.isTestnet ?? false

  // ── Factory isAccount guard ─────────────────────────────────────────────────
  // Determine which chain name to show in error messages.
  const chainName = net?.chain.name ?? walletChain?.name ?? 'this network'

  // Case: connected to a known chain but factory not yet deployed (empty address)
  const noFactory = !net

  const {
    data: isAccountResult,
    isLoading: isAccountLoading,
    isError: isAccountError,
    refetch: refetchIsAccount,
  } = useReadContract({
    address: net?.factoryAddress,
    abi: factoryAbi,
    functionName: 'isAccount',
    args: [accountAddress],
    chainId: chainId as number,
    query: { enabled: !noFactory && !!chainId },
  })

  // ── Loading skeleton ────────────────────────────────────────────────────────
  if (!noFactory && isAccountLoading) {
    return (
      <div className="flex flex-col gap-5 max-w-5xl">
        <div className="flex items-center gap-3 mb-1">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-40" />
        </div>
        <Skeleton className="h-40 w-full rounded-[20px]" />
        <Skeleton className="h-64 w-full rounded-[20px]" />
      </div>
    )
  }

  // ── No factory on this network ──────────────────────────────────────────────
  if (noFactory) {
    return (
      <div className="max-w-lg">
        <button
          onClick={onBack}
          className="flex items-center gap-1 text-[#8C97B2] hover:text-[#E6EBF5] text-sm transition-colors mb-4"
        >
          ← All accounts
        </button>
        <div className="rounded-[20px] border border-[#2A3658] bg-[#121B33] px-6 py-8 text-center flex flex-col gap-3">
          <p className="text-[#F2C27B] font-medium text-sm">Not deployed yet</p>
          <p className="text-[#8C97B2] text-xs">
            Allova isn't deployed on {chainName} yet.
          </p>
          <button
            onClick={onBack}
            className="mt-2 text-xs text-[#A9BDF0] hover:text-[#BFD0F7] underline underline-offset-2 transition-colors"
          >
            Go back
          </button>
        </div>
      </div>
    )
  }

  // ── RPC / read error ────────────────────────────────────────────────────────
  if (isAccountError) {
    return (
      <div className="max-w-lg">
        <button
          onClick={onBack}
          className="flex items-center gap-1 text-[#8C97B2] hover:text-[#E6EBF5] text-sm transition-colors mb-4"
        >
          ← All accounts
        </button>
        <div className="rounded-[20px] border border-[#2A3658] bg-[#121B33] px-6 py-8 text-center flex flex-col gap-3 items-center">
          <p className="text-[#8C97B2] text-sm">Couldn't load this account.</p>
          <Button size="sm" variant="secondary" onClick={() => { void refetchIsAccount() }}>
            Retry
          </Button>
          <button
            onClick={onBack}
            className="text-xs text-[#A9BDF0] hover:text-[#BFD0F7] underline underline-offset-2 transition-colors"
          >
            Go back
          </button>
        </div>
      </div>
    )
  }

  // ── Not an AllowanceAccount ─────────────────────────────────────────────────
  if (isAccountResult === false) {
    return (
      <div className="max-w-lg">
        <button
          onClick={onBack}
          className="flex items-center gap-1 text-[#8C97B2] hover:text-[#E6EBF5] text-sm transition-colors mb-4"
        >
          ← All accounts
        </button>
        <div className="rounded-[20px] border border-[#5B3440] bg-[#1E1A2E] px-6 py-8 text-center flex flex-col gap-3">
          <p className="text-[#F2A0A0] font-medium text-sm">Not an Allova account</p>
          <p className="text-[#8C97B2] text-xs">
            <span className="font-mono text-[#C3D1F5]">{accountAddress}</span>
            {' '}isn't an Allova account on {chainName}.
          </p>
          <button
            onClick={onBack}
            className="mt-2 text-xs text-[#A9BDF0] hover:text-[#BFD0F7] underline underline-offset-2 transition-colors"
          >
            Go back
          </button>
        </div>
      </div>
    )
  }

  // ── Playground fallback: nav to overview if not testnet ─────────────────────
  const effectiveNav: NavItem =
    activeNav === 'playground' && !isTestnet ? 'overview' : activeNav

  return (
    <div className="flex flex-col gap-5 max-w-5xl">
      <AccountHeader accountAddress={accountAddress} onBack={onBack} />

      {effectiveNav === 'overview' && (
        <div className="flex gap-6 items-start">
          {/* Left: agents + activity */}
          <div className="flex-1 min-w-0 flex flex-col gap-8">
            <AgentsPanel accountAddress={accountAddress} />
            <ActivityPanel accountAddress={accountAddress} />
          </div>
          {/* Right: simulator sticky */}
          <div className="hidden lg:block w-[300px] shrink-0 sticky top-6">
            <CheckPlayground accountAddress={accountAddress} />
          </div>
        </div>
      )}

      {effectiveNav === 'overview' && (
        <div className="lg:hidden">
          <CheckPlayground accountAddress={accountAddress} />
        </div>
      )}

      {effectiveNav === 'agents' && (
        <AgentsPanel accountAddress={accountAddress} />
      )}

      {effectiveNav === 'payees' && (
        <PayeesPanel accountAddress={accountAddress} />
      )}

      {effectiveNav === 'activity' && (
        <ActivityPanel accountAddress={accountAddress} />
      )}

      {effectiveNav === 'playground' && (
        <Playground accountAddress={accountAddress} onChanged={() => {}} />
      )}
    </div>
  )
}
