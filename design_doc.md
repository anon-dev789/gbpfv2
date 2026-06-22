# GBPF v2 Design — Build Specification

Status: design committed, ready for implementation. All parameters and addresses below are immutable post-deploy.

Deployment target: **Base mainnet**.

---

## Core architecture

A permissionless synthetic GBP protocol on Base, accessed via a Uniswap V4 hook that intercepts swaps and converts them into primary-market mint/redeem operations against a yield-bearing collateral vault.

**No traditional AMM pool.** The hook overrides Uniswap's swap mechanism entirely. There are no LPs, no inventory split across token sides, no constant-product invariant. The pool framework is used purely as a routing layer so aggregators, wallets, and other contracts discover GBPF through standard interfaces — but every "swap" is a mint or redeem against protocol reserves at oracle-adjusted prices.

**Collateral asset: sUSDS (Base, SkyLink-bridged).** Deposited USDS is wrapped to sUSDS and held in an immutable vault contract. Yield accrues via the Sky Savings Rate. Because Base sUSDS is the SkyLink-bridged representation, yield accrual on Base reads from a separate Spark oracle (`SSRAuthOracle`) rather than from the sUSDS token itself — see "Oracle and rate infrastructure" below.

**Capital efficiency:** every dollar of protocol capital earns yield and is available for redemption. No idle inventory, no LP capital waiting for trades.

**Vault is a contract, not a wallet.** Immutable Solidity contract with no owner, no admin functions, no upgrade path. Only the hook can move funds in/out, and only via the mint/redeem/withdraw functions specified below.

---

## Solvency ratio

The solvency ratio `s` is the input to the spread curve. It is computed *net* of the beneficiary multisig's accrued-but-unwithdrawn share — the un-withdrawn portion is a liability to an external party and does not back GBPF.

```
s = ( (sUSDS_balance - pendingBeneficiarySUsds)
      · SSRAuthOracle.getConversionRate() / 1e27
      / gbp_usd_twap )
    / GBPF.totalSupply()
```

**Component sources:**
- `sUSDS_balance` — sUSDS held by the vault contract at current block
- `pendingBeneficiarySUsds` — accumulator tracking the beneficiary multisig's accrued-but-unwithdrawn fees plus its 50% share of yield (see "Fee and yield distribution")
- `SSRAuthOracle.getConversionRate()` — returned in ray (27 decimals); compounds continuously between bridge updates of `ssr`
- `gbp_usd_twap` — 5-minute TWAP of the Chainlink GBP/USD feed on Base
- `GBPF.totalSupply()` — current block

---

## Spread curve

Mint and redeem are priced around the oracle rate with a spread that's a continuous function of solvency.

**Formula (immutable):**

```
spread(s) = -S_max · tanh( ((1 - s) / d_50)² )   for s < 1   (a discount)
spread(s) = 0                                     for s ≥ 1   (no intervention)
```

The curve is **one-sided**: a defensive discount that is active only below 100% solvency. A surplus
is not a risk to defend against, so there is no spread at or above peg.

**Parameters (immutable):**
- `S_max = 5%` (500bp) — cap on the one-sided discount; max shortfall round-trip ~10%
- `d_50 = 5%` — solvency deviation at which the discount reaches `tanh(1) · S_max ≈ 380bp`
- **Flat fee: 20bp each side**, additive to the curve

**Sanity values (discount magnitude, excluding flat fee) — verified against the SpreadCurve library.**
The spread is **negative below 100%** (a discount on GBPF: cheaper mint, redeem haircut) and **zero
at and above 100%**:

| Solvency | Spread |
|---|---|
| ≥100.0% | 0 bp |
| 99.0%  | −20 bp |
| 97.0%  | −172.6 bp |
| 95.0%  | −380.8 bp |
| 90.0%  | −499.7 bp |
| ≤80%   | −500 bp (capped at −S_MAX) |

**Properties:**
- `spread = 0` and gradient = 0 at `s = 1.0` (the `d²` term gives "nearly flat at peg"); because the
  curve and its first derivative are both zero there, clamping the surplus side to 0 introduces no
  kink — it is C¹-smooth across the peg.
- One-sided: `spread ≤ 0` everywhere; strictly negative only below peg.
- Bounded by `−S_max` — the worst-case redeemer haircut is knowable.

