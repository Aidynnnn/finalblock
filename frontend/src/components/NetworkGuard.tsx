import { useAccount, useSwitchChain } from 'wagmi'
import { targetChain } from '../config/wagmi'

interface Props {
  children: React.ReactNode
}

export function NetworkGuard({ children }: Props) {
  const { isConnected, chain } = useAccount()
  const { switchChain, isPending, error } = useSwitchChain()

  // Not connected — let the rest of the UI handle the "connect wallet" state.
  if (!isConnected) return <>{children}</>

  // Connected to the right network — pass through.
  if (chain?.id === targetChain.id) return <>{children}</>

  // Connected to the WRONG network — block and prompt.
  const wrongChainName = chain?.name ?? `Chain ${chain?.id}`

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-gray-950/95 backdrop-blur-sm p-4">
      <div className="w-full max-w-md rounded-2xl bg-gray-900 border border-red-500/30 shadow-2xl shadow-red-900/20 p-8 text-center space-y-6">
        {/* Icon */}
        <div className="mx-auto w-16 h-16 rounded-full bg-red-500/10 border border-red-500/20 flex items-center justify-center">
          <svg className="w-8 h-8 text-red-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
          </svg>
        </div>

        {/* Heading */}
        <div>
          <h2 className="text-xl font-bold text-white mb-2">Wrong Network</h2>
          <p className="text-gray-400 text-sm leading-relaxed">
            You are connected to <span className="text-red-400 font-medium">{wrongChainName}</span>.
            This app only works on{' '}
            <span className="text-brand-400 font-medium">{targetChain.name}</span>.
          </p>
        </div>

        {/* Error message (non-technical) */}
        {error && (
          <p className="text-sm text-red-400 bg-red-500/10 border border-red-500/20 rounded-lg px-4 py-2">
            {friendlyError(error.message)}
          </p>
        )}

        {/* Switch button */}
        <button
          onClick={() => switchChain({ chainId: targetChain.id })}
          disabled={isPending}
          className="w-full flex items-center justify-center gap-2 px-6 py-3 rounded-xl font-semibold text-sm bg-brand-600 hover:bg-brand-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all text-white shadow-lg shadow-brand-900/40"
        >
          {isPending ? (
            <>
              <span className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
              Switching…
            </>
          ) : (
            `Switch to ${targetChain.name}`
          )}
        </button>

        {/* Manual instructions */}
        <p className="text-xs text-gray-500">
          If the switch fails, open MetaMask manually and select{' '}
          <span className="text-gray-400">{targetChain.name}</span>.
        </p>
      </div>
    </div>
  )
}

function friendlyError(raw: string): string {
  if (raw.includes('user rejected'))          return 'You rejected the network switch in MetaMask.'
  if (raw.includes('already pending'))        return 'A switch request is already pending in MetaMask.'
  if (raw.includes('chain not configured'))   return 'This network is not configured in your wallet. Add it manually.'
  return 'Could not switch network. Please switch manually in MetaMask.'
}
