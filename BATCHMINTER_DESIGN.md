# BatchMinter / BatchRedeemer design

Authoritative spec for `src/periphery/BatchMinter.sol` (USDS→GBPF) and its mirror
`src/periphery/BatchRedeemer.sol` (GBPF→USDS). Periphery — **not** part of the immutable audited
core. Like `BufferVault`, each has an owner for tuning + rescue; market integrity never depends
on the owner.

Everything below describes the **minter**; the **redeemer** is the exact mirror — see
"BatchRedeemer (the reverse)" at the end for the three differences.

## Purpose

Let small users pool their USDS so a single keeper ("the runner") amortises the gas of minting
GBPF through the V4 hook across the whole pool. Users deposit USDS; a permissionless runner
triggers one batched mint; everyone is sent their GBPF pro-rata in the same transaction; the
runner is paid out of an ETH gas tank that the contract keeps topped up from a small flat
per-depositor fee on each batch.

This is a convenience/aggregation layer on top of the hook. It mints at exactly the hook's
oracle price — it does not change protocol pricing, custody backing, or solvency.

## Actors

- **Depositor** — transfers USDS in via `deposit()`. May reclaim it with `withdrawDeposit()`
  any time before a batch runs.
- **Runner** — anyone. Calls `executeBatch()`, pays the L2 gas, and is reimbursed in ETH
  (gas cost + bonus) from the tank.
- **Owner** — periphery operator. Tunes `feeUsds` / `bonusBps` / `maxDepositors`, can rescue
  stray tokens and seed/withdraw the ETH tank. Cannot touch queued user funds beyond running
  the documented flow.

## The six requirements (from the request) → where they live

1. *Collects USDS and notes who sent them* → `deposit()` records `pendingUsds[sender]` and
   appends to the `depositors` queue.
2. *Runs the V4 hook to swap to GBPF* → `executeBatch()` → `unlockCallback()` performs one
   exact-input USDS→GBPF swap against the hook pool (`POOL_MANAGER.swap`).
3. *Returns correct GBPF to each sender wallet* → the distribution loop transfers
   `gbpfOut * net_d / swapUsds` GBPF (net = post-fee) to each depositor `d`, same tx (push).
