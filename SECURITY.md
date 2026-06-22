# GBPF v2 — Security Model

This document is the canonical reference for the protocol's security posture. It describes:
the threat model, every trust assumption, every external dependency, every fail-open / fail-closed
decision, the known residual risks, and how each component is verified.

It is intended to be the first document an auditor reads.

**Status:** in progress. Current scope: `src/SpreadCurve.sol`. Sections marked _(future)_ will be
populated as the corresponding modules are built (Vault, Hook, deploy script, oracle adapters).

---

## 1. Threat model

The protocol is an **immutable**, **permissionless** on-chain primitive on Base. There is no upgrade
path, no admin role, and no governance over normal operations. Once deployed, behaviour is determined
entirely by the code and by the on-chain state of its external dependencies.

The high-level commitments the protocol makes:

1. **Bounded overpayment (not solvent-by-construction).** The redeem haircut is capped at
   `S_MAX = 5%` one-sided, so at a shortfall the protocol can pay redeemers up to ~5% more than the
   true per-token backing. Below ~95% solvency redemptions therefore still draw slightly more than
   backing — a slow drain. This is a bounded, documented residual risk, mitigated by the deviation
   circuit-breaker (bounds how fast solvency can fall), the mint-side discount (pulls collateral in),
   and the redeem-side discount (discourages draining). The protocol is *not* solvent-by-construction
   in deep distress; a redeem-at-NAV mechanism would be required for that (see ROLLOUT notes).
2. **Bounded, knowable haircut for the last redeemer.** Even in deep distress the one-sided spread is
   capped at `S_MAX = 5%`, so the worst-case redeemer haircut (and mint premium) is knowable in advance.
3. **No silent loss of funds.** Beneficiary withdrawals can only flow to the hardcoded multisig.
   Vault funds can only leave via legitimate mint/redeem/beneficiary-withdraw flows.
4. **Availability under normal conditions.** Mint/redeem succeed whenever oracles are healthy and the
   sequencer is up.

The threats the protocol must defend against:

| Threat | Defence |
|---|---|
| Oracle manipulation (single-block) | TWAP on GBP/USD (5min) |
| Oracle catastrophic mispricing | Deviation circuit-breaker (>2% single update) |
| Oracle outage / staleness | Staleness pause (>26h) |
| Sequencer outage on Base | Chainlink L2 uptime feed + 1h recovery grace |
| Flash-crash arbitrage | Hysteresis pause cooldown (15min) |
| First-mint inflation attack | $1 atomic seed burned to address(0) at deploy |
| Beneficiary key compromise | Multisig (Gnosis Safe); signers can rotate, address cannot |
| Bridge compromise (SkyLink) | Accepted residual risk; canonical OP-Stack messenger only |
| Arithmetic overflow / underflow | Solidity 0.8.26 checked arithmetic + Solady's audited fixed-point |
| Arithmetic precision loss | Documented per-call; rounding-direction analysis; differential testing |
| MEV via deterministic unpause | Hysteresis cooldown makes unpause non-deterministic to attacker |

Out of scope (explicit non-defences):

- **Coinbase-controlled sequencer censorship.** Base has a single sequencer. Mitigation is the L2 uptime
  feed only; we cannot defend against transaction censorship at the sequencer level.
- **Sky/Spark/SkyLink governance compromise.** If Sky governance changes the SSR to a malicious value
  and the change is bridged to Base, the protocol's solvency math will use the malicious value.
- **Chainlink data feed compromise.** Chainlink GBP/USD is the sole oracle for GBP/USD on Base; no
  secondary push-feed exists. If Chainlink reports a wrong price within the deviation circuit-breaker
  threshold, the protocol prices mint/redeem against that wrong price.
- **Smart contract bugs in the dependencies themselves.** We trust Solady, v4-core, v4-periphery,
  Spark's SSRAuthOracle, and Chainlink contracts to be correctly implemented.

---

## 2. External dependencies and trust assumptions

Every contract or feed the protocol reads from is a trust dependency. They are listed below with
their failure mode if compromised and the protocol's reaction if any.

### 2.1 Chainlink GBP/USD feed (Base)

