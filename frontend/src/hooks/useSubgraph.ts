/**
 * React hooks that execute the named queries from subgraph/queries.graphql
 * through the typed GraphQLClient in src/lib/graphql.ts.
 *
 * Each hook returns { data, loading, error, refetch }.
 */

import { useState, useEffect, useCallback, useRef } from 'react'
import {
  subgraphClient,
  POOL_DASHBOARD,
  DAILY_PROTOCOL_ACTIVITY,
  GOVERNANCE_PROPOSALS,
  USER_VAULT_ACTIVITY,
  PROPOSAL_DETAIL,
  type PoolDashboardData,
  type DailyActivityData,
  type GovernanceProposalsData,
  type UserVaultActivityData,
  type ProposalDetailData,
} from '../lib/graphql'
import { AMM_ADDRESS } from '../config/contracts'

// ── Generic query hook ────────────────────────────────────────────────────────

interface QueryState<T> {
  data:    T | null
  loading: boolean
  error:   string | null
}

function useQuery<T>(
  query:     string,
  variables: Record<string, unknown>,
  enabled = true,
): QueryState<T> & { refetch: () => void } {
  const [state, setState] = useState<QueryState<T>>({
    data: null, loading: true, error: null,
  })

  // Serialize variables to a stable string to use as effect dep
  const varKey = JSON.stringify(variables)
  // Keep latest variables ref so the callback always uses fresh values
  const varsRef = useRef(variables)
  varsRef.current = variables

  const run = useCallback(() => {
    if (!enabled) { setState(s => ({ ...s, loading: false })); return }
    setState(s => ({ ...s, loading: true, error: null }))
    subgraphClient
      .request<T>(query, varsRef.current)
      .then(data  => setState({ data, loading: false, error: null }))
      .catch(err  => setState({ data: null, loading: false, error: (err as Error).message }))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query, varKey, enabled])

  useEffect(() => { run() }, [run])

  return { ...state, refetch: run }
}

// ── Query 1: PoolDashboard ────────────────────────────────────────────────────
// Renders pool overview: reserves, all-time volumes, last 10 swaps.
export function usePoolDashboard(poolId?: string) {
  const id = (poolId ?? AMM_ADDRESS).toLowerCase()
  return useQuery<PoolDashboardData>(
    POOL_DASHBOARD,
    { poolId: id },
    !!id,
  )
}

// ── Query 2: DailyProtocolActivity ───────────────────────────────────────────
// Powers the 30-day activity chart (swap volume, deposits, governance).
export function useDailyActivity(days = 30) {
  const since = Math.floor(Date.now() / 1000) - days * 86_400
  return useQuery<DailyActivityData>(
    DAILY_PROTOCOL_ACTIVITY,
    { since: since.toString() },
  )
}

// ── Query 3: UserVaultActivity ────────────────────────────────────────────────
// Loads a connected user's deposit + withdrawal history across all vaults.
export function useUserVaultActivity(user?: string, skip = 0, first = 20) {
  return useQuery<UserVaultActivityData>(
    USER_VAULT_ACTIVITY,
    { user: (user ?? '').toLowerCase(), skip, first },
    !!user,
  )
}

// ── Query 4: GovernanceProposals ──────────────────────────────────────────────
// Paginated list of proposals sorted by voteEnd descending.
export function useGovernanceProposals(first = 10, skip = 0) {
  return useQuery<GovernanceProposalsData>(
    GOVERNANCE_PROPOSALS,
    { first, skip },
  )
}

// ── Query 5: ProposalDetail ───────────────────────────────────────────────────
// Single proposal with full call data + paginated individual votes.
export function useProposalDetail(proposalId?: string, first = 20, skip = 0) {
  return useQuery<ProposalDetailData>(
    PROPOSAL_DETAIL,
    { proposalId: proposalId ?? '', first, skip },
    !!proposalId,
  )
}

// ── Re-export types for convenience ──────────────────────────────────────────
export type {
  GqlPool,
  GqlSwap,
  GqlDayData,
  GqlProposal,
  GqlVote,
  GqlVaultDeposit,
  GqlVaultWithdrawal,
} from '../lib/graphql'