**Behaviour by solvency regime:**
- **Below 100% (shortfall):** mint favourable (discounted), redeem discounted (haircut) → pulls in
  new collateral and stops redeemers extracting more than the backing behind each token, so
  redemption *heals* the shortfall instead of draining reserves.
- **At/above 100% (fully backed or surplus):** no spread — trade at the oracle rate (± the flat
  fee). A surplus is not a risk to defend against; leaving it untouched retains it in the vault
  rather than paying it out to whoever redeems first.

**Key property:** at a shortfall the protocol redeems at a *discount* (a haircut toward actual
backing), so an arbitrageur who buys GBPF cheaply on the secondary market and redeems against the
protocol cannot extract more than the collateral backing each token. The arbitrage shrinks supply
toward the collateral ratio and *reduces* the protocol's liability without draining reserves. The
inverse — paying redeemers a premium at a shortfall — lets arbitrage drain the vault in a death
spiral (`ds = (dS/S)·(s − r) < 0` whenever payout `r` exceeds solvency `s`); that inversion was the
original bug this sign convention exists to prevent.

**No hard peg, soft solvency.** GBPF does not promise 1 token = £1 at all times. It prices mint/redeem against on-chain reserves and discounts redemption toward backing during a shortfall — but the discount is capped at the 5% one-sided spread, so it is *not* fully solvent-by-construction in deep distress (redemptions below ~95% solvency still draw slightly more than backing). A redeem-at-NAV mechanism would close that gap; see the residual-risk note in `SECURITY.md`.