- Address: `0xCceA6576904C118037695eB71195a5425E69Fa15`
- Trust assumption: Chainlink's node operators report accurate GBP/USD prices within 24h heartbeat / 0.5% deviation tolerance.
- If compromised:
  - Within ±2% of the previous value: protocol prices mint/redeem against the bad value. **Direct loss possible.**
  - Greater than 2%: deviation circuit-breaker fires; pause for ≥15min.
  - Stops updating beyond 26h: staleness pause fires.
- Single point of failure. Pre-deploy verification: confirm address, heartbeat, deviation, decimals.

### 2.2 Chainlink L2 sequencer uptime feed (Base)

- Address: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
- Trust assumption: Chainlink correctly reports the Base sequencer's up/down status.
- If compromised: protocol may pause unnecessarily (false-positive) or accept transactions during a real
  sequencer outage (false-negative). False-positive is unavailability, not loss; false-negative is the
  worse case but is bounded by Chainlink's own price-feed staleness check below.
- Standard L2 protection; well-understood. Used for safety, not pricing.

### 2.3 Spark SSRAuthOracle (Base)

- Address: `0x65d946e533748A998B1f0E430803e39A6388f7a1`
- Trust assumption: Spark's bridged SSR rate reflects Sky's mainnet SSR within bounded delay; the
  underlying `chi`/`ssr`/`rho` accumulator math is correct.
- If compromised:
  - Stale `ssr`: protocol accrues yield at the wrong (old) rate. Bounded drift — single-digit basis
    points for typical delays.
  - Compromised `chi`: protocol over- or under-states collateral value. **Direct loss possible.**
  - Sanity bounds (`maxSSR`, monotonic `chi`) in the oracle limit the magnitude of a single bad update.
- Trust path: Base canonical OP-Stack messenger → Spark L1 authority `0xB2833…f188E`. No third-party bridge.

**Interface quirks (verified by fork test):**
- `getChi()` returns the raw stored chi (last bridge update), **not** extrapolated to the current block.
- `getConversionRate()` returns chi extrapolated to `block.timestamp` using SSR × elapsed time.
- `getSSR()` stores `(1 + per_second_rate)` in ray — neutral (0% APY) is `1e27`, not `0`.

The Vault calls `getConversionRate()` (not `getChi()`) so yield accrues continuously between bridge updates rather than in lumps at bridge messages.

### 2.4 sUSDS and USDS tokens on Base

- sUSDS: `0x5875eEE11Cf8398102FdAd704C9E96607675467a` (SkyLink-bridged, plain ERC-20)
- USDS: `0x820C137fa70C8691f0e44Dc420a5e53c168921Dc` (SkyLink-bridged, plain ERC-20)
- Trust assumption: SkyLink bridge correctly mirrors Ethereum-side mints/burns to Base balances.
- If compromised: bridge minting unauthorised tokens would silently inflate vault collateral or supply.
  No on-chain detection possible from the protocol's side.

### 2.5 Uniswap V4 PoolManager (Base)

- Address: `0x498581fF718922c3f8e6A244956aF099B2652b2b`
- Trust assumption: Uniswap V4 PoolManager correctly orchestrates swap flow, flash-accounting,
  hook callbacks, and delta settlement per Uniswap's documented semantics.
- If compromised: arbitrary outcomes for in-flight swaps. Out of protocol's control.

### 2.6 Solady FixedPointMathLib

- Library, not address.
- Trust assumption: `mulWad`, `divWad`, `expWad` behave per their documented semantics and rounding
  rules.
- Verified by: maintained by `vectorized/solady`, used in production by many DeFi protocols,
  documented rounding (see `SpreadCurve.sol` inline notes), differential tested in
  `test/SpreadCurveDifferential.t.sol`.

### 2.7 Beneficiary multisig

- Address: TBD (deployed before hook; hardcoded immutably into hook)
- Type: Gnosis Safe or equivalent multisig contract on Base mainnet
- Trust assumption: signers act in good faith; threshold prevents single-key compromise.
- If compromised: beneficiary share (fees + 50% yield) is captured by attacker.
- **Vault funds are *not* at risk** — the multisig has no admin role over the protocol; it can only
  receive `pendingBeneficiarySUsds` via the permissionless `withdrawBeneficiary()` flow.

---

## 3. Module: SpreadCurve

