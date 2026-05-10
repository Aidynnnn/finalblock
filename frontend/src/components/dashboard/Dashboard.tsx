import { useAccount, useReadContract, useReadContracts } from 'wagmi'
import { formatUnits } from 'viem'
import {
  AMM_ADDRESS, VAULT_ADDRESS, GOVERNOR_ADDRESS, GOV_TOKEN_ADDRESS,
  AMM_ABI, VAULT_ABI, GOV_TOKEN_ABI, GOVERNOR_ABI,
} from '../../config/contracts'

function StatCard({
  label,
  value,
  sub,
  loading,
}: {
  label: string
  value: string
  sub?: string
  loading?: boolean
}) {
  return (
    <div className="bg-white/5 border border-white/10 rounded-xl p-5 space-y-1">
      <p className="text-xs text-gray-500 font-medium uppercase tracking-widest">{label}</p>
      {loading ? (
        <div className="h-7 w-32 bg-white/10 animate-pulse rounded-md" />
      ) : (
        <p className="text-2xl font-bold text-white font-mono">{value}</p>
      )}
      {sub && <p className="text-xs text-gray-500">{sub}</p>}
    </div>
  )
}

function fmt(val: bigint | undefined, decimals = 18, dp = 4): string {
  if (val === undefined) return '—'
  const s = formatUnits(val, decimals)
  const n = parseFloat(s)
  if (n === 0) return '0'
  if (n < 0.0001) return '< 0.0001'
  return n.toLocaleString('en-US', { maximumFractionDigits: dp })
}

