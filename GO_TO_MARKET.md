# GBPF Go-To-Market Plan

**Status:** all on-chain infrastructure is live (core + Gateway, see DEPLOYMENT.md). This file
is the plan for making GBPF actually swappable by normal users. Written 2026-06-11.

## The constraint everything follows from

No public router or UI will ever construct a swap against the V4 hook pool on its own:

1. **Hooked V4 pools are routed by the Uniswap interface only after Uniswap Labs lists the
   hook.** Our hook is technically eligible (beforeSwap returns a full delta, so the on-chain
   V4 Quoter can simulate it) but unlisted. Until then the hook pool is reachable only by
   custom integrations (our scripts, our front-end, anyone who reads DEPLOYMENT.md).
2. **The V3 Gateway pool is a standard, always-routable pool — but routers filter by
   liquidity.** At smoke scale (~0.05 USDS per side) it is visible yet below every routing
   threshold; quotes beyond its depth collapse (e.g. 0.5 GBPF quoted ≈ 0.05 USDS — the whole
   USDS side — which is the depth ceiling, not a peg failure).

Verified empirically this week: Uniswap UI shows "no route" for USDS→GBPF; the same swap
executes perfectly via the direct hook path (SmokeMint, Bootstrap, BufferVault all did it).

## The three paths (they compose; none is blocked by another)

### Path 1 — Own front-end (full control, works immediately)

A small mint/redeem web page that swaps against the hook pool directly via the proven
unlock/swap pattern (the same call path as `script/SmokeMint.s.sol` / `MinimalRouter`).

- Gives: true oracle pricing, effectively unlimited mint depth, redeem depth = protocol
  backing. No listing, no extra capital, no third parties.
- Costs: building + hosting a dapp; users must come to OUR page (no uniswap.org presence).
- Components: connect wallet → quote (eth_call simulate `update()` for TWAP + hook fee math)
  → approve USDS/GBPF to a small router contract → swap. The on-chain router contract
  already exists in spirit (`MinimalRouter`); deploy a canonical instance and verify it.
- Status: NOT STARTED. This is the recommended next build.

### Path 2 — Scale the Gateway (passive discoverability)

The live Gateway (V3 GBPF/USDS pool `0xd478…df7e` + BufferVault `0x6aB1…B7EC`) self-pegs to
the hook; its only limitation is capital.

- Mechanics: transfer USDS (and/or GBPF) to the BufferVault, call `rebalance()`. The vault
  hook-mints the GBPF side and redeploys a deeper ±30bp band. No redeploy ever needed.
- Sizing guide: depth per side ≈ half the total funding. For a 100-USDS trade to fit inside
  the band, fund ~200+ USDS. Aggregator/router indexing thresholds are typically $10k+ TVL —
  treat that as the "appears in auto-routing" bar, to be confirmed empirically.
- Costs: capital locked (recoverable via `exitAndWithdrawAll`), bounded IL between
  rebalances, keeper gas.
- Status: LIVE at smoke scale (0.1 USDS). Keeper workflow committed
  (`.github/workflows/keeper.yml`) — needs the KEEPER_PRIVATE_KEY secret + a funded
  gas-only wallet to activate.

### Path 3 — Uniswap hook listing + aggregator submissions (the endgame)

The only route to "uniswap.org swaps GBPF via the hook directly".

- Steps: (a) fork-test the official V4 Quoter against the live hook pool — expected to pass
  since beforeSwap returns the full delta; (b) apply for Uniswap interface hook listing with
  that artifact (contracts are verified + immutable + audited — strong application);
  (c) submit custom-source integrations to aggregators (1inch, 0x, OKX).
- Costs: effort only. Decision and timeline belong to Uniswap Labs / the aggregators.
- Status: NOT STARTED.

## Recommended order

1. **Front-end (Path 1)** — the only path that produces a usable product unilaterally.
2. **Keeper activation** (Path 2 prerequisite) — `cast wallet new`, fund ~0.001 ETH on Base,
   `gh secret set KEEPER_PRIVATE_KEY`.
3. **Gateway capital decision** (Path 2) — pick a size; any amount works mechanically.
4. **Quoter fork test + listing application** (Path 3) — fire and forget, then wait.

## Current swap workarounds (until Path 1 ships)

- Mint (USDS→GBPF): `MINT_USDS=N forge script script/SmokeMint.s.sol:SmokeMint --rpc-url
  https://mainnet.base.org --broadcast --slow --account deployer --sender <wallet>`
  (whole-USDS amounts; wallet must hold N USDS).
- Redeem (GBPF→USDS): no script yet — same pattern with the swap direction flipped
  (`zeroForOne = true`, GBPF is currency0). Write `SmokeRedeem.s.sol` when needed.
- Tiny trades also execute against the Gateway pool at the correct marginal price (~1.34),
  bounded by its ~0.05 USDS/side depth.
