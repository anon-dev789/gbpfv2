#!/usr/bin/env python3
"""Generate differential test vectors for src/SpreadCurve.sol.

Reference implementation of the immutable spread curve:

    spread(s) = S_MAX * tanh( ((1 - s) / D_50)^2 ) * sign(1 - s)

with S_MAX = 0.05 and D_50 = 0.05.

Emits a JSON array of {solvency_wad, expected_spread_wad} records that the
Solidity diff-test loads via vm.readFile and asserts against on-chain output.

Run from project root:
    python3 script/python/generate_curve_vectors.py > test/vectors/spread_curve.json
"""

import json
import math
import sys

WAD = 10**18

S_MAX = 0.05
D_50 = 0.05
MAX_SOLVENCY = 10.0  # matches MAX_SOLVENCY_WAD in SpreadCurve.sol

def spread_reference(solvency: float) -> float:
    """Exact reference using Python's stdlib math.tanh (double precision)."""
    if solvency > MAX_SOLVENCY:
        raise ValueError(f"solvency {solvency} exceeds MAX_SOLVENCY {MAX_SOLVENCY}")
    d = 1.0 - solvency
    if d == 0:
        return 0.0
    arg = (d * d) / (D_50 * D_50)
    return S_MAX * math.tanh(arg) * (1.0 if d > 0 else -1.0)


def wad(x: float) -> int:
    """Convert a real number to WAD with banker's rounding."""
    return int(round(x * WAD))


def collect_inputs() -> list[float]:
    """Curated set of inputs covering edge cases, the steep zone, and the saturated tails."""
    inputs: list[float] = []

    # Exact peg and tiny deviations
    inputs += [1.0, 1.0 - 1e-9, 1.0 + 1e-9, 1.0 - 1e-12, 1.0 + 1e-12]

    # Sanity table from the design doc
    for s in [0.80, 0.85, 0.90, 0.95, 0.97, 0.99, 0.995, 0.999,
              1.001, 1.005, 1.01, 1.03, 1.05, 1.10, 1.15, 1.20]:
        inputs.append(s)

    # Dense linear sweep in the steep zone
    for i in range(1, 100):
        inputs.append(1.0 - i * 0.001)  # 0.999 down to 0.901
        inputs.append(1.0 + i * 0.001)  # 1.001 up to 1.099

    # Tail sweep to confirm saturation
    for s in [0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.01]:
        inputs.append(s)
    for s in [1.5, 2.0, 3.0, 5.0, 10.0]:
        inputs.append(s)

    # De-duplicate while preserving order
    seen = set()
    deduped = []
    for s in inputs:
        key = round(s, 15)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(s)
    return deduped


def main() -> int:
    inputs = collect_inputs()
    vectors = []
    for s in inputs:
        try:
            expected = spread_reference(s)
        except ValueError as e:
            print(f"skipping {s}: {e}", file=sys.stderr)
            continue
        vectors.append({
            "solvency_wad": str(wad(s)),
            "expected_spread_wad": str(wad(expected)),
        })

    # Stable order for deterministic output
    vectors.sort(key=lambda r: int(r["solvency_wad"]))

    out = {
        "version": 1,
        "S_MAX_wad": str(wad(S_MAX)),
        "D_50_wad": str(wad(D_50)),
        "count": len(vectors),
        "vectors": vectors,
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
