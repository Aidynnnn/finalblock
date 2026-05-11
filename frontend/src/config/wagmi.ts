import { createConfig, http } from 'wagmi'
import { sepolia, arbitrumSepolia, baseSepolia } from 'wagmi/chains'
import { metaMask } from 'wagmi/connectors'

const chainId = Number(import.meta.env.VITE_CHAIN_ID ?? 11155111)
const rpcUrl  = import.meta.env.VITE_RPC_URL as string | undefined

function resolveChain() {
  switch (chainId) {
    case arbitrumSepolia.id: return arbitrumSepolia
    case baseSepolia.id:     return baseSepolia
    default:                 return sepolia
  }
}

export const targetChain = resolveChain()

export const wagmiConfig = createConfig({
  chains: [targetChain],
  connectors: [metaMask()],
  transports: {
    [targetChain.id]: http(rpcUrl || undefined),
  },
})
