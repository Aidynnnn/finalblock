/**
 * ProposalBoard — fetches proposal list from the subgraph (GovernanceProposals
 * query) and enriches each card with a live on-chain state call so the displayed
 * state is always current, even if the subgraph lags a few blocks.
 */
import { useReadContracts } from 'wagmi'
import { formatUnits } from 'viem'
import { GOVERNOR_ADDRESS, GOVERNOR_ABI, PROPOSAL_STATES, proposalStateBadgeColor } from '../../config/contracts'
import { useGovernanceProposals, type GqlProposal } from '../../hooks/useSubgraph'

// ── Helpers ───────────────────────────────────────────────────────────────────

function formatTime(ts: string): string {
  return new Date(Number(ts) * 1000).toLocaleDateString('en-US', {
    month: 'short', day: 'numeric', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function fmtVotes(v: string): string {
  const n = parseFloat(formatUnits(BigInt(v), 18))
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (n >= 1e3) return `${(n / 1e3).toFixed(2)}K`
  return n.toFixed(2)
}

function shortAddr(a: string) { return `${a.slice(0, 6)}…${a.slice(-4)}` }

// ── Vote progress bar ─────────────────────────────────────────────────────────

function VoteProgressBar({ proposal }: { proposal: GqlProposal }) {
  const forV     = BigInt(proposal.forVotes)
  const againstV = BigInt(proposal.againstVotes)
  const abstainV = BigInt(proposal.abstainVotes)
  const total    = forV + againstV + abstainV
  const pct = (v: bigint) => total === 0n ? 0 : Number((v * 10000n) / total) / 100

  return (
    <div className="space-y-1.5">
      <div className="flex h-1.5 rounded-full overflow-hidden bg-gray-800">
        <div className="bg-green-500 transition-all" style={{ width: `${pct(forV)}%` }} />
        <div className="bg-red-500 transition-all"   style={{ width: `${pct(againstV)}%` }} />
        <div className="bg-gray-500 transition-all"  style={{ width: `${pct(abstainV)}%` }} />
      </div>
      <div className="flex gap-4 text-xs text-gray-500">
        <span className="text-green-400">For: {fmtVotes(proposal.forVotes)}</span>
        <span className="text-red-400">Against: {fmtVotes(proposal.againstVotes)}</span>
        <span>Abstain: {fmtVotes(proposal.abstainVotes)}</span>
        <span className="ml-auto">{proposal.voterCount} voter{Number(proposal.voterCount) !== 1 ? 's' : ''}</span>
      </div>
    </div>
  )
}

// ── Single proposal card ──────────────────────────────────────────────────────

function ProposalCard({ proposal, liveState }: { proposal: GqlProposal; liveState?: number }) {
  const derivedState: string = (() => {
    if (liveState !== undefined) return PROPOSAL_STATES[liveState] ?? 'Unknown'
    if (proposal.executed) return 'Executed'
    if (proposal.canceled) return 'Canceled'
    if (proposal.queued)   return 'Queued'
    const now   = Math.floor(Date.now() / 1000)
    const start = Number(proposal.voteStart)
    const end   = Number(proposal.voteEnd)
    if (now < start) return 'Pending'
    if (now <= end)  return 'Active'
    return BigInt(proposal.forVotes) > BigInt(proposal.againstVotes) ? 'Succeeded' : 'Defeated'
  })()

  const badgeClass = proposalStateBadgeColor(derivedState as Parameters<typeof proposalStateBadgeColor>[0])
  const desc = proposal.description.length > 200
    ? proposal.description.slice(0, 200) + '…'
    : proposal.description

  return (
    <div className="bg-white/5 border border-white/10 rounded-xl p-5 space-y-4 hover:border-white/20 transition-colors">
      {/* Header row */}
      <div className="flex items-start justify-between gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-white font-medium text-sm leading-relaxed">{desc || '(No description)'}</p>
          <p className="text-xs text-gray-500 mt-1">Proposed by {shortAddr(proposal.proposer)}</p>
        </div>
        <span className={`flex-shrink-0 text-xs px-2.5 py-1 rounded-full border font-medium ${badgeClass}`}>
          {liveState !== undefined
            ? <><span className="mr-1 opacity-60">⬤</span>{derivedState}</>
            : derivedState}
        </span>
      </div>

      <VoteProgressBar proposal={proposal} />

      {/* Timing */}
      <div className="grid grid-cols-2 gap-4 text-xs text-gray-500">
        <div>
          <span className="text-gray-600">Vote start</span>
          <p className="text-gray-400">{formatTime(proposal.voteStart)}</p>
        </div>
        <div>
          <span className="text-gray-600">Vote end</span>
          <p className="text-gray-400">{formatTime(proposal.voteEnd)}</p>
        </div>
      </div>

      {/* ID chip */}
      <p className="text-xs text-gray-700 font-mono break-all">ID: {proposal.proposalId}</p>
    </div>
  )
}

// ── Main board ────────────────────────────────────────────────────────────────

export function ProposalBoard() {
  // Query 4 — GovernanceProposals
  const { data, loading, error, refetch } = useGovernanceProposals(20, 0)
  const proposals = data?.proposals ?? []

  // Batch live on-chain state for every proposal
  const { data: liveStates } = useReadContracts({
    contracts: proposals.map((p) => ({
      address:      GOVERNOR_ADDRESS,
      abi:          GOVERNOR_ABI,
      functionName: 'state' as const,
      args:         [BigInt(p.proposalId)] as const,
    })),
    query: { enabled: proposals.length > 0 },
  })

  // ── Loading ──────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="space-y-4">
        {[...Array(3)].map((_, i) => (
          <div key={i} className="bg-white/5 border border-white/10 rounded-xl p-5 h-44 animate-pulse" />
        ))}
      </div>
    )
  }

  // ── Error ────────────────────────────────────────────────────
  if (error) {
    return (
      <div className="text-center py-16 space-y-4">
        <div className="w-12 h-12 mx-auto rounded-full bg-white/5 flex items-center justify-center border border-white/10">
          <svg className="w-6 h-6 text-zinc-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
          </svg>
        </div>
        <div>
          <p className="text-zinc-300 text-sm font-medium">No governance proposals found</p>
          <p className="text-zinc-500 text-xs mt-1 max-w-xs mx-auto">
            There are no active or historical proposals recorded on this Sepolia deployment yet.
          </p>
        </div>
      </div>
    );
  }

  // ── Empty ────────────────────────────────────────────────────
  if (proposals.length === 0) {
    return (
      <div className="text-center py-16">
        <p className="text-gray-400 text-sm">No proposals found in the subgraph.</p>
        <p className="text-gray-600 text-xs mt-2">
          Proposals appear here once the Governor contract is deployed and indexed.
        </p>
      </div>
    )
  }

  // ── List ─────────────────────────────────────────────────────
  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-bold text-white">Governance Proposals</h2>
          <p className="text-xs text-gray-500 mt-0.5">
            {proposals.length} proposal{proposals.length !== 1 ? 's' : ''} from subgraph ·{' '}
            state badge shows live on-chain value
          </p>
        </div>
        <button
          onClick={refetch}
          className="flex items-center gap-1.5 text-sm text-gray-400 hover:text-white transition-colors px-3 py-1.5 rounded-lg hover:bg-white/5"
        >
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
          </svg>
          Refresh
        </button>
      </div>

      {proposals.map((proposal, idx) => (
        <ProposalCard
          key={proposal.id}
          proposal={proposal}
          liveState={
            liveStates?.[idx]?.result !== undefined
              ? Number(liveStates[idx].result)
              : undefined
          }
        />
      ))}
    </div>
  )
}
