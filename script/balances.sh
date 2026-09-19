#!/usr/bin/env bash
# Print native coin balances on all chains (ETH, MATIC, RBTC on Rootstock) for
# the deployer address, or for any address given.
#
# Usage:
#   ./balances.sh               deployer derived from MNEMONIC (reads from .env)
#   ./balances.sh 0x...         another address, e.g. the swap server's EOA or a
#                               deployed HTLC contract

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ADDRESS="${1:-$DEPLOYER}"
if [[ ! "$ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Error: '$ADDRESS' is not an EVM address."
  exit 1
fi

if [ "$ADDRESS" = "$DEPLOYER" ]; then
  echo "Address: $ADDRESS (deployer)"
else
  echo "Address: $ADDRESS"
fi
echo ""

for i in "${!CHAINS[@]}"; do
  name="${CHAIN_NAMES[$i]}"
  rpc="${CHAIN_RPCS[$i]}"
  token="${CHAIN_TOKENS[$i]}"

  printf "  %-14s " "$name:"

  if ! check_rpc "$i"; then
    echo "unreachable"
    continue
  fi

  balance=$(get_balance "$rpc" "$ADDRESS")
  if [ -z "$balance" ]; then
    echo "error fetching balance"
    continue
  fi

  echo "$(format_ether "$balance") $token"
done
