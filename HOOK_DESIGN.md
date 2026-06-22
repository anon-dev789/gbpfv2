# Hook design

Authoritative spec for `src/Hook.sol`. Written before implementation; any deviation in the code requires updating this doc.

## Responsibilities

The hook is the protocol. It owns the swap path through Uniswap V4 and composes Curve + Vault + OracleAdapter + GBPF token + Spark PSM3 into atomic mint/redeem operations.

Per swap, the hook:
1. Pulls the latest oracle TWAP + health from `OracleAdapter.update()`.
2. Reverts if the oracle reports unhealthy (any pause condition active).
3. Reads `Vault.solvencyInputs()` (which settles yield as a side effect).
4. Computes solvency `s` in WAD.
5. Computes the spread for `s` via `SpreadCurve.spread`.
6. Computes the swap output via the pricing formula below.
7. Moves tokens: USDS ↔ sUSDS via Spark PSM3, vault deposit/withdraw, GBPF mint/burn.
8. Returns a `BeforeSwapDelta` that tells V4's PoolManager the hook handled the trade fully.

## V4 plumbing

### Flags

The hook sets exactly two flags:
- `BEFORE_SWAP_FLAG = 1 << 7`
- `BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3`

The contract's address must have bits 7 and 3 of its low 14 bits set, and no other hook bits. Enforced at deploy via CREATE2 salt mining.

### Pool key binding

At construction, the hook records the exact `PoolKey` it expects:
- `currency0 = min(USDS, GBPF)`, `currency1 = max(USDS, GBPF)`
- `fee = 0` (we set the V4 LP fee to zero; our fee mechanism is bespoke)
- `tickSpacing = 1` (irrelevant — no liquidity is added)
- `hooks = address(this)`

On every `beforeSwap` call, the hook verifies the passed `PoolKey` matches this binding. Mismatch → `WrongPool` revert. This blocks attacks where an attacker creates a different pool pointing at our hook to abuse the price logic.

### Direction interpretation

At deploy: `USDS_IS_TOKEN0 = address(USDS) < address(GBPF)`.

In `beforeSwap`:
- `mint` (USDS → GBPF) when `params.zeroForOne == USDS_IS_TOKEN0`
- `redeem` (GBPF → USDS) otherwise

### Exact-input and exact-output both supported

V4 distinguishes exact-input (`params.amountSpecified < 0`) from exact-output (`params.amountSpecified > 0`). Both paths are implemented.

The curve is *not* being inverted — we read solvency `s` from the vault, compute `spread(s)` once, and that gives a linear price multiplier. The exact-output paths just invert that linear formula:

- Mint exact-input:  `gbpfOut = usdsIn * WAD / mintPriceUsdsPerGbpf` (round down)
- Mint exact-output: `usdsIn = gbpfOut * mintPriceUsdsPerGbpf / WAD` (round up)
- Redeem exact-input:  `usdsOut = gbpfIn * redeemPriceUsdsPerGbpf / WAD` (round down)
- Redeem exact-output: `gbpfIn = usdsOut * WAD / redeemPriceUsdsPerGbpf` (round up)

In all four cases the rounding direction protects the protocol: user gets at most the computed output (exact-input) or pays at least the computed input (exact-output).

### sqrtPriceLimit handling

Ignored. Our hook doesn't use a sqrt price; it computes the trade against the oracle directly. The hook does not need to honour `params.sqrtPriceLimitX96`.

### Delta semantics

In V4 with `beforeSwap` returning a delta and the `RETURNS_DELTA` flag set, the hook fully handles the trade. The returned `BeforeSwapDelta` has two halves (packed into one `int256`):

- **specifiedDelta**: the negative of the user's specified amount (cancels their input from the pool's perspective).
- **unspecifiedDelta**: the negative of the output amount (the pool now owes the user this much of the other currency).

After `beforeSwap`:
- The PoolManager calls `currencyDelta(hook, specifiedCurrency) -= specifiedDelta` and `currencyDelta(hook, unspecifiedCurrency) -= unspecifiedDelta`, effectively assigning the trade obligation to the hook.
- The hook must `take` the input from PM and `settle` the output to PM, leaving its currency deltas at zero.

## Pricing

All values in WAD (1e18). `twap` is USDS per GBP. `spread(s)` is one-sided: negative (a discount) below 100% solvency, zero at/above 100%.

```
priceMultiplier_mint   = WAD + spread + FLAT_FEE_WAD
priceMultiplier_redeem = WAD + spread - FLAT_FEE_WAD

mintPriceUsdsPerGbpf   = twap * priceMultiplier_mint   / WAD
redeemPriceUsdsPerGbpf = twap * priceMultiplier_redeem / WAD

// Mint exact-input:  given usdsIn, find gbpfOut.
gbpfOut = usdsIn * WAD / mintPriceUsdsPerGbpf                      // round down

// Mint exact-output: given gbpfOut, find usdsIn.
usdsIn = ceilDiv(gbpfOut * mintPriceUsdsPerGbpf, WAD)              // round up

// Redeem exact-input: given gbpfIn, find usdsOut.
usdsOut = gbpfIn * redeemPriceUsdsPerGbpf / WAD                    // round down

// Redeem exact-output: given usdsOut, find gbpfIn.
gbpfIn = ceilDiv(usdsOut * WAD, redeemPriceUsdsPerGbpf)            // round up
```

