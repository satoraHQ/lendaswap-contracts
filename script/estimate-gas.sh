#!/usr/bin/env bash
# Estimate gas costs to deploy HTLCErc20 + HTLCCoordinator on all target chains.
#
# Runs a dry-run (simulation) of the deployment script against each chain's RPC,
# then prints current gas prices, estimated gas units, and the total native token
# cost per chain.  Also shows current deployer balances so you can see what's
# missing.
#
# Usage:
#   ./estimate-gas.sh          (reads from .env)
#
# Optional env vars:
#   GAS_PRICE_MULTIPLIER  - Safety multiplier for gas price (default: 1.5)
#                           Gas prices fluctuate; 1.5x gives a comfortable buffer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"

GAS_PRICE_MULTIPLIER="${GAS_PRICE_MULTIPLIER:-1.5}"

# Check for forge
if ! command -v forge &>/dev/null; then
  echo "Error: 'forge' not found. Install Foundry: https://getfoundry.sh"
  exit 1
fi

# Build contracts first
echo "Building contracts..."
(cd "$CONTRACTS_DIR" && forge build --silent)
echo ""

echo "============================================"
echo "  Deployment Gas Estimation"
echo "============================================"
echo ""
echo "Deployer address:     $DEPLOYER"
echo "Gas price multiplier: ${GAS_PRICE_MULTIPLIER}x (safety buffer)"
echo ""

# ─── Bytecode sizes ──────────────────────────────────────────────────────────

HTLC_BYTECODE_SIZE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCErc20.sol/HTLCErc20.json" | sed 's/^0x//' | wc -c | awk '{print int(($1-1)/2)}')
COORD_BYTECODE_SIZE=$(jq -r '.bytecode.object' "$CONTRACTS_DIR/out/HTLCCoordinator.sol/HTLCCoordinator.json" | sed 's/^0x//' | wc -c | awk '{print int(($1-1)/2)}')

echo "Contract bytecode sizes:"
echo "  HTLCErc20:       ${HTLC_BYTECODE_SIZE} bytes"
echo "  HTLCCoordinator: ${COORD_BYTECODE_SIZE} bytes"
echo ""

# ─── Per-chain estimation ────────────────────────────────────────────────────

# Table header
printf "%-14s  %10s  %14s  %20s  %20s  %20s  %10s\n" \
  "Chain" "Gas Units" "Gas Price" "Est. Cost" "Est. Cost (w/ buf)" "Balance" "Status"
printf "%-14s  %10s  %14s  %20s  %20s  %20s  %10s\n" \
  "──────────────" "──────────" "──────────────" "────────────────────" "────────────────────" "────────────────────" "──────────"

TOTAL_DEFICIT_FOUND=false

# Store results for the summary (avoid re-running simulations)
declare -a DEFICIT_NAMES=()
declare -a DEFICIT_AMOUNTS=()
declare -a DEFICIT_TOKENS=()

