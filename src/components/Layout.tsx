import { type ReactNode } from 'react'
import { ConnectKitButton } from 'connectkit'
import { ExternalLink } from 'lucide-react'
import { useAccount, useDisconnect } from 'wagmi'
import { useNetwork } from '../hooks/useNetwork'
import { formatAddr } from '../lib/format'

// ── Logo mark: rounded square + semicircle gauge arc ─────────────────────────
export function LogoMark() {
  return (
    <svg width="28" height="28" viewBox="0 0 28 28" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="28" height="28" rx="8" fill="#18233F" />
      {/* Semicircle gauge track */}
      <path
        d="M7 19 A9 9 0 0 1 21 19"
        stroke="#2A3658"
        strokeWidth="2.5"
        strokeLinecap="round"
        fill="none"
      />
      {/* Gauge fill ~70% */}
      <path
        d="M7 19 A9 9 0 0 1 21 19"
        stroke="#A9BDF0"
        strokeWidth="2.5"
        strokeLinecap="round"
        strokeDasharray="70 100"
        pathLength="100"
        fill="none"
      />
      {/* Dot at gauge tip */}
      <circle cx="19.5" cy="11.5" r="1.5" fill="#A9BDF0" />
    </svg>
  )
}

// ── CK connect button style vars (applied to the button itself, not the modal)
export const ckButtonVars = {
  '--ck-connectbutton-background': '#A9BDF0',
  '--ck-connectbutton-color': '#0B1226',
  '--ck-connectbutton-hover-background': '#BFD0F7',
  '--ck-connectbutton-border-radius': '999px',
  '--ck-connectbutton-font-size': '14px',
} as React.CSSProperties

// ── Nav item type ─────────────────────────────────────────────────────────────
export type NavItem = 'overview' | 'agents' | 'payees' | 'playground' | 'activity'

// ── Nav data ──────────────────────────────────────────────────────────────────
export const NAV_ITEMS: { id: NavItem; label: string; testnetOnly?: boolean }[] = [
  { id: 'overview',   label: 'Overview' },
  { id: 'agents',     label: 'Agents' },
  { id: 'payees',     label: 'Payees' },
  { id: 'playground', label: 'Playground', testnetOnly: true },
  { id: 'activity',   label: 'Activity' },
]

const NAV_ICONS: Record<NavItem, JSX.Element> = {
  overview:   <NavIcon d="M3 12L12 3l9 9M4 10v10a1 1 0 001 1h5m5 0h2a1 1 0 001-1V10" />,
  agents:     <NavIcon d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />,
  payees:     <NavIcon d="M17 8l4 4m0 0l-4 4m4-4H3" />,
  playground: <NavIcon d="M5 3l14 9-14 9V3z" />,
  activity:   <NavIcon d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />,
}

function NavIcon({ d }: { d: string }) {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <path d={d} />
    </svg>
  )
}

// ── Sidebar props ─────────────────────────────────────────────────────────────
interface SidebarProps {
  activeItem: NavItem | null
  onNav: (item: NavItem) => void
  showAccountNav: boolean
  isTestnet: boolean
}