Constants:
- `FLAT_FEE_WAD = 20e14` (20bp = 0.002)

### Pricing rounding direction

All math rounds in the protocol's favour:
- Mint: `gbpfOut` rounds **down** (user gets at most the computed amount).
- Redeem: `usdsOut` rounds **down** (user gets at most the computed amount).

This is the natural Solidity integer-division behaviour. Documented inline.

### Fee accumulation

The flat fee is "the amount the protocol takes." On a mint of `usdsIn`, the fee portion is:
- The user pays `usdsIn` USDS, receives `gbpfOut` GBPF.
- Without the fee, they would have received `gbpfOut * priceMultiplier_mint / (WAD + spread)` GBPF.
- The difference is the fee, measured in GBPF terms, but credited to the beneficiary in sUSDS terms.

Cleanest accounting: compute the fee in **sUSDS** at the time of deposit. For mint:
- `feeUsds = usdsIn * FLAT_FEE_WAD / priceMultiplier_mint` (the USDS-equivalent portion of the user's payment that maps to fee).
- The hook delivers `usdsIn - feeUsds` of "principal" to the vault and `feeUsds` of "fee" — but in practice everything goes to vault as sUSDS, and we just tell the vault `feeAmount = feeUsds * (sUSDS per USDS)`.

Actually simpler: compute fee fraction up front. Of the user's `usdsIn`:
- The fee portion (in USDS terms) is the part that maps to the +/-`FLAT_FEE_WAD` multiplier.
- Specifically: `feeUsds = usdsIn * FLAT_FEE_WAD / priceMultiplier_mint`.

This is the USDS-value the protocol captures as fee. The hook converts the entire `usdsIn` to sUSDS via PSM3 and reports both the total sUSDS amount and the fee portion (in sUSDS terms) to the vault.

Conversion: `sUsdsAmount_total = psm3.swapExactIn(USDS, sUSDS, usdsIn, ...)`. Of that, `feeAmount = sUsdsAmount_total * feeUsds / usdsIn` (proportional split).

Same pattern for redeem: fee is the USDS-equivalent portion of the redeem amount; converted to sUSDS terms before being credited.

## Token movement

### Mint (USDS → GBPF)

```
1. Compute gbpfOut, feeUsds (see pricing).
2. poolManager.take(USDS, address(this), usdsIn)          // pull USDS from PM
3. usds.approve(PSM3, usdsIn)                              // no-op if max allowance set at deploy
4. sUsdsAmount = psm3.swapExactIn(USDS, sUSDS, usdsIn, minOut, address(vault), 0)
5. feeAmountSUsds = sUsdsAmount * feeUsds / usdsIn         // proportional
6. vault.deposit(sUsdsAmount, feeAmountSUsds)
7. gbpf.mint(address(this), gbpfOut)
8. gbpf.approve(poolManager, gbpfOut)
9. poolManager.sync(GBPF)
10. gbpf.transfer(address(poolManager), gbpfOut)
11. poolManager.settle()                                    // credits the GBPF debt
12. return BeforeSwapDelta(-usdsIn, -gbpfOut)               // specified, unspecified
```

PSM3 minOut: call `psm3.previewSwapExactIn(USDS, sUSDS, usdsIn)` first to get the exact amount the PSM will produce, then pass that value as `minAmountOut`. Since the PSM uses the same SSRAuthOracle and runs in the same block, the preview and the actual swap agree exactly — no arbitrary slippage margin needed.

### Redeem (GBPF → USDS)

```
1. Compute usdsOut, feeUsds.
2. poolManager.take(GBPF, address(this), gbpfIn)
3. gbpf.burn(gbpfIn)                                       // burns from hook's own balance
4. Need sUSDS from vault to convert back to USDS. Compute sUsdsNeeded = usdsOut * 1e27 / ssrRate (round up).
5. feeAmountSUsds = sUsdsNeeded * feeUsds / usdsOut
6. vault.withdraw(sUsdsNeeded + small_margin_for_fee?, address(this), feeAmountSUsds)
   // Actually: the user receives `usdsOut` of USDS, the beneficiary receives `feeAmountSUsds`.
   // sUSDS needed total = sUsds_for_user_payout + sUsds_for_fee (which stays in vault as pending).
   // vault.withdraw(amount, to, feeAmount): amount goes to `to`, feeAmount is added to pending.
   // The amount going to `to` should be enough sUSDS to redeem for `usdsOut` of USDS via PSM3.
7. sUsds.approve(PSM3, sUsdsForUser)
8. psm3.swapExactIn(sUSDS, USDS, sUsdsForUser, minUsdsOut=usdsOut*999/1000, address(this), 0)
9. poolManager.sync(USDS)
10. usds.transfer(address(poolManager), usdsOut)
11. poolManager.settle()
12. return BeforeSwapDelta(-gbpfIn, -usdsOut)
```

Subtle: step 4-6 involve computing how much sUSDS to pull from the vault to produce `usdsOut` USDS after PSM3 conversion. That's the inverse of the PSM rate. Round up so we don't under-deliver, then any surplus from PSM rate quantisation goes... actually we should use PSM3's `swapExactOut` here to be precise: ask PSM for *exactly* `usdsOut` USDS, it tells us the sUSDS input needed.

**Revised redeem token flow:**
```
6'. sUsdsForUserOut = psm3.previewSwapExactOut(sUSDS, USDS, usdsOut)
7'. vault.withdraw(sUsdsForUserOut, address(this), feeAmountSUsds)
8'. sUsds.approve(PSM3, sUsdsForUserOut)
9'. psm3.swapExactOut(sUSDS, USDS, usdsOut, sUsdsForUserOut, address(this), 0)
10'. poolManager.sync(USDS); usds.transfer(PM, usdsOut); poolManager.settle()
```

PSM3 has no fee and uses the same rate, so `previewSwapExactOut` will agree with our internal math exactly. Pass the previewed value as `maxAmountIn` so the call reverts if anything is unexpectedly off.

### Reentrancy

The hook is callable only by `PoolManager` (verified by `if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager()`). The PoolManager itself has reentrancy guards. We don't need additional guards on the hook.

The PSM3 swap could in principle reenter the hook (it ends up transferring sUSDS to the vault, which doesn't call back). Concretely: `psm3.swapExactIn` calls `sUSDS.transfer(receiver, amountOut)` and `USDS.transferFrom(sender, address(psm3), amountIn)`. Neither token has callbacks. Safe.

### Vault settlement

The hook calls `vault.solvencyInputs()` (non-view, settles yield first) before pricing. The vault's `_settleBeneficiaryYield()` runs to update `pendingBeneficiarySUsds`. The pricing then reflects up-to-date solvency.

After the swap, the hook calls `vault.deposit(...)` or `vault.withdraw(...)`, both of which also call `_settleBeneficiaryYield()` internally — but that's a no-op because chi hasn't advanced within the same block. Safe.

## Other notes

- The hook revert-on-pause behaviour: if `OracleAdapter.update()` returns `healthy = false`, the hook reverts `OraclePaused()`. The PoolManager then reverts the whole swap. Users see a clean error.
- The hook does NOT support adding liquidity, removing liquidity, donating, or `beforeInitialize`. The PoolManager will simply revert any attempt because the hook flags aren't set for those operations.
- `afterSwap` is not implemented — all logic is in `beforeSwap`.

## Constructor parameters

```solidity
constructor(
    address poolManager_,
    address curve_,           // SpreadCurve library — actually a library, not an address; the hook will use it via internal lib calls
    address vault_,
    address oracleAdapter_,
    address gbpf_,
    address usds_,
    address sUsds_,
    address psm3_,
    address beneficiary_      // For deploy-time recording; the beneficiary lives in the vault
)
```

Wait — `SpreadCurve` is a library with internal functions. The hook uses it via Solidity's `using` directive, not a call to an address. So no `curve_` address needed.

Actually, with `internal` functions, the library is inlined into the hook bytecode. No external call.

Revised constructor:
```solidity
constructor(
    address poolManager_,
    address vault_,
    address oracleAdapter_,
    address gbpf_,
    address usds_,
    address sUsds_,
    address psm3_
)
```

All addresses immutable. `BENEFICIARY` lives in `Vault`; the hook doesn't need to know it directly.

## V4 settle pattern (verified against IPoolManager source)

The hook pays tokens to the PoolManager using a sync → transfer → settle dance:

```solidity
poolManager.sync(currency);                           // snapshots PM's balance
ERC20(currency).transfer(address(poolManager), amt);  // hook pushes tokens
poolManager.settle();                                 // PM credits the delta
```

There is no `approve`/`transferFrom` because PM does not pull; the hook pushes. This is the standard V4 flash-accounting pattern.

For `take`, PM pushes to the hook — no settle dance needed:

```solidity
poolManager.take(currency, address(this), amt);
```

## Pool fee tier

Set to `0` in the PoolKey. V4 permits zero LP fee for non-dynamic-fee pools. Our protocol fee mechanism is bespoke and does not use V4's fee accumulator.

## CREATE2 salt mining

The hook contract's address must encode the two hook flags (bits 3 and 7 of the low 14 bits). At deploy, a CREATE2 salt is mined offline so the resulting address has those bits set. The deploy script handles this; the hook source code itself does not care.
