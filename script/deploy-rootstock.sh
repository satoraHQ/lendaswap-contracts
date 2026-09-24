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
#   ROOTSTOCK_RPC_URL        - override the public mainnet node
#   ROOTSTOCK_TESTNET_RPC_URL - override the public testnet node. Separate from
#                              ROOTSTOCK_RPC_URL so a mainnet URL in .env cannot
#                              leak into a testnet run (the chain-id check would
#                              refuse it, but the run should not need a tweak).
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
    RPC_URL="${ROOTSTOCK_TESTNET_RPC_URL:-https://public-node.testnet.rsk.co}"
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

# A contract already at its predicted address is reused by the forge script and
# only the missing one is deployed, so a run that broke between the two
# transactions is resumed by running the same command again. Bump DEPLOY_SALT
# for a fresh pair instead.
HTLC_EXISTS=false
COORD_EXISTS=false
if [ "$(cast code "$HTLC_ADDRESS" --rpc-url "$RPC_URL")" != "0x" ]; then
  HTLC_EXISTS=true
  echo "HTLCNative already deployed at $HTLC_ADDRESS; reusing it."
fi
if [ "$(cast code "$COORD_ADDRESS" --rpc-url "$RPC_URL")" != "0x" ]; then
  COORD_EXISTS=true
  echo "HTLCNativeCoordinator already deployed at $COORD_ADDRESS; nothing to deploy."
fi

if ! $DRY_RUN; then
  read -r -p "Broadcast to Rootstock $NETWORK (chain $CHAIN_ID)? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# ─── Deploy ──────────────────────────────────────────────────────────────────

# --slow: one transaction at a time. RSKj weighs a tx with a pending nonce gap
# against the sender's tx-pool quota; the second tx of a burst gets rejected with
# "account exceeds quota" on a fresh account.
FORGE_ARGS=(script/DeployHTLCNative.s.sol --rpc-url "$RPC_URL" --legacy --slow -vvv)
if ! $DRY_RUN; then
  FORGE_ARGS+=(--broadcast --verify --verifier blockscout --verifier-url "$VERIFIER_URL")
fi

# Failures past this point must not skip the summary: a run that broke between
# the two transactions still needs to tell which contract landed and where.
FAILED=false
(cd "$CONTRACTS_DIR" && \
  MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" DEPLOY_SALT="$DEPLOY_SALT" HTLC_OWNER="$HTLC_OWNER" \
  forge script "${FORGE_ARGS[@]}") || FAILED=true

is_verified() {
  local verified
  verified=$(curl -sf "$VERIFIER_URL/v2/smart-contracts/$1" | jq -r ".is_verified // false" || echo false)
  [ "$verified" == "true" ]
}

# forge --verify only covers contracts deployed in this run. A contract that
# pre-existed (resumed run) is verified here unless Blockscout already has it.
verify_if_needed() {
  local address="$1" contract="$2" args="$3"
  if is_verified "$address"; then
    echo "$contract at $address is already verified."
    return
  fi
  echo "Verifying $contract at $address..."
  (cd "$CONTRACTS_DIR" && forge verify-contract "$address" "$contract" \
    --chain-id "$CHAIN_ID" --verifier blockscout --verifier-url "$VERIFIER_URL" \
    --constructor-args "$args" --watch) || FAILED=true
}

if ! $DRY_RUN; then
  $HTLC_EXISTS && verify_if_needed "$HTLC_ADDRESS" src/HTLCNative.sol:HTLCNative "$HTLC_ARG"
  $COORD_EXISTS && verify_if_needed "$COORD_ADDRESS" src/HTLCNativeCoordinator.sol:HTLCNativeCoordinator "$COORD_ARG"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

# Hash of the deploy tx forge recorded for a contract in this chain's latest
# broadcast, or empty (never sent, or dry run).
deploy_tx_hash() {
  local run="$CONTRACTS_DIR/broadcast/DeployHTLCNative.s.sol/$CHAIN_ID/run-latest.json"
  [ -f "$run" ] || return 0
  jq -r --arg name "$1" '[.transactions[] | select(.contractName == $name) | .hash // empty][0] // empty' "$run"
}

# Live on-chain state, not the script's view: the explorer links are only
# useful for a contract that actually landed.
report_contract() {
  local name="$1" address="$2"
  echo "  $name"
  echo "    address:  $EXPLORER/address/$address"
  if [ "$(cast code "$address" --rpc-url "$RPC_URL")" == "0x" ]; then
    echo "    deployed: NO"
    return
  fi
  if is_verified "$address"; then
    echo "    deployed: yes, verified"
  else
    echo "    deployed: yes, NOT verified"
  fi
  if ! $DRY_RUN; then
    local hash
    hash=$(deploy_tx_hash "$name")
    [ -n "$hash" ] && echo "    tx:       $EXPLORER/tx/$hash"
  fi
}

echo ""
echo "============================================"
if $DRY_RUN; then
  echo "  Rootstock $NETWORK summary (DRY RUN, nothing broadcast)"
else
  echo "  Rootstock $NETWORK summary"
fi
echo "============================================"
report_contract HTLCNative "$HTLC_ADDRESS"
report_contract HTLCNativeCoordinator "$COORD_ADDRESS"
echo ""
echo "Config (lowercase, EIP-1191 chains):"
echo "  native_htlc_contract:             \"$HTLC_ADDRESS\""
echo "  native_htlc_coordinator_contract: \"$COORD_ADDRESS\""

if $FAILED; then
  echo ""
  echo "Deployment did not complete; see the errors above. Rerunning resumes it."
  exit 1
fi
