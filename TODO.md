# TODO — ship the send-and-forget batchers + keeper

Ordered. **Step 1 is a blocker:** the Cloudflare keeper cannot do anything until the *forwarder*
contracts are deployed and their addresses are in the keeper config. The currently-live
`0xD16D…`/`0x7dd7…` are the **deposit-based** batchers — NOT what the keeper targets.

---

## ⛔ Step 1 — Deploy the forwarder contracts (REQUIRED before the keeper runs)

The keeper calls `sweepAndExecute` on `ForwarderMinter` / `ForwarderRedeemer`. These are built and
fork-tested but **not deployed yet**. Until they exist on Base and their addresses are filled into
`keeper/wrangler.toml` (`MINTER` / `REDEEMER`), the keeper just idles (it skips a zero address).

- [ ] Extend `script/BatchDeploy.s.sol` (or a new script) to deploy `ForwarderMinter` +
      `ForwarderRedeemer` (same constructor wiring as the deposit-based pair; redeemer also takes
      the Vault).
- [ ] Simulate, then broadcast + verify on Basescan (same flow as the earlier deploy:
      `FOUNDRY_PROFILE=ci forge script … --broadcast --slow --account deployer --verify`).
- [ ] Record the two deployed addresses → put them in `keeper/wrangler.toml` `[vars]` `MINTER` /
      `REDEEMER`, and set `START_BLOCK` to a few blocks before they were deployed.
- [ ] Add the addresses + tx hashes to `DEPLOYMENT.md`.

## Step 2 — Things to have on hand

- [ ] A **Cloudflare account** (free plan covers Cron Triggers + KV; $5/mo Workers Paid only if you
      hit CPU/subrequest limits on the log scan).
- [ ] An **executor key**: `cast wallet new`. Fund it with a **small one-time ETH float** (~0.005
      ETH on Base). It only fronts gas; each batch refunds it from the contract's tank.
- [ ] A **Base RPC URL** that allows `eth_getLogs` (a private endpoint — Alchemy/QuickNode/etc. —
      is strongly recommended; the public one throttles the scan).

## Step 3 — Install the keeper on Cloudflare

Two paths — pick one.

### Path A — Cloudflare builds from Git (no local install)

1. [ ] Push the repo so `keeper/` is on GitHub.
2. [ ] Cloudflare dashboard → **Workers & Pages → Create → Workers → Connect to Git** → pick the
       repo, set **root directory = `keeper`**.
3. [ ] **KV:** dashboard → Storage & Databases → **KV → Create namespace** (`KEEPER_KV`) → copy its
       ID into `keeper/wrangler.toml` (`[[kv_namespaces]].id`), commit, push.
4. [ ] **Secrets:** Worker → Settings → **Variables and Secrets** → add `BASE_RPC_URL` and
       `EXECUTOR_PRIVATE_KEY` (encrypted).
5. [ ] **Vars:** confirm `MINTER` / `REDEEMER` are set in `wrangler.toml` (from Step 1), push.
6. [ ] Re-deploy from the dashboard. It runs on the cron (`*/2 * * * *`).

### Path B — CLI (`wrangler`)

Needs `npm install` locally once (wrangler is the deploy tool — unavoidable for this path).

```
cd keeper
npm install
npx wrangler login                          # browser auth
npx wrangler kv namespace create KEEPER_KV  # paste printed id into wrangler.toml
# edit wrangler.toml: set MINTER / REDEEMER (from Step 1) + START_BLOCK
npx wrangler secret put BASE_RPC_URL
npx wrangler secret put EXECUTOR_PRIVATE_KEY
npx wrangler deploy
npx wrangler tail                           # live logs
```

## Step 4 — Verify it's working

- [ ] `wrangler tail` (or dashboard → Logs) shows each tick:
      `blocks X-Y | logs N | candidates C | funded F | total T`, and a tx hash when it sweeps.
- [ ] Smoke test: send a little USDS to `ForwarderMinter.depositAddressOf(yourWallet)` (a plain
      transfer), wait one cron interval, confirm the keeper sweeps and you receive GBPF.

## Tuning (`keeper/wrangler.toml` `[vars]`)

- `MIN_BATCH_WEI` — don't sweep a token until its waiting total reaches this (avoid dust gas).
- cron interval — latency from deposit to processing ≈ the interval (1 min is the CF minimum).
- `MAX_RANGE` — max blocks scanned per tick (keep within your RPC's `getLogs` limit).

## Notes / limitations

- The keeper discovers **self-funded** deposits (`to == depositAddressOf(from)`). Third-party-funded
  deposits (e.g. a CEX withdrawal, where `from` ≠ the user) need a one-time on-chain `register()`
  event on the contracts, or a frontend hint. Out of scope for v1.
- `sweepAndExecute` is permissionless, so this keeper is just the liveness floor — independent
  searchers can run the same scan once volume justifies it.
- Also outstanding: **commit** the forwarder contracts + keeper to the `feat/batch-minter-redeemer`
  branch (currently uncommitted).