**Why this curve shape (and not the obvious alternatives):**
- Piecewise-flat-around-peg creates a kink at the band edge (arbitrageurs target kinks) and a no-restoring-force dead zone inside the band.
- Pure cubic under-responds in the mid-distress 95–99% range — exactly where bot arbitrage needs strong signal.
- Sigmoid-of-`d²` is gentle near peg (cheap normal operation), steep in mid-distress (bots activate when supply needs to shrink), saturating at the tail (last human redeemer's loss is bounded).

---

## Fee and yield distribution

**Splits (immutable):**
- **100% of the 20bp flat mint/redeem fee** → beneficiary multisig
- **50% of sUSDS yield accruals** → beneficiary multisig
- **50% of yield + 100% of curve-spread revenue** → stays in vault (compounds, strengthens solvency over time)

The curve-spread revenue stays in the vault because it is structural protection (the mechanism's response to distress), not protocol revenue.

**Beneficiary address (immutable):**
- Single Gnosis Safe (or equivalent multisig contract) on Base mainnet
- Address hardcoded in the hook
- The Safe contract supports adding/removing/rotating signers without changing its address, so the signer set can evolve while the on-chain recipient cannot
- Deploy sequence: Safe deployed first (deterministically via CREATE2 if possible), then hook deployed with the known Safe address baked in

**Withdrawal mechanism: pull.**
- `withdrawBeneficiary()` is callable permissionlessly (anyone can trigger)
- Function transfers `pendingBeneficiarySUsds` to the hardcoded beneficiary address and resets the pending counter to zero
- Pull (not push on every swap) for gas efficiency

**Yield-share accounting:**
- Maintain a beneficiary share index that scales with the SSR oracle's `chi`
- Beneficiary's claim accrued since last settlement = `(current_chi - last_settled_chi) × principal × 0.5`, where `principal` is the vault's effective USDS-denominated balance at the start of the period
- This avoids under-crediting during quiet periods (which a naive "credit on every state-changing call" approach would do)

**Ownership / control implications:**
- The protocol is **not "ownerless"** in the strict sense — the beneficiary multisig is an external party with an immutable claim on a defined share of revenue
- The multisig's powers are **bounded**: it can only receive its hardcoded share; it cannot pause the protocol, change parameters, upgrade contracts, or touch the rest of the vault
- This is "external recipient with no admin authority," not governance

---

## Oracle and rate infrastructure (Base mainnet)

**GBP/USD: Chainlink only.**

- Proxy address: `0xCceA6576904C118037695eB71195a5425E69Fa15`
- Heartbeat: 24 hours
- Deviation threshold: 0.5%
- Decimals: 8
- Used as: 5-minute TWAP for solvency, also the underlying for the pricing math

**Why no secondary feed:** Pyth and Redstone only offer GBP/USD on Base in pull mode (caller must bundle an update payload), which breaks aggregator-routed swaps — fatal for the Uniswap-as-routing-layer thesis. API3 has no GBP/USD dAPI on Base at all. Single-oracle risk is the price of being on Base; mitigated by TWAP, the deviation circuit-breaker, and the sequencer-uptime feed.

**sUSDS rate: Spark `SSRAuthOracle`.**

- Address: `0x65d946e533748A998B1f0E430803e39A6388f7a1`
- `getConversionRate()` returns USDS-per-sUSDS in ray (27 decimals)
- The rate accrues continuously on Base between bridge updates by extrapolating `chi` forward using `ssr × (block.timestamp - rho)` — same compounding math as Ethereum mainnet
- Bridge messages (from Sky's L1 authority `0xB2833392527f41262eB0E3C7b47AFbe030ef188E` via Base's canonical OP-Stack messenger) update `ssr` itself, which happens only when Sky governance changes the savings rate (rare)
- The Base sUSDS token (`0x5875eEE11Cf8398102FdAd704C9E96607675467a`) is a plain ERC-20 with no `convertToAssets` — do not call it for rate

**Sequencer uptime: Chainlink L2 uptime feed.**

- Address: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
- Grace period after sequencer recovery: 1 hour

---

## Pause semantics

Fully automatic with hysteresis. **No roles, no admin, no `unpause()` function, no governance.** Pause is implicit in the hook's logic — if any trigger condition holds (or the cooldown is active), every mint/redeem reverts.

**Trigger conditions (immutable):**

```
on every mint/redeem:
  if (sequencer_uptime_feed reports recently_down OR
      time_since_sequencer_recovery < 1h OR
      time_since_last_chainlink_update > 26h OR
      |latest_chainlink - previous_chainlink| / price > 2% OR
      paused_until > now):
    paused_until = now + 15 minutes
    revert
  else:
    execute mint/redeem
```

**Parameters (immutable):**

| Parameter | Value | Reasoning |
|---|---|---|
| Cooldown / hysteresis | 15 minutes | Suppresses oracle flap; prevents deterministic-unpause MEV; < heartbeat so a single missed update doesn't cascade |
| TWAP window for GBP/USD | 5 minutes | 150 blocks at Base's 2s blocktime; equivalent manipulation cost to a ~30-minute TWAP on Ethereum |
| Single-update circuit-breaker | >2% step | Normal Chainlink updates step by ~0.5% (deviation trigger); a 2% single-update jump is flash-crash-like; sustained legitimate moves arrive as many small steps |
| Staleness pause threshold | >26h since last update | 24h heartbeat + 1h sequencer grace + 1h buffer |
| Sequencer recovery grace | 1 hour | Chainlink-standard for L2 uptime feed |

**No bridge-staleness pause for sUSDS.** The SSR oracle's local extrapolation handles continuous accrual; the only thing the bridge updates is the rate itself, which is rare and bounded by sanity checks in the oracle.

**No secondary-feed divergence trigger.** No second push-mode GBP/USD source exists on Base.

---

## Hook mechanics (Uniswap V4)

The hook implements Uniswap V4's "custom curve" pattern: it intercepts swaps in `beforeSwap` and returns a delta that tells the PoolManager to use the hook's own pricing rather than the pool's constant-product math.

**Hook responsibilities per swap:**
1. Read GBP/USD price (5-minute TWAP) and sequencer uptime
2. Check pause conditions; revert if any condition holds or cooldown is active
3. Read the SSRAuthOracle to get current sUSDS conversion rate
4. Compute current solvency `s`
5. Compute spread = curve(s) + flat fee
6. Compute mint/redeem amounts at oracle ± spread
7. Move sUSDS in/out of the vault, mint/burn GBPF, update `pendingBeneficiarySUsds`
8. Return the delta to the PoolManager so flash-accounting balances

**Why "the hook is the protocol, Uniswap is the routing layer":**
- Universal access through aggregators (1inch, Matcha, Uniswap Universal Router)
- No separate integration work per venue — anything that speaks V4 finds GBPF
- "Infinite liquidity" in the meaningful sense: trades clear at any size bounded only by vault collateral; no slippage curve from inventory depletion
- Capital efficiency maximised — no LP capital sitting idle

**Implementation note:** detailed V4 plumbing (return-delta encoding, flash-accounting settlement, hook permission bits, native vs ERC-20 handling, reentrancy with the PoolManager) is deferred to the implementation phase but does not constrain any of the design decisions above.

---

## Bootstrap

Atomic with deployment:

1. Deploy hook + vault contracts.
2. Same transaction (or atomic deploy script): deposit **$1 USDS** as seed, mint corresponding GBPF, **burn the GBPF to `address(0)`**.

**Why $1 is enough:** the vault is not an AMM and has no inventory requirement. The seed only needs to (a) eliminate the inflation-attack pattern on the first deposit, and (b) avoid a divide-by-zero on the first solvency read. Both satisfied at $1.

**Why burn:** if seed GBPF stayed with the deployer, the deployer would be 100%-of-supply holder at deploy. Burning makes the seed contribution permanent and removes any deployer centralisation footprint.

**Why atomic:** without atomicity, a bot could front-run with their own first mint between deploy and seed. At $1 scale this doesn't break anything material but eliminates a needless footnote in security reviews.

---

## Confirmed addresses (Base mainnet)

| Component | Address |
|---|---|
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Uniswap Universal Router | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
| Chainlink GBP/USD | `0xCceA6576904C118037695eB71195a5425E69Fa15` |
| Chainlink L2 sequencer uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
| Spark `SSRAuthOracle` (sUSDS rate) | `0x65d946e533748A998B1f0E430803e39A6388f7a1` |
| sUSDS token (SkyLink-bridged) | `0x5875eEE11Cf8398102FdAd704C9E96607675467a` |
| USDS token (SkyLink-bridged) | `0x820C137fa70C8691f0e44Dc420a5e53c168921Dc` |
| Beneficiary multisig | TBD (deploy Safe first, then hardcode) |

---

## Properties summary

- **Permissionless:** no admin functions, no KYC, no whitelisting on mint/redeem
- **Bounded external recipient:** beneficiary multisig has immutable claim on defined revenue share but no operational control
- **Bounded overpayment:** redemption is haircut toward backing during a shortfall, capped at the 5% one-sided spread — not fully solvent-by-construction in deep distress (see `SECURITY.md` residual risks)
- **Transparent:** solvency ratio publicly computable every block
- **Self-funding (partially):** 50% of yield plus 100% of curve-spread revenue compound into reserves
- **MEV-resistant:** layered defences — flat fee, curve spread, TWAP, circuit-breaker, sequencer-uptime feed
- **Composable:** standard ERC-20 token, V4-routable, integrates with any DeFi protocol that accepts ERC-20s
- **Immutable:** all parameters, addresses, and mechanisms fixed at deploy

---

## Pre-deploy verification checklist

These must be confirmed at deploy time, not assumed from this document:

1. Chainlink GBP/USD on Base: confirm proxy address, current aggregator, heartbeat (24h), deviation (0.5%), decimals (8)
2. SSRAuthOracle: confirm address, current `ssr`/`chi`/`rho`, ABI signature for `getConversionRate()`
3. Base block time: confirm ~2s; confirm Flashblocks behaviour and whether it affects TWAP semantics
4. Sequencer uptime feed: confirm address and current status
5. Beneficiary Safe: deployed on Base, threshold/signers set, address known before hook deploy (use CREATE2 for determinism)
6. sUSDS and USDS token addresses on Base: confirm current proxies and any upgrade history
7. Uniswap V4 PoolManager: confirm address and hook-permission bit layout

---

## Implementation effort

Estimated 3–6 months of focused engineering, plus audit, plus stress-testing period. Recommended phasing:

1. Curve and solvency math in isolation (Foundry, fuzzing)
2. Vault contract (mint/redeem/withdraw, beneficiary accounting)
3. V4 hook integration (custom-curve pattern, flash-accounting)
4. Simulation harness against historical GBP/USD and stressed scenarios
5. External audit
6. Mainnet deploy with atomic seed

Once deployed, no upgrades — every parameter and address above is final.
