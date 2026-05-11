import { useAccount } from 'wagmi'
import { ConnectButton } from '../ConnectButton'
import { targetChain } from '../../config/wagmi'

interface Props {
  activeTab: string
  onTabChange: (tab: string) => void
}

const TABS = [
  { id: 'dashboard',  label: 'Dashboard' },
  { id: 'actions',    label: 'Actions' },
  { id: 'proposals',  label: 'Proposals' },
  { id: 'analytics',  label: 'Analytics' },
]

export function Header({ activeTab, onTabChange }: Props) {
  const { chain } = useAccount()
  const onCorrectChain = chain?.id === targetChain.id

  return (
    <header className="sticky top-0 z-40 border-b border-white/10 bg-gray-950/90 backdrop-blur-sm">
      <div className="max-w-7xl mx-auto px-4 sm:px-6">
        {/* Top row */}
        <div className="flex items-center justify-between h-16 gap-4">
          {/* Logo */}
          <div className="flex items-center gap-3 flex-shrink-0">
            <div className="w-8 h-8 rounded-lg bg-brand-600 flex items-center justify-center">
              <span className="text-white font-bold text-xs">B2</span>
            </div>
            <span className="font-bold text-white text-lg tracking-tight">BCHT2 DeFi</span>
            {/* Network chip */}
            <span className={`hidden sm:inline-flex items-center gap-1.5 text-xs px-2 py-0.5 rounded-full border font-medium ${
              onCorrectChain
                ? 'bg-green-500/10 text-green-400 border-green-500/20'
                : 'bg-yellow-500/10 text-yellow-400 border-yellow-500/20'
            }`}>
              <span className={`w-1.5 h-1.5 rounded-full ${onCorrectChain ? 'bg-green-400' : 'bg-yellow-400'}`} />
              {targetChain.name}
            </span>
          </div>

          <ConnectButton />
        </div>

        {/* Tab row */}
        <nav className="flex gap-1 pb-0 -mb-px">
          {TABS.map(tab => (
            <button
              key={tab.id}
              onClick={() => onTabChange(tab.id)}
              className={`px-4 py-3 text-sm font-medium border-b-2 transition-all ${
                activeTab === tab.id
                  ? 'border-brand-500 text-brand-400'
                  : 'border-transparent text-gray-400 hover:text-gray-200 hover:border-gray-600'
              }`}
            >
              {tab.label}
            </button>
          ))}
        </nav>
      </div>
    </header>
  )
}
