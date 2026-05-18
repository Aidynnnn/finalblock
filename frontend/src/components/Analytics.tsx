/**
 * Analytics — full protocol analytics panel.
 *
 * Data sourced exclusively from The Graph subgraph via the named queries
 * defined in subgraph/queries.graphql (no direct contract calls on this tab).
 *
 * Sections:
 *   1. Pool Dashboard      — PoolDashboard query
 *   2. Daily Activity      — DailyProtocolActivity query (30-day chart)
 *   3. Governance Summary  — GovernanceProposals query (vote tallies)
 *   4. My Vault History    — UserVaultActivity query (wallet-gated)
 */
import { useAccount } from 'wagmi'
import { formatUnits } from 'viem'
import {
  usePoolDashboard,
  useDailyActivity,
  useGovernanceProposals,
  useUserVaultActivity,
  type GqlSwap,
  type GqlDayData,
  type GqlProposal,
  type GqlVaultDeposit,
  type GqlVaultWithdrawal,
} from '../hooks/useSubgraph'
import { SUBGRAPH_URL, AMM_ADDRESS, proposalStateBadgeColor, PROPOSAL_STATES } from '../config/contracts'

// ── Formatting helpers ────────────────────────────────────────────────────────

function fmtToken(raw: string, dp = 4): string {
  try {
    const n = parseFloat(formatUnits(BigInt(raw), 18))
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`
    if (n >= 1_000)     return `${(n / 1_000).toFixed(2)}K`
    return n.toLocaleString('en-US', { maximumFractionDigits: dp })
  } catch { return raw }
}
function shortAddr(a: string)  { return `${a.slice(0, 6)}…${a.slice(-4)}` }
function shortHash(h: string)  { return `${h.slice(0, 10)}…` }
function fmtDate(ts: string)   {
  return new Date(Number(ts) * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}
function fmtDateTime(ts: string) {
  return new Date(Number(ts) * 1000).toLocaleString('en-US', {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  })
}
function derivedState(p: GqlProposal): string {
  if (p.executed) return 'Executed'
  if (p.canceled) return 'Canceled'
  if (p.queued)   return 'Queued'
  const now = Math.floor(Date.now() / 1000)
  if (now < Number(p.voteStart)) return 'Pending'
  if (now <= Number(p.voteEnd))  return 'Active'
  return BigInt(p.forVotes) > BigInt(p.againstVotes) ? 'Succeeded' : 'Defeated'
}

// ── Shared UI primitives ──────────────────────────────────────────────────────

function SectionHeader({ title, sub, onRefresh }: { title: string; sub: string; onRefresh?: () => void }) {
  return (
    <div className="flex items-center justify-between mb-4">
      <div>
        <h3 className="text-sm font-semibold text-white">{title}</h3>
        <p className="text-xs text-gray-500 mt-0.5">{sub}</p>
      </div>
      {onRefresh && (
        <button
          onClick={onRefresh}
          className="flex items-center gap-1 text-xs text-gray-500 hover:text-white transition-colors px-2.5 py-1.5 rounded-lg hover:bg-white/5"
        >
          <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
          </svg>
          Refresh
        </button>
      )}
    </div>
  )
}

function Skeleton({ rows = 4, cols = 4 }: { rows?: number; cols?: number }) {
  return (
    <div className="rounded-xl border border-white/10 overflow-hidden">
      <div className="bg-white/5 grid gap-3 px-4 py-3" style={{ gridTemplateColumns: `repeat(${cols},1fr)` }}>
        {Array.from({ length: cols }).map((_, i) => <div key={i} className="h-3 bg-white/10 rounded animate-pulse" />)}
      </div>
      {Array.from({ length: rows }).map((_, r) => (
        <div key={r} className="grid gap-3 px-4 py-3 border-t border-white/5" style={{ gridTemplateColumns: `repeat(${cols},1fr)` }}>
          {Array.from({ length: cols }).map((_, c) => <div key={c} className="h-3 bg-white/5 rounded animate-pulse" />)}
        </div>
      ))}
    </div>
  )
}

function ErrorCard({ msg, onRetry }: { msg: string; onRetry: () => void }) {
  let friendlyMessage = "No historical transactions or indexer data found on Sepolia yet."
  
  if (msg.includes('pool')) {
    friendlyMessage = "No active liquidity pool data found on this Sepolia deployment yet."
  } else if (msg.includes('protocolDayDatas')) {
    friendlyMessage = "No volume or protocol activity recorded within the last 30 days."
  } else if (msg.includes('proposals')) {
    friendlyMessage = "No historical governance proposals found in the indexing database."
  }

  return (
    <div className="rounded-xl border border-white/10 bg-white/5 p-8 text-center">
      <p className="text-sm text-gray-500">{friendlyMessage}</p>
    </div>
  )
}

function EmptyCard({ msg }: { msg: string }) {
  return (
    <div className="rounded-xl border border-white/10 bg-white/5 p-8 text-center">
      <p className="text-sm text-gray-500">{msg}</p>
    </div>
  )
}

// ── Section 1: Pool Dashboard (Query 1 — PoolDashboard) ───────────────────────

function PoolDashboardSection() {
  const { data, loading, error, refetch } = usePoolDashboard()
  const pool = data?.pool

  return (
    <section className="space-y-3">
      <SectionHeader
        title="AMM Pool — PoolDashboard Query"
        sub={`Pool: ${shortAddr(AMM_ADDRESS)}`}
        onRefresh={refetch}
      />
      {loading && <Skeleton rows={3} cols={4} />}
      {error   && <ErrorCard msg={error} onRetry={refetch} />}
      {!loading && !error && !pool && <EmptyCard msg="Pool not yet indexed. Deploy contracts and seed liquidity first." />}
      {pool && (
        <div className="space-y-4">
          {/* Stats grid */}
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            {[
              { label: 'Reserve 0',      value: fmtToken(pool.reserve0) },
              { label: 'Reserve 1',      value: fmtToken(pool.reserve1) },
              { label: 'Total Vol T0',   value: fmtToken(pool.totalVolumeToken0) },
              { label: 'Swap Count',     value: pool.swapCount },
            ].map(({ label, value }) => (
              <div key={label} className="bg-white/5 border border-white/10 rounded-xl p-3">
                <p className="text-xs text-gray-500">{label}</p>
                <p className="font-mono font-bold text-white mt-0.5">{value}</p>
              </div>
            ))}
          </div>

          {/* Last 10 swaps from pool.swaps */}
          <div className="overflow-x-auto rounded-xl border border-white/10">
            <table className="w-full text-xs">
              <thead className="bg-white/5 text-gray-400">
                <tr>
                  <th className="text-left px-4 py-2.5">Time</th>
                  <th className="text-left px-4 py-2.5">Swapper</th>
                  <th className="text-left px-4 py-2.5">Token In</th>
                  <th className="text-right px-4 py-2.5">Amount In</th>
                  <th className="text-right px-4 py-2.5">Amount Out</th>
                  <th className="text-left px-4 py-2.5">Tx</th>
                </tr>
              </thead>
              <tbody>
                {pool.swaps.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-4 py-6 text-center text-gray-600">No swaps yet.</td>
                  </tr>
                )}
                {pool.swaps.map((s: GqlSwap) => (
                  <tr key={s.id} className="border-t border-white/5 hover:bg-white/5 transition-colors">
                    <td className="px-4 py-2.5 text-gray-400 whitespace-nowrap">{fmtDateTime(s.timestamp)}</td>
                    <td className="px-4 py-2.5 font-mono text-gray-300">{shortAddr(s.swapper)}</td>
                    <td className="px-4 py-2.5 font-mono text-gray-400">{shortAddr(s.tokenIn)}</td>
                    <td className="px-4 py-2.5 text-right font-mono text-white">{fmtToken(s.amountIn)}</td>
                    <td className="px-4 py-2.5 text-right font-mono text-green-400">{fmtToken(s.amountOut)}</td>
                    <td className="px-4 py-2.5 font-mono text-brand-400">{shortHash(s.transactionHash)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </section>
  )
}

// ── Section 2: Daily Activity (Query 2 — DailyProtocolActivity) ───────────────

function DailyActivitySection() {
  const { data, loading, error, refetch } = useDailyActivity(30)
  const days = data?.protocolDayDatas ?? []
  const maxSwaps = Math.max(...days.map(d => Number(d.dailySwapCount)), 1)

  return (
    <section className="space-y-3">
      <SectionHeader
        title="Daily Protocol Activity — DailyProtocolActivity Query"
        sub="30-day roll-up: swap count, volumes, deposits, governance"
        onRefresh={refetch}
      />
      {loading && <div className="h-36 rounded-xl bg-white/5 animate-pulse" />}
      {error   && <ErrorCard msg={error} onRetry={refetch} />}
      {!loading && !error && days.length === 0 && <EmptyCard msg="No daily data indexed yet." />}
      {days.length > 0 && (
        <div className="space-y-4">
          {/* Bar chart */}
          <div className="bg-white/5 border border-white/10 rounded-xl p-5">
            <p className="text-xs text-gray-500 mb-4">Daily swap count (30 days)</p>
            <div className="flex items-end gap-1" style={{ height: '80px' }}>
              {days.map((d: GqlDayData) => {
                const pct = (Number(d.dailySwapCount) / maxSwaps) * 100
                return (
                  <div key={d.id} className="flex-1 flex flex-col items-center gap-0.5 group relative">
                    {/* Tooltip */}
                    <div className="absolute bottom-full mb-1 left-1/2 -translate-x-1/2 bg-gray-800 text-white text-xs rounded px-2 py-1 opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none whitespace-nowrap z-10">
                      {fmtDate(d.date)}: {d.dailySwapCount} swap{Number(d.dailySwapCount) !== 1 ? 's' : ''}
                    </div>
                    <div
                      className="w-full bg-brand-500/50 hover:bg-brand-500 rounded-t transition-colors"
                      style={{ height: `${Math.max(pct, 2)}%` }}
                    />
                  </div>
                )
              })}
            </div>
            {/* X-axis labels — show every 5th date */}
            <div className="flex gap-1 mt-1">
              {days.map((d: GqlDayData, i: number) => (
                <div key={d.id} className="flex-1 text-center">
                  {(i === 0 || i === Math.floor(days.length / 2) || i === days.length - 1) && (
                    <span className="text-gray-600 text-xs">{fmtDate(d.date)}</span>
                  )}
                </div>
              ))}
            </div>
          </div>

          {/* Summary table */}
          <div className="overflow-x-auto rounded-xl border border-white/10">
            <table className="w-full text-xs">
              <thead className="bg-white/5 text-gray-400">
                <tr>
                  <th className="text-left px-4 py-2.5">Date</th>
                  <th className="text-right px-4 py-2.5">Swaps</th>
                  <th className="text-right px-4 py-2.5">Vol T0</th>
                  <th className="text-right px-4 py-2.5">Vol T1</th>
                  <th className="text-right px-4 py-2.5">Deposits</th>
                  <th className="text-right px-4 py-2.5">Proposals</th>
                  <th className="text-right px-4 py-2.5">Votes</th>
                </tr>
              </thead>
              <tbody>
                {[...days].reverse().map((d: GqlDayData) => (
                  <tr key={d.id} className="border-t border-white/5 hover:bg-white/5 transition-colors">
                    <td className="px-4 py-2 text-gray-400">{fmtDate(d.date)}</td>
                    <td className="px-4 py-2 text-right font-mono text-white">{d.dailySwapCount}</td>
                    <td className="px-4 py-2 text-right font-mono text-gray-300">{fmtToken(d.dailyVolumeToken0, 2)}</td>
                    <td className="px-4 py-2 text-right font-mono text-gray-300">{fmtToken(d.dailyVolumeToken1, 2)}</td>
                    <td className="px-4 py-2 text-right font-mono text-brand-400">{d.dailyDepositCount}</td>
                    <td className="px-4 py-2 text-right font-mono text-yellow-400">{d.dailyProposalCount}</td>
                    <td className="px-4 py-2 text-right font-mono text-green-400">{d.dailyVoteCount}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </section>
  )
}

// ── Section 3: Governance Proposals (Query 4 — GovernanceProposals) ───────────

function GovernanceSection() {
  const { data, loading, error, refetch } = useGovernanceProposals(10, 0)
  const proposals = data?.proposals ?? []

  return (
    <section className="space-y-3">
      <SectionHeader
        title="DAO Vote Tallies — GovernanceProposals Query"
        sub="Historical proposal vote counts from the subgraph"
        onRefresh={refetch}
      />
      {loading && <Skeleton rows={4} cols={5} />}
      {error   && <ErrorCard msg={error} onRetry={refetch} />}
      {!loading && !error && proposals.length === 0 && <EmptyCard msg="No proposals indexed yet." />}
      {proposals.length > 0 && (
        <div className="space-y-3">
          {proposals.map((p: GqlProposal) => {
            const state     = derivedState(p)
            const badgeCls  = proposalStateBadgeColor(state as Parameters<typeof proposalStateBadgeColor>[0])
            const forV      = BigInt(p.forVotes)
            const againstV  = BigInt(p.againstVotes)
            const abstainV  = BigInt(p.abstainVotes)
            const total     = forV + againstV + abstainV
            const pct = (v: bigint) => total === 0n ? 0 : Number((v * 10000n) / total) / 100

            return (
              <div key={p.id} className="bg-white/5 border border-white/10 rounded-xl p-4 space-y-3">
                <div className="flex items-start gap-3">
                  <p className="flex-1 text-sm text-white leading-relaxed line-clamp-2">
                    {p.description || '(no description)'}
                  </p>
                  <span className={`flex-shrink-0 text-xs px-2.5 py-0.5 rounded-full border font-medium ${badgeCls}`}>
                    {state}
                  </span>
                </div>
                {/* Tally bars */}
                <div className="space-y-1">
                  <div className="flex h-1.5 rounded-full overflow-hidden bg-gray-800">
                    <div className="bg-green-500" style={{ width: `${pct(forV)}%` }} />
                    <div className="bg-red-500"   style={{ width: `${pct(againstV)}%` }} />
                    <div className="bg-gray-600"  style={{ width: `${pct(abstainV)}%` }} />
                  </div>
                  <div className="flex gap-4 text-xs">
                    <span className="text-green-400">For {fmtToken(p.forVotes, 2)}</span>
                    <span className="text-red-400">Against {fmtToken(p.againstVotes, 2)}</span>
                    <span className="text-gray-400">Abstain {fmtToken(p.abstainVotes, 2)}</span>
                    <span className="text-gray-600 ml-auto">{p.voterCount} voters · {fmtDate(p.createdAtTimestamp)}</span>
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}

// ── Section 4: User Vault Activity (Query 3 — UserVaultActivity) ──────────────

function UserVaultSection() {
  const { address } = useAccount()
  const { data, loading, error, refetch } = useUserVaultActivity(address)
  const deposits    = data?.deposits    ?? []
  const withdrawals = data?.withdrawals ?? []

  if (!address) {
    return (
      <section>
        <SectionHeader title="My Vault History — UserVaultActivity Query" sub="Wallet-gated" />
        <EmptyCard msg="Connect your wallet to view your personal vault activity." />
      </section>
    )
  }

  return (
    <section className="space-y-3">
      <SectionHeader
        title="My Vault History — UserVaultActivity Query"
        sub={`Deposits & withdrawals for ${shortAddr(address)}`}
        onRefresh={refetch}
      />
      {loading && <Skeleton rows={4} cols={5} />}
      {error   && <ErrorCard msg={error} onRetry={refetch} />}
      {!loading && !error && deposits.length === 0 && withdrawals.length === 0 && (
        <EmptyCard msg="No vault activity found for your address." />
      )}
      {(deposits.length > 0 || withdrawals.length > 0) && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {/* Deposits */}
          <div className="space-y-2">
            <p className="text-xs font-medium text-gray-400 uppercase tracking-widest">Deposits ({deposits.length})</p>
            <div className="overflow-x-auto rounded-xl border border-white/10">
              <table className="w-full text-xs">
                <thead className="bg-white/5 text-gray-500">
                  <tr>
                    <th className="text-left px-3 py-2">Date</th>
                    <th className="text-right px-3 py-2">Assets</th>
                    <th className="text-right px-3 py-2">Shares</th>
                  </tr>
                </thead>
                <tbody>
                  {deposits.length === 0 && (
                    <tr><td colSpan={3} className="px-3 py-4 text-center text-gray-600">None</td></tr>
                  )}
                  {deposits.map((d: GqlVaultDeposit) => (
                    <tr key={d.id} className="border-t border-white/5 hover:bg-white/5">
                      <td className="px-3 py-2 text-gray-400">{fmtDate(d.timestamp)}</td>
                      <td className="px-3 py-2 text-right font-mono text-white">{fmtToken(d.assets)}</td>
                      <td className="px-3 py-2 text-right font-mono text-brand-400">{fmtToken(d.shares)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {/* Withdrawals */}
          <div className="space-y-2">
            <p className="text-xs font-medium text-gray-400 uppercase tracking-widest">Withdrawals ({withdrawals.length})</p>
            <div className="overflow-x-auto rounded-xl border border-white/10">
              <table className="w-full text-xs">
                <thead className="bg-white/5 text-gray-500">
                  <tr>
                    <th className="text-left px-3 py-2">Date</th>
                    <th className="text-right px-3 py-2">Assets</th>
                    <th className="text-right px-3 py-2">Shares</th>
                  </tr>
                </thead>
                <tbody>
                  {withdrawals.length === 0 && (
                    <tr><td colSpan={3} className="px-3 py-4 text-center text-gray-600">None</td></tr>
                  )}
                  {withdrawals.map((w: GqlVaultWithdrawal) => (
                    <tr key={w.id} className="border-t border-white/5 hover:bg-white/5">
                      <td className="px-3 py-2 text-gray-400">{fmtDate(w.timestamp)}</td>
                      <td className="px-3 py-2 text-right font-mono text-white">{fmtToken(w.assets)}</td>
                      <td className="px-3 py-2 text-right font-mono text-red-400">{fmtToken(w.shares)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}
    </section>
  )
}

// ── Main export ───────────────────────────────────────────────────────────────

export function Analytics() {
  return (
    <div className="space-y-10">
      {/* Subgraph banner */}
      <div className="flex items-start gap-3 bg-brand-500/10 border border-brand-500/20 rounded-xl px-4 py-3">
        <svg className="w-4 h-4 text-brand-400 mt-0.5 flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        <div className="text-xs text-brand-300 space-y-1 min-w-0">
          <p className="font-semibold">All data below is queried directly from The Graph subgraph — no RPC calls.</p>
          <p className="text-brand-400/70 break-all">
            Endpoint:{' '}
            <code className="bg-black/20 px-1 rounded font-mono">
              {SUBGRAPH_URL || 'not configured — set VITE_SUBGRAPH_URL in .env'}
            </code>
          </p>
          <p className="text-brand-400/70">
            Named queries: <code className="font-mono">PoolDashboard</code> ·{' '}
            <code className="font-mono">DailyProtocolActivity</code> ·{' '}
            <code className="font-mono">GovernanceProposals</code> ·{' '}
            <code className="font-mono">UserVaultActivity</code>
          </p>
        </div>
      </div>

      <PoolDashboardSection />
      <DailyActivitySection />
      <GovernanceSection />
      <UserVaultSection />
    </div>
  )
}

// Re-export proposal state helpers for use in ProposalBoard
export { PROPOSAL_STATES }
