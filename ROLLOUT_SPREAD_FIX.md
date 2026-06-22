# Rollout plan — SpreadCurve sign-inversion fix

**Branch:** `fix/spread-sign-inversion`
**What changed in code:** `SpreadCurve.spread` is rewritten to a **one-sided defensive curve** — a
discount below 100% solvency, and **zero at/above 100%** (a surplus is not a risk to defend against).
Previously it returned a *positive* spread at a shortfall (paying redeemers a premium → drain). Plus
docstrings, the Python reference generator, regenerated differential vectors, updated test
assertions, new anti-drain guard tests, and corrected design docs. No other contract logic changed.

**Why a redeploy:** the Hook is an immutable Uniswap v4 hook and the pool is bound to the hook
address in its `PoolKey`. The `SpreadCurve` library is `using`-inlined into the Hook bytecode, so
the corrected curve only takes effect in a **newly deployed Hook**. Per decision, we also deploy a
**fresh GBPF token and a fresh Vault** and **do not migrate collateral or holders** — clean start.

---

## The bug, in one paragraph (for reviewers)

The deployed curve returns a **positive** spread at a shortfall (`solvency < 100%`), which the Hook
**adds** to both prices: `mintPrice = twap·(1+spread+fee)`, `redeemPrice = twap·(1+spread−fee)`. So
at a shortfall it makes minting *more expensive* and redeeming *more rewarding* — paying redeemers a
premium above peg while the vault is under-backed. Because solvency moves by
`ds = (dS/S)·(s − r)` per redemption (where `r` = backing paid out per GBPF burned), paying `r > s`
**lowers** solvency on every redemption — a death spiral the rising spread amplifies, and a drain
vector (buy GBPF near backing on the secondary market, redeem for a premium). The fix makes the
curve **one-sided**: a discount below peg (cheaper mint to pull collateral in, redeem haircut), and
**no spread at/above peg** (a surplus is not a risk, so don't intervene — and the surplus stays in
the vault rather than being paid out to early redeemers). This is the direction the project's own
"solvent by construction / priced honestly against actual collateral" invariant always intended.

---

## Phase 0 — Verification gate (DO THIS FIRST; do not deploy until signed off)

A sign flip on the core pricing mechanism, against deliberate (but mistaken) design docs, must be
independently confirmed before spending gas on an immutable redeploy.

- [ ] **Independent economic review.** Have a second engineer (or auditor) re-derive
      `ds = (dS/S)·(s − r)` and confirm: at a shortfall, redemption only *heals* solvency when the
      payout `r < s`, so the spread must be **negative** at a shortfall. Confirm the old sign drains.