**Path:** `src/SpreadCurve.sol`
**Type:** Pure library, internal functions only, no storage, no external calls.

### 3.1 Surface

Two functions:

- `spread(uint256 solvencyWad) → int256 spreadWad`
- `tanhWad(uint256 xWad) → uint256` (internal helper, also externally testable)

### 3.2 Invariants

The library is responsible for these properties holding for **every** input in its declared range:

| Invariant | Verified by |
|---|---|
| `|spread(s)|` ≤ `S_MAX` for all `s ∈ [0, 10·WAD]` | `testFuzz_spread_bounded` (10k runs), `invariant_spread_always_bounded` (8192 calls) |
| `spread(s) == 0` for all `s ≥ 1·WAD` (one-sided: no surplus-side spread) | `test_spread_at_100pct_is_zero`, `testFuzz_spread_zero_at_or_above_peg`, `test_surplus_spread_is_zero` |
| Monotonic discount below peg (deeper discount as solvency falls) | `testFuzz_spread_monotonic_below_peg` (10k runs) |
| `spread(s) ≤ 0` everywhere; strictly negative only below peg | `testFuzz_spread_sign` (10k runs) |
| Shortfall is a discount, never a premium (anti-drain): redeem priced below peg at a shortfall | `test_shortfall_spread_is_discount`, `test_shortfall_redeem_priced_below_peg`, `test_shortfall_mint_not_premium` |
| `tanhWad(x)` ≤ `WAD` for all `x ≥ 0` | `testFuzz_tanh_bounded`, `invariant_tanh_always_bounded` |
| `tanhWad(x)` monotonically non-decreasing | `testFuzz_tanh_monotonic` |
| `tanhWad(x)` saturates at exactly `WAD` for `x ≥ 20·WAD` | `test_tanh_saturates` |
| Out-of-range `solvencyWad > MAX_SOLVENCY_WAD` reverts with `SolvencyOutOfRange` | (covered implicitly by fuzz; an explicit test could be added) |

### 3.3 Numerical precision

Per `src/SpreadCurve.sol` inline notes:

- `mulWad` rounds **down**. Net effect across the spread computation: precision loss at the
  sub-wei (1e-15 WAD) level, direction unspecified at that magnitude.
- `divWad(2, denom)` inside `tanhWad` rounds **down**, making `tanhWad` very slightly
  **larger** than mathematical truth (≤ 1 wei).
- `expWad`: well-documented; reverts at input ≥ ~135·WAD; returns 0 at input ≤ ~-41·WAD. Neither
  bound is approached by `tanhWad` because the `xWad < 20·WAD` clamp short-circuits before the
  doubling step.

**Differential test** (`test/SpreadCurveDifferential.t.sol`): 222 vectors generated by a Python
reference implementation using stdlib `math.tanh` (~15 decimal digits precision). Maximum observed
divergence between Solidity and Python: **68 wei** at solvency ~104.3%, vs a 10,000 wei tolerance.
Approximately 150× headroom.

### 3.4 Safety analysis of integer casts

All casts in `src/SpreadCurve.sol` are individually justified with `forge-lint: disable-next-line(unsafe-typecast)`:

1. `int256(mag)` where `mag ≤ S_MAX = 5e16`: trivially safe (≪ 2^255).
2. `int256(xWad * 2)` where `xWad < 20e18` after the saturation clamp: `xWad * 2 < 40e18 ≪ 2^255`.
3. `uint256(e2x)` where `e2x = expWad(twoX)` with `twoX ≥ 0`: `expWad` of a non-negative input
   is always positive, cast cannot wrap.

Input validation: `spread()` reverts with `SolvencyOutOfRange` if `solvencyWad > MAX_SOLVENCY_WAD`
(10·WAD). This bounds all downstream arithmetic to a known safe range, making the casts above
provably safe.

### 3.5 What we have NOT done for this module

- **Formal verification.** A Halmos or Certora proof of boundedness and monotonicity for all
  `2^256` inputs would strengthen the bound test (currently 10k fuzz + 8k invariant runs).
- **Static analysis.** Slither was attempted but is currently deferred — pure libraries with no
  storage / external calls / access control are a thin target for slither's high-value detectors.
  Will run against the full stack (Vault + Hook) once they exist.
