#!/usr/bin/env bash
# Multi-chain HTLCCoordinator deployment using CREATE2 for deterministic addresses.
#
# Usage:
#   ./deploy-multichain.sh              # deploy for real
#   ./deploy-multichain.sh --dry-run    # simulate only (no broadcast)
#
# Additional optional env vars (beyond those in common.sh):
#   DEPLOY_SALT           - CREATE2 salt for deterministic addresses (default: 0x0)
#                           Same salt + same bytecode + same deployer = same address on every chain.
#                           Bump the salt if redeploying new versions to a fresh address.

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"

DEPLOY_SALT="${DEPLOY_SALT:-0x0000000000000000000000000000000000000000000000000000000000000000}"

# Check for forge
if ! command -v forge &>/dev/null; then
  echo "Error: 'forge' not found. Install Foundry: https://getfoundry.sh"
  exit 1
fi

# ─── Pre-flight checks ───────────────────────────────────────────────────────

echo "============================================"
if $DRY_RUN; then
echo "  Multi-chain Deployment (DRY RUN)"
else
echo "  Multi-chain HTLCCoordinator Deployment"
fi
echo "============================================"
echo ""
echo "Deployer address: $DEPLOYER"
echo "Derivation index: $DERIVATION_INDEX"
echo ""

# Build contracts first
echo "Building contracts..."
(cd "$CONTRACTS_DIR" && forge build --silent)
echo "Build successful."
echo ""

# ─── Predict CREATE2 addresses ─────────────────────────────────────────────
echo "CREATE2 salt: $DEPLOY_SALT"

# Forge's salted `new` deploys through the canonical CREATE2 factory, so the
# factory (not the broadcasting EOA) is the deployer in the address formula.
CREATE2_FACTORY="0x4e59b44847B379578588920cA78FbF26c0B4956C"

# CREATE2 address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:]
compute_create2_address() {
  local deployer="$1" salt="$2" initcode_hash="$3"
  local packed="0xff${deployer#0x}${salt#0x}${initcode_hash#0x}"
  local hash
  hash=$(cast keccak "$packed")
  # Last 20 bytes of the hash = last 40 hex chars
  echo "0x${hash:26}"
}

# HTLCErc20 constructor arg is the owner — ABI-encoded and appended to creation bytecode.
# It is part of the init code, so the same owner is required on every chain for the
# addresses to match. Keep this in sync with HTLC_OWNER in DeployHTLCCoordinator.s.sol.
HTLC_OWNER="${HTLC_OWNER:-$DEPLOYER}"
HTLC_BYTECODE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCErc20.sol/HTLCErc20.json")
HTLC_ENCODED_ARG=$(cast abi-encode "constructor(address)" "$HTLC_OWNER")
HTLC_INITCODE="${HTLC_BYTECODE}${HTLC_ENCODED_ARG#0x}"
HTLC_INITCODE_HASH=$(cast keccak "$HTLC_INITCODE")
HTLC_ADDRESS=$(compute_create2_address "$CREATE2_FACTORY" "$DEPLOY_SALT" "$HTLC_INITCODE_HASH")

echo "HTLCErc20 owner:                   $HTLC_OWNER"
echo "Predicted HTLCErc20 address:       $HTLC_ADDRESS"

# HTLCCoordinator constructor args are the HTLC address and canonical Permit2 —
# ABI-encoded and appended to creation bytecode. Keep in sync with
# DeployHTLCCoordinator.s.sol.
PERMIT2_ADDRESS="0x000000000022D473030F116dDEE9F6B43aC78BA3"
COORDINATOR_BYTECODE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCCoordinator.sol/HTLCCoordinator.json")
ENCODED_ARG=$(cast abi-encode "constructor(address,address)" "$HTLC_ADDRESS" "$PERMIT2_ADDRESS")
COORDINATOR_INITCODE="${COORDINATOR_BYTECODE}${ENCODED_ARG#0x}"
COORDINATOR_INITCODE_HASH=$(cast keccak "$COORDINATOR_INITCODE")
COORDINATOR_ADDRESS=$(compute_create2_address "$CREATE2_FACTORY" "$DEPLOY_SALT" "$COORDINATOR_INITCODE_HASH")

