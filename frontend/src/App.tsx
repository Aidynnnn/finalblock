import { useState } from 'react'
import { useAccount } from 'wagmi'
import { Header }       from './components/layout/Header'
import { NetworkGuard } from './components/NetworkGuard'
import { WalletConnect } from './components/WalletConnect'
import { Dashboard }    from './components/dashboard/Dashboard'
import { Actions }      from './components/Actions'
import { ProposalBoard } from './components/proposals/ProposalBoard'
import { Analytics }    from './components/Analytics'

type Tab = 'dashboard' | 'actions' | 'proposals' | 'analytics'

export default function App() {
  const [activeTab, setActiveTab] = useState<Tab>('dashboard')
  const { isConnected } = useAccount()

  return (
    <>
      {/* Network guard renders a full-screen modal when on the wrong chain */}
      <NetworkGuard>
        <div className="flex flex-col min-h-screen">
          <Header
            activeTab={activeTab}
            onTabChange={(t) => setActiveTab(t as Tab)}
          />

          <main className="flex-1 max-w-7xl mx-auto w-full px-4 sm:px-6 py-8">
            {/* Gate: show connect-wallet screen until the user connects */}
            {!isConnected ? (
              <WalletConnect />
            ) : (
              <>
                {activeTab === 'dashboard'  && <Dashboard />}
                {activeTab === 'actions'    && <Actions />}
                {activeTab === 'proposals'  && <ProposalBoard />}
                {activeTab === 'analytics'  && <Analytics />}
              </>
            )}
          </main>

          <footer className="border-t border-white/5 py-4 text-center text-xs text-gray-700">
            BCHT2 DeFi · Sepolia Testnet · Built with Wagmi, Viem & The Graph
          </footer>
        </div>
      </NetworkGuard>
    </>
  )
}