- **Mutation testing.** No `slither-mutate` or similar pass has been run to confirm the test suite
  fails on intentionally-broken implementations.
- **Gas profile under hostile inputs.** Sanity gas (~1k–2k per call) is bounded but not stress-tested.

These are acceptable gaps **only because** subsequent modules will be the higher-value targets for
each of these techniques, and the curve will be re-verified as part of the full-stack passes.

---

## 4. Module: Vault

**Path:** `src/Vault.sol`
**Type:** Immutable stateful contract. Custody of sUSDS, beneficiary-share accounting. No owner, no admin, no upgrade path.

### 4.1 Surface

External / hook-only:
- `deposit(uint256 sUsdsAmount, uint256 feeAmount)` — HOOK only. Records an incoming mint deposit.
- `withdraw(uint256 sUsdsAmount, address to, uint256 feeAmount)` — HOOK only. Pays sUSDS to a redeemer.

External / permissionless:
- `settle()` — advance yield-share index without transferring.
- `withdrawBeneficiary()` — settle then forward `pendingBeneficiarySUsds` to the hardcoded BENEFICIARY.

Views:
- `solvencyInputs()` — non-view; settles then returns `(balance, pending, ssrRate)`.
- `previewSolvencyInputs()` — view; same data including unsettled yield.
- `backingBalance()` — view; principal currently backing GBPF, including unsettled yield.

### 4.2 Invariants

Verified by `test/Vault.t.sol` (27 unit + fuzz tests) and `test/invariants/VaultInvariants.t.sol` (3 invariants × 8192 random call sequences):

| Invariant | Verified by |
|---|---|
| `pendingBeneficiarySUsds <= SUSDS.balanceOf(this)` | `testFuzz_pending_never_exceeds_balance` (10k), `invariant_pending_never_exceeds_balance` |
| `lastSettledChi` is monotonically non-decreasing | `testFuzz_lastSettledChi_monotonic` (10k), `invariant_lastSettledChi_never_exceeds_oracle` |
| `deposit` / `withdraw` revert if caller != HOOK | `test_deposit_revertsIfNotHook`, `test_withdraw_revertsIfNotHook` |
| `withdraw` reverts if `sUsdsAmount + feeAmount > principalSUsds` | `test_withdraw_blocked_when_exceeds_backing` |
| `deposit` reverts if `feeAmount > sUsdsAmount` | `test_deposit_feeExceedsAmount_reverts` |
| `withdrawBeneficiary` always sends to the hardcoded `BENEFICIARY` | `test_withdrawBeneficiary_is_permissionless` |
| Conservation: `ghostMintInflow == vaultBalance + ghostRedeemOutflow + ghostBeneficiaryWithdrawn` | `invariant_conservation_of_sUsds_shares` |

### 4.3 Yield-share accounting

The beneficiary multisig receives:
- 100% of `feeAmount` passed by the hook on `deposit` / `withdraw`.
- 50% of yield accruing on `principalSUsds` between settlements.

Yield credit derivation (full reasoning inline in `_settleBeneficiaryYield`):

```
credit = principal * chiDelta * NUM / (currentChi * DENOM)
```

with `NUM=1`, `DENOM=2`. Two correctness-critical details:

1. **Divide by `currentChi`, not `lastChi`.** The credit is the *current* sUSDS share value of the beneficiary's USDS claim; using `lastChi` would over-state it by the proportional growth.
2. **Use `principalSUsds`, not the live vault balance.** Newly-arrived deposits MUST NOT retroactively earn yield they did not accrue. This was caught by invariant fuzzing — the initial "balance - pending" formulation over-credited under same-block deposit-then-settle sequences.

### 4.4 Rounding

`credit` is integer-divided by `currentChi * DENOM`, rounding **down**. The truncated remainder stays in the vault as principal, which compounds for future settlements. This is the protocol-safe direction: the beneficiary receives slightly less than the mathematically exact share, with the residue benefiting GBPF holders via solvency.

### 4.5 Trust model for `deposit` / `withdraw`

The HOOK is trusted to:
- Transfer `sUsdsAmount` of sUSDS into the vault before calling `deposit()`.
- Pass `feeAmount` values consistent with its own pricing math.

