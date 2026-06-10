#!/usr/bin/env bash
#
# Verify the live GBPF contracts on Sourcify (keyless).
#
# Deployment: Base mainnet (chain 8453), commit 60d3895. Addresses from DEPLOYMENT.md.
# Sourcify needs no API key. Re-runnable: already-verified contracts just report as such.
#
# Usage:
#   ./script/verify.sh
#
# Note: the constructor-args use `cast abi-encode`, which is pure-local (no RPC), so it works
# even on a machine where cast's network calls crash. If a call still fails, run the
# `cast abi-encode ...` line alone, copy the hex, and pass it to --constructor-args directly.

set -euo pipefail

CHAIN=base
VERIFIER=sourcify

# --- Live deployed contract addresses (Base 8453, commit 60d3895) ---
ORACLE=0x9c66F3F8a102d6Bf3EeaEAAe5d9ECAe88985eB2F
GBPF=0x1817FD23ceF7Da47DF934fdc880d72e653786770
VAULT=0xA9a831a348D0Db372cf75dd7C082cFF67A453498
HOOK=0x5613c279E8Db9815DBD0CdFbd10515EAbD350088

# --- Hardcoded Base infra (from Deploy.s.sol) ---
CHAINLINK_GBP_USD=0xCceA6576904C118037695eB71195a5425E69Fa15
CHAINLINK_SEQUENCER=0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
SSR_ORACLE=0x65d946e533748A998B1f0E430803e39A6388f7a1
SUSDS=0x5875eEE11Cf8398102FdAd704C9E96607675467a
USDS=0x820C137fa70C8691f0e44Dc420a5e53c168921Dc
POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b
PSM3=0x1601843c5E9bC251A3272907010AFa41Fa18347E
BENEFICIARY=0x621D531A97185BcB5f3E513C192a3327163377D3

# --- Committed protocol params (from Deploy.s.sol) ---
TWAP_WINDOW=300              # 5 minutes
MAX_STALENESS=93600          # 26 hours
MAX_STEP_WAD=20000000000000000   # 0.02e18
SEQUENCER_GRACE=3600         # 1 hour
COOLDOWN=900                 # 15 minutes

echo "==> 1/4 OracleAdapter ($ORACLE)"
forge verify-contract "$ORACLE" src/OracleAdapter.sol:OracleAdapter \
  --chain "$CHAIN" --verifier "$VERIFIER" \
  --constructor-args "$(cast abi-encode 'constructor(address,address,uint256,uint256,uint256,uint256,uint256)' \
    "$CHAINLINK_GBP_USD" "$CHAINLINK_SEQUENCER" "$TWAP_WINDOW" "$MAX_STALENESS" "$MAX_STEP_WAD" "$SEQUENCER_GRACE" "$COOLDOWN")"

echo "==> 2/4 GBPF ($GBPF) — no constructor args"
forge verify-contract "$GBPF" src/GBPF.sol:GBPF \
  --chain "$CHAIN" --verifier "$VERIFIER"

echo "==> 3/4 Vault ($VAULT)"
forge verify-contract "$VAULT" src/Vault.sol:Vault \
  --chain "$CHAIN" --verifier "$VERIFIER" \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address,address,address)' \
    "$BENEFICIARY" "$SUSDS" "$USDS" "$GBPF" "$SSR_ORACLE" "$PSM3" "$POOL_MANAGER")"

echo "==> 4/4 Hook ($HOOK)"
forge verify-contract "$HOOK" src/Hook.sol:Hook \
  --chain "$CHAIN" --verifier "$VERIFIER" \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address,address,address)' \
    "$POOL_MANAGER" "$VAULT" "$ORACLE" "$GBPF" "$USDS" "$SUSDS" "$PSM3")"

echo "==> All four submitted. Check each job's status URL printed above for a match."