4. *Holds back enough USDS to buy ETH for gas + a fee to the runner* → each depositor pays
   `perHead = feeUsds + fixedFeeUsds/n` (marginal + a share of the batch's fixed overhead), so
   `totalFee = n × feeUsds + fixedFeeUsds`, capped per depositor at their balance.
5. *Swaps the fee to ETH to top up the gas tank* → `swapFeeToEth(totalFee)`:
   USDS →(PSM3)→ USDC →(Uniswap V3)→ WETH →(`withdraw`)→ ETH into `address(this).balance`.
6. *Won't pay the runner if there are no swaps to be made* → `executeBatch()` reverts
   `NothingToDo` when `totalQueued == 0` (or when fees would consume the whole queue, leaving
   `swapUsds == 0`), so an empty batch can neither distribute nor pay the runner (no
   tank-draining by spamming).

## Fee model: per-depositor marginal + shared fixed (mirrors the gas)

The runner's gas in `executeBatch` has two parts:

```
gas = FIXED_OVERHEAD  +  n × per_depositor_cost
```

- **Fixed** (~400–500k): the *one* hook swap for the whole batch + the *one* USDS→ETH conversion
  + base tx. Paid once regardless of `n`.
- **Marginal** (~60–80k each): the GBPF transfer + storage writes per depositor.

The fee mirrors this shape exactly. Each depositor pays:

```
perHead = feeUsds  +  fixedFeeUsds / n
totalFee = n × feeUsds + fixedFeeUsds          // = marginal × n + fixed
```

`feeUsds` is the per-depositor marginal fee; `fixedFeeUsds` is the batch's fixed overhead split
evenly across its depositors. Every depositor in a batch pays the **same** `perHead` (a whale and
a minnow alike), so the fee is *not* proportional to deposit size. A lone depositor bears the
whole `fixedFeeUsds`, which is correct — they alone caused the fixed gas — and discourages
uneconomic tiny batches at the wallet rather than by draining the tank.

Each depositor's GBPF is proportional to their **net** (post-fee) USDS:
`share_d = gbpfOut × (pending_d − perHead) / swapUsds`, with `swapUsds = totalQueued − totalFee`.

The fee is capped per depositor at their own balance (`min(perHead, pending_d)`), so an owner
raising fees after someone has queued can never drive a net negative. `deposit` requires the
running balance to cover the **worst-case** fee — `feeUsds + fixedFeeUsds` (the `n = 1` case) —
so every accepted deposit mints something even if no one else joins.

## Distribution: push, with escrow-on-failure

GBPF is sent directly to each depositor wallet in `executeBatch` (the requested behaviour).
A *single* malicious depositor contract whose `transfer` reverts must not be able to brick the
whole batch, so each push uses a low-level call: on failure the share is credited to
`claimable[d]` and can be pulled later with `claim()`. Honest EOA depositors are unaffected and
need no second transaction.

`maxDepositors` bounds the loop so the batch can never exceed the block gas limit. `deposit()`
reverts `BatchFull` once the queue is full; the runner clears it.

## Runner reward: gas reimbursement + bonus

```
gasUsed = gasStart - gasleft() + GAS_OVERHEAD        // GAS_OVERHEAD covers base tx + calldata + payout
reward  = gasUsed * block.basefee * (10000 + bonusBps) / 10000
payout  = min(reward, address(this).balance)         // capped by the tank
```

`gasStart` is sampled at the top of `executeBatch`; the measurement spans the hook swap,
distribution, and the fee→ETH conversion (all real runner cost). The payout is sent last, via
`call`, and is `min`-capped by the tank balance, so the contract can never owe more ETH than it
holds. If the tank is empty the batch still completes — the runner simply earns 0 that round and
will wait until the fee has funded the tank.

## Fee → ETH route

`USDS → USDC` via Spark **PSM3** (`swapExactIn`, no fee, par-ish at the SSR rate), then
`USDC → WETH` via a configured Uniswap **V3 pool** (raw `swap` + `uniswapV3SwapCallback`, same
pattern as `BufferVault`), then `WETH.withdraw` to native ETH. This reuses infrastructure the
core already depends on (PSM3) and routes the second hop through the deepest pool on Base
(USDC/WETH) rather than a thin USDS/WETH market.

The conversion runs inside `executeBatch` wrapped in `try/catch` (via an external self-call):
**a failed fee swap never blocks user mints.** On failure the fee USDS simply stays in the
contract and rolls into the tank top-up on a future batch; the runner is paid from existing tank
ETH. Sandwich risk on the dust-sized USDC→WETH leg is accepted (the value is a fraction of a
basis point of a batch); the owner can set `feeUsds = 0` to disable the swap if a route ever degrades.

## State

| Field | Meaning |
|---|---|
| `pendingUsds[addr]` | queued USDS for this address in the current round |
| `depositors[]` | addresses with non-zero `pendingUsds` (the round's queue) |
| `depositorIndexPlus1[addr]` | 1-based index into `depositors` for O(1) `withdrawDeposit` |
| `totalQueued` | sum of all `pendingUsds` |
| `claimable[addr]` | GBPF escrowed because a direct push failed |
| ETH balance | the gas tank |

## Owner-tunable parameters (bounded)

| Param | Default | Hard cap | Notes |
|---|---|---|---|
| `feeUsds` | 0.05 USDS | 5 USDS | marginal fee **per depositor** |
| `fixedFeeUsds` | 0.10 USDS | 20 USDS | fixed fee **per batch**, split `/n` across depositors |
| `bonusBps` | 2000 (20%) | 10000 (100%) | runner bonus over basefee reimbursement |
| `maxDepositors` | 150 | 500 | batch loop bound |

Caps are enforced in the setters so the owner can never charge more than 5 USDS/depositor +
20 USDS/batch or starve depositors. Both fee parts are converted to ETH for the tank.

## Trust / safety notes

- Immutable wiring (pool manager, hook, tokens, PSM3, V3 pool) is fixed at deploy.
- `unlockCallback` is gated to the PoolManager; `uniswapV3SwapCallback` to the configured V3
  pool; `_swapFeeToEth` to a self-call only.
- `nonReentrant` guards `deposit` / `withdrawDeposit` / `executeBatch` / `claim`; the runner
  payout is the last action and is made while the guard is still held.
- The contract holds USDS only transiently (between deposit and the next batch) and ETH (the
  tank). It never custodies user GBPF except the rare `claimable` escrow.
- `minGbpfOut` on `executeBatch` lets the runner abort if the hook would return less than
  expected (e.g. oracle moved); an oracle-paused hook reverts the whole batch and deposits stay
  safely queued.

## BatchRedeemer (the reverse): GBPF → USDS

`BatchRedeemer` is the mirror image — depositors queue **GBPF**, one batched redeem returns
**USDS** pro-rata, the runner is paid from the same ETH gas tank. All the machinery (queue,
push-with-escrow, per-depositor + fixed fee, gas-metered reimbursement, USDS→USDC→WETH→ETH
top-up, owner caps, reentrancy) is identical. Three differences:

1. **Tokens flip.** Deposit = GBPF, payout = USDS; `claimable`/escrow is in USDS; `rescueToken`
   guards queued **GBPF** instead of USDS; the deposit floor is `minGbpfDeposit` (a GBPF dust
   floor, since the USDS-denominated fee can't be expressed exactly in GBPF without a price).
2. **Swap direction flips.** `unlockCallback` runs `zeroForOne = GBPF_IS_TOKEN0` with
   `amountSpecified = -gbpfIn` (exact-input GBPF); the USDS leg is the positive delta it `take`s.
3. **Fee comes out of the proceeds, and backing must be realised first.** The fee is in USDS,
   which only exists *after* the redeem — so it's a single post-swap pass:
   `gross_d = usdsOut × gbpf_d / totalQueued`, `fee_d = min(perHead, gross_d)`, pay `gross_d −
   fee_d`. And because the hook redeem needs the vault's backing as sUSDS, `executeBatch` calls
   the permissionless `Vault.flush()` first (wrapped in `try/catch` — it reverts `NothingToFlush`
   when idle, which is ignored).