Defence-in-depth:
- `deposit()` verifies `feeAmount <= sUsdsAmount` even though the hook is the only authorised caller — turns a buggy hook into a revert rather than a silent over-credit.
- `withdraw()` verifies `sUsdsAmount + feeAmount <= principalSUsds` — caught a real bug during invariant fuzzing where the previous check (`sUsdsAmount <= backing`) allowed `feeAmount` to push `pendingBeneficiarySUsds` above the vault balance.

### 4.6 What we have NOT done for this module

- **Fork tests against the real SSRAuthOracle on Base.** Pending; mock-based tests confirm the math; fork tests confirm the integration.
- **Formal verification of the conservation invariant** (a Halmos/Certora pass).
- **Slither pass.** Deferred until Hook is in.

---

## 5. Module: OracleAdapter

**Path:** `src/OracleAdapter.sol`
**Type:** Immutable stateful contract. Owns GBP/USD pricing and operational health for the hook.

### 5.1 Surface

- `update()` — state-changing; pulls latest Chainlink, advances cumulative integral if new, evaluates pause conditions, returns `(twapWad, healthy, pausedUntil)`. Called by hook on every swap.
- `preview()` — view; same return, no mutation. For off-chain monitors.
- `latestPriceWad()` — view; most recent Chainlink answer in WAD.

### 5.2 Invariants and behaviours verified

| Property | Verified by |
|---|---|
| TWAP at constant price equals that price | `test_twap_constant_price_returns_that_price` |
| TWAP at single step is time-weighted correctly | `test_twap_step_change_is_time_weighted`, `test_twap_step_change_mid_window_is_blend` |
| Staleness pause fires at MAX_STALENESS+1 | `test_staleness_pauses_when_chainlink_too_old` |
| Staleness pause does not fire at MAX_STALENESS-1 | `test_staleness_does_not_pause_within_window` |
| Deviation circuit-breaker fires on >2% step | `test_deviation_triggers_on_large_step` (both directions) |
| Deviation circuit-breaker does not fire on <2% step | `test_deviation_does_not_trigger_on_small_step` |
| Sequencer down triggers pause | `test_sequencer_down_pauses` |
| Within-grace recovery triggers pause | `test_sequencer_recently_recovered_within_grace_pauses` |
| Past-grace recovery is OK | `test_sequencer_recovered_past_grace_is_ok` |
| Pause persists for full cooldown | `test_pause_persists_for_full_cooldown` |
| Innocuous updates don't shorten the cooldown | `test_new_trigger_extends_cooldown_not_reduces` |
| After cooldown expires, new trigger re-arms cleanly | `test_new_trigger_after_cooldown_arms_again` |
| `preview()` matches `update()` when no state change | `test_preview_matches_update_when_nothing_changed` |
| `preview()` does not mutate state | `test_preview_does_not_mutate_state` |

### 5.3 TWAP design choice

Cumulative-sum accumulator anchored to **Chainlink's update cadence** (not to swap cadence). When Chainlink reports a new observation, we extend the integral by `previousPrice × (newUpdatedAt − previousUpdatedAt)` and store a snapshot. Between Chainlink updates, the price is by convention unchanged, so the TWAP "extension up to now" uses the last Chainlink price.

This means:
- Swap frequency does not skew the TWAP.
- TWAP is correct over any window the ring covers (64 snapshots; under 24h Chainlink heartbeat, the ring effectively never wraps).
- Cumulative storage cost is low: one storage slot per Chainlink update, not per swap.

### 5.4 Circuit-breaker semantics

The 2% deviation check compares **successive Chainlink answers**, not the current Chainlink answer to some moving average. This means:
- A single 6% flash-crash update fires the circuit-breaker.
- A gradual 6% move spread across 12× 0.5% updates does NOT fire the circuit-breaker — those updates trickle through and the curve handles the solvency drift.

This is intentional and reflects the committed semantics in `project_gbpf_pause.md`.

### 5.5 What we have NOT done for this module

- **Fork tests against the real Base Chainlink feed and sequencer-uptime feed.** Pending; mock tests verify the math; fork tests verify the integration.
- **Invariant test harness.** The pure-curve and Vault modules have invariant harnesses; OracleAdapter would benefit from one that exercises chains of `update()` calls with random oracle inputs. Deferred to when we wire it into the Hook.
- **Slither pass.** Deferred until Hook is in.

