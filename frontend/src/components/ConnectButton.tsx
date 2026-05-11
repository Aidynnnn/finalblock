import { useAccount, useConnect, useDisconnect } from 'wagmi'
import { metaMask } from 'wagmi/connectors'

function shortAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export function ConnectButton() {
  const { address, isConnected } = useAccount()
  const { connect, isPending }   = useConnect()
  const { disconnect }           = useDisconnect()

  if (isConnected && address) {
    return (
      <div className="flex items-center gap-3">
        <span className="font-mono text-sm text-gray-300 bg-white/5 border border-white/10 rounded-lg px-3 py-1.5">
          {shortAddress(address)}
        </span>
        <button
          onClick={() => disconnect()}
          className="text-sm text-gray-400 hover:text-red-400 transition-colors px-3 py-1.5 rounded-lg hover:bg-red-500/10 border border-transparent hover:border-red-500/20"
        >
          Disconnect
        </button>
      </div>
    )
  }

  return (
    <button
      onClick={() => connect({ connector: metaMask() })}
      disabled={isPending}
      className="flex items-center gap-2 px-4 py-2 rounded-lg font-medium text-sm bg-brand-600 hover:bg-brand-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all text-white shadow-lg shadow-brand-900/40"
    >
      {isPending ? (
        <>
          <span className="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin" />
          Connecting…
        </>
      ) : (
        <>
          <MetaMaskIcon />
          Connect MetaMask
        </>
      )}
    </button>
  )
}

function MetaMaskIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 318 318" fill="none">
      <path d="M274.1 35.5L174.6 109l19.2-45.2L274.1 35.5z" fill="#E2761B" stroke="#E2761B" strokeWidth="0.5" strokeLinecap="round" strokeLinejoin="round"/>
      <path d="M43.8 35.5l98.4 74.2-18.3-45.9L43.8 35.5z" fill="#E4761B" stroke="#E4761B" strokeWidth="0.5" strokeLinecap="round" strokeLinejoin="round"/>
      <path d="M238.2 206.9l-26.4 40.5 56.5 15.6 16.2-55.4-46.3-.7z" fill="#E4761B" stroke="#E4761B" strokeWidth="0.5" strokeLinecap="round" strokeLinejoin="round"/>
      <path d="M33.4 207.6l16.1 55.4 56.4-15.6-26.4-40.5-46.1.7z" fill="#E4761B" stroke="#E4761B" strokeWidth="0.5" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  )
}
