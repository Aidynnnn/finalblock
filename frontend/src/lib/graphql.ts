/**
 * Lightweight GraphQL client for The Graph subgraph queries.
 *
 * Mirrors the interface of `graphql-request` without the extra dependency:
 *   client.request<T>(query, variables?) → Promise<T>
 *
 * All named query strings below are taken verbatim from
 * subgraph/queries.graphql so the frontend and subgraph stay in sync.
 */

import { SUBGRAPH_URL } from '../config/contracts'

// ── Client ────────────────────────────────────────────────────────────────────

export class GraphQLClient {
  constructor(private readonly endpoint: string) {}

  async request<T>(
    query:      string,
    variables?: Record<string, unknown>,
  ): Promise<T> {
    if (!this.endpoint) {
      throw new Error(
        'Subgraph endpoint not configured. Set VITE_SUBGRAPH_URL in your .env file.',
      )
    }

    const response = await fetch(this.endpoint, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ query, variables }),
    })

    if (!response.ok) {
      throw new Error(`HTTP ${response.status} — ${response.statusText}`)
    }

    const body = (await response.json()) as {
      data?:   T
      errors?: { message: string; locations?: unknown; path?: string[] }[]
    }

    if (body.errors?.length) {
      const msg = body.errors.map((e) => e.message).join('; ')
      throw new Error(`Subgraph error: ${msg}`)
    }

    if (!body.data) {
      throw new Error('Subgraph returned an empty response (no "data" field).')
    }

    return body.data
  }
}

/** Singleton client used by all hooks. */
export const subgraphClient = new GraphQLClient(SUBGRAPH_URL)

// ── Named queries (from subgraph/queries.graphql) ─────────────────────────────

/**
 * Query 1 — AMM Pool Dashboard
 * Renders pool overview: reserves, all-time volumes, last 10 swaps.
 * Variables: $poolId (lowercase AMM contract address)
 */
export const POOL_DASHBOARD = /* GraphQL */ `
  query PoolDashboard($poolId: ID!) {
    pool(id: $poolId) {
      id
      token0
      token1
      reserve0
      reserve1
      totalVolumeToken0
      totalVolumeToken1
      swapCount
      txCount
      updatedAtTimestamp
      swaps(first: 10, orderBy: timestamp, orderDirection: desc) {
        id
        swapper
        tokenIn
        amountIn
        amountOut
        timestamp
        transactionHash
      }
    }
  }
`

/**
 * Query 2 — Protocol-wide Daily Activity Chart
 * 30-day bar chart: swap volume, deposit count, governance activity.
 * Variables: $since (Unix timestamp of earliest day)
 */
export const DAILY_PROTOCOL_ACTIVITY = /* GraphQL */ `
  query DailyProtocolActivity($since: BigInt!) {
    protocolDayDatas(
      where:          { date_gte: $since }
      orderBy:        date
      orderDirection: asc
      first:          30
    ) {
      id
      date
      dailySwapCount
      dailyVolumeToken0
      dailyVolumeToken1
      dailyDepositCount
      dailyWithdrawalCount
      dailyProposalCount
      dailyVoteCount
    }
  }
`

/**
 * Query 3 — Vault Portfolio for a User
 * Shows a user's deposits and withdrawals across all vaults.
 * Variables: $user (lowercase wallet address), $skip, $first
 */
export const USER_VAULT_ACTIVITY = /* GraphQL */ `
  query UserVaultActivity($user: Bytes!, $skip: Int = 0, $first: Int = 20) {
    deposits: vaultDeposits(
      where:          { owner: $user }
      orderBy:        timestamp
      orderDirection: desc
      skip:           $skip
      first:          $first
    ) {
      id
      assets
      shares
      timestamp
      transactionHash
      vault { id lpToken paused }
    }
    withdrawals: vaultWithdrawals(
      where:          { owner: $user }
      orderBy:        timestamp
      orderDirection: desc
      skip:           $skip
      first:          $first
    ) {
      id
      assets
      shares
      receiver
      timestamp
      transactionHash
      vault { id lpToken }
    }
  }
`

