# V4 6909-claims refactor — required before mainnet

## What the fork test discovered

Real PoolManager fork test (`test/fork/Hook.fork.t.sol`) revealed that the Hook's current mint/redeem flow **does not work** against the real V4 PoolManager. It only worked against my mock because the mock didn't enforce V4's flash-accounting ordering.

The bug: `_handleMint` calls `POOL_MANAGER.take(USDS, address(this), usdsIn)`. In V4, `take` does a real ERC20 `transfer` from PoolManager. But the PoolManager does not yet hold the user's USDS at that point — the user's USDS isn't delivered until the *router* settles, which happens after `beforeSwap` returns.

Symptom on the real chain: `Usds/insufficient-balance` revert inside `beforeSwap`.

## The fix: 6909 claims + deferred PSM3 conversion

Inside `beforeSwap`, the Hook cannot acquire real ERC20s. It can only:
- Mint V4 6909 claim tokens, which create a hook-side debt that the router settles later.
- Sync + transfer + settle tokens it already holds (output side).

So the mint flow becomes:

1. **Inside beforeSwap (mint):**
   - `PM.mint(VAULT, USDS_id, usdsIn)` — Vault gets a 6909 USDS claim. Hook is debited usdsIn USDS.
   - `Vault.recordMint(usdsIn, feeUsds)` — Vault records pending claim + beneficiary fee portion.
   - `GBPF.mint(self, gbpfOut)` — Hook gets real GBPF.
   - `PM.sync(GBPF); GBPF.transfer(PM, gbpfOut); PM.settle()` — PM owes user the GBPF.
   - Return BeforeSwapDelta describing the trade.
   - Router-side settlement (after `swap()` returns) transfers user's USDS to PM. PM now holds it.

2. **Later (any time, anyone calls):** `Vault.flush()`:
   - Calls `PM.unlock` with self as IUnlockCallback.
   - Inside callback: `PM.burn(self, USDS_id, claim); PM.take(USDS, self, claim);` — Vault now holds real USDS.
   - `PSM3.swapExactIn(USDS, sUSDS, claim, ..., self)` — Vault converts USDS → sUSDS.
   - Credits `principalSUsds` and `pendingBeneficiarySUsds` proportionally.
   - For pending GBPF claims (from redeems): `PM.burn; PM.take; GBPF.burn`.

Similarly for redeem:

1. **Inside beforeSwap (redeem):**
   - `PM.mint(VAULT, GBPF_id, gbpfIn)` — Vault gets 6909 GBPF claim, hook is debited.
   - `Vault.recordRedeem(sUsdsForUser, gbpfIn, feeSUsds)`:
     - Vault transfers `sUsdsForUser` sUSDS to the Hook (for PSM3 conversion).
     - Vault records the GBPF claim + credits beneficiary fee.
   - Hook calls `PSM3.swapExactOut(sUSDS, USDS, usdsOut, ...)` to get real USDS.
   - `PM.sync(USDS); USDS.transfer(PM, usdsOut); PM.settle()` — PM owes user the USDS.

## Implementation status

Stage 1 (Vault refactor) and stage 2 (Hook refactor) were drafted but stashed because they need extensive test-suite rewrites that don't fit in one session. The stashed work compiles for the production contracts but breaks all tests because:

- Vault constructor signature changes from `(beneficiary, sUSDS, ssrOracle)` to `(beneficiary, sUSDS, USDS, GBPF, ssrOracle, PSM3, PoolManager)`.
- Vault `deposit(amount, fee)` → `recordMint(usdsClaim, feeUsds)`.
- Vault `withdraw(amount, to, fee)` → `recordRedeem(sUsdsToHook, gbpfClaim, feeSUsds)`.
- `solvencyInputs()` returns 4 values now (adds `usdsClaimBacking`).
- Hook's `_handleMint` / `_handleRedeem` rewritten to use PM.mint + Vault.recordMint/recordRedeem.
- New `Vault.flush()` and `unlockCallback` for the deferred conversion.

