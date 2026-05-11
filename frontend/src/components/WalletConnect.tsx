/**
 * WalletConnect — full-page wallet onboarding shown when the user has
 * not yet connected a wallet.  Handles MetaMask connection with clear
 * loading, error and success states.
 *
 * Note: Wrong-chain interception is handled separately by <NetworkGuard>.
 */
import { useConnect, useAccount } from 'wagmi'
import { metaMask } from 'wagmi/connectors'
import { targetChain } from '../config/wagmi'

function friendlyConnectError(msg: string): string {
  if (msg.includes('user rejected'))  return 'Connection rejected. Open MetaMask and approve the request.'
  if (msg.includes('already pending')) return 'A connection request is already pending in MetaMask.'
  if (msg.includes('not installed') || msg.includes('No provider')) {
    return 'MetaMask is not installed. Install it from metamask.io, then reload this page.'
  }
  return 'Could not connect. Make sure MetaMask is unlocked and try again.'
}

export function WalletConnect() {
  const { connect, isPending, error } = useConnect()
  const { isConnecting }              = useAccount()

  const busy = isPending || isConnecting

  return (
    <div className="flex flex-col items-center justify-center min-h-[70vh] px-4">
      {/* Card */}
      <div className="w-full max-w-md bg-white/5 border border-white/10 rounded-2xl p-8 space-y-6 shadow-2xl shadow-black/40">

        {/* Logo / icon */}
        <div className="text-center space-y-3">
          <div className="mx-auto w-16 h-16 rounded-2xl bg-brand-600/20 border border-brand-500/30 flex items-center justify-center">
            <svg className="w-8 h-8 text-brand-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M21 12a2.25 2.25 0 00-2.25-2.25H15a3 3 0 11-6 0H5.25A2.25 2.25 0 003 12m18 0v6a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 18v-6m18 0V9M3 12V9m18-3a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6m18 0V5.25A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25V6" />
            </svg>
          </div>
          <div>
            <h1 className="text-2xl font-bold text-white">Connect Your Wallet</h1>
            <p className="text-gray-400 text-sm mt-1.5 leading-relaxed">
              Connect MetaMask to access the BCHT2 DeFi protocol on{' '}
              <span className="text-brand-400 font-medium">{targetChain.name}</span>.
            </p>
          </div>
        </div>

        {/* Feature bullets */}
        <ul className="space-y-2.5 text-sm text-gray-400">
          {[
            'Trade tokens via the constant-product AMM',
            'Deposit LP tokens into the upgradeable ERC-4626 Vault',
            'Vote on DAO proposals with your DGOV tokens',
            'View historical protocol data from The Graph',
          ].map((feat) => (
            <li key={feat} className="flex items-center gap-2.5">
              <span className="w-4 h-4 rounded-full bg-brand-500/20 border border-brand-500/30 flex-shrink-0 flex items-center justify-center">
                <span className="w-1.5 h-1.5 rounded-full bg-brand-400" />
              </span>
              {feat}
            </li>
          ))}
        </ul>

        {/* Error */}
        {error && (
          <div className="flex items-start gap-2.5 bg-red-500/10 border border-red-500/20 rounded-xl px-4 py-3">
            <svg className="w-4 h-4 text-red-400 flex-shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
            </svg>
            <p className="text-red-400 text-sm">{friendlyConnectError(error.message)}</p>
          </div>
        )}

        {/* Connect button */}
        <button
          onClick={() => connect({ connector: metaMask() })}
          disabled={busy}
          className="w-full flex items-center justify-center gap-3 py-3.5 rounded-xl font-semibold text-sm bg-brand-600 hover:bg-brand-500 active:bg-brand-700 disabled:opacity-50 disabled:cursor-not-allowed transition-all text-white shadow-lg shadow-brand-900/40"
        >
          {busy ? (
            <>
              <span className="w-5 h-5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
              Connecting to MetaMask…
            </>
          ) : (
            <>
              <MetaMaskLogo />
              Connect MetaMask
            </>
          )}
        </button>

        {/* Footnote */}
        <p className="text-center text-xs text-gray-600">
          No account? Install{' '}
          <a
            href="https://metamask.io"
            target="_blank"
            rel="noopener noreferrer"
            className="text-brand-400 hover:text-brand-300 underline underline-offset-2"
          >
            MetaMask
          </a>{' '}
          and set up a wallet first.
        </p>
      </div>

      {/* Network hint below card */}
      <p className="mt-6 text-xs text-gray-600 text-center">
        This app requires <span className="text-gray-500">{targetChain.name}</span>{' '}
        (chain&nbsp;ID&nbsp;{targetChain.id}).
        If you are on a different network you will be prompted to switch.
      </p>
    </div>
  )
}

function MetaMaskLogo() {
  return (
    <svg width="22" height="22" viewBox="0 0 318.6 318.6" fill="none" xmlns="http://www.w3.org/2000/svg">
      <polygon fill="#E2761B" stroke="#E2761B" strokeLinecap="round" strokeLinejoin="round" points="274.1,35.5 174.6,109.4 193.8,64.2 " />
      <polygon fill="#E4761B" stroke="#E4761B" strokeLinecap="round" strokeLinejoin="round" points="44.4,35.5 143.1,110.1 124.8,64.2 " />
      <polygon fill="#D7C1B3" stroke="#D7C1B3" strokeLinecap="round" strokeLinejoin="round" points="238.3,206.8 211.8,247.4 268.5,263 284.8,207.7 " />
      <polygon fill="#D7C1B3" stroke="#D7C1B3" strokeLinecap="round" strokeLinejoin="round" points="33.9,207.7 50.1,263 106.8,247.4 80.3,206.8 " />
      <polygon fill="#233447" stroke="#233447" strokeLinecap="round" strokeLinejoin="round" points="103.6,138.2 87.8,162.1 144.1,164.6 142.1,104.1 " />
      <polygon fill="#233447" stroke="#233447" strokeLinecap="round" strokeLinejoin="round" points="214.9,138.2 175.9,103.4 174.6,164.6 230.8,162.1 " />
      <polygon fill="#CD6116" stroke="#CD6116" strokeLinecap="round" strokeLinejoin="round" points="106.8,247.4 140.6,230.9 111.4,208.1 " />
      <polygon fill="#CD6116" stroke="#CD6116" strokeLinecap="round" strokeLinejoin="round" points="177.9,230.9 211.8,247.4 207.1,208.1 " />
    </svg>
  )
}
