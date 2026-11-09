import { ethers } from 'ethers'

// Which blockchain to use: "localhost" while developing, "sepolia" on the live site.
// Set in frontend/.env.development and frontend/.env.production.
const NETWORK = import.meta.env.VITE_NETWORK || 'localhost'

const NETWORKS = {
  localhost: {
    chainIdHex: '0x7a69', // 31337
    chainName: 'Hardhat Local',
    rpcUrl: 'http://127.0.0.1:8545',
  },
  sepolia: {
    chainIdHex: '0xaa36a7', // 11155111
    chainName: 'Sepolia',
    rpcUrl: import.meta.env.VITE_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com',
  },
}

const config = NETWORKS[NETWORK]
const deployments = import.meta.glob('../../deployments/*.json', { eager: true, import: 'default' })
const deployment = deployments[`../../deployments/${NETWORK}.json`]

if (!config || !deployment) {
  throw new Error(`No deployment found for "${NETWORK}". Deploy the contract to that network first.`)
}

// ---------- Reading (every page uses this) ----------

const provider = new ethers.JsonRpcProvider(config.rpcUrl)
export const contract = new ethers.Contract(deployment.address, deployment.abi, provider)

export const ROLE_NAMES = ['None', 'Cooperative', 'Processor', 'Exporter', 'Auditor']

export function formatDate(ts) {
  return new Date(Number(ts) * 1000).toLocaleString('en-KE', { dateStyle: 'medium', timeStyle: 'short' })
}

export function shortAddress(a) {
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

const names = new Map()
export async function participantName(address) {
  if (names.has(address)) return names.get(address)
  const p = await contract.participants(address)
  if (p.name) names.set(address, p.name) // only cache real names, so new registrations show up
  return p.name || shortAddress(address)
}

// ---------- Writing with MetaMask (the dashboard uses this) ----------

export const hasMetaMask = () => typeof window !== 'undefined' && !!window.ethereum

export async function ensureNetwork() {
  const current = await window.ethereum.request({ method: 'eth_chainId' })
  if (current === config.chainIdHex) return
  try {
    await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: config.chainIdHex }] })
  } catch (err) {
    if (err.code !== 4902) throw err
    await window.ethereum.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: config.chainIdHex,
        chainName: config.chainName,
        rpcUrls: [config.rpcUrl],
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      }],
    })
  }
}

export async function connectWallet() {
  if (!hasMetaMask()) throw new Error('MetaMask is not installed. Install it from metamask.io, then refresh this page.')
  const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' })
  await ensureNetwork()
  return ethers.getAddress(accounts[0])
}

export async function getConnectedAddress() {
  if (!hasMetaMask()) return null
  const accounts = await window.ethereum.request({ method: 'eth_accounts' })
  return accounts.length ? ethers.getAddress(accounts[0]) : null
}

// A fresh contract connected to the user's wallet, created for each transaction.
// Never store it in Vue state: Vue's reactivity breaks ethers objects.
export async function getWriter() {
  const browserProvider = new ethers.BrowserProvider(window.ethereum)
  const signer = await browserProvider.getSigner()
  return new ethers.Contract(deployment.address, deployment.abi, signer)
}

export function onWalletChange(callback) {
  if (!hasMetaMask()) return () => {}
  window.ethereum.on('accountsChanged', callback)
  window.ethereum.on('chainChanged', callback)
  return () => {
    window.ethereum.removeListener('accountsChanged', callback)
    window.ethereum.removeListener('chainChanged', callback)
  }
}

const ERROR_MESSAGES = {
  NotOwner: 'Only the admin can do this.',
  NotAuthorised: 'Your account does not have the right role for this action.',
  NotCurrentHolder: 'Only the participant currently holding this batch can do this.',
  BatchNotFound: 'That batch number does not exist.',
  InvalidInput: 'Some details are missing or not allowed. Please check the form.',
}

export function friendlyError(err) {
  if (err?.code === 'ACTION_REJECTED' || err?.code === 4001) return 'You cancelled the request in MetaMask.'

  let name = err?.revert?.name
  if (!name) {
    const data = err?.data ?? err?.info?.error?.data?.data ?? err?.info?.error?.data ?? err?.error?.data
    if (typeof data === 'string' && data.startsWith('0x')) {
      try { name = contract.interface.parseError(data)?.name } catch { /* not one of our errors */ }
    }
  }
  if (name && ERROR_MESSAGES[name]) return ERROR_MESSAGES[name]

  if (/insufficient funds/i.test(err?.message ?? '')) {
    return 'This account does not have enough ETH to pay the network fee.'
  }
  if (/nonce/i.test(err?.message ?? '')) {
    return 'MetaMask is out of sync with the local blockchain. In MetaMask go to Settings → Advanced → Clear activity tab data, then try again.'
  }
  return err?.shortMessage || err?.message || 'Something went wrong. Please try again.'
}