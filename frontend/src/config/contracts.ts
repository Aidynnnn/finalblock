import type { Address } from 'viem'

// ── Addresses (configured via .env) ─────────────────────────────
export const AMM_ADDRESS       = (import.meta.env.VITE_AMM_ADDRESS       ?? '0x0000000000000000000000000000000000000000') as Address
export const VAULT_ADDRESS     = (import.meta.env.VITE_VAULT_ADDRESS     ?? '0x0000000000000000000000000000000000000000') as Address
export const GOVERNOR_ADDRESS  = (import.meta.env.VITE_GOVERNOR_ADDRESS  ?? '0x0000000000000000000000000000000000000000') as Address
export const GOV_TOKEN_ADDRESS = (import.meta.env.VITE_GOV_TOKEN_ADDRESS ?? '0x0000000000000000000000000000000000000000') as Address
export const SUBGRAPH_URL      = (import.meta.env.VITE_SUBGRAPH_URL      ?? '') as string

// ── Minimal ERC-20 ABI ───────────────────────────────────────────
export const ERC20_ABI = [
  { type: 'function', name: 'name',        inputs: [], outputs: [{ type: 'string' }],  stateMutability: 'view' },
  { type: 'function', name: 'symbol',      inputs: [], outputs: [{ type: 'string' }],  stateMutability: 'view' },
  { type: 'function', name: 'decimals',    inputs: [], outputs: [{ type: 'uint8' }],   stateMutability: 'view' },
  { type: 'function', name: 'totalSupply', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  {
    type: 'function', name: 'balanceOf',
    inputs:  [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'allowance',
    inputs:  [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'approve',
    inputs:  [{ name: 'spender', type: 'address' }, { name: 'value', type: 'uint256' }],
    outputs: [{ type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function', name: 'transfer',
    inputs:  [{ name: 'to', type: 'address' }, { name: 'value', type: 'uint256' }],
    outputs: [{ type: 'bool' }],
    stateMutability: 'nonpayable',
  },
] as const

// ── GovernanceToken (DGOV) ABI ───────────────────────────────────
export const GOV_TOKEN_ABI = [
  ...ERC20_ABI,
  {
    type: 'function', name: 'getVotes',
    inputs:  [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'delegates',
    inputs:  [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'delegate',
    inputs:  [{ name: 'delegatee', type: 'address' }],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function', name: 'getPastVotes',
    inputs:  [{ name: 'account', type: 'address' }, { name: 'timepoint', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'clock',
    inputs:  [],
    outputs: [{ type: 'uint48' }],
    stateMutability: 'view',
  },
] as const

// ── ConstantProductAMM ABI ───────────────────────────────────────
export const AMM_ABI = [
  // View
  {
    type: 'function', name: 'token0',
    inputs:  [],
    outputs: [{ name: '', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'token1',
    inputs:  [],
    outputs: [{ name: '', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'getReserves',
    inputs:  [],
    outputs: [{ name: 'reserve0', type: 'uint256' }, { name: 'reserve1', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'getAmountOut',
    inputs:  [{ name: 'tokenIn', type: 'address' }, { name: 'amountIn', type: 'uint256' }],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
    stateMutability: 'view',
  },
  // LP token (AMM IS an ERC-20)
  { type: 'function', name: 'totalSupply', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  {
    type: 'function', name: 'balanceOf',
    inputs:  [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'allowance',
    inputs:  [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'approve',
    inputs:  [{ name: 'spender', type: 'address' }, { name: 'value', type: 'uint256' }],
    outputs: [{ type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  // Write
  {
    type: 'function', name: 'swap',
    inputs: [
      { name: 'tokenIn',      type: 'address' },
      { name: 'amountIn',     type: 'uint256' },
      { name: 'amountOutMin', type: 'uint256' },
      { name: 'to',           type: 'address' },
      { name: 'deadline',     type: 'uint256' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function', name: 'addLiquidity',
    inputs: [
      { name: 'amount0Desired', type: 'uint256' },
      { name: 'amount1Desired', type: 'uint256' },
      { name: 'amount0Min',     type: 'uint256' },
      { name: 'amount1Min',     type: 'uint256' },
      { name: 'to',             type: 'address' },
      { name: 'deadline',       type: 'uint256' },
    ],
    outputs: [
      { name: 'amount0',   type: 'uint256' },
      { name: 'amount1',   type: 'uint256' },
      { name: 'lpTokens',  type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  // Events
  {
    type: 'event', name: 'Swap',
    inputs: [
      { name: 'swapper',   type: 'address', indexed: true },
      { name: 'tokenIn',   type: 'address', indexed: true },
      { name: 'amountIn',  type: 'uint256', indexed: false },
      { name: 'amountOut', type: 'uint256', indexed: false },
    ],
    anonymous: false,
  },
  {
    type: 'event', name: 'LiquidityAdded',
    inputs: [
      { name: 'provider',       type: 'address', indexed: true },
      { name: 'amount0',        type: 'uint256', indexed: false },
      { name: 'amount1',        type: 'uint256', indexed: false },
      { name: 'lpTokensMinted', type: 'uint256', indexed: false },
    ],
    anonymous: false,
  },
  {
    type: 'event', name: 'ReservesUpdated',
    inputs: [
      { name: 'reserve0', type: 'uint256', indexed: false },
      { name: 'reserve1', type: 'uint256', indexed: false },
    ],
    anonymous: false,
  },
] as const

// ── ERC-4626 Vault (UUPS proxy) ABI ─────────────────────────────
export const VAULT_ABI = [
  // Metadata
  { type: 'function', name: 'name',    inputs: [], outputs: [{ type: 'string' }],  stateMutability: 'view' },
  { type: 'function', name: 'symbol',  inputs: [], outputs: [{ type: 'string' }],  stateMutability: 'view' },
  { type: 'function', name: 'decimals',inputs: [], outputs: [{ type: 'uint8' }],   stateMutability: 'view' },
  { type: 'function', name: 'version', inputs: [], outputs: [{ type: 'string' }],  stateMutability: 'pure' },
  { type: 'function', name: 'paused',  inputs: [], outputs: [{ type: 'bool' }],    stateMutability: 'view' },
  { type: 'function', name: 'asset',   inputs: [], outputs: [{ type: 'address' }], stateMutability: 'view' },
  { type: 'function', name: 'amm',     inputs: [], outputs: [{ type: 'address' }], stateMutability: 'view' },
  // ERC-20 share token
  { type: 'function', name: 'totalSupply', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  {
    type: 'function', name: 'balanceOf',
    inputs:  [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'allowance',
    inputs:  [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'approve',
    inputs:  [{ name: 'spender', type: 'address' }, { name: 'value', type: 'uint256' }],
    outputs: [{ type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  // ERC-4626 view
  { type: 'function', name: 'totalAssets', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' },
  {
    type: 'function', name: 'convertToShares',
    inputs:  [{ name: 'assets', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'convertToAssets',
    inputs:  [{ name: 'shares', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'previewDeposit',
    inputs:  [{ name: 'assets', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'previewRedeem',
    inputs:  [{ name: 'shares', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'maxDeposit',
    inputs:  [{ name: 'receiver', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'maxWithdraw',
    inputs:  [{ name: 'owner', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'maxRedeem',
    inputs:  [{ name: 'owner', type: 'address' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  // ERC-4626 write (standard 2-arg overload)
  {
    type: 'function', name: 'deposit',
    inputs:  [{ name: 'assets', type: 'uint256' }, { name: 'receiver', type: 'address' }],
    outputs: [{ name: 'shares', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function', name: 'redeem',
    inputs: [
      { name: 'shares',   type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'owner',    type: 'address' },
    ],
    outputs: [{ name: 'assets', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function', name: 'withdraw',
    inputs: [
      { name: 'assets',   type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'owner',    type: 'address' },
    ],
    outputs: [{ name: 'shares', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  // Events
  {
    type: 'event', name: 'Deposit',
    inputs: [
      { name: 'sender', type: 'address', indexed: true },
      { name: 'owner',  type: 'address', indexed: true },
      { name: 'assets', type: 'uint256', indexed: false },
      { name: 'shares', type: 'uint256', indexed: false },
    ],
    anonymous: false,
  },
  {
    type: 'event', name: 'Withdraw',
    inputs: [
      { name: 'sender',   type: 'address', indexed: true },
      { name: 'receiver', type: 'address', indexed: true },
      { name: 'owner',    type: 'address', indexed: true },
      { name: 'assets',   type: 'uint256', indexed: false },
      { name: 'shares',   type: 'uint256', indexed: false },
    ],
    anonymous: false,
  },
] as const

// ── ProtocolGovernor ABI ─────────────────────────────────────────
export const GOVERNOR_ABI = [
  // View
  {
    type: 'function', name: 'name',
    inputs:  [],
    outputs: [{ type: 'string' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'votingDelay',
    inputs:  [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'votingPeriod',
    inputs:  [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'proposalThreshold',
    inputs:  [],
    outputs: [{ name: 'threshold', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'state',
    inputs:  [{ name: 'proposalId', type: 'uint256' }],
    outputs: [{ type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'proposalSnapshot',
    inputs:  [{ name: 'proposalId', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'proposalDeadline',
    inputs:  [{ name: 'proposalId', type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'proposalVotes',
    inputs:  [{ name: 'proposalId', type: 'uint256' }],
    outputs: [
      { name: 'againstVotes', type: 'uint256' },
      { name: 'forVotes',     type: 'uint256' },
      { name: 'abstainVotes', type: 'uint256' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'hasVoted',
    inputs:  [{ name: 'proposalId', type: 'uint256' }, { name: 'account', type: 'address' }],
    outputs: [{ type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'quorumNumerator',
    inputs:  [],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function', name: 'timelock',
    inputs:  [],
    outputs: [{ type: 'address' }],
    stateMutability: 'view',
  },
  // Write
  {
    type: 'function', name: 'castVote',
    inputs:  [{ name: 'proposalId', type: 'uint256' }, { name: 'support', type: 'uint8' }],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function', name: 'castVoteWithReason',
    inputs: [
      { name: 'proposalId', type: 'uint256' },
      { name: 'support',    type: 'uint8' },
      { name: 'reason',     type: 'string' },
    ],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function', name: 'propose',
    inputs: [
      { name: 'targets',     type: 'address[]' },
      { name: 'values',      type: 'uint256[]' },
      { name: 'calldatas',   type: 'bytes[]' },
      { name: 'description', type: 'string' },
    ],
    outputs: [{ type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  // Events
  {
    type: 'event', name: 'ProposalCreated',
    inputs: [
      { name: 'proposalId',  type: 'uint256',   indexed: false },
      { name: 'proposer',    type: 'address',   indexed: false },
      { name: 'targets',     type: 'address[]', indexed: false },
      { name: 'values',      type: 'uint256[]', indexed: false },
      { name: 'signatures',  type: 'string[]',  indexed: false },
      { name: 'calldatas',   type: 'bytes[]',   indexed: false },
      { name: 'voteStart',   type: 'uint256',   indexed: false },
      { name: 'voteEnd',     type: 'uint256',   indexed: false },
      { name: 'description', type: 'string',    indexed: false },
    ],
    anonymous: false,
  },
  {
    type: 'event', name: 'VoteCast',
    inputs: [
      { name: 'voter',      type: 'address', indexed: true },
      { name: 'proposalId', type: 'uint256', indexed: false },
      { name: 'support',    type: 'uint8',   indexed: false },
      { name: 'weight',     type: 'uint256', indexed: false },
      { name: 'reason',     type: 'string',  indexed: false },
    ],
    anonymous: false,
  },
] as const

// ── Proposal state enum ──────────────────────────────────────────
export const PROPOSAL_STATES = [
  'Pending', 'Active', 'Canceled', 'Defeated',
  'Succeeded', 'Queued', 'Expired', 'Executed',
] as const

export type ProposalState = typeof PROPOSAL_STATES[number]

export function proposalStateBadgeColor(state: ProposalState): string {
  switch (state) {
    case 'Active':    return 'bg-green-500/20 text-green-300 border-green-500/30'
    case 'Pending':   return 'bg-yellow-500/20 text-yellow-300 border-yellow-500/30'
    case 'Succeeded': return 'bg-brand-500/20 text-brand-300 border-brand-500/30'
    case 'Queued':    return 'bg-blue-500/20 text-blue-300 border-blue-500/30'
    case 'Executed':  return 'bg-gray-500/20 text-gray-300 border-gray-500/30'
    case 'Defeated':  return 'bg-red-500/20 text-red-300 border-red-500/30'
    case 'Canceled':  return 'bg-orange-500/20 text-orange-300 border-orange-500/30'
    case 'Expired':   return 'bg-gray-600/20 text-gray-400 border-gray-600/30'
  }
}
