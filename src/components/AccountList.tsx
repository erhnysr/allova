import { useState } from 'react'
import { Plus, ChevronRight } from 'lucide-react'
import { useAccount, useSwitchChain } from 'wagmi'
import { isAddress } from 'viem'
import { useAccounts } from '../hooks/useAccounts'
import { useNetwork } from '../hooks/useNetwork'
import { useTxFull } from '../hooks/useTx'
import { factoryAbi } from '../lib/abis'
import { formatAddr } from '../lib/format'
import { Button, Input, Skeleton, AddressChip } from './Ui'
import { explorerAddressUrl, SUPPORTED_NETWORKS } from '../lib/networks'

interface Props {
  onSelectAccount: (addr: `0x${string}`) => void
}

export function AccountList({ onSelectAccount }: Props) {
  const { address } = useAccount()
  const { net, chainId } = useNetwork()
  const { accounts, isLoading, refetch } = useAccounts()
  const { switchChain } = useSwitchChain()
  const { send, isPending } = useTxFull(chainId, () => { void refetch() })

  const [showCreate, setShowCreate] = useState(false)
  const [guardian, setGuardian] = useState('')
  const [guardianError, setGuardianError] = useState('')

  async function handleCreate() {
    if (!net || !address) return
    const g = (guardian.trim() || '0x0000000000000000000000000000000000000000') as `0x${string}`
    if (guardian.trim() && !isAddress(guardian.trim())) {
      setGuardianError('Invalid address')
      return
    }
    setGuardianError('')
    try {
      await send(
        { address: net.factoryAddress, abi: factoryAbi, functionName: 'createAccount', args: [g], chainId },
        'Create account'
      )
      setShowCreate(false)
      setGuardian('')
    } catch { /* handled in useTxFull */ }
  }

  // When net is undefined the wallet is on an unsupported chain — show the switch screen
  if (!net) {
    return (
      <div className="rounded-[20px] border border-[#1F2A47] bg-[#121B33] p-8 flex flex-col items-center gap-4 text-center">
        <p className="text-[#E6EBF5] font-medium">Allova runs on Arc.</p>
        <p className="text-sm text-[#8C97B2]">Switch network:</p>
        <div className="flex flex-wrap gap-3 justify-center">
          {SUPPORTED_NETWORKS.map(n => (
            <Button key={n.chain.id} onClick={() => switchChain({ chainId: n.chain.id })}>
              {n.chain.name}
            </Button>
          ))}
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <h2 className="font-medium text-xl text-[#E6EBF5]">Accounts</h2>
        <Button size="sm" variant="secondary" onClick={() => setShowCreate(v => !v)} disabled={!address}>
          <Plus size={13} /> New account
        </Button>
      </div>

      {showCreate && (
        <div className="rounded-[20px] border border-[#2A3658] bg-[#121B33] p-5 flex flex-col gap-4">
          <p className="text-sm text-[#8C97B2]">Deploy a new Allova account. You will be the owner.</p>
          <Input
            label="Guardian address (optional)"
            placeholder="0x… or leave blank"
            value={guardian}
            onChange={e => setGuardian(e.target.value)}
            error={guardianError}
            hint="Can freeze the account in emergencies. Cannot withdraw or change policies."
          />
          <div className="flex gap-2">
            <Button loading={isPending} onClick={() => { void handleCreate() }}>Deploy account</Button>
            <Button variant="ghost" onClick={() => { setShowCreate(false); setGuardian('') }}>Cancel</Button>
          </div>
        </div>
      )}

      {isLoading && (
        <div className="flex flex-col gap-2">
          {[0, 1].map(i => <Skeleton key={i} className="h-16 w-full rounded-xl" />)}
        </div>
      )}

      {!isLoading && (!accounts || accounts.length === 0) && (
        <div className="rounded-[20px] border border-[#1F2A47] bg-[#121B33] p-10 text-center">
          <p className="text-[#8C97B2] text-sm">No accounts yet. Create your first one.</p>
        </div>
      )}

      {!isLoading && accounts && accounts.length > 0 && (
        <div className="rounded-[20px] border border-[#1F2A47] bg-[#121B33] overflow-hidden divide-y divide-[#1F2A47]">
          {accounts.map(acc => (
            <div
              key={acc}
              className="relative flex items-center justify-between px-5 py-4 hover:bg-[#18233F] transition-colors group"
            >
              {/* Full-row nav button (sits behind the address chip controls) */}
              <button
                onClick={() => onSelectAccount(acc)}
                className="absolute inset-0 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[#A9BDF0]"
                aria-label={`Open account ${acc}`}
              />
              {/* Content row (pointer-events-none so clicks fall through to the nav button) */}
              <div className="relative flex items-center gap-3 pointer-events-none">
                <div className="w-8 h-8 rounded-xl bg-[#18233F] flex items-center justify-center text-xs font-mono text-[#8C97B2]"
                  style={{ fontFamily: "'DM Mono', monospace" }}>
                  {formatAddr(acc).slice(0, 2)}
                </div>
                {/* AddressChip copy/explorer buttons need pointer-events-auto to be clickable */}
                <div className="pointer-events-auto">
                  <AddressChip address={acc} explorerUrl={explorerAddressUrl(chainId!, acc)} />
                </div>
              </div>
              <ChevronRight size={15} className="relative text-[#8C97B2] group-hover:text-[#E6EBF5] transition-colors pointer-events-none" />
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
