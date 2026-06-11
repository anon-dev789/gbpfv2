# GBPF Gateway — UI-visible market that defers to the mint/redeem hook

**Goal:** a pool that (a) is discoverable and routable by the Uniswap front-end and
aggregators, and (b) executes swaps at (or within a tight, known band of) the GBPF
primary-market price — i.e. the V4 hook's oracle-priced mint/redeem — without relying on
third-party arbitrageurs, LP recruitment, or a redeploy of the immutable core.

**Status:** design. Core protocol (DEPLOYMENT.md addresses) is live, immutable, and unchanged
by this design.

---

## 1. The constraint this design is built around

Two facts, both verified (Freehold's deployed code + Uniswap routing behaviour):

1. **Pools the Uniswap UI routes to unconditionally cannot call the hook.** V3 pools and
   vanilla V4 pools execute swaps with closed-form AMM math against their own liquidity.
   There is no mechanism for them to delegate execution to another contract mid-swap.

2. **Pools that CAN defer (V4 hooked pools) are not UI-routable by default.** The official
   interface routes hooked pools only after Uniswap Labs lists the hook. Our hook returns its
   delta in `beforeSwap`, so the on-chain V4 Quoter *can* simulate and quote it — the
   blocker is interface listing policy, not mechanics. Freehold never solved this either:
   its hook pool is reached only by custom routers; its UI presence is a separate, ordinary
   V3 pool (`freehold_full/script/SeedPool.s.sol`) of the bridged token with real liquidity.

**Conclusion:** literal per-swap deferral inside uniswap.org is gated on Uniswap listing.
Everything else about the goal — visible pool, oracle-accurate execution, no external arb
dependency, no LP capital at risk beyond a small buffer — is achievable now. The design
therefore has a **primary system** (autonomous oracle-pegged buffer pool, ships now) and a
**parallel track** (hook listing application, gives literal deferral if accepted).

## 2. System overview

```
                 uniswap.org / 1inch / 0x / wallets
                              │ (normal V3 routing)
                              ▼
              ┌──────────────────────────────────┐
              │   Gateway pool (Uniswap V3)      │  GBPF/USDS, 0.05%
              │   single LP position, tight band │  ← the ONLY position
              │   centred on oracle price        │
              └──────────────┬───────────────────┘
                             │ owns + recentres the position
                             ▼
              ┌──────────────────────────────────┐
              │   BufferVault (new contract)     │  permissionless rebalance()
              │   inventory: GBPF + USDS         │  owner: you (deposit/withdraw)
              └──────────────┬───────────────────┘
                             │ mint/redeem at oracle price (unlock/swap pattern)
                             ▼
              ┌──────────────────────────────────┐
              │   LIVE V4 hook pool (unchanged)  │  primary market
              │   oracle TWAP ± curve ± 20bp     │
              └──────────────────────────────────┘
```

The Gateway pool is what the world sees and trades. The BufferVault makes it behave as a
thin client of the hook: all of the pool's liquidity is one position, held in a tight band
(default ±30 bp) centred on the hook's oracle price, and every deviation is pushed back
through the hook — buy pressure drains GBPF from the band, `rebalance()` mints fresh GBPF
at the hook with the USDS received and recentres; sell pressure does the reverse via
redeem. The hook is the infinite-depth backstop; the V3 band is just its front window.

**Execution quality for a user:** worst case = band half-width + V3 fee ≈ 35 bp from the
hook's own price (which itself carries a 20 bp flat fee). Comparable to the hook's
round-trip cost; honest and bounded. Depth per block = buffer size; the buffer auto-refills
from the hook, so sustained one-sided flow is served at scale across blocks.

## 3. Components

### 3.1 Gateway pool — Uniswap V3, GBPF/USDS, 0.05%

- Base mainnet, `NonfungiblePositionManager` `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1`
  (proven on Base by Freehold's SeedPool).
- token0 = GBPF `0x1817FD23ceF7Da47DF934fdc880d72e653786770`,
  token1 = USDS `0x820C137fa70C8691f0e44Dc420a5e53c168921Dc` (address order; both 18 dec).
- Price = USDS per GBPF ≈ GBP/USD TWAP (USDS ≈ USD). 1 tick ≈ 1 bp; tickSpacing 10.
- Initialised at the OracleAdapter TWAP at creation time, not a placeholder.
- Why V3 over vanilla V4: unconditional routing support in every UI/aggregator today, and
  a working reference deploy (Freehold) on the same chain. A vanilla-V4 variant of this
  design is drop-in later if desired; BufferVault isolates the venue behind one interface.

### 3.2 BufferVault — the deferral engine (new contract, ~300 lines)

Periphery, not core: it holds *your* operating capital, so unlike the immutable core it has
an owner (deposit/withdraw only). Everything that affects market integrity is permissionless
or automatic.

State: the V3 position (one NFT), inventory accounting, immutable config
(pool, hook PoolKey, OracleAdapter, band/trigger params).

`rebalance()` — **permissionless**, the heart of the system:

1. Read OracleAdapter. **If unhealthy → withdraw the entire position and stop.** A paused
   oracle pauses the primary market; the Gateway pool must not keep quoting a stale price,
   so it goes empty (UI then shows no liquidity — honest). Next healthy `rebalance()`
   restores it.
2. Compute `oracleTick` from TWAP. If the position is centred within `RECENTER_BPS` and
   inventory is balanced → no-op (cheap, callable by anyone, any time).
3. Otherwise: burn + collect the position → hold raw GBPF + USDS. Compute the imbalance at
   oracle price. Push the excess side through the **hook pool** (the proven unlock/swap
   pattern from Bootstrap/SmokeMint, inlined): excess USDS → mint GBPF; excess GBPF →
   redeem to USDS. Re-mint the position `[oracleTick − W, oracleTick + W]`.
4. Every swap against the hook routes value through the live core: fees to the beneficiary,
   backing into the Vault — the Gateway *feeds* the protocol rather than competing with it.

Properties:
- **No third-party arb dependency.** `rebalance()` is the arb, owned by the system. If an
  external MEV bot front-runs it, they perform the same repricing for us — the pool is
  repegged either way; we just don't capture the spread. Graceful degradation to the
  Freehold model.
- **Bounded loss.** The position is only ever exposed within the band between rebalances;
  adverse selection cost per cycle ≤ band width vs the hook price, and each rebalance
  recaptures deviation ≥ trigger − hook fee − V3 fee, which is ≥ 0 by parameter choice.
- **Safety rails:** V3 mint/swap bounded by oracle-derived `sqrtPriceLimitX96`; unlock
  callback restricted to PoolManager; no external calls outside Uniswap/hook/oracle/tokens.

Default parameters (constants, tunable at (re)deploy of this cheap periphery contract):

| Param | Default | Rationale |
|---|---|---|
| Band half-width `W` | 30 bp | tight quote, 1 tick ≈ 1 bp, rounded to spacing 10 |
| Rebalance trigger | 50 bp deviation | > 20 bp hook fee + 5 bp V3 fee + gas → never loss-making |
| Recenter threshold | 15 bp oracle drift | follow GBP/USD without churning |
| Oracle unhealthy | pull all liquidity | never quote a stale price |

### 3.3 Keeper — one bot, two duties

A single scheduled job (cron / `/schedule`; permissionless functions, so anyone can run it):
1. `BufferVault.rebalance()` — no-ops when nothing to do.
2. `Vault.flush()` — the already-needed core duty (convert pending claims to sUSDS
   backing), folded into the same heartbeat. Tolerates `NothingToFlush`.

Cadence: every few minutes, plus event-driven on Gateway-pool swaps (optional v2).

### 3.4 Parallel track — literal in-UI hook routing

Free to pursue, not load-bearing:
1. **Fork-test the V4 Quoter against the live hook pool** — expected to quote correctly
   since `beforeSwap` returns the full delta. This artifact is the core of a listing case.
2. **Apply for Uniswap interface hook listing** (verified source ✓, immutable ✓, audited ✓,
   quoter-compatible ✓). If accepted, uniswap.org routes the hook pool directly — true
   per-swap deferral — and GBPF then has both the primary route and the Gateway band.
3. **Aggregator custom-source submissions** (1inch, 0x, OKX) with the same artifact.

## 4. What this design explicitly is not

- **Not dust liquidity.** A dust pool is visible but fills at garbage prices and has no
  link to the hook. The Gateway band is small-but-real and *continuously enforced*.
- **Not a core change.** No redeploy, no re-audit of the immutable contracts. A hook
  redeploy was evaluated and rejected: it cannot force interface routing (listing is
  permissioned) and Freehold — the working reference — never did it either.
- **Not Freehold's passive model.** Freehold seeded a static V3 position and relied on
  outside arbitrage. The Gateway actively self-pegs, needs no third parties, pulls quotes
  when the oracle pauses, and recycles its flow through the protocol's own primary market.

## 5. Capital

Buffer size = instantaneous depth; any size works mechanically (it refills from the hook).
Practical floor for being *useful*: enough that a retail-sized swap (~$100s) stays inside
the band. Funding it = mint GBPF at the hook with USDS + retain matching USDS. Current
deployer holdings (~0.77 GBPF + ~0.15 USDS) are sufficient only for a smoke-scale Gateway;
scale is the owner's choice and can grow incrementally by depositing into BufferVault.

## 6. Implementation plan

| Phase | Deliverable | Verification |
|---|---|---|
| 1 | `src/periphery/BufferVault.sol` (+ V3 interfaces) | unit + **Base fork test**: create pool, seed, swap-induced deviation, `rebalance()` repegs via hook, oracle-pause pulls liquidity |
| 2 | `script/GatewayDeploy.s.sol` (create+init V3 pool at oracle price, deploy vault, fund, first rebalance) | fork simulation, then mainnet broadcast |
| 3 | Keeper job (rebalance + flush) | dry-run cadence on live |
| 4 | V4-Quoter fork test + listing/aggregator submissions | quoter quote == hook execution on fork |

Phase 1 reuses: the proven unlock/swap router pattern (Bootstrap/SmokeMint), OracleAdapter
read path, Freehold's V3 mint mechanics (`SeedPool.s.sol`) as reference.