export function Dashboard() {
  const { address } = useAccount()

  // ── On-chain reads ───────────────────────────────────────────
  const { data: govToken, isLoading: loadingGov } = useReadContracts({
    contracts: [
      { address: GOV_TOKEN_ADDRESS, abi: GOV_TOKEN_ABI, functionName: 'symbol' },
      { address: GOV_TOKEN_ADDRESS, abi: GOV_TOKEN_ABI, functionName: 'balanceOf', args: [address ?? '0x0000000000000000000000000000000000000000'] },
      { address: GOV_TOKEN_ADDRESS, abi: GOV_TOKEN_ABI, functionName: 'getVotes',  args: [address ?? '0x0000000000000000000000000000000000000000'] },
      { address: GOV_TOKEN_ADDRESS, abi: GOV_TOKEN_ABI, functionName: 'delegates', args: [address ?? '0x0000000000000000000000000000000000000000'] },
    ],
    query: { enabled: !!address },
  })

  const { data: ammData, isLoading: loadingAmm } = useReadContracts({
    contracts: [
      { address: AMM_ADDRESS, abi: AMM_ABI, functionName: 'token0' },
      { address: AMM_ADDRESS, abi: AMM_ABI, functionName: 'token1' },
      { address: AMM_ADDRESS, abi: AMM_ABI, functionName: 'getReserves' },
      { address: AMM_ADDRESS, abi: AMM_ABI, functionName: 'totalSupply' },
      { address: AMM_ADDRESS, abi: AMM_ABI, functionName: 'balanceOf', args: [address ?? '0x0000000000000000000000000000000000000000'] },
    ],
    query: { enabled: !!address },
  })

  const { data: vaultData, isLoading: loadingVault } = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'totalAssets' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'totalSupply' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'balanceOf', args: [address ?? '0x0000000000000000000000000000000000000000'] },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'paused' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'version' },
    ],
    query: { enabled: !!address },
  })

  const { data: govData, isLoading: loadingGovParams } = useReadContract({
    address: GOVERNOR_ADDRESS,
    abi: GOVERNOR_ABI,
    functionName: 'proposalThreshold',
  })

  // ── Parsed values ────────────────────────────────────────────
  const dgovSymbol     = govToken?.[0].result as string | undefined ?? 'DGOV'
  const dgovBalance    = govToken?.[1].result as bigint | undefined
  const votingPower    = govToken?.[2].result as bigint | undefined
  const delegateTo     = govToken?.[3].result as string | undefined

  const reserves       = ammData?.[2].result as [bigint, bigint] | undefined
  const lpTotalSupply  = ammData?.[3].result as bigint | undefined
  const lpBalance      = ammData?.[4].result as bigint | undefined

  const vaultAssets    = vaultData?.[0].result as bigint | undefined
  const vaultShares    = vaultData?.[1].result as bigint | undefined
  const userShares     = vaultData?.[2].result as bigint | undefined
  const isPaused       = vaultData?.[3].result as boolean | undefined
  const vaultVersion   = vaultData?.[4].result as string | undefined

  const selfDelegated  = delegateTo?.toLowerCase() === address?.toLowerCase()
  const loadingAny     = loadingGov || loadingAmm || loadingVault || loadingGovParams

  return (
    <div className="space-y-8">
      {/* ── Governance Token ──────────────────────────────── */}
      <section>
        <h2 className="text-sm font-semibold text-gray-400 uppercase tracking-widest mb-4">
          Governance Token ({dgovSymbol})
        </h2>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <StatCard
            label="Your Balance"
            value={fmt(dgovBalance)}
            sub={dgovSymbol}
            loading={loadingGov}
          />
          <StatCard
            label="Voting Power"
            value={fmt(votingPower)}
            sub={selfDelegated ? 'Self-delegated ✓' : 'Not self-delegated'}
            loading={loadingGov}
          />
          <StatCard
            label="Proposal Threshold"
            value={fmt(govData)}
            sub="Min DGOV to propose"
            loading={loadingGovParams}
          />
          <StatCard
            label="Delegation"
            value={delegateTo ? `${delegateTo.slice(0, 6)}…${delegateTo.slice(-4)}` : '—'}
            sub={selfDelegated ? 'To self' : 'To another account'}
            loading={loadingGov}
          />
        </div>
        {!selfDelegated && votingPower === 0n && dgovBalance !== undefined && dgovBalance > 0n && (
          <p className="mt-3 text-sm text-yellow-400 bg-yellow-500/10 border border-yellow-500/20 rounded-lg px-4 py-2">
            You have {dgovSymbol} tokens but no voting power. Use the Vote tab to delegate to yourself.
          </p>
        )}
      </section>

      {/* ── AMM Pool ──────────────────────────────────────── */}
      <section>
        <h2 className="text-sm font-semibold text-gray-400 uppercase tracking-widest mb-4">
          AMM Pool Reserves
        </h2>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <StatCard
            label="Reserve 0"
            value={fmt(reserves?.[0])}
            sub="Token 0"
            loading={loadingAmm}
          />
          <StatCard
            label="Reserve 1"
            value={fmt(reserves?.[1])}
            sub="Token 1"
            loading={loadingAmm}
          />
          <StatCard
            label="LP Total Supply"
            value={fmt(lpTotalSupply)}
            sub="LP tokens"
            loading={loadingAmm}
          />
          <StatCard
            label="Your LP Balance"
            value={fmt(lpBalance)}
            sub="LP tokens"
            loading={loadingAmm}
          />
        </div>
        {reserves && reserves[0] > 0n && reserves[1] > 0n && (
          <p className="mt-3 text-xs text-gray-500">
            Price ratio: 1 Token0 ≈{' '}
            {(Number(formatUnits(reserves[1], 18)) / Number(formatUnits(reserves[0], 18))).toFixed(6)}{' '}
            Token1
          </p>
        )}
      </section>

      {/* ── ERC-4626 Vault ────────────────────────────────── */}
      <section>
        <div className="flex items-center gap-3 mb-4">
          <h2 className="text-sm font-semibold text-gray-400 uppercase tracking-widest">
            ERC-4626 Vault {vaultVersion ? `v${vaultVersion}` : ''}
          </h2>
          {isPaused !== undefined && (
            <span className={`text-xs px-2 py-0.5 rounded-full border font-medium ${
              isPaused
                ? 'bg-red-500/20 text-red-300 border-red-500/30'
                : 'bg-green-500/20 text-green-300 border-green-500/30'
            }`}>
              {isPaused ? 'Paused' : 'Active'}
            </span>
          )}
        </div>
        <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <StatCard
            label="Total Assets (LP)"
            value={fmt(vaultAssets)}
            sub="LP tokens held"
            loading={loadingVault}
          />
          <StatCard
            label="Total Shares"
            value={fmt(vaultShares)}
            sub="Vault shares issued"
            loading={loadingVault}
          />
          <StatCard
            label="Your Shares"
            value={fmt(userShares)}
            sub="Your vault position"
            loading={loadingVault}
          />
        </div>
        {loadingAny && (
          <p className="mt-2 text-xs text-gray-600 animate-pulse">Fetching on-chain data…</p>
        )}
      </section>
    </div>
  )
}