// ── Desktop Sidebar ───────────────────────────────────────────────────────────
export function Sidebar({ activeItem, onNav, showAccountNav, isTestnet }: SidebarProps) {
  const { address } = useAccount()
  const { net } = useNetwork()
  const { disconnect } = useDisconnect()

  const visibleItems = showAccountNav
    ? NAV_ITEMS.filter(i => !i.testnetOnly || isTestnet)
    : []

  return (
    <aside
      className="hidden md:flex flex-col shrink-0 bg-[#0E1630] border-r border-[#1F2A47] h-full"
      style={{ width: 232 }}
    >
      {/* Logo */}
      <div className="flex items-center gap-2.5 px-5 h-14 border-b border-[#1F2A47] shrink-0">
        <LogoMark />
        <span className="text-[#E6EBF5] font-medium text-base select-none">
          Allova
        </span>
      </div>

      {/* Nav */}
      <nav className="flex-1 px-3 py-4 flex flex-col gap-0.5 overflow-y-auto">
        {visibleItems.map(item => {
          const active = activeItem === item.id
          return (
            <button
              key={item.id}
              onClick={() => onNav(item.id)}
              className={`w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-colors text-left ${
                active
                  ? 'bg-[#18233F] text-[#E6EBF5]'
                  : 'text-[#8C97B2] hover:text-[#C3D1F5] hover:bg-[#18233F]/60'
              }`}
            >
              <span className={active ? 'text-[#A9BDF0]' : 'text-[#8C97B2]'}>
                {NAV_ICONS[item.id]}
              </span>
              {item.label}
            </button>
          )
        })}
      </nav>

      {/* Testnet faucet pill — only shown on testnet */}
      {isTestnet && (
        <div className="px-3 pb-3 shrink-0">
          <a
            href="https://faucet.circle.com"
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-2 px-3 py-2 rounded-full border border-[#2A3658] text-xs text-[#8C97B2] hover:text-[#C3D1F5] hover:border-[#A9BDF0] transition-colors"
          >
            <ExternalLink size={11} />
            Testnet faucet
          </a>
        </div>
      )}

      {/* Wallet chip */}
      <div className="px-3 pb-4 border-t border-[#1F2A47] pt-3 shrink-0">
        {address ? (
          <div className="flex items-center gap-2.5 px-3 py-2.5 rounded-xl bg-[#18233F]">
            <span className="w-7 h-7 rounded-full bg-[#A9BDF0] flex items-center justify-center text-[#0B1226] text-xs font-semibold select-none shrink-0">
              {address.slice(2, 3).toUpperCase()}
            </span>
            <div className="min-w-0 flex-1">
              <p className="text-xs font-medium text-[#E6EBF5] truncate" style={{ fontFamily: "'DM Mono', monospace" }}>
                {formatAddr(address)}
              </p>
              <div className="flex items-center gap-1.5 mt-0.5">
                <p className="text-[10px] text-[#8C97B2] truncate">
                  {net?.chain.name ?? 'Not connected'}
                </p>
                {net && !isTestnet && (
                  <span className="shrink-0 px-1.5 py-0.5 rounded-full bg-[#F2C27B]/15 text-[#F2C27B] text-[9px] font-semibold leading-none">
                    Mainnet
                  </span>
                )}
              </div>
            </div>
            <button
              onClick={() => disconnect()}
              className="shrink-0 text-[10px] text-[#8C97B2] hover:text-[#F2A0A0] transition-colors leading-none"
              title="Disconnect wallet"
            >
              Disconnect
            </button>
          </div>
        ) : (
          <div style={ckButtonVars}>
            <ConnectKitButton />
          </div>
        )}
      </div>
    </aside>
  )
}

// ── Mobile top bar ────────────────────────────────────────────────────────────
export function MobileTopBar({ activeItem, onNav, showAccountNav, isTestnet }: SidebarProps) {
  const { address } = useAccount()
  const { net } = useNetwork()
  const { disconnect } = useDisconnect()

  const visibleItems = showAccountNav
    ? NAV_ITEMS.filter(i => !i.testnetOnly || isTestnet)
    : []

  return (
    <header className="md:hidden flex items-center gap-2 px-3 py-2 bg-[#0E1630] border-b border-[#1F2A47] shrink-0">
      {/* Logo */}
      <div className="flex items-center gap-2 shrink-0 pr-2">
        <LogoMark />
        <span className="text-[#E6EBF5] font-medium text-sm select-none">
          Allova
        </span>
      </div>

      {/* Nav pills — horizontally scrollable, no overflow */}
      {visibleItems.length > 0 && (
        <nav className="flex-1 min-w-0 overflow-x-auto" style={{ scrollbarWidth: 'none' }}>
          <div className="flex gap-1 pr-2">
            {visibleItems.map(item => {
              const active = activeItem === item.id
              return (
                <button
                  key={item.id}
                  onClick={() => onNav(item.id)}
                  className={`shrink-0 px-3 py-1.5 rounded-full text-xs font-medium transition-colors whitespace-nowrap ${
                    active
                      ? 'bg-[#A9BDF0] text-[#0B1226]'
                      : 'text-[#8C97B2] hover:text-[#C3D1F5] bg-[#18233F]/60'
                  }`}
                >
                  {item.label}
                </button>
              )
            })}
          </div>
        </nav>
      )}

      {/* Wallet button */}
      <div className="shrink-0 ml-auto flex items-center gap-1" style={ckButtonVars}>
        {address ? (
          <>
            <span
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-[#18233F] text-xs text-[#E6EBF5]"
              style={{ fontFamily: "'DM Mono', monospace" }}
            >
              <span className="w-4 h-4 rounded-full bg-[#A9BDF0] flex items-center justify-center text-[#0B1226] text-[9px] font-bold shrink-0">
                {address.slice(2, 3).toUpperCase()}
              </span>
              {formatAddr(address)}
              {net && !isTestnet && (
                <span className="shrink-0 px-1.5 py-0.5 rounded-full bg-[#F2C27B]/15 text-[#F2C27B] text-[9px] font-semibold leading-none">
                  Mainnet
                </span>
              )}
            </span>
            <button
              onClick={() => disconnect()}
              className="w-6 h-6 flex items-center justify-center rounded-full text-[#8C97B2] hover:text-[#F2A0A0] hover:bg-[#18233F] transition-colors text-xs"
              title="Disconnect wallet"
              aria-label="Disconnect wallet"
            >
              ✕
            </button>
          </>
        ) : (
          <ConnectKitButton />
        )}
      </div>
    </header>
  )
}

// ── Footer ────────────────────────────────────────────────────────────────────
export function Footer() {
  const { net } = useNetwork()
  const factoryUrl = net ? `${net.explorerUrl}/address/${net.factoryAddress}` : undefined

  return (
    <footer className="border-t border-[#1F2A47] py-4 px-6 pr-6 md:pr-56 shrink-0">
      <div className="flex items-center justify-between text-xs text-[#8C97B2] flex-wrap gap-2">
        <span>Built on Arc</span>
        <div className="flex items-center gap-4 flex-wrap">
          {factoryUrl && (
            <a href={factoryUrl} target="_blank" rel="noopener noreferrer"
              className="flex items-center gap-1 hover:text-[#C3D1F5] transition-colors">
              <ExternalLink size={10} /> factory {net?.factoryAddress.slice(0, 8)}&hellip;
            </a>
          )}
          <a href="https://github.com/erhnysr/allowance" target="_blank" rel="noopener noreferrer"
            className="flex items-center gap-1 hover:text-[#C3D1F5] transition-colors">
            <ExternalLink size={10} /> github.com/erhnysr/allowance
          </a>
        </div>
      </div>
    </footer>
  )
}

// ── Shell ─────────────────────────────────────────────────────────────────────
// sidebar = <Sidebar> (desktop-only, hidden on mobile via its own hidden md:flex)
// mobileBar = <MobileTopBar> (mobile-only, hidden on desktop via its own md:hidden)
export function Shell({
  children,
  sidebar,
  mobileBar,
}: {
  children: ReactNode
  sidebar: ReactNode
  mobileBar: ReactNode
}) {
  return (
    <div className="min-h-dvh flex flex-col md:flex-row bg-[#0B1226]">
      {/* Mobile top bar — full width, stacks above content */}
      {mobileBar}

      {/* Desktop sidebar — sticky column on the left */}
      <div className="hidden md:flex sticky top-0 h-dvh shrink-0">
        {sidebar}
      </div>

      {/* Main content column */}
      <div className="flex-1 min-w-0 flex flex-col min-h-0">
        <main className="flex-1 px-4 md:px-8 py-6 pb-24 md:pb-8 min-w-0">
          {children}
        </main>
        <Footer />
      </div>
    </div>
  )
}
