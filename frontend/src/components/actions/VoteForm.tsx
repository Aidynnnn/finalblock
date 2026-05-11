import { useState, useEffect } from 'react'
import { useAccount, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { formatUnits } from 'viem'
import { GOVERNOR_ADDRESS, GOV_TOKEN_ADDRESS, GOVERNOR_ABI, GOV_TOKEN_ABI, PROPOSAL_STATES } from '../../config/contracts'

function friendlyTxError(msg: string): string {
  if (msg.includes('user rejected'))        return 'Transaction rejected in wallet.'
  if (msg.includes('GovernorAlreadyCastVote')) return 'You have already voted on this proposal.'
  if (msg.includes('GovernorNonexistentProposal')) return 'Proposal not found. Check the proposal ID.'
  if (msg.includes('GovernorUnexpectedProposalState')) return 'This proposal is not currently active for voting.'
  return 'Transaction failed. Check your inputs and try again.'
}

type Support = 0 | 1 | 2

const SUPPORT_OPTIONS: { value: Support; label: string; color: string }[] = [
  { value: 1, label: 'For',     color: 'bg-green-600 hover:bg-green-500 text-white' },
  { value: 0, label: 'Against', color: 'bg-red-600 hover:bg-red-500 text-white' },
  { value: 2, label: 'Abstain', color: 'bg-gray-600 hover:bg-gray-500 text-white' },
]

export function VoteForm() {
  const { address } = useAccount()

  const [proposalId, setProposalId] = useState('')
  const [support, setSupport]       = useState<Support>(1)
  const [reason, setReason]         = useState('')
  const [txError, setTxError]       = useState<string | null>(null)
  const [txSuccess, setTxSuccess]   = useState<string | null>(null)

  const parsedId = (() => {
    try { return proposalId ? BigInt(proposalId) : undefined } catch { return undefined }
  })()

  // ── Read voting power + proposal state ───────────────────────
  const { data: govInfo } = useReadContracts({
    contracts: [
      {
        address: GOV_TOKEN_ADDRESS,
        abi: GOV_TOKEN_ABI,
        functionName: 'getVotes',
        args: [address ?? '0x0000000000000000000000000000000000000000'],
      },
      {
        address: GOV_TOKEN_ADDRESS,
        abi: GOV_TOKEN_ABI,
        functionName: 'delegates',
        args: [address ?? '0x0000000000000000000000000000000000000000'],
      },
    ],
    query: { enabled: !!address },
  })

  const votingPower  = govInfo?.[0].result as bigint | undefined
  const delegateTo   = govInfo?.[1].result as string | undefined
  const selfDelegated = delegateTo?.toLowerCase() === address?.toLowerCase()

  // Proposal state lookup
  const { data: proposalState } = useReadContract({
    address: GOVERNOR_ADDRESS,
    abi:     GOVERNOR_ABI,
    functionName: 'state',
    args:    [parsedId ?? 0n],
    query:   { enabled: parsedId !== undefined },
  })

  const { data: hasVotedData } = useReadContract({
    address: GOVERNOR_ADDRESS,
    abi:     GOVERNOR_ABI,
    functionName: 'hasVoted',
    args:    [parsedId ?? 0n, address ?? '0x0000000000000000000000000000000000000000'],
    query:   { enabled: parsedId !== undefined && !!address },
  })

  const { data: voteBreakdown } = useReadContract({
    address: GOVERNOR_ADDRESS,
    abi:     GOVERNOR_ABI,
    functionName: 'proposalVotes',
    args:    [parsedId ?? 0n],
    query:   { enabled: parsedId !== undefined },
  })

  const stateLabel    = proposalState !== undefined ? PROPOSAL_STATES[Number(proposalState)] : undefined
  const alreadyVoted  = hasVotedData as boolean | undefined
  const breakdown     = voteBreakdown as { againstVotes: bigint; forVotes: bigint; abstainVotes: bigint } | undefined

  // ── Delegate to self ─────────────────────────────────────────
  const { writeContract: delegate, data: delegateTx, isPending: delegating, error: delegateError } = useWriteContract()
  const { isLoading: delegatePending, isSuccess: delegateSuccess } = useWaitForTransactionReceipt({ hash: delegateTx })

  useEffect(() => {
    if (delegateSuccess) setTxSuccess('Successfully self-delegated! Your voting power is now active.')
  }, [delegateSuccess])

  // ── Cast vote ────────────────────────────────────────────────
  const { writeContract: castVote, data: voteTx, isPending: voting, error: voteError } = useWriteContract()
  const { isLoading: votePending, isSuccess: voteSuccess } = useWaitForTransactionReceipt({ hash: voteTx })

  useEffect(() => {
    if (voteSuccess) {
      setTxSuccess('Vote cast successfully!')
      setTimeout(() => setTxSuccess(null), 6000)
    }
  }, [voteSuccess])

  useEffect(() => {
    const err = delegateError ?? voteError
    if (err) setTxError(friendlyTxError(err.message))
  }, [delegateError, voteError])

  const isBusy       = delegating || delegatePending || voting || votePending
  const canVote      = stateLabel === 'Active' && !alreadyVoted && votingPower !== undefined && votingPower > 0n
  const isActive     = stateLabel === 'Active'

  function handleVote() {
    if (!parsedId || !address) return
    setTxError(null)
    if (reason.trim()) {
      castVote({
        address: GOVERNOR_ADDRESS,
        abi:     GOVERNOR_ABI,
        functionName: 'castVoteWithReason',
        args: [parsedId, support, reason],
      })
    } else {
      castVote({
        address: GOVERNOR_ADDRESS,
        abi:     GOVERNOR_ABI,
        functionName: 'castVote',
        args: [parsedId, support],
      })
    }
  }

  function handleDelegate() {
    if (!address) return
    setTxError(null)
    delegate({
      address: GOV_TOKEN_ADDRESS,
      abi:     GOV_TOKEN_ABI,
      functionName: 'delegate',
      args: [address],
    })
  }

  return (
    <div className="bg-white/5 border border-white/10 rounded-2xl p-6 space-y-5">
      <h3 className="font-bold text-lg text-white">Cast a Vote</h3>

      {/* Voting power summary */}
      <div className="bg-gray-900/60 border border-white/5 rounded-xl p-4 flex items-center justify-between">
        <div>
          <p className="text-xs text-gray-500 mb-1">Your Voting Power</p>
          <p className="text-xl font-mono font-bold text-white">
            {votingPower !== undefined ? formatUnits(votingPower, 18) : '—'}
          </p>
        </div>
        {!selfDelegated && (
          <button
            onClick={handleDelegate}
            disabled={isBusy}
            className="flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium bg-yellow-600/20 text-yellow-300 border border-yellow-500/30 hover:bg-yellow-600/30 transition-all disabled:opacity-50"
          >
            {(delegating || delegatePending) && <Spinner />}
            {delegating ? 'Delegating…' : delegatePending ? 'Confirming…' : 'Self-delegate'}
          </button>
        )}
      </div>

      {/* Proposal ID */}
      <div className="space-y-1">
        <label className="text-xs text-gray-400">Proposal ID</label>
        <input
          type="text"
          placeholder="Enter proposal ID (uint256)"
          value={proposalId}
          onChange={e => { setProposalId(e.target.value.trim()); setTxError(null) }}
          className="w-full bg-gray-900 border border-white/10 rounded-xl px-4 py-3 text-white font-mono focus:outline-none focus:border-brand-500 transition-colors text-sm"
        />
        {/* Proposal state indicator */}
        {stateLabel && (
          <div className="flex items-center gap-2 mt-2">
            <span className="text-xs text-gray-400">State:</span>
            <span className={`text-xs px-2 py-0.5 rounded-full border font-medium ${stateColor(stateLabel)}`}>
              {stateLabel}
            </span>
            {alreadyVoted && (
              <span className="text-xs text-brand-400 ml-1">✓ You already voted</span>
            )}
          </div>
        )}
      </div>

      {/* Vote breakdown */}
      {breakdown && (
        <VoteBar breakdown={breakdown} />
      )}

      {/* Support selection */}
      <div className="space-y-2">
        <label className="text-xs text-gray-400">Your Vote</label>
        <div className="flex gap-2">
          {SUPPORT_OPTIONS.map(opt => (
            <button
              key={opt.value}
              onClick={() => setSupport(opt.value)}
              className={`flex-1 py-2.5 rounded-lg text-sm font-semibold transition-all ${
                support === opt.value
                  ? opt.color
                  : 'bg-white/5 text-gray-400 hover:text-white border border-white/10'
              }`}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </div>

      {/* Optional reason */}
      <div className="space-y-1">
        <label className="text-xs text-gray-400">Reason (optional, stored on-chain)</label>
        <textarea
          rows={2}
          placeholder="Explain your vote…"
          value={reason}
          onChange={e => setReason(e.target.value)}
          className="w-full bg-gray-900 border border-white/10 rounded-xl px-4 py-3 text-white text-sm focus:outline-none focus:border-brand-500 transition-colors resize-none"
        />
      </div>

      {/* Error / success */}
      {txError && (
        <p className="text-sm text-red-400 bg-red-500/10 border border-red-500/20 rounded-lg px-3 py-2">{txError}</p>
      )}
      {txSuccess && (
        <p className="text-sm text-green-400 bg-green-500/10 border border-green-500/20 rounded-lg px-3 py-2">{txSuccess}</p>
      )}

      {/* Action button */}
      <button
        onClick={handleVote}
        disabled={isBusy || !address || !canVote || parsedId === undefined}
        className="w-full py-3 rounded-xl font-semibold text-sm bg-brand-600 hover:bg-brand-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all text-white flex items-center justify-center gap-2"
      >
        {(voting || votePending) && <Spinner />}
        {voting ? 'Submitting…' : votePending ? 'Confirming…' : (
          !address ? 'Connect wallet' :
          !isActive ? 'Proposal not active' :
          alreadyVoted ? 'Already voted' :
          !votingPower || votingPower === 0n ? 'No voting power' :
          `Cast ${['Against', 'For', 'Abstain'][support]} Vote`
        )}
      </button>
    </div>
  )
}

function VoteBar({ breakdown }: { breakdown: { againstVotes: bigint; forVotes: bigint; abstainVotes: bigint } }) {
  const total = breakdown.forVotes + breakdown.againstVotes + breakdown.abstainVotes
  const pct = (v: bigint) => total === 0n ? 0 : Number((v * 10000n) / total) / 100

  return (
    <div className="space-y-2">
      <p className="text-xs text-gray-400">Current Vote Tally</p>
      <div className="flex h-2 rounded-full overflow-hidden bg-gray-800">
        <div className="bg-green-500 transition-all" style={{ width: `${pct(breakdown.forVotes)}%` }} />
        <div className="bg-red-500 transition-all"   style={{ width: `${pct(breakdown.againstVotes)}%` }} />
        <div className="bg-gray-500 transition-all"  style={{ width: `${pct(breakdown.abstainVotes)}%` }} />
      </div>
      <div className="grid grid-cols-3 text-xs text-center gap-1">
        <span className="text-green-400">For: {formatUnits(breakdown.forVotes, 18).slice(0, 8)}</span>
        <span className="text-red-400">Against: {formatUnits(breakdown.againstVotes, 18).slice(0, 8)}</span>
        <span className="text-gray-400">Abstain: {formatUnits(breakdown.abstainVotes, 18).slice(0, 8)}</span>
      </div>
    </div>
  )
}

function stateColor(state: string): string {
  switch (state) {
    case 'Active':    return 'bg-green-500/20 text-green-300 border-green-500/30'
    case 'Pending':   return 'bg-yellow-500/20 text-yellow-300 border-yellow-500/30'
    case 'Succeeded': return 'bg-brand-500/20 text-brand-300 border-brand-500/30'
    case 'Defeated':  return 'bg-red-500/20 text-red-300 border-red-500/30'
    case 'Executed':  return 'bg-gray-500/20 text-gray-300 border-gray-500/30'
    default:          return 'bg-gray-700/20 text-gray-400 border-gray-700/30'
  }
}

function Spinner() {
  return <span className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
}
