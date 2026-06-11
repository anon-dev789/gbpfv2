#!/usr/bin/env bash
#
# GBPF keeper: one heartbeat, two permissionless duties.
#   1. BufferVault.rebalance() — repeg/recentre the Gateway pool against the oracle
#      (cheaply reverts NothingToDo when the band is fine; we pre-check and skip).
#   2. Vault.flush()           — realise the core's pending 6909 claims into sUSDS backing
#      and burn redeemed GBPF (reverts NothingToFlush when empty; same pre-check).
#
# Both functions are permissionless: the keeper wallet has NO privileges and only pays gas.
# Use a dedicated, low-value key — NOT the deployer/BufferVault-owner key.
#
# Env:
#   KEEPER_PRIVATE_KEY  (required) — gas-only keeper wallet key
#   BASE_RPC_URL        (optional) — defaults to the public Base endpoint
#
# Runs from CI (.github/workflows/keeper.yml) every 15 minutes, or locally/cron.

set -uo pipefail

RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
KEY="${KEEPER_PRIVATE_KEY:?KEEPER_PRIVATE_KEY not set}"

# Live addresses (Base 8453) — see DEPLOYMENT.md.
BUFFER_VAULT=0x6aB1571CCd465568612a8a306490385CbF58B7EC
CORE_VAULT=0xA9a831a348D0Db372cf75dd7C082cFF67A453498

KEEPER_ADDR=$(cast wallet address --private-key "$KEY")
echo "keeper: $KEEPER_ADDR  rpc: ${RPC%%\?*}"

# Pre-check with eth_call; only send when the call would succeed. An expected no-op
# (NothingToDo / NothingToFlush) is a skip, not a failure. A send that fails AFTER a
# successful pre-check is a real error and fails the run (so CI notifies).
try() {
  local name=$1 target=$2 sig=$3
  if cast call "$target" "$sig" --from "$KEEPER_ADDR" --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "[$name] work available -> sending tx"
    if cast send "$target" "$sig" --private-key "$KEY" --rpc-url "$RPC"; then
      echo "[$name] done"
    else
      echo "[$name] SEND FAILED" >&2
      return 1
    fi
  else
    echo "[$name] nothing to do"
  fi
}

rc=0
try rebalance "$BUFFER_VAULT" "rebalance()" || rc=1
try flush "$CORE_VAULT" "flush()" || rc=1
exit $rc
