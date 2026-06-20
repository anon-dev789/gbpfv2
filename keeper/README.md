# GBPF forwarder keeper (Cloudflare Worker)

A serverless keeper that drives the send-and-forget batchers (`ForwarderMinter` /
`ForwarderRedeemer`). Cloudflare runs it on a cron schedule — **you host nothing.**

Each tick it scans the deposit token's `Transfer` logs for plain transfers to forwarder addresses
(`to == depositAddressOf(from)`), re-checks previously-seen candidates, sees which forwarders hold
a balance, and — once the waiting total clears `MIN_BATCH_WEI` — calls `sweepAndExecute(users, 0)`.
The contract mints/redeems everyone and **reimburses the keeper's gas (+bonus) from its ETH tank,
in the same transaction.**

## Prerequisites

1. **Deploy the forwarder contracts first.** The live `0xD16D…`/`0x7dd7…` are the *deposit-based*
   batchers; the keeper targets the *forwarder* pair (`ForwarderMinter`/`ForwarderRedeemer`), which
   still need deploying. Put their addresses in `wrangler.toml` (`MINTER`, `REDEEMER`).
2. **An executor key** — a fresh hot key, seeded with a **small one-time ETH float** (e.g. 0.005
   ETH on Base). It only fronts each tx's gas; the in-contract refund lands in the same tx, so the
   balance stays roughly flat (drifts up via the bonus). It is *not* an ongoing funding source.
   Cold start (empty tank) draws the float down until fees start flowing — top up once if needed.
3. **A Base RPC** that supports `eth_getLogs` (a private endpoint is strongly recommended; the
   public one will rate-limit the log scan).
4. **Node + wrangler:** `npm install`, and `npx wrangler login`.

## Setup

```bash
cd keeper
npm install

# 1. Create the KV namespace and paste its id into wrangler.toml ([[kv_namespaces]].id).
npx wrangler kv namespace create KEEPER_KV

# 2. Set the contract addresses in wrangler.toml ([vars] MINTER / REDEEMER), and START_BLOCK to a
#    few blocks before they were deployed.

# 3. Secrets (encrypted; never in the repo):
npx wrangler secret put BASE_RPC_URL
npx wrangler secret put EXECUTOR_PRIVATE_KEY

# 4. Dry-run locally (fires the scheduled handler once):
npm run dev            # then in another shell: curl "http://localhost:8787/__scheduled"

# 5. Ship it.
npm run deploy
npm run tail           # live logs
```

The cron is `*/2 * * * *` (every 2 min) in `wrangler.toml` — adjust to taste (1 min is the
Cloudflare minimum). Latency from deposit to processing ≈ the cron interval.

## Tuning (`wrangler.toml` `[vars]`)

| Var | Meaning |
|---|---|
| `MIN_BATCH_WEI` | Don't sweep a token until its waiting total reaches this — avoids paying gas for dust. |
| `MAX_RANGE` | Max blocks scanned per tick (catch-up bound; keep within your RPC's `getLogs` limits). |
| `START_BLOCK` | Where the scan begins (a few blocks before the forwarder contracts were deployed). |

## What it does and doesn't cover

- **Covers:** self-funded deposits — a user sends the token *from their own wallet* to their
  deposit address. Those are discoverable from `Transfer` logs (`to == depositAddressOf(from)`).
- **Doesn't cover:** third-party-funded deposits (e.g. a CEX withdrawal, where `from` is the
  exchange, not the user). The log scan can't attribute those. If you need that path, add a
  one-time on-chain `register()` (emitting `Registered(wallet)`) to the contracts and have the
  keeper also watch that event — or surface the wallet via the frontend.
- **Permissionless by design:** this keeper is just *one* runner. `sweepAndExecute` is open to
  anyone, so independent searchers can run the same scan and execute as volume grows; you can keep
  this keeper as the liveness floor.

## Safety notes

- The keeper only ever calls `sweepAndExecute` / reads balances. It can't move user funds — the
  contracts route swept funds only to the depositors (attribution is enforced on-chain by the
  CREATE2 address), and reimburse only the caller's gas from the tank.
- Keep the executor key low-value (just the gas float). Compromise of it costs at most that float;
  it has no authority over deposits or the tank beyond triggering an honest batch.
- A dry-run (`simulateContract`) precedes every send, so a reverting state (e.g. oracle paused)
  skips cleanly instead of burning gas.