To resume:

```
git stash pop          # restore the WIP changes
forge build            # production contracts will compile
forge test ...         # ~50+ test failures expected; needs rewrite
```

## Test-suite work required to resume

1. **MockPoolManager** needs to support `mint(addr, id, amount)` and `burn(addr, id, amount)` for 6909 + `unlock()` returning data + a way to track 6909 balances and verify `burn` matches a prior `mint`.

2. **Vault unit tests** (`test/Vault.t.sol`) need full rewrite: no more direct `deposit`/`withdraw`, all flows happen through `recordMint`/`recordRedeem` and `flush`. The tests should cover:
   - `recordMint` accumulates `pendingUsdsClaim` and `pendingBeneficiaryUsdsClaim`.
   - `recordRedeem` accumulates `pendingGbpfClaim`, transfers sUSDS to hook, credits beneficiary in sUSDS.
   - `flush` reverts `NothingToFlush` when both pending counters are zero.
   - `flush` correctly burns 6909, takes real tokens, runs PSM3, updates principalSUsds + pendingBeneficiarySUsds.
   - `flush` correctly burns GBPF claims.
   - `unlockCallback` reverts `NotPoolManager` when called externally.
   - `unlockCallback` reverts `ReentrantUnlock` when called outside of flush.

3. **Vault invariant tests** need the new conservation invariant: `principalSUsds + pendingBeneficiarySUsds == sUSDS.balanceOf(vault)` AFTER settle (unchanged) + `pendingUsdsClaim` and `pendingGbpfClaim` are conserved through swap-then-flush cycles.

4. **Hook unit tests** need the mock PM updated for 6909, and the assertion logic updated: after a mint, the vault now holds a 6909 USDS claim (not sUSDS), and `principalSUsds` doesn't grow until flush.

5. **Hook fork test** should now actually work end-to-end. After fixing setUp's `_giveUsds` (already done — whale-prank from Spark PSM3), the swap should succeed and a subsequent `vault.flush()` call should convert claims to sUSDS in the vault.

6. **Deploy script** needs the new Vault constructor signature.

## Trade-offs accepted by this refactor

- **Per-swap gas down ~35%**: PSM3 + vault.deposit work moves out of beforeSwap.
- **Total system gas up if flush per swap, down if batched**: keeper economics make batched flushes natural.
- **Pending USDS claims earn no SSR yield**: brief windows of lost yield. At 5% APY, $100k unflushed for 1 day = ~$14. Daily flush is fine; hourly is better.
- **Solvency math is dirtier**: now includes the USDS claim term. Documented as design intent ("pending claims back GBPF at 1:1 USDS-value").
- **Anyone can call flush**: permissionless. Keeper economics: whoever has a stake in the protocol runs it (deployer, beneficiary, even users who want healthy-looking solvency). Failure-mode is benign: unflushed claims sit at PM, no funds lost.
- **New attack surface**: Vault is now an IUnlockCallback. Audit must verify the `_unlocking` guard and `msg.sender == POOL_MANAGER` check are correct, and that `flush` can't be re-entered.

## Audit briefing summary

The Hook does not interact with PSM3 anymore. The Vault does, asynchronously, via `flush()`. The Hook's only responsibilities during a swap are:
- Pricing math from oracle TWAP + spread curve + flat fee.
- Mint 6909 claims to Vault (input side).
- Mint GBPF to self and settle to PM (mint case) OR convert sUSDS to USDS via PSM3 and settle to PM (redeem case).
- Update Vault's pending counters via `recordMint` / `recordRedeem`.

The Vault's only responsibilities:
- Hold sUSDS principal + beneficiary's accrued share.
- Track pending USDS claims (mint side) and GBPF claims (redeem side).
- Convert pending claims to real assets on `flush()`.
- Yield share accounting (unchanged).