---

## 6. Module: GBPF token

**Path:** `src/GBPF.sol`
**Type:** Immutable Solady ERC20 with EIP-2612 permit. 18 decimals. Name "GBP Float", symbol "GBPF".

### 6.1 Surface

- `mint(to, amount)` — HOOK only. Reverts if `to == address(0)` (explicit guard — Solady's `_mint` permits zero-address mints which would lock tokens forever).
- `burn(amount)` — HOOK only. Burns from `msg.sender` (= HOOK). The hook is expected to hold the tokens before calling, having received them via Uniswap V4's settlement flow.

Standard ERC20 functions (`transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `totalSupply`, `permit`, `nonces`, `DOMAIN_SEPARATOR`) are inherited from Solady.

### 6.2 Trust model

- HOOK is the sole authority on supply. No owner, no admin, no pausing of the token itself (pause is enforced upstream at the hook layer; a paused hook simply doesn't call mint/burn).
- No blocklists. No transfer hooks beyond standard ERC20.
- No `selfdestruct`, no `delegatecall`, no upgrade.

### 6.3 burn-from-self design choice

Earlier draft accepted `burn(from, amount)` allowing the hook to burn from arbitrary addresses. Rejected in favour of `burn(amount)` operating on `msg.sender`'s balance because:
- V4's swap settlement moves the user's GBPF to the hook as part of the swap itself — no separate approval needed for the user→hook leg.
- The token contract enforces a balance check at `_burn`; the hook cannot burn what it doesn't hold.
- Eliminates an attack surface where a buggy hook could be tricked into burning the wrong user's tokens.

### 6.4 Verified properties

| Property | Verified by |
|---|---|
| name/symbol/decimals correct | `test_name`, `test_symbol`, `test_decimals` |
| Initial supply zero | `test_initial_supply_is_zero` |
| HOOK address immutable | `test_hook_address_immutable` |
| Only HOOK can mint | `test_mint_by_hook_succeeds`, `test_mint_by_random_address_reverts`, `test_mint_by_alice_reverts` |
| Mint to zero address reverts | `test_mint_to_zero_address_reverts` |
| Only HOOK can burn; burns from self | `test_burn_by_hook_from_self_succeeds`, `test_burn_by_random_address_reverts` |
| Cannot burn more than HOOK balance | `test_burn_more_than_hook_balance_reverts` |
| Zero burn is no-op | `test_burn_zero_succeeds` |
| Transfer, transferFrom, allowance behave as standard ERC20 | `test_transfer_works`, `test_transferFrom_with_approval_works`, `test_transfer_exceeds_balance_reverts` |
| Permit grants allowance with valid sig | `test_permit_grants_allowance` |
| Permit rejects bad signature | `test_permit_with_bad_signature_reverts` |
| Permit rejects expired deadline | `test_permit_after_deadline_reverts` |
| Total supply tracks mint/burn sequences (fuzz) | `testFuzz_supply_tracks_mints_and_burns` (10k runs) |

### 6.5 What we have NOT done for this module

- **Invariant test harness.** Token is simple enough that the unit + fuzz coverage above is comprehensive; an invariant harness would be redundant.
- **Slither pass.** Deferred until Hook is in.

---

## 7. Module: Hook

**Path:** `src/Hook.sol`
**Type:** Immutable V4 hook contract. The protocol. Composes Curve + Vault + OracleAdapter + GBPF + Spark PSM3.

### 7.1 Surface

- `beforeSwap(address, PoolKey, SwapParams, bytes)` — the only functional callback. All other IHooks callbacks revert `InvalidHookCall` (the corresponding flag bits are not set on the hook's mined CREATE2 address, so PoolManager will never invoke them, but the reverts are defence-in-depth).

### 7.2 Trust gates

| Check | Where | If it fails |
|---|---|---|
| `msg.sender == POOL_MANAGER` | beforeSwap top | reverts `NotPoolManager` |
| `keccak256(key) == POOL_KEY_HASH` | beforeSwap | reverts `WrongPool` |
| `amountSpecified != 0` | beforeSwap | reverts `ZeroSwap` |
| Oracle `healthy == true` | after `ORACLE.update()` | reverts `OraclePaused` |
| `gbpfSupply > 0` | post-bootstrap invariant | reverts `InvalidHookCall` |

### 7.3 Pricing

```
priceMultiplier_mint   = WAD + spread + FLAT_FEE_WAD     // both signed; cast safe in operating regime
priceMultiplier_redeem = WAD + spread - FLAT_FEE_WAD
mintPriceUsdsPerGbpf   = twap * priceMultiplier_mint   / WAD
redeemPriceUsdsPerGbpf = twap * priceMultiplier_redeem / WAD
```

Exact-input rounds **down** (protocol favourable); exact-output rounds **up** (protocol favourable).

### 7.4 Token movement

- **Mint:** `PoolManager.take(USDS) → PSM3.swapExactIn(USDS→sUSDS, recv=vault) → Vault.deposit(sUSDS, fee) → GBPF.mint(self) → sync/transfer/settle(GBPF)`.
- **Redeem:** `PoolManager.take(GBPF) → GBPF.burn → PSM3.previewSwapExactOut → Vault.withdraw(sUSDS, self, fee) → PSM3.swapExactOut(sUSDS→USDS, recv=self) → sync/transfer/settle(USDS)`.

PSM3 uses the same SSRAuthOracle the Vault reads, so `previewSwap*` agrees with our solvency math exactly within a block. No basis risk.

### 7.5 Verified properties

13 hook tests + integration with all other modules. See `test/Hook.t.sol`.

### 7.6 What we have NOT done for this module

- Slither pass (deferred).
- Invariant tests across random swap sequences.
- Fork test that exercises the hook end-to-end against the real PoolManager (the existing fork tests only deploy and verify wiring).
- The 20 int128/int256 casts in `beforeSwap` delta construction still carry lint warnings. All safe by construction (amounts ≤ uint256.max → fit in int128 since they come from int256), to be annotated.

---

## 8. Deploy

**Paths:** `script/Deploy.s.sol`, `script/HookMiner.sol`

### 8.1 Circular dependency resolution: one-shot `initialize(hook)`

The Hook's CREATE2 address must encode V4 flag bits (BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA), and its constructor takes Vault and GBPF addresses. So:

- Vault and GBPF constructors do NOT take the hook address.
- Both contracts expose `initialize(address hook)` callable exactly once. After the call, HOOK is fixed forever.
- All hook-only functions (`deposit`, `withdraw`, `mint`, `burn`) revert `NotInitialized` if called before initialize.

**Audit must confirm:**
- `initialize` reverts `AlreadyInitialized` on second call.
- `initialize` reverts `ZeroHook` on null input.
- No other path can change `HOOK`.

### 8.2 Verified properties (`DeployForkTest`, 7 tests)

- Deploy script succeeds against Base mainnet at block 46,700,000.
- Hook address has exactly `BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG` in its low 14 bits and no other hook flag bits.
- OracleAdapter, Vault, and Hook are wired to the real Base addresses we hardcoded.
- Vault.lastSettledChi is seeded from the real Spark oracle's `getConversionRate()`.
- `initialize()` on Vault and GBPF reverts when re-called post-deploy.
- Hook has max allowances to PSM3 for both USDS and sUSDS.

### 8.3 Seed-and-burn

Performed by the operator post-deploy, not by the script (see DEPLOY_DESIGN.md for the design rationale). The operator must:

1. `PoolManager.initialize()` with the canonical PoolKey.
2. Pre-mint 1 wei of GBPF (avoids `gbpfSupply == 0` revert) via exact-output mint.
3. Execute a 1 USDS exact-input mint swap.
4. Transfer all resulting GBPF to `0xdEaD`.

**Front-running risk:** between contracts-deployed and seed-completed, an attacker could initialise the V4 pool first or execute the seed swap themselves. Neither extracts value — they pay 1 USDS for ~0.8 GBPF at oracle price, the protocol is bootstrapped as intended, only the GBPF beneficiary differs.

---

## 9. Modules _(future, populated as built)_

- 9.1 **Fork test of full hook flow** — exercise the hook end-to-end against real PoolManager
- 9.2 **Invariant tests on the hook** — random swap sequences

---

## 10. Deployment posture _(future)_

To be populated before mainnet deploy:

- Audit history (firms, scope, findings, remediations)
- Formal verification report
- Bug bounty programme (platform, scope, payouts)
- TVL cap during initial period (if any) and how it's enforced in-contract
- Deterministic address derivation (CREATE2 salt and bytecode hash)
- On-chain verification on Basescan
- Mainnet deployer multisig configuration (if used)

---

## 11. Changelog

| Date | Change | Affected modules |
|---|---|---|
| 2026-06-03 | Initial doc | SpreadCurve |
| 2026-06-03 | Added Vault module + invariants. Caught two real bugs via fuzz/invariant testing: (a) yield-share formula divided by lastChi instead of currentChi, (b) `withdraw` allowed `feeAmount` to push `pendingBeneficiarySUsds` above vault balance. Both fixed before any code shipped. | Vault |
| 2026-06-03 | Added OracleAdapter module. Cumulative-sum TWAP anchored to Chainlink update cadence; all five committed pause triggers (staleness, deviation, sequencer-down, sequencer-grace, hysteresis) verified by unit tests. Lint-clean after annotating intentional block.timestamp / cast sites. | OracleAdapter |
| 2026-06-03 | Added GBPF token. Solady ERC20 + permit, hook-only mint/burn, burn-from-self design to avoid arbitrary-from attack surface. | GBPF |
| 2026-06-03 | Added fork tests against real Base mainnet infrastructure. Caught two real bugs in our assumptions about Spark's SSRAuthOracle: (1) `getChi()` returns the raw stored chi (stale between bridge updates), NOT the extrapolated value — Vault must use `getConversionRate()` instead, or yield would only accrue in lumps at bridge messages; (2) `getSSR()` returns `1 + per_second_rate` in ray (neutral = 1e27), not the differential. Vault rewired to `getConversionRate()`; ISSRAuthOracle interface doc corrected; MockSSRAuthOracle split into separate storedChi/conversionRate fields so the regime is exercised in unit tests too. | Vault, ISSRAuthOracle, MockSSRAuthOracle |
| 2026-06-03 | Added Hook (V4 integration) with end-to-end tests. 13/13 tests pass covering mint/redeem × exact-input/exact-output, oracle-pause guard, wrong-pool guard, only-PoolManager guard. Uses Spark PSM3 at `0x1601843c5E9bC251A3272907010AFa41Fa18347E` for atomic USDS↔sUSDS conversion at the same SSR oracle rate the Vault reads. | Hook |
| 2026-06-06 | Refactored Vault and GBPF for one-shot `initialize(hook)` to resolve the circular deploy dependency (Hook's CREATE2 address must encode V4 flag bits; its constructor takes Vault and GBPF addresses). Vault and GBPF now have non-immutable `HOOK` set exactly once via `initialize`. Added 9 tests for the initialize semantics. Trust model: protocol is "deploy-script-immutable" — only the deploying transaction can call `initialize`, and re-calls revert `AlreadyInitialized`. | Vault, GBPF |
| 2026-06-06 | Added HookMiner library for V4 hook salt mining. Iterates CREATE2 salts until the resulting address has exactly the required hook flag bits in its low 14 bits (0x88) and no other bits set. ~3000 iterations on average for our 2-bit pattern. | HookMiner |
| 2026-06-06 | Added Deploy script and fork test against Base mainnet. Script mines the hook salt, deploys all five contracts in order, calls initialize on Vault and GBPF. Pre-flight checks verify all hardcoded Base addresses are live and the SSR oracle reports a sane rate. Seed-and-burn is deferred to the operator post-deploy (DEPLOY_DESIGN.md "seed on mainnet" covers the front-running analysis). Fork test confirmed: deploy succeeds against real Base infrastructure, all wiring correct. | Deploy, HookMiner |
| 2026-06-06 | Confirmed oracle architecture: single Chainlink GBP/USD feed, no admin-controlled fallback. The protocol's pause logic (staleness, deviation, sequencer, hysteresis) is the no-admin failure-handling mechanism. If Chainlink fails, the protocol pauses; users can redeem after Chainlink recovers. The alternative — admin-controlled price feeds — would defeat immutability. Documented as an intentional design choice, not a limitation. | (design only) |
