# The GBPF Exchange Rate & Curve — In Plain English

A non-technical explanation of how the protocol prices mints and redeems.

## The exchange rate, in plain English

**There's a "true" reference rate.** The system constantly reads the real GBP↔USD
price from a price oracle (smoothed over the last 5 minutes so it can't be jerked
around by a single moment). Think of this as the honest mid-market rate — what £1 is
"really" worth in dollars right now.

GBPF is a digital pound. You can always do two things with the protocol:

- **Mint:** hand in dollars (USDS), get GBPF.
- **Redeem:** hand in GBPF, get dollars back.

The price you actually get isn't *exactly* the reference rate. Two adjustments sit on
top of it: a **flat fee** and a **spread**.

### 1. The flat fee — a fixed 20bp toll

Every trade pays 0.20% (20 basis points), in both directions. It's like a bureau de
change that posts the real rate but buys a hair below and sells a hair above.
Round-trip in and straight back out, you lose ~0.40%. This is constant and never
changes.

### 2. The spread — a "health surcharge" that breathes with the vault

This is the interesting part. The GBPF in circulation is backed by a vault of real
reserves. **Solvency** = how much backing exists per pound of GBPF:

- **100% (= 1.0):** exactly fully backed. The healthy normal state.
- **Above 100%:** surplus reserves (e.g. the vault has earned yield).
- **Below 100%:** a shortfall.

The spread is a *surcharge that depends on how far solvency has drifted from 100%*, and
it tilts the rate to nudge the system back to health:

| Vault state | What it does to the rate |
|---|---|
| **Exactly 100%** | Spread is **zero**. You trade right at the reference rate (just the 20bp fee). |
| **Below 100%** (shortfall) | **Minting gets expensive, redeeming gets favourable.** This discourages new GBPF and rewards people for handing GBPF back — shrinking what the vault owes and healing the shortfall. |
| **Above 100%** (surplus) | **Minting gets favourable, redeeming gets expensive.** This pulls in new money and discourages exits, spreading the surplus across more tokens. |

### The "curve" — why it's a smooth S-shape, not a switch

The size of the spread isn't linear with the shortfall. It follows an S-shaped curve
(a `tanh` of the *squared* distance from 100%), which gives three deliberately
different behaviours:

- **Near 100% — almost flat.** Small wobbles barely move the price. Normal day-to-day
  trading stays cheap and stable. There's no "dead band" with a sudden edge, just a
  gentle, ever-present pull back toward peg.
- **In mid-distress (say 95–99% backed) — steep.** This is where the surcharge ramps up
  hard, sending a strong signal that gets arbitrage bots actively working to shrink
  supply.
- **In the extreme tail — it flattens out (saturates).** The spread is **capped at 5%
  one-side** (so a worst-case round trip is ~10%). Even in a severe shortfall, the last
  person redeeming knows the maximum haircut in advance — losses are bounded and
  knowable.

Some concrete points on the curve: at 100% the spread is 0; by the time backing has
drifted ~5% away, the spread is around 3.8%; and it can never exceed 5%.

## The one big idea to take away

**GBPF does not promise "1 token = £1, always."** It promises something stronger and
more honest: the protocol is *always solvent against its actual reserves*, and it always
lets you redeem at a price that reflects the **real backing per token** — generous when
there's a surplus, fair-but-discounted when there's a shortfall. The spread is the
self-correcting force that keeps it healthy, and because it makes the rate move
predictably with the vault's health, arbitrage traders naturally do the rebalancing
work — and when they do, they *shrink the protocol's liabilities rather than drain its
reserves*.

So the rate a user sees = **reference oracle rate, ± a health-based spread, ± a fixed
20bp fee.**

---

### Where this lives in the code

- Flat fee: `FLAT_FEE_WAD = 2e15` (20bp) — `src/Hook.sol`
- Spread curve: `spread(s) = S_MAX · tanh(((1 - s) / D_50)²) · sign(1 - s)` — `src/SpreadCurve.sol`
  (`S_MAX = 5%`, `D_50 = 5%`)
- Price multipliers: `WAD + spread ± FLAT_FEE_WAD` — `src/Hook.sol`
- Design rationale: `HOOK_DESIGN.md`, `design_doc.md`
