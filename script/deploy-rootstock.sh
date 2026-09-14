#!/usr/bin/env bash
# Deploy HTLCNative + HTLCNativeCoordinator to Rootstock via CREATE2.
#
# Usage:
#   ./deploy-rootstock.sh testnet [--dry-run]   # chain 31, https://public-node.testnet.rsk.co
#   ./deploy-rootstock.sh mainnet [--dry-run]   # chain 30, https://public-node.rsk.co
#
# Required env vars (or in contracts/.env):
#   MNEMONIC                 - HD wallet mnemonic
#
# Optional env vars:
#   DERIVATION_INDEX         - HD derivation index (default: 0)
#   DEPLOY_SALT              - CREATE2 salt (default: 0x0). Same salt + bytecode + owner
#                              = same address on testnet and mainnet.
#   HTLC_OWNER               - HTLCNative owner (default: deployer). Mainnet: the key
#                              that owns HTLCErc20 on the other chains.
#   ROOTSTOCK_RPC_URL        - override the public node for the chosen network
#
# Rootstock specifics baked in below:
#   --legacy       no EIP-1559 (eth_feeHistory is "method not found"), type-0 txs only
#   blockscout     verification goes to rootstock.blockscout.com, not Etherscan
#   lowercase      Rootstock tooling uses EIP-1191 checksums; addresses are printed lowercase

set -euo pipefail

NETWORK="${1:-}"
DRY_RUN=false
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# .env first: ROOTSTOCK_RPC_URL may live there and the case below reads it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"

for f in "$SCRIPT_DIR/.env" "$CONTRACTS_DIR/.env"; do
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
    break
  fi
done

case "$NETWORK" in
  testnet)
    CHAIN_ID=31
    RPC_URL="${ROOTSTOCK_RPC_URL:-https://public-node.testnet.rsk.co}"
    VERIFIER_URL="https://rootstock-testnet.blockscout.com/api"
    EXPLORER="https://rootstock-testnet.blockscout.com"
    ;;
  mainnet)
    CHAIN_ID=30
    RPC_URL="${ROOTSTOCK_RPC_URL:-https://public-node.rsk.co}"
    VERIFIER_URL="https://rootstock.blockscout.com/api"
    EXPLORER="https://rootstock.blockscout.com"
    ;;
  *)
    echo "Usage: $0 <testnet|mainnet> [--dry-run]"
    exit 1
    ;;
esac

if [ -z "${MNEMONIC:-}" ]; then
  echo "Error: MNEMONIC is not set."
  exit 1
fi
for tool in forge cast jq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Error: '$tool' not found."
    exit 1
  fi
done

DERIVATION_INDEX="${DERIVATION_INDEX:-0}"
DEPLOY_SALT="${DEPLOY_SALT:-0x0000000000000000000000000000000000000000000000000000000000000000}"
DEPLOYER=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$DERIVATION_INDEX")
HTLC_OWNER="${HTLC_OWNER:-$DEPLOYER}"

echo "============================================"
if $DRY_RUN; then
  echo "  Rootstock $NETWORK deployment (DRY RUN)"
else
  echo "  Rootstock $NETWORK deployment"
fi
echo "============================================"
echo ""
echo "RPC:              $RPC_URL"
echo "Deployer:         $DEPLOYER"
echo "HTLCNative owner: $HTLC_OWNER"
echo "CREATE2 salt:     $DEPLOY_SALT"
echo ""

# ─── Pre-flight ──────────────────────────────────────────────────────────────

actual_chain=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$actual_chain" != "$CHAIN_ID" ]; then
  echo "Error: RPC reports chain id $actual_chain, expected $CHAIN_ID."
  exit 1
fi

# The canonical CREATE2 factory forge's salted `new` deploys through.
CREATE2_FACTORY="0x4e59b44847B379578588920cA78FbF26c0B4956C"
if [ "$(cast code "$CREATE2_FACTORY" --rpc-url "$RPC_URL")" == "0x" ]; then
  echo "Error: CREATE2 factory $CREATE2_FACTORY is not deployed on chain $CHAIN_ID."
  exit 1
fi

balance=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")
echo "Deployer balance: $(cast from-wei "$balance") RBTC"
if [ "$balance" == "0" ]; then
  echo "Error: deployer has no RBTC."
  [ "$NETWORK" == "testnet" ] && echo "Faucet: https://faucet.rootstock.io"
  exit 1
fi
echo ""

echo "Building contracts..."
(cd "$CONTRACTS_DIR" && forge build --silent)

# ─── Predict CREATE2 addresses ───────────────────────────────────────────────

compute_create2_address() {
  local deployer="$1" salt="$2" initcode_hash="$3"
  local hash
  hash=$(cast keccak "0xff${deployer#0x}${salt#0x}${initcode_hash#0x}")
  echo "0x${hash:26}" | tr '[:upper:]' '[:lower:]'
}

HTLC_BYTECODE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCNative.sol/HTLCNative.json")
HTLC_ARG=$(cast abi-encode "constructor(address)" "$HTLC_OWNER")
HTLC_ADDRESS=$(compute_create2_address "$CREATE2_FACTORY" "$DEPLOY_SALT" "$(cast keccak "${HTLC_BYTECODE}${HTLC_ARG#0x}")")

COORD_BYTECODE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCNativeCoordinator.sol/HTLCNativeCoordinator.json")
COORD_ARG=$(cast abi-encode "constructor(address)" "$HTLC_ADDRESS")
COORD_ADDRESS=$(compute_create2_address "$CREATE2_FACTORY" "$DEPLOY_SALT" "$(cast keccak "${COORD_BYTECODE}${COORD_ARG#0x}")")

echo "Predicted HTLCNative:            $HTLC_ADDRESS"
echo "Predicted HTLCNativeCoordinator: $COORD_ADDRESS"
echo ""

if [ "$(cast code "$HTLC_ADDRESS" --rpc-url "$RPC_URL")" != "0x" ]; then
  echo "HTLCNative already deployed at $HTLC_ADDRESS (same salt, bytecode and owner). Bump DEPLOY_SALT for a fresh address."
fi

if ! $DRY_RUN; then
  read -r -p "Broadcast to Rootstock $NETWORK (chain $CHAIN_ID)? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# ─── Deploy ──────────────────────────────────────────────────────────────────

FORGE_ARGS=(script/DeployHTLCNative.s.sol --rpc-url "$RPC_URL" --legacy -vvv)
if ! $DRY_RUN; then
  FORGE_ARGS+=(--broadcast --verify --verifier blockscout --verifier-url "$VERIFIER_URL")
fi

(cd "$CONTRACTS_DIR" && \
  MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" DEPLOY_SALT="$DEPLOY_SALT" HTLC_OWNER="$HTLC_OWNER" \
  forge script "${FORGE_ARGS[@]}")

echo ""
echo "============================================"
echo "  Rootstock $NETWORK summary"
echo "============================================"
echo "  HTLCNative:            $EXPLORER/address/$HTLC_ADDRESS"
echo "  HTLCNativeCoordinator: $EXPLORER/address/$COORD_ADDRESS"
echo ""
echo "Config (lowercase, EIP-1191 chains):"
echo "  native_htlc_contract:             \"$HTLC_ADDRESS\""
echo "  native_htlc_coordinator_contract: \"$COORD_ADDRESS\""