for i in "${!CHAINS[@]}"; do
  name="${CHAIN_NAMES[$i]}"
  rpc="${CHAIN_RPCS[$i]}"
  token="${CHAIN_TOKENS[$i]}"

  # The native pair deploys through deploy-rootstock.sh (legacy transactions).
  if ! is_erc20_chain "$i"; then
    printf "%-14s  %10s  %14s  %20s  %20s  %20s  %10s\n" \
      "$name" "-" "-" "-" "-" "-" "native pair"
    continue
  fi

  # Check RPC connectivity
  if ! check_rpc "$i" 2>/dev/null; then
    printf "%-14s  %10s  %14s  %20s  %20s  %20s  %10s\n" \
      "$name" "-" "-" "-" "-" "-" "RPC error"
    continue
  fi

  # Run forge script dry-run to get gas estimate
  DRY_RUN_OUTPUT=$(cd "$CONTRACTS_DIR" && \
    MNEMONIC="$MNEMONIC" DERIVATION_INDEX="$DERIVATION_INDEX" \
    forge script script/DeployHTLCCoordinator.s.sol \
      --rpc-url "$rpc" \
      -vvv 2>&1)

  # Parse output
  GAS_UNITS=$(echo "$DRY_RUN_OUTPUT" | grep "Estimated total gas used" | sed 's/.*: //')
  GAS_PRICE_RAW=$(echo "$DRY_RUN_OUTPUT" | grep "Estimated gas price" | sed 's/.*: //')
  EST_COST=$(echo "$DRY_RUN_OUTPUT" | grep "Estimated amount required" | sed 's/.*: //' | awk '{print $1}')
  EST_TOKEN=$(echo "$DRY_RUN_OUTPUT" | grep "Estimated amount required" | sed 's/.*: //' | awk '{print $2}')

  if [ -z "$GAS_UNITS" ] || [ -z "$EST_COST" ]; then
    printf "%-14s  %10s  %14s  %20s  %20s  %20s  %10s\n" \
      "$name" "-" "-" "simulation failed" "-" "-" "ERROR"
    continue
  fi

  # Calculate buffered cost
  BUFFERED_COST=$(python3 -c "print(f'{float(\"$EST_COST\") * $GAS_PRICE_MULTIPLIER:.18f}')" 2>/dev/null)

  # Get current balance
  BALANCE_WEI=$(get_balance "$rpc" "$DEPLOYER")
  BALANCE_FORMATTED=""
  STATUS=""

  if [ -n "$BALANCE_WEI" ]; then
    BALANCE_FORMATTED=$(format_ether "$BALANCE_WEI")

    # Compare: is balance >= buffered cost?
    BUFFERED_WEI=$(python3 -c "print(int(float('$BUFFERED_COST') * 1e18))" 2>/dev/null)
    IS_SUFFICIENT=$(python3 -c "print('YES' if int('$BALANCE_WEI') >= int('$BUFFERED_WEI') else 'NO')" 2>/dev/null)

    if [ "$IS_SUFFICIENT" = "YES" ]; then
      STATUS="✅ OK"
    else
      STATUS="❌ FUND"
      TOTAL_DEFICIT_FOUND=true

      # Calculate deficit
      DEFICIT=$(python3 -c "
d = int('$BUFFERED_WEI') - int('$BALANCE_WEI')
if d > 0:
    print(f'{d / 1e18:.18f}')
else:
    print('0')
" 2>/dev/null)
      if [ "$DEFICIT" != "0" ]; then
        DEFICIT_NAMES+=("$name")
        DEFICIT_AMOUNTS+=("$DEFICIT")
        DEFICIT_TOKENS+=("$token")
      fi
    fi
  else
    BALANCE_FORMATTED="error"
    STATUS="⚠️  ?"
  fi

  printf "%-14s  %10s  %14s  %20s  %20s  %20s  %10s\n" \
    "$name" "$GAS_UNITS" "$GAS_PRICE_RAW" "$EST_COST $EST_TOKEN" "$BUFFERED_COST $EST_TOKEN" "$BALANCE_FORMATTED $token" "$STATUS"
done

echo ""

# ─── Summary ──────────────────────────────────────────────────────────────────

echo "────────────────────────────────────────────────────────────────────────────"
echo ""
echo "Notes:"
echo "  • Gas estimates come from forge script dry-run (simulation mode)."
echo "  • 'Est. Cost' is the raw estimate at current gas prices."
echo "  • 'Est. Cost (w/ buf)' applies a ${GAS_PRICE_MULTIPLIER}x multiplier for gas price fluctuations."
echo "  • Gas prices are volatile — fund with the buffered amount for safety."
echo "  • Arbitrum gas includes L1 calldata costs (automatically estimated by the RPC)."
echo ""

if [ "$TOTAL_DEFICIT_FOUND" = true ]; then
  echo "⚠️  Some chains need funding! Send native tokens to: $DEPLOYER"
  echo ""

  echo "Per-chain funding needed (with buffer):"
  for j in "${!DEFICIT_NAMES[@]}"; do
    printf "  %-14s needs ~%s %s more\n" "${DEFICIT_NAMES[$j]}" "${DEFICIT_AMOUNTS[$j]}" "${DEFICIT_TOKENS[$j]}"
  done
  echo ""
fi
