#!/usr/bin/env python3
"""Compute the live GBPF mint/redeem exchange rate (Base mainnet).

Reproduces the Hook's pricing:
    spread(s) = S_MAX * tanh(((1 - s) / D_50)^2) * sign(1 - s)
    mintPrice   = twap * (1 + spread + FLAT_FEE)   (USDS per GBPF)
    redeemPrice = twap * (1 + spread - FLAT_FEE)    (USDS per GBPF)

Reads:
  - Vault.previewSolvencyInputs()  (collateral pieces)
  - OracleAdapter.update()         (TWAP, simulated via eth_call)
  - GBPF.totalSupply()             (liabilities)

Zero dependencies — uses only the Python standard library. The solvency step
is exact integer math (matches the contract bit-for-bit); the tanh spread is
computed in float and matches the on-chain fixed-point curve to ~1e-15.

Usage:
    python3 tools/gbpf_rate.py            # show rates
    python3 tools/gbpf_rate.py 1000       # also quote minting 1000 USDS / redeeming 1000 GBPF
    GBPF_RPC=https://my.base.rpc python3 tools/gbpf_rate.py
"""

import json
import math
import os
import sys
import urllib.request

# --- Live deployment (Base, chain 8453), commit 60d3895 -----------------------
VAULT = "0xA9a831a348D0Db372cf75dd7C082cFF67A453498"
ORACLE = "0x9c66F3F8a102d6Bf3EeaEAAe5d9ECAe88985eB2F"
GBPF = "0x1817FD23ceF7Da47DF934fdc880d72e653786770"

SEL_PREVIEW_SOLVENCY = "0xf392169c"  # previewSolvencyInputs()
SEL_UPDATE = "0xa2e62045"            # update()
SEL_TOTAL_SUPPLY = "0x18160ddd"      # totalSupply()

# --- Fixed-point + curve constants (mirror Hook.sol / SpreadCurve.sol) --------
WAD = 10**18
RAY = 10**27
MAX_SOLVENCY_WAD = 10 * WAD
S_MAX = 0.05          # SpreadCurve.S_MAX  (5% one-sided cap)
D_50 = 0.05           # SpreadCurve.D_50
FLAT_FEE = 0.002      # Hook.FLAT_FEE_WAD = 2e15 = 20bp

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
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def mul_div(a: int, b: int, d: int) -> int:
    return (a * b) // d


def compute_solvency_wad(s_usds, pending_ben, ssr_rate, usds_claim, twap, supply):
    principal = s_usds - pending_ben if s_usds > pending_ben else 0
    total_usds_value = mul_div(principal, ssr_rate, RAY) + usds_claim
    collateral_gbp_wad = mul_div(total_usds_value, WAD, twap)
    return min(mul_div(collateral_gbp_wad, WAD, supply), MAX_SOLVENCY_WAD)


def spread(solvency: float) -> float:
    """Signed spread fraction. Positive (=> price up) when under-collateralised."""
    d = 1.0 - solvency
    if d == 0.0:
        return 0.0
    arg = (d / D_50) ** 2
    mag = S_MAX * math.tanh(arg)
    return mag if d > 0 else -mag


def main():
    quote_amount = float(sys.argv[1]) if len(sys.argv) > 1 else None

    sv = words(eth_call(VAULT, SEL_PREVIEW_SOLVENCY))
    s_usds, pending_ben, ssr_rate, usds_claim = sv[0], sv[1], sv[2], sv[3]

    ow = words(eth_call(ORACLE, SEL_UPDATE))
    twap_wad, healthy = ow[0], (ow[1] != 0)
    if twap_wad == 0:
        sys.exit("Oracle returned zero TWAP — aborting.")

    supply = words(eth_call(GBPF, SEL_TOTAL_SUPPLY))[0]
    if supply == 0:
        sys.exit("GBPF totalSupply is zero — aborting.")

    solvency_wad = compute_solvency_wad(
        s_usds, pending_ben, ssr_rate, usds_claim, twap_wad, supply
    )
    solvency = solvency_wad / WAD
    twap = twap_wad / WAD
    sp = spread(solvency)

    mint_price = twap * (1 + sp + FLAT_FEE)    # USDS you pay per GBPF
    redeem_price = twap * (1 + sp - FLAT_FEE)  # USDS you get per GBPF

    print(f"RPC                 {RPC}")
    print(f"Oracle healthy      {healthy}")
    print(f"Solvency            {solvency * 100:.4f}%")
    print(f"Reference rate      {twap:.6f}  USDS/GBP (oracle TWAP)")
    print(f"Spread              {sp * 1e4:+.2f} bp   |  flat fee {FLAT_FEE * 1e4:.0f} bp each side")
    print("-" * 52)
    print(f"MINT  (USDS -> GBPF)  price {mint_price:.6f} USDS/GBPF")
    print(f"REDEEM (GBPF -> USDS) price {redeem_price:.6f} USDS/GBPF")

    if quote_amount is not None:
        gbpf_out = quote_amount / mint_price
        usds_out = quote_amount * redeem_price
        print("-" * 52)
        print(f"Mint   {quote_amount:,.2f} USDS  ->  {gbpf_out:,.6f} GBPF")
        print(f"Redeem {quote_amount:,.2f} GBPF  ->  {usds_out:,.6f} USDS")

    if not healthy:
        print("\n⚠️  Oracle reports unhealthy — swaps would revert OraclePaused.")
    print("\nNote: indicative price (pre-slippage/rounding). For an executable quote,")
    print("simulate a swap against the Hook/periphery via eth_call.")


if __name__ == "__main__":
    main()