echo "Predicted HTLCCoordinator address: $COORDINATOR_ADDRESS"
echo ""

# ─── Balance & connectivity checks ───────────────────────────────────────────
# For detailed gas estimates, run ./estimate-gas.sh first.

echo "Checking balances on target chains..."
echo ""

DEPLOYABLE=()

for i in "${!CHAINS[@]}"; do
  name="${CHAIN_NAMES[$i]}"
  rpc="${CHAIN_RPCS[$i]}"
  token="${CHAIN_TOKENS[$i]}"

  printf "  %-14s " "$name:"

  if ! is_erc20_chain "$i"; then
    echo "SKIP (native HTLC pair; see deploy-rootstock.sh)"
    continue
  fi

  if ! check_rpc "$i"; then
    echo "SKIP (RPC unreachable or wrong chain ID)"
    continue
  fi

  balance=$(get_balance "$rpc" "$DEPLOYER")
  if [ -z "$balance" ]; then
    echo "SKIP (could not fetch balance)"
    continue
  fi

  echo "$(format_ether "$balance") $token"
  DEPLOYABLE+=("$i")
done

echo ""

if [ ${#DEPLOYABLE[@]} -eq 0 ]; then
  echo "Error: No chains reachable."
  exit 1
fi

echo -n "Will deploy to:"
for i in "${DEPLOYABLE[@]}"; do echo -n " ${CHAINS[$i]}"; done
echo ""
echo ""
read -r -p "Proceed with deployment? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled."
  exit 0
fi
echo ""

# ─── Deploy ───────────────────────────────────────────────────────────────────

RESULTS=()
FAILURES=()

for i in "${DEPLOYABLE[@]}"; do
  name="${CHAIN_NAMES[$i]}"
  rpc="${CHAIN_RPCS[$i]}"

  echo "────────────────────────────────────────────"
  echo "Deploying to $name..."
  echo "────────────────────────────────────────────"

  FORGE_ARGS=(script/DeployHTLCCoordinator.s.sol --rpc-url "$rpc" -vvv)
  if ! $DRY_RUN; then
    FORGE_ARGS+=(--broadcast --verify)
  fi

  if (cd "$CONTRACTS_DIR" && \
      MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" DEPLOY_SALT="$DEPLOY_SALT" \
      forge script "${FORGE_ARGS[@]}"); then
    echo ""
    echo "$name deployment: SUCCESS"
    RESULTS+=("$i")
  else
    echo ""
    echo "$name deployment: FAILED"
    FAILURES+=("$i")
  fi
  echo ""
done

# ─── Summary ──────────────────────────────────────────────────────────────────

# Block-explorer address-page base per chain, indexed like CHAINS.
EXPLORERS=( "${CHAIN_EXPLORERS[@]}" )

echo "============================================"
echo "  Deployment Summary"
echo "============================================"

if [ ${#RESULTS[@]} -gt 0 ]; then
  echo ""
  echo "Successful (CREATE2 — same addresses on every chain):"
  echo "  HTLCErc20:       $HTLC_ADDRESS"
  echo "  HTLCCoordinator: $COORDINATOR_ADDRESS"
  echo ""
  for i in "${RESULTS[@]}"; do
    explorer="${EXPLORERS[$i]}"
    echo "  ${CHAIN_NAMES[$i]}:"
    echo "    HTLCErc20:       $explorer/address/$HTLC_ADDRESS"
    echo "    HTLCCoordinator: $explorer/address/$COORDINATOR_ADDRESS"
  done
fi

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo ""
  echo "Failed:"
  for i in "${FAILURES[@]}"; do
    echo "  - ${CHAIN_NAMES[$i]}"
  done
fi

echo ""

if [ ${#FAILURES[@]} -gt 0 ]; then
  exit 1
fi