/**
 * Query 4 — Governance Proposal List
 * Renders governance dashboard: proposals sorted by voteEnd desc.
 * Variables: $first, $skip
 */
export const GOVERNANCE_PROPOSALS = /* GraphQL */ `
  query GovernanceProposals($first: Int = 10, $skip: Int = 0) {
    proposals(
      orderBy:        voteEnd
      orderDirection: desc
      first:          $first
      skip:           $skip
    ) {
      id
      proposalId
      proposer
      description
      voteStart
      voteEnd
      queued
      etaSeconds
      executed
      canceled
      forVotes
      againstVotes
      abstainVotes
      voterCount
      createdAtTimestamp
    }
  }
`

/**
 * Query 5 — Proposal Detail with Individual Votes
 * Full proposal data + paginated ballot list (by descending weight).
 * Variables: $proposalId (hex string), $first, $skip
 */
export const PROPOSAL_DETAIL = /* GraphQL */ `
  query ProposalDetail($proposalId: ID!, $first: Int = 20, $skip: Int = 0) {
    proposal(id: $proposalId) {
      id
      proposalId
      proposer
      targets
      values
      calldatas
      description
      voteStart
      voteEnd
      queued
      etaSeconds
      executed
      canceled
      forVotes
      againstVotes
      abstainVotes
      voterCount
      createdAtBlock
      createdAtTimestamp
      votes(
        orderBy:        weight
        orderDirection: desc
        first:          $first
        skip:           $skip
      ) {
        id
        voter
        support
        weight
        reason
        timestamp
        transactionHash
      }
    }
  }
`

// ── Response types ─────────────────────────────────────────────────────────────

export interface GqlSwap {
  id:              string
  swapper:         string
  tokenIn:         string
  amountIn:        string
  amountOut:       string
  timestamp:       string
  transactionHash: string
}

export interface GqlPool {
  id:                 string
  token0:             string
  token1:             string
  reserve0:           string
  reserve1:           string
  totalVolumeToken0:  string
  totalVolumeToken1:  string
  swapCount:          string
  txCount:            string
  updatedAtTimestamp: string
  swaps:              GqlSwap[]
}

export interface PoolDashboardData   { pool: GqlPool | null }

export interface GqlDayData {
  id:                   string
  date:                 string
  dailySwapCount:       string
  dailyVolumeToken0:    string
  dailyVolumeToken1:    string
  dailyDepositCount:    string
  dailyWithdrawalCount: string
  dailyProposalCount:   string
  dailyVoteCount:       string
}

export interface DailyActivityData   { protocolDayDatas: GqlDayData[] }

export interface GqlVaultRef { id: string; lpToken: string; paused?: boolean }

export interface GqlVaultDeposit {
  id:              string
  assets:          string
  shares:          string
  timestamp:       string
  transactionHash: string
  vault:           GqlVaultRef
}

export interface GqlVaultWithdrawal {
  id:              string
  assets:          string
  shares:          string
  receiver:        string
  timestamp:       string
  transactionHash: string
  vault:           GqlVaultRef
}

export interface UserVaultActivityData {
  deposits:    GqlVaultDeposit[]
  withdrawals: GqlVaultWithdrawal[]
}

export interface GqlProposal {
  id:                string
  proposalId:        string
  proposer:          string
  description:       string
  voteStart:         string
  voteEnd:           string
  queued:            boolean
  etaSeconds:        string | null
  executed:          boolean
  canceled:          boolean
  forVotes:          string
  againstVotes:      string
  abstainVotes:      string
  voterCount:        string
  createdAtTimestamp: string
}

export interface GovernanceProposalsData { proposals: GqlProposal[] }

export interface GqlVote {
  id:              string
  voter:           string
  support:         number
  weight:          string
  reason:          string
  timestamp:       string
  transactionHash: string
}

export interface GqlProposalDetail extends GqlProposal {
  targets:       string[]
  values:        string[]
  calldatas:     string[]
  createdAtBlock: string
  votes:         GqlVote[]
}

export interface ProposalDetailData { proposal: GqlProposalDetail | null }
