#!/usr/bin/env python3
"""Read the live GBPF vault solvency ratio (Base mainnet).

Reproduces Hook._computeSolvencyWad exactly, using:
  - Vault.previewSolvencyInputs()  (collateral pieces)
  - OracleAdapter.update()         (TWAP, simulated via eth_call)
  - GBPF.totalSupply()             (liabilities)

Zero dependencies — uses only the Python standard library.

Usage:
    python3 tools/gbpf_solvency.py
    GBPF_RPC=https://my.base.rpc python3 tools/gbpf_solvency.py
"""

import json
import os
import sys
import urllib.request

# --- Live deployment (Base, chain 8453), commit 60d3895 -----------------------
VAULT = "0xA9a831a348D0Db372cf75dd7C082cFF67A453498"
ORACLE = "0x9c66F3F8a102d6Bf3EeaEAAe5d9ECAe88985eB2F"
GBPF = "0x1817FD23ceF7Da47DF934fdc880d72e653786770"

# --- Function selectors -------------------------------------------------------
SEL_PREVIEW_SOLVENCY = "0xf392169c"  # previewSolvencyInputs()
SEL_UPDATE = "0xa2e62045"            # update()  (non-view; safe to eth_call-simulate)
SEL_TOTAL_SUPPLY = "0x18160ddd"      # totalSupply()

# --- Fixed-point constants (mirror Hook.sol / SpreadCurve.sol) ----------------
WAD = 10**18
RAY = 10**27
MAX_SOLVENCY_WAD = 10 * WAD

RPC = os.environ.get("GBPF_RPC", "https://mainnet.base.org")


def eth_call(to: str, data: str) -> str:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [{"to": to, "data": data}, "latest"],
    }
    req = urllib.request.Request(
        RPC,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "gbpf-tools/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.load(resp)
    if "error" in body:
        raise RuntimeError(f"RPC error calling {to}: {body['error']}")
    return body["result"]


def words(hexstr: str):
    """Split an eth_call return into 32-byte words as ints."""
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def mul_div(a: int, b: int, d: int) -> int:
    """Floor(a*b/d) — matches FixedPointMathLib.mulDiv rounding."""
    return (a * b) // d


def compute_solvency_wad(s_usds, pending_ben, ssr_rate, usds_claim, twap, supply):
    """Exact integer reproduction of Hook._computeSolvencyWad."""
    principal = s_usds - pending_ben if s_usds > pending_ben else 0
    s_usds_value = mul_div(principal, ssr_rate, RAY)
    total_usds_value = s_usds_value + usds_claim
    collateral_gbp_wad = mul_div(total_usds_value, WAD, twap)
    solvency_wad = mul_div(collateral_gbp_wad, WAD, supply)
    return min(solvency_wad, MAX_SOLVENCY_WAD)


def main():
    # 1. Vault inputs.
    sv = words(eth_call(VAULT, SEL_PREVIEW_SOLVENCY))
    s_usds, pending_ben, ssr_rate, usds_claim = sv[0], sv[1], sv[2], sv[3]

    # 2. Oracle TWAP (update() returns (twapWad, healthy, pausedUntil)).
    ow = words(eth_call(ORACLE, SEL_UPDATE))
    twap, healthy = ow[0], (ow[1] != 0)
    if twap == 0:
        sys.exit("Oracle returned zero TWAP — aborting.")

    # 3. GBPF supply.
    supply = words(eth_call(GBPF, SEL_TOTAL_SUPPLY))[0]
    if supply == 0:
        sys.exit("GBPF totalSupply is zero — aborting.")

    solvency_wad = compute_solvency_wad(
        s_usds, pending_ben, ssr_rate, usds_claim, twap, supply
    )

    ratio = solvency_wad / WAD
    print(f"RPC                 {RPC}")
    print(f"Oracle healthy      {healthy}")
    print(f"TWAP (USDS/GBP)     {twap / WAD:.6f}")
    print(f"GBPF supply         {supply / WAD:,.6f}")
    print(f"sUSDS balance       {s_usds / WAD:,.6f}")
    print(f"pending beneficiary {pending_ben / WAD:,.6f}")
    print(f"USDS claim backing  {usds_claim / WAD:,.6f}")
    print("-" * 40)
    state = "fully backed" if abs(ratio - 1) < 1e-9 else ("surplus" if ratio > 1 else "SHORTFALL")
    print(f"SOLVENCY            {ratio * 100:.4f}%  ({state})")
    if not healthy:
        print("\n⚠️  Oracle reports unhealthy — swaps would revert OraclePaused.")


if __name__ == "__main__":
    main()
