import { useState, useEffect } from 'react'
import { useAccount, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits, formatUnits, maxUint256 } from 'viem'
import { VAULT_ADDRESS, VAULT_ABI, AMM_ADDRESS, AMM_ABI, ERC20_ABI } from '../../config/contracts'

function friendlyTxError(msg: string): string {
  if (msg.includes('user rejected'))      return 'Transaction rejected in wallet.'
  if (msg.includes('insufficient funds')) return 'Insufficient ETH for gas.'
  if (msg.includes('Pausable: paused'))   return 'The vault is currently paused. Deposits are disabled.'
  if (msg.includes('ERC4626ExceededMaxDeposit')) return 'Amount exceeds the maximum deposit limit.'
  return 'Transaction failed. Check your inputs and try again.'
}

export function VaultDepositForm() {
  const { address } = useAccount()
  const [assets, setAssets]         = useState('')
  const [mode, setMode]             = useState<'deposit' | 'redeem'>('deposit')
  const [txError, setTxError]       = useState<string | null>(null)
  const [txSuccess, setTxSuccess]   = useState<string | null>(null)

  // ── Read vault/LP info ───────────────────────────────────────
  const { data: vaultInfo, refetch } = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'paused' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'totalAssets' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'totalSupply' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'balanceOf', args: [address ?? '0x0000000000000000000000000000000000000000'] },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'asset' },
      { address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: 'version' },
    ],
    query: { enabled: !!address },
  })

  const isPaused     = vaultInfo?.[0].result as boolean | undefined
  const totalAssets  = vaultInfo?.[1].result as bigint | undefined
  const totalShares  = vaultInfo?.[2].result as bigint | undefined
  const userShares   = vaultInfo?.[3].result as bigint | undefined
  const assetAddr    = vaultInfo?.[4].result as `0x${string}` | undefined
  const version      = vaultInfo?.[5].result as string | undefined

  // LP token balance
  const { data: lpBalance, refetch: refetchLp } = useReadContract({
    address: AMM_ADDRESS,
    abi:     AMM_ABI,
    functionName: 'balanceOf',
    args: [address ?? '0x0000000000000000000000000000000000000000'],
    query: { enabled: !!address },
  })

  // LP token allowance to vault
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: AMM_ADDRESS,
    abi:     AMM_ABI,
    functionName: 'allowance',
    args: [address ?? '0x0000000000000000000000000000000000000000', VAULT_ADDRESS],
    query: { enabled: !!address },
  })

  const parsedAmount = (() => {
    try { return assets ? parseUnits(assets, 18) : 0n } catch { return 0n }
  })()

  // Preview shares for given deposit
  const { data: previewShares } = useReadContract({
    address: VAULT_ADDRESS,
    abi:     VAULT_ABI,
    functionName: 'previewDeposit',
    args: [parsedAmount],
    query: { enabled: parsedAmount > 0n && mode === 'deposit' },
  })

  // Preview assets for given redeem
  const { data: previewAssets } = useReadContract({
    address: VAULT_ADDRESS,
    abi:     VAULT_ABI,
    functionName: 'previewRedeem',
    args: [parsedAmount],
    query: { enabled: parsedAmount > 0n && mode === 'redeem' },
  })

  const needsApproval = mode === 'deposit'
    && allowance !== undefined
    && parsedAmount > 0n
    && (allowance as bigint) < parsedAmount

  // ── Approve LP token ─────────────────────────────────────────
  const { writeContract: approve, data: approveTx, isPending: approving, error: approveError } = useWriteContract()
  const { isLoading: approvePending, isSuccess: approveSuccess } = useWaitForTransactionReceipt({ hash: approveTx })

  useEffect(() => {
    if (approveSuccess) void refetchAllowance()
  }, [approveSuccess, refetchAllowance])

  // ── Deposit ──────────────────────────────────────────────────
  const { writeContract: deposit, data: depositTx, isPending: depositing, error: depositError } = useWriteContract()
  const { isLoading: depositPending, isSuccess: depositSuccess } = useWaitForTransactionReceipt({ hash: depositTx })

  useEffect(() => {
    if (depositSuccess) {
      setTxSuccess('Deposit confirmed! Vault shares minted.')
      setAssets('')
      void refetch()
      void refetchLp()
      setTimeout(() => setTxSuccess(null), 6000)
    }
  }, [depositSuccess, refetch, refetchLp])

  // ── Redeem ───────────────────────────────────────────────────
  const { writeContract: redeem, data: redeemTx, isPending: redeeming, error: redeemError } = useWriteContract()
  const { isLoading: redeemPending, isSuccess: redeemSuccess } = useWaitForTransactionReceipt({ hash: redeemTx })

  useEffect(() => {
    if (redeemSuccess) {
      setTxSuccess('Redeem confirmed! LP tokens returned.')
      setAssets('')
      void refetch()
      void refetchLp()
      setTimeout(() => setTxSuccess(null), 6000)
    }
  }, [redeemSuccess, refetch, refetchLp])

  useEffect(() => {
    const err = approveError ?? depositError ?? redeemError
    if (err) setTxError(friendlyTxError(err.message))
  }, [approveError, depositError, redeemError])

  const isBusy = approving || approvePending || depositing || depositPending || redeeming || redeemPending

  function handleAction() {
    if (!address || parsedAmount === 0n) return
    setTxError(null)
    if (mode === 'deposit') {
      deposit({
        address: VAULT_ADDRESS,
        abi:     VAULT_ABI,
        functionName: 'deposit',
        args: [parsedAmount, address],
      })
    } else {
      redeem({
        address: VAULT_ADDRESS,
        abi:     VAULT_ABI,
        functionName: 'redeem',
        args: [parsedAmount, address, address],
      })
    }
  }

  function handleApprove() {
    setTxError(null)
    approve({
      address: AMM_ADDRESS,
      abi:     ERC20_ABI,
      functionName: 'approve',
      args: [VAULT_ADDRESS, maxUint256],
    })
  }

  function setMax() {
    if (mode === 'deposit' && lpBalance) {
      setAssets(formatUnits(lpBalance as bigint, 18))
    } else if (mode === 'redeem' && userShares) {
      setAssets(formatUnits(userShares, 18))
    }
  }

  return (
    <div className="bg-white/5 border border-white/10 rounded-2xl p-6 space-y-5">
      <div className="flex items-center justify-between">
        <h3 className="font-bold text-lg text-white">
          ERC-4626 Vault {version ? <span className="text-sm text-gray-400 font-normal">v{version}</span> : null}
        </h3>
        {isPaused && (
          <span className="text-xs px-2 py-0.5 rounded-full bg-red-500/20 text-red-300 border border-red-500/30">
            Paused
          </span>
        )}
      </div>

      {/* Vault stats */}
      <div className="grid grid-cols-2 gap-3">
        <div className="bg-gray-900/60 border border-white/5 rounded-xl p-3">
          <p className="text-xs text-gray-500">Total Assets</p>
          <p className="font-mono text-white text-sm">{totalAssets !== undefined ? formatUnits(totalAssets, 18) : '—'} LP</p>
        </div>
        <div className="bg-gray-900/60 border border-white/5 rounded-xl p-3">
          <p className="text-xs text-gray-500">Your Shares</p>
          <p className="font-mono text-white text-sm">{userShares !== undefined ? formatUnits(userShares, 18) : '—'}</p>
        </div>
      </div>

      {/* Mode toggle */}
      <div className="flex gap-2 bg-gray-900/60 p-1 rounded-xl">
        <button
          onClick={() => { setMode('deposit'); setAssets(''); setTxError(null) }}
          className={`flex-1 py-2 rounded-lg text-sm font-medium transition-all ${
            mode === 'deposit' ? 'bg-brand-600 text-white' : 'text-gray-400 hover:text-white'
          }`}
        >
          Deposit LP tokens
        </button>
        <button
          onClick={() => { setMode('redeem'); setAssets(''); setTxError(null) }}
          className={`flex-1 py-2 rounded-lg text-sm font-medium transition-all ${
            mode === 'redeem' ? 'bg-brand-600 text-white' : 'text-gray-400 hover:text-white'
          }`}
        >
          Redeem Shares
        </button>
      </div>

      {/* Amount input */}
      <div className="space-y-1">
        <div className="flex justify-between items-center">
          <label className="text-xs text-gray-400">
            {mode === 'deposit' ? 'LP tokens to deposit' : 'Vault shares to redeem'}
          </label>
          <button onClick={setMax} className="text-xs text-brand-400 hover:text-brand-300 transition-colors">
            Max
          </button>
        </div>
        <input
          type="number"
          min="0"
          step="any"
          placeholder="0.0"
          value={assets}
          onChange={e => { setAssets(e.target.value); setTxError(null) }}
          className="w-full bg-gray-900 border border-white/10 rounded-xl px-4 py-3 text-white font-mono text-lg focus:outline-none focus:border-brand-500 transition-colors"
        />
        <p className="text-xs text-gray-500">
          {mode === 'deposit'
            ? `Your LP balance: ${lpBalance !== undefined ? formatUnits(lpBalance as bigint, 18) : '—'}`
            : `Your shares: ${userShares !== undefined ? formatUnits(userShares, 18) : '—'}`}
        </p>
      </div>

      {/* Preview */}
      {parsedAmount > 0n && (
        <div className="bg-gray-900/60 border border-white/5 rounded-xl px-4 py-3 text-sm">
          <div className="flex justify-between">
            <span className="text-gray-400">
              {mode === 'deposit' ? 'Shares to receive' : 'LP tokens to receive'}
            </span>
            <span className="font-mono text-white">
              {mode === 'deposit'
                ? (previewShares !== undefined ? formatUnits(previewShares as bigint, 18) : '…')
                : (previewAssets !== undefined ? formatUnits(previewAssets as bigint, 18) : '…')}
            </span>
          </div>
        </div>
      )}

      {/* Error / success */}
      {txError && (
        <p className="text-sm text-red-400 bg-red-500/10 border border-red-500/20 rounded-lg px-3 py-2">{txError}</p>
      )}
      {txSuccess && (
        <p className="text-sm text-green-400 bg-green-500/10 border border-green-500/20 rounded-lg px-3 py-2">{txSuccess}</p>
      )}

      {/* Action buttons */}
      <div className="flex gap-3">
        {needsApproval && (
          <button
            onClick={handleApprove}
            disabled={isBusy || !address}
            className="flex-1 py-3 rounded-xl font-semibold text-sm bg-yellow-600 hover:bg-yellow-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all text-white flex items-center justify-center gap-2"
          >
            {(approving || approvePending) && <Spinner />}
            {approving ? 'Approving…' : approvePending ? 'Confirming…' : 'Approve LP Token'}
          </button>
        )}
        <button
          onClick={handleAction}
          disabled={isBusy || !address || parsedAmount === 0n || (mode === 'deposit' && (needsApproval || !!isPaused))}
          className="flex-1 py-3 rounded-xl font-semibold text-sm bg-brand-600 hover:bg-brand-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all text-white flex items-center justify-center gap-2"
        >
          {(depositing || depositPending || redeeming || redeemPending) && <Spinner />}
          {mode === 'deposit'
            ? (depositing ? 'Depositing…' : depositPending ? 'Confirming…' : 'Deposit')
            : (redeeming  ? 'Redeeming…'  : redeemPending  ? 'Confirming…' : 'Redeem')}
        </button>
      </div>

      {assetAddr && (
        <p className="text-xs text-gray-600 break-all">
          Asset (LP token): {assetAddr}
        </p>
      )}
    </div>
  )
}

function Spinner() {
  return <span className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
}
