/**
 * Actions — tabbed panel containing all three write-transaction forms:
 *   1. Swap    — ConstantProductAMM.swap()
 *   2. Vault   — ERC4626VaultV1.deposit() / redeem()
 *   3. Vote    — ProtocolGovernor.castVoteWithReason() + delegate()
 *
 * Each form manages its own approval flow, loading states, and
 * user-readable error messages (no raw RPC errors surfaced).
 */
import { useState } from 'react'
import { SwapForm }         from './actions/SwapForm'
import { VaultDepositForm } from './actions/VaultDepositForm'
import { VoteForm }         from './actions/VoteForm'

type ActionTab = 'swap' | 'vault' | 'vote'

const TABS: { id: ActionTab; label: string; icon: string; description: string }[] = [
  {
    id: 'swap',
    label: 'Swap',
    icon: '⇄',
    description: 'Trade Token0 ↔ Token1 via the constant-product AMM (0.3% fee).',
  },
  {
    id: 'vault',
    label: 'Vault',
    icon: '🏦',
    description: 'Deposit AMM LP tokens into the upgradeable ERC-4626 Vault to earn yield.',
  },
  {
    id: 'vote',
    label: 'Vote',
    icon: '🗳',
    description: 'Cast a For / Against / Abstain vote on an active DAO proposal.',
  },
]

export function Actions() {
  const [active, setActive] = useState<ActionTab>('swap')
  const current = TABS.find(t => t.id === active)!

  return (
    <div className="space-y-6">
      {/* Page title */}
      <div>
        <h2 className="text-lg font-bold text-white">Protocol Actions</h2>
        <p className="text-sm text-gray-500 mt-0.5">
          Execute on-chain transactions — all steps handled in-browser via MetaMask.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-[280px_1fr] gap-6 items-start">
        {/* ── Sidebar tab selector ───────────────────────────────── */}
        <div className="space-y-2">
          {TABS.map(tab => (
            <button
              key={tab.id}
              onClick={() => setActive(tab.id)}
              className={`w-full text-left flex items-start gap-3 px-4 py-3.5 rounded-xl border transition-all ${
                active === tab.id
                  ? 'bg-brand-500/10 border-brand-500/30 text-white'
                  : 'bg-white/5 border-white/10 text-gray-400 hover:text-gray-200 hover:border-white/20'
              }`}
            >
              <span className="text-xl leading-none mt-0.5">{tab.icon}</span>
              <div>
                <p className={`font-semibold text-sm ${active === tab.id ? 'text-brand-300' : ''}`}>
                  {tab.label}
                </p>
                <p className="text-xs text-gray-500 mt-0.5 leading-relaxed">{tab.description}</p>
              </div>
            </button>
          ))}

          {/* Info box */}
          <div className="mt-4 bg-white/5 border border-white/10 rounded-xl p-4 space-y-2">
            <p className="text-xs font-medium text-gray-400">Transaction flow</p>
            <ol className="space-y-1.5 text-xs text-gray-500">
              <li className="flex items-start gap-2"><span className="text-brand-400 font-bold">1.</span> Approve token spending (if required)</li>
              <li className="flex items-start gap-2"><span className="text-brand-400 font-bold">2.</span> Confirm the action transaction</li>
              <li className="flex items-start gap-2"><span className="text-brand-400 font-bold">3.</span> Wait for on-chain confirmation</li>
            </ol>
          </div>
        </div>

        {/* ── Form panel ─────────────────────────────────────────── */}
        <div>
          {/* Breadcrumb */}
          <p className="text-xs text-gray-600 mb-4">
            Actions / <span className="text-gray-400">{current.label}</span>
          </p>
          {active === 'swap'  && <SwapForm />}
          {active === 'vault' && <VaultDepositForm />}
          {active === 'vote'  && <VoteForm />}
        </div>
      </div>
    </div>
  )
}
