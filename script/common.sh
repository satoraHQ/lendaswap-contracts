#!/usr/bin/env bash
# Shared chain definitions and helpers for multi-chain scripts.
#
# Required env vars:
#   MNEMONIC              - HD wallet mnemonic
#   ETH_RPC_URL           - Ethereum RPC endpoint
#   ARBITRUM_RPC_URL      - Arbitrum RPC endpoint
#   POLYGON_RPC_URL       - Polygon RPC endpoint
#
# Optional env vars:
#   ROOTSTOCK_RPC_URL     - Rootstock RPC endpoint (default: the public node,
#                           as in deploy-rootstock.sh). Only balances.sh reads
#                           Rootstock; the ERC20 deploy, gas and CCTP scripts
#                           never do, so they must not require it.
#   DERIVATION_INDEX      - HD derivation index (default: 0)

set -euo pipefail

# Load .env if found (check script dir, then contracts dir)
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$COMMON_DIR/.env" ]; then
  set -a
  source "$COMMON_DIR/.env"
  set +a
elif [ -f "$(dirname "$COMMON_DIR")/.env" ]; then
  set -a
  source "$(dirname "$COMMON_DIR")/.env"
  set +a
fi

MISSING=()
[ -z "${MNEMONIC:-}" ] && MISSING+=("MNEMONIC")
[ -z "${ETH_RPC_URL:-}" ] && MISSING+=("ETH_RPC_URL")
[ -z "${ARBITRUM_RPC_URL:-}" ] && MISSING+=("ARBITRUM_RPC_URL")
[ -z "${POLYGON_RPC_URL:-}" ] && MISSING+=("POLYGON_RPC_URL")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: Missing required environment variables:"
  for var in "${MISSING[@]}"; do
    echo "  - $var"
  done
  exit 1
fi

ROOTSTOCK_RPC_URL="${ROOTSTOCK_RPC_URL:-https://public-node.rsk.co}"
DERIVATION_INDEX="${DERIVATION_INDEX:-0}"

# ─── Chain definitions (parallel arrays, bash 3.2 compatible) ────────────────
# CHAIN_FAMILIES names the HTLC pair a chain runs: "erc20" (HTLCErc20 +
# HTLCCoordinator, deployed by deploy-multichain.sh) or "native" (HTLCNative +
# HTLCNativeCoordinator for the chain's own coin, deployed by
# deploy-rootstock.sh with legacy transactions). The ERC20 deploy and gas
# scripts skip native chains; balances cover every chain.
#           index:   0            1              2            3
CHAINS=(         "ethereum"    "arbitrum"      "polygon"    "rootstock" )
CHAIN_NAMES=(    "Ethereum"    "Arbitrum One"  "Polygon"    "Rootstock" )
CHAIN_RPCS=(     "$ETH_RPC_URL" "$ARBITRUM_RPC_URL" "$POLYGON_RPC_URL" "$ROOTSTOCK_RPC_URL" )
CHAIN_TOKENS=(   "ETH"         "ETH"           "MATIC"      "RBTC" )
CHAIN_IDS=(      "1"           "42161"         "137"        "30" )
CHAIN_FAMILIES=( "erc20"       "erc20"         "erc20"      "native" )
CHAIN_EXPLORERS=( "https://etherscan.io" "https://arbiscan.io" "https://polygonscan.com" "https://rootstock.blockscout.com" )

# ─── Helpers ──────────────────────────────────────────────────────────────────

get_deployer_address() {
  cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$DERIVATION_INDEX" 2>/dev/null
}

get_balance() {
  local rpc_url="$1"
  local address="$2"
  cast balance "$address" --rpc-url "$rpc_url" 2>/dev/null
}

format_ether() {
  cast from-wei "$1" 2>/dev/null
}

# True for chains whose HTLC pair is the ERC20 family (deploy-multichain.sh's
# contracts); the native family has its own deploy script.
is_erc20_chain() {
  [ "${CHAIN_FAMILIES[$1]}" = "erc20" ]
}

check_rpc() {
  local idx="$1"
  local rpc_url="${CHAIN_RPCS[$idx]}"
  local chain_id
  chain_id=$(cast chain-id --rpc-url "$rpc_url" 2>/dev/null) || return 1

  if [ "$chain_id" != "${CHAIN_IDS[$idx]}" ]; then
    echo "Warning: ${CHAIN_NAMES[$idx]} RPC returned chain ID $chain_id, expected ${CHAIN_IDS[$idx]}"
    return 1
  fi
  return 0
}

# Check dependencies
if ! command -v cast &>/dev/null; then
  echo "Error: 'cast' not found. Install Foundry: https://getfoundry.sh"
  exit 1
fi

# Derive deployer address
DEPLOYER=$(get_deployer_address)
if [ -z "$DEPLOYER" ]; then
  echo "Error: Failed to derive address from mnemonic"
  exit 1
fi
