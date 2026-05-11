import { useState, useEffect } from 'react'
import { useAccount, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits, formatUnits, maxUint256 } from 'viem'
import type { Address } from 'viem'
import { AMM_ADDRESS, AMM_ABI, ERC20_ABI } from '../../config/contracts'

function friendlyTxError(msg: string): string {
  if (msg.includes('user rejected'))          return 'Transaction rejected in wallet.'
  if (msg.includes('insufficient funds'))     return 'Insufficient ETH for gas.'
  if (msg.includes('AMM__SlippageExceeded'))  return 'Slippage too high — try a smaller amount or increase slippage tolerance.'
  if (msg.includes('AMM__InsufficientLiquidity')) return 'Pool has insufficient liquidity for this swap.'
  if (msg.includes('insufficient allowance')) return 'Approval needed. Click Approve first.'
  return 'Transaction failed. Check your inputs and try again.'
}

export function SwapForm() {
  const { address } = useAccount()

  const [amountIn, setAmountIn]       = useState('')
  const [swapDirection, setSwapDir]   = useState<0 | 1>(0)   // 0 = token0→token1, 1 = token1→token0
  const [slippageBps, setSlippageBps] = useState(50)         // 0.5%
  const [txError, setTxError]         = useState<string | null>(null)
  const [txSuccess, setTxSuccess]     = useState(false)

  // ── Read token addresses ─────────────────────────────────────
  const { data: tokens } = useReadContracts({
    contracts: [
      { address: AMM_ADDRESS, abi: AMM_ABI, functionName: 'token0' },
      { address: AMM_ADDRESS, abi: AMM_ABI, functionName: 'token1' },
    ],
  })
  const token0 = tokens?.[0].result as Address | undefined
  const token1 = tokens?.[1].result as Address | undefined

  const tokenIn  = swapDirection === 0 ? token0 : token1
  const tokenOut = swapDirection === 0 ? token1 : token0

  // ── Token symbols ────────────────────────────────────────────
  const { data: symbolData } = useReadContracts({
    contracts: [
      { address: token0, abi: ERC20_ABI, functionName: 'symbol' },
      { address: token1, abi: ERC20_ABI, functionName: 'symbol' },
    ],
    query: { enabled: !!token0 && !!token1 },
  })
  const sym0 = symbolData?.[0].result as string | undefined ?? 'Token0'
  const sym1 = symbolData?.[1].result as string | undefined ?? 'Token1'
  const symIn  = swapDirection === 0 ? sym0 : sym1
  const symOut = swapDirection === 0 ? sym1 : sym0

  // ── Amount out preview ───────────────────────────────────────
  const parsedIn = (() => {
    try { return amountIn ? parseUnits(amountIn, 18) : 0n } catch { return 0n }
  })()

  const { data: previewOut } = useReadContract({
    address: AMM_ADDRESS,
    abi:     AMM_ABI,
    functionName: 'getAmountOut',
    args: [tokenIn ?? '0x0000000000000000000000000000000000000000', parsedIn],
    query: { enabled: parsedIn > 0n && !!tokenIn },
  })

  const minOut = previewOut ? (previewOut * BigInt(10000 - slippageBps)) / 10000n : 0n

  // ── Allowance ────────────────────────────────────────────────
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: tokenIn,
    abi:     ERC20_ABI,
    functionName: 'allowance',
    args: [address ?? '0x0000000000000000000000000000000000000000', AMM_ADDRESS],
    query: { enabled: !!address && !!tokenIn },
  })
  const needsApproval = allowance !== undefined && parsedIn > 0n && allowance < parsedIn

  // ── Write: approve ───────────────────────────────────────────
  const { writeContract: approve, data: approveTx, isPending: approving, error: approveError } = useWriteContract()
  const { isLoading: approvePending, isSuccess: approveSuccess } = useWaitForTransactionReceipt({ hash: approveTx })

  useEffect(() => {
    if (approveSuccess) void refetchAllowance()
  }, [approveSuccess, refetchAllowance])

  // ── Write: swap ──────────────────────────────────────────────
  const { writeContract: swap, data: swapTx, isPending: swapping, error: swapError } = useWriteContract()
  const { isLoading: swapPending, isSuccess: swapSuccess } = useWaitForTransactionReceipt({ hash: swapTx })

  useEffect(() => {
    if (swapSuccess) {
      setTxSuccess(true)
      setAmountIn('')
      setTimeout(() => setTxSuccess(false), 5000)
    }
  }, [swapSuccess])

  useEffect(() => {
    const err = approveError ?? swapError
    if (err) setTxError(friendlyTxError(err.message))
  }, [approveError, swapError])

  const isBusy = approving || approvePending || swapping || swapPending

  function handleSwap() {
    if (!address || !tokenIn || parsedIn === 0n) return
    setTxError(null)
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 300) // 5 min
    swap({
      address: AMM_ADDRESS,
      abi:     AMM_ABI,
      functionName: 'swap',
      args: [tokenIn, parsedIn, minOut, address, deadline],
    })
  }

  function handleApprove() {
    if (!tokenIn) return
    setTxError(null)
    approve({
      address: tokenIn,
      abi:     ERC20_ABI,
      functionName: 'approve',
      args: [AMM_ADDRESS, maxUint256],
    })
  }

  return (
    <div className="bg-white/5 border border-white/10 rounded-2xl p-6 space-y-5">
      <h3 className="font-bold text-lg text-white">Swap Tokens</h3>

      {/* Direction selector */}
      <div className="flex gap-2">
        <button
          onClick={() => setSwapDir(0)}
          className={`flex-1 py-2 rounded-lg text-sm font-medium transition-all ${
            swapDirection === 0
              ? 'bg-brand-600 text-white'
              : 'bg-white/5 text-gray-400 hover:text-white border border-white/10'
          }`}
        >
          {sym0} → {sym1}
        </button>
        <button
          onClick={() => setSwapDir(1)}
          className={`flex-1 py-2 rounded-lg text-sm font-medium transition-all ${
            swapDirection === 1
              ? 'bg-brand-600 text-white'
              : 'bg-white/5 text-gray-400 hover:text-white border border-white/10'
          }`}
        >
          {sym1} → {sym0}
        </button>
      </div>

      {/* Amount in */}
      <div className="space-y-1">
        <label className="text-xs text-gray-400">You Pay ({symIn})</label>
        <input
          type="number"
          min="0"
          step="any"
          placeholder="0.0"
          value={amountIn}
          onChange={e => { setAmountIn(e.target.value); setTxError(null) }}
          className="w-full bg-gray-900 border border-white/10 rounded-xl px-4 py-3 text-white font-mono text-lg focus:outline-none focus:border-brand-500 transition-colors"
        />
      </div>

      {/* Preview out */}
      <div className="bg-gray-900/60 border border-white/5 rounded-xl px-4 py-3 space-y-1">
        <div className="flex justify-between text-sm">
          <span className="text-gray-400">You Receive ({symOut})</span>
          <span className="font-mono text-white">
            {previewOut !== undefined ? formatUnits(previewOut, 18) : '—'}
          </span>
        </div>
        <div className="flex justify-between text-xs text-gray-500">
          <span>Min received (after slippage)</span>
          <span className="font-mono">{minOut > 0n ? formatUnits(minOut, 18) : '—'}</span>
        </div>
      </div>

      {/* Slippage */}
      <div className="flex items-center gap-3">
        <span className="text-xs text-gray-400 flex-shrink-0">Slippage</span>
        {[30, 50, 100].map(bps => (
          <button
            key={bps}
            onClick={() => setSlippageBps(bps)}
            className={`text-xs px-2.5 py-1 rounded-lg transition-all ${
              slippageBps === bps
                ? 'bg-brand-600 text-white'
                : 'bg-white/5 text-gray-400 hover:text-white border border-white/10'
            }`}
          >
            {bps / 100}%
          </button>
        ))}
      </div>

      {/* Error / success */}
      {txError && (
        <p className="text-sm text-red-400 bg-red-500/10 border border-red-500/20 rounded-lg px-3 py-2">{txError}</p>
      )}
      {txSuccess && (
        <p className="text-sm text-green-400 bg-green-500/10 border border-green-500/20 rounded-lg px-3 py-2">
          Swap confirmed!
        </p>
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
            {approving ? 'Approving…' : approvePending ? 'Confirming…' : `Approve ${symIn}`}
          </button>
        )}
        <button
          onClick={handleSwap}
          disabled={isBusy || !address || parsedIn === 0n || needsApproval}
          className="flex-1 py-3 rounded-xl font-semibold text-sm bg-brand-600 hover:bg-brand-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all text-white flex items-center justify-center gap-2"
        >
          {(swapping || swapPending) && <Spinner />}
          {swapping ? 'Swapping…' : swapPending ? 'Confirming…' : `Swap ${symIn} → ${symOut}`}
        </button>
      </div>
    </div>
  )
}

function Spinner() {
  return <span className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
}