- [ ] **Confirm the corrected direction against the prose invariant** in `design_doc.md` ("solvent
      by construction", "priced honestly against actual collateral") and `EXCHANGE_RATE_EXPLAINED.md`
      ("fair-but-discounted when there's a shortfall"). The fix aligns code with that prose.
- [ ] **Decide on the `S_MAX` cap (separate design call).** Even with the corrected sign, the ±5%
      cap means at a deep shortfall the redeem price is still *above* true backing (e.g. at 76%
      solvency the redeem multiplier is ~0.948 vs 0.76 backing). The sign flip stops the death
      spiral and the above-peg premium, but does **not** by itself guarantee "never pay more than
      backing". Decide whether to (a) ship the sign flip alone now, or (b) also lift/scale the cap so
      redeem price ≤ backing at any shortfall. **Recommended: ship (a) now; track (b) separately.**
- [ ] **Sign-off recorded** (who/when) in this file or the PR before proceeding.

---

## Phase 1 — Finalize the code fix

- [ ] PR `fix/spread-sign-inversion` → review focused on `src/SpreadCurve.sol:66` (the flipped
      ternary) and the docstring.
- [ ] Regenerate vectors deterministically and confirm no drift beyond the commit:
      `python3 script/python/generate_curve_vectors.py > test/vectors/spread_curve.json`
- [ ] `forge test --use 0.8.26` — full suite green. Specifically:
      - `test/SpreadCurve.t.sol` (sign, monotonicity, sanity table, **new anti-drain guards**)
      - `test/SpreadCurveDifferential.t.sol` (matches regenerated Python vectors)
      - `test/Hook.t.sol` + `test/invariants/HookInvariants.t.sol`
- [ ] `forge fmt --check` clean (the pre-commit hook handles staged `.sol`).
- [ ] **Add a Hook-level shortfall integration test** (recommended, not yet in the branch): drive
      the Vault below 100% solvency and assert the redeem payout per GBPF is a discount (and,
      if the cap decision in Phase 0 is (b), that payout ≤ per-token backing). The existing Hook
      tests only run at ~100% solvency, so this regime is currently untested at the integration level.
- [ ] Merge to `main` (or your release branch). Tag the commit (e.g. `v2-spread-fix`).

---

## Phase 2 — Pre-deploy preparation

- [ ] Deployer EOA funded on Base: ≥ ~0.01 ETH gas + **≥ 1 USDS** for the seed swap.
- [ ] Confirm the immutable constants in `script/Deploy.s.sol` are still correct: `BENEFICIARY`
      (`0x621D…77D3`), Chainlink GBP/USD, sequencer feed, Spark SSR oracle, sUSDS, USDS, V4
      PoolManager, PSM3. The `_preflightChecks()` will assert these have code + sane values.
- [ ] Decide whether to **reuse the existing `OracleAdapter`** (`0x9c66…eB2F`) — it has no
      dependency on the Hook/Vault/GBPF, so it is safe to reuse and saves the TWAP re-warmup window.
      `Deploy.s.sol` redeploys it by default; if reusing, adapt the script to pass the existing
      address into the Hook constructor. **Recommended: reuse it** to avoid the post-deploy TWAP
      warmup (`_inWarmup`) gating swaps.
- [ ] Inventory every address that will change so nothing is missed in Phase 5–6 (table at bottom).

---

## Phase 3 — Deploy the fresh core (Hook + Vault + GBPF)

Order is fixed by `script/Deploy.s.sol`:

1. [ ] (Reuse or) deploy `OracleAdapter`.
2. [ ] Deploy `GBPF` (hook unset; constructor mints 1 wei dust to `0xdEaD` to avoid the
       `gbpfSupply == 0` guard on the first swap).
3. [ ] Deploy `Vault(BENEFICIARY, sUSDS, USDS, GBPF, SSR_ORACLE, PSM3, PoolManager)`.
4. [ ] Mine the Hook CREATE2 salt for the flag bits (`BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA`)
       via `HookMiner`, then deploy `Hook{salt}` with the **corrected SpreadCurve inlined**.
5. [ ] `vault.initialize(hook)` and `gbpf.initialize(hook, vault)` (one-shot; revert on re-call).

Run:
```
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base --broadcast --verify \
  --account deployer --sender 0xYOUR_DEPLOYER
```

Then the **manual bootstrap** (printed by the script):

6. [ ] `PoolManager.initialize()` with the canonical `PoolKey { currency0: min(USDS,GBPF),
       currency1: max(USDS,GBPF), fee: 0, tickSpacing: 1, hooks: <new Hook> }`.
7. [ ] Seed swap: exact-input mint of **1 USDS** through the V4 PoolManager → deployer gets ~0.8 GBPF.
8. [ ] Burn the seed: transfer all deployer GBPF to `0xdEaD`.

Record the new addresses (Oracle, GBPF, Vault, Hook, hook salt).

---

## Phase 4 — Verify the fix on-chain (before any periphery/UI points at it)

- [ ] **Standard health:** `ORACLE.update()` returns `healthy = true`, `twap > 0`; a tiny mint and
      redeem round-trip at ~100% solvency behaves as before (only the 40bp round-trip fee).
- [ ] **The fix itself.** Construct a shortfall and confirm the *discount* direction. Easiest path:
      a small fork/anvil simulation (or a scripted read) where `solvency < 1e18`, asserting:
      - `SpreadCurve.spread(0.95e18) < 0` (discount, not premium),
      - redeem price multiplier `(WAD + spread − fee) < WAD` at a shortfall (redeemer haircut),
      - mint price multiplier `< WAD` at a deep shortfall (minter discount).
      These are exactly the new guard tests in `test/SpreadCurve.t.sol`; re-running them against the
      deployed bytecode (same source) is the confirmation.
- [ ] Basescan-verify the new Hook, Vault, GBPF, (Oracle if redeployed).

---

## Phase 5 — Redeploy periphery against the new core

All periphery binds to the Hook/GBPF/USDS (and Vault for redeemers); each must be redeployed
pointing at the **new** addresses. None of the old periphery can be re-pointed (addresses are
immutable constructor args).

- [ ] **Batchers** — `script/BatchDeploy.s.sol` → new `BatchMinter`, `BatchRedeemer`.
- [ ] **Forwarder batchers** — `script/ForwarderDeploy.s.sol` → new `ForwarderMinter`,
      `ForwarderRedeemer`. Note the per-user CREATE2 **deposit addresses change** (new factory
      addresses), even though `FORWARDER_INIT_HASH` may be unchanged.
- [ ] **Gateway** (if keeping it) — `script/GatewayDeploy.s.sol` → new V3 pool + `BufferVault`
      bound to the new GBPF.
- [ ] Basescan-verify all periphery.

---

## Phase 6 — Re-point off-chain services

- [ ] **Keeper** (`keeper/wrangler.toml`): update `MINTER`, `REDEEMER`, `GBPF`, (`USDS` unchanged),
      and **reset `START_BLOCK`** to ~the new ForwarderRedeemer/Minter deploy block. Redeploy the
      worker. (Note: the BASE_RPC_URL must point at a non-stale archive RPC — see prior keeper notes.)
- [ ] **Web — `anon-dev789/gbpf-swap` repo (`index.html`)**: update `ORACLE`, `VAULT`, `GBPF`, and
      the `DIRECTIONS[*].factory` addresses (ForwarderMinter/Redeemer). If the Hook address is
      referenced anywhere for display, update it. Commit + push `main` (Cloudflare Pages redeploys).
- [ ] **Web mirror — `gbpfv2/web/index.html`**: same edits, keep in sync (or retire it if you've
      consolidated on `gbpf-swap`).
- [ ] Confirm the live page computes the correct new deposit addresses and reads balances/oracle.

---

## Phase 7 — Decommission the old (buggy) stack

The old Hook is immutable and **cannot be paused** — it will keep pricing redemptions at a premium
during any shortfall. Mitigation is to remove all paths to it and warn users.

- [ ] Remove every UI/keeper/reference pointing at the old Hook/Vault/GBPF/periphery (covered by
      Phase 6 once they point at the new stack).
- [ ] Announce the migration; mark the old GBPF/addresses as deprecated in `DEPLOYMENT.md`.
- [ ] If any value remains in the old vault/periphery, sweep it out via the owner-only rescue paths
      where they exist (batchers/forwarders have owner stray-rescue + tank withdraw).
- [ ] Do **not** advertise the old deposit addresses anywhere; any funds sent there will price on
      the buggy curve.

---

## Phase 8 — Record & close out

- [ ] Update `DEPLOYMENT.md` with the new core + periphery addresses, tx hashes, and a note that the
      previous deployment was retired due to the spread sign inversion.
- [ ] Link this plan and the PR from `DEPLOYMENT.md`.
- [ ] Tag the release; archive the broadcast artifacts under `broadcast/`.

---

## Rollback / abort criteria

- If Phase 0 review does **not** confirm the sign flip → stop; do not deploy. (Re-examine the
  derivation; the change is high-blast-radius.)
- If Phase 4 on-chain verification shows the discount direction is **not** in effect → halt before
  Phase 5; the wrong bytecode was deployed.
- Because this is a fresh stack with no migrated funds, "rollback" before Phase 6 is simply: don't
  point anything at the new addresses and keep using nothing (the old stack stays as-is, deprecated).
  After Phase 6, rollback = repoint UIs/keeper back to old addresses (not recommended — old curve is
  buggy).

---

## Address inventory (fill in during deploy)

| Component | Old (live) | New |
|---|---|---|
| OracleAdapter | `0x9c66F3F8a102d6Bf3EeaEAAe5d9ECAe88985eB2F` | reuse / ______ |
| GBPF | `0x1817FD23ceF7Da47DF934fdc880d72e653786770` | ______ |
| Vault | `0xA9a831a348D0Db372cf75dd7C082cFF67A453498` | ______ |
| Hook | `0x5613c279E8Db9815DBD0CdFbd10515EAbD350088` | ______ |
| Pool (v4 PoolKey) | bound to old Hook | bound to new Hook |
| BatchMinter | `0xD16D00e3eA0295cB5fCDB9e381171c8f7B101670` | ______ |
| BatchRedeemer | `0x7dd7cCd4BAb1494a274b95474b7d369717e2c188` | ______ |
| ForwarderMinter | `0x163e95500660bDF76D7F2dD97bb6F47d947C7226` | ______ |
| ForwarderRedeemer | `0x5b1c7dF048a7E4EbEA285B64Cb1FCa675044c9E2` | ______ |
| Gateway pool / BufferVault | `0xd478…df7e` / `0x6aB1…B7EC` | ______ |
| Keeper worker | `summer-field-d89b` | repoint vars |
| Web (gbpf-swap, gbpfv2/web) | old addrs | new addrs |

Unchanged externals: USDS `0x820C…21Dc`, sUSDS `0x5875…467a`, PoolManager `0x4985…2b2b`,
PSM3 `0x1601…347E`, Multicall3, Chainlink GBP/USD, SSR oracle.
