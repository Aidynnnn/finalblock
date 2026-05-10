import { createConfig, http } from 'wagmi'
import { sepolia, arbitrumSepolia, baseSepolia } from 'wagmi/chains'
import { metaMask } from 'wagmi/connectors'

const chainId = Number(import.meta.env.VITE_CHAIN_ID ?? 11155111)
const rpcUrl  = import.meta.env.VITE_RPC_URL as string | undefined

export const targetChain =
  chainId === arbitrumSepolia.id ? arbitrumSepolia :
  chainId === baseSepolia.id     ? baseSepolia     :
  sepolia

export const wagmiConfig = createConfig({
  chains: [sepolia, arbitrumSepolia, baseSepolia],
  connectors: [metaMask()],
  transports: {
    [sepolia.id]:         http(chainId === sepolia.id         ? rpcUrl : undefined),
    [arbitrumSepolia.id]: http(chainId === arbitrumSepolia.id ? rpcUrl : undefined),
    [baseSepolia.id]:     http(chainId === baseSepolia.id     ? rpcUrl : undefined),
  },
})
