# Forwarder batcher — one-screen UI spec

A minimal frontend for the send-and-forget batchers (`ForwarderMinter` / `ForwarderRedeemer`).
The user's only on-chain action is a **plain token transfer to an address** — the UI never asks
them to approve or call a contract. The app's jobs are: (1) show each user their deposit address,
(2) keep the candidate list so a runner can sweep, (3) show status.

## The screen (mint direction; redeem is identical with tokens swapped)

```
┌────────────────────────────────────────────────┐
│  Pool USDS → get GBPF (gas-shared)              │
│                                                 │
│  Your wallet:  0x398C…5c24      [Connect]       │
│                                                 │
│  Send USDS to your deposit address:             │
│  ┌──────────────────────────────────────────┐  │
│  │  0xD16D…1670  derived for you   [Copy][QR]│  │
│  └──────────────────────────────────────────┘  │
│  ⓘ A normal transfer. No approval, no contract  │
│    call. Funds stay yours until a batch runs.   │
│                                                 │
│  Status:  ● 6,000 USDS waiting at your address  │
│           Next batch mints you ~ 4,560 GBPF     │
│                                                 │
│  [ I changed my mind — refund ]                 │
└────────────────────────────────────────────────┘
```

## Data the UI needs

| Need | Source |
|---|---|
| User's wallet address | wallet connect, or a pasted address (read-only mode — no signature needed to *see* the deposit address) |
| Deposit address | `ForwarderMinter.depositAddressOf(wallet)` (free `eth_call`) |
| Pending balance | `USDS.balanceOf(depositAddress)` (free `eth_call`) |
| Est. GBPF out | `pending × (1 − feeShare)` ÷ hook price; price via the oracle/quoter |
| Batch history / "minted" | `BatchExecuted` + `Swept(user)` events |

## The one off-chain responsibility: the candidate list

The contract can't enumerate depositors, so **the app maintains the `users[]` list** for the
runner. Two ways, pick one:

1. **Indexer (recommended).** When a user views their address, record `(wallet → depositAddress)`
   in a small DB. A keeper periodically calls `USDS.balanceOf(depositAddress)` for each known
   wallet and builds `users[]` for those with a balance, then calls `sweepAndExecute(users, minOut)`.
2. **On-chain announce (optional).** Add a one-time `register()` that emits `Registered(wallet)`;
   the keeper watches that event. Costs the user one cheap tx ever — only if you don't want any
   off-chain index.

Either way the on-chain attribution + payout stays trustless; the list only decides *who gets
included*, and anyone (not just your keeper) can run a batch.

## Flows

- **Deposit:** connect/paste → UI shows address → user sends USDS from their wallet (or a CEX
  withdrawal). UI polls `balanceOf(depositAddress)` and shows "waiting".
- **Get GBPF:** happens automatically when any runner sweeps; UI shows the resulting balance via
  the `Swept`/`BatchExecuted` events. The user does nothing.
- **Refund:** the button calls `refund(wallet)` (anyone can; returns to the wallet). For a fully
  no-signature UX, the keeper can also expose a "refund me" that calls it on the user's behalf.
- **Redeem:** same screen, token = GBPF, contract = `ForwarderRedeemer`; the user sends GBPF and
  gets USDS back.

## Guardrails to surface

- **Send only to the address shown for *your* wallet.** Proceeds go to the wallet the address is
  derived from; sending to someone else's address credits them. (Standard wrong-address risk.)
- **Minimums.** A deposit below ~`feeUsds + fixedFeeUsds` worth nets ~nothing after fees — warn
  if `pending` is near the fee floor.
- **Right network (Base) and right token (USDS/GBPF).** Show chainId + token address.

## Build size

This is a single static page + read-only RPC calls + a tiny keeper (a cron that builds `users[]`
and calls `sweepAndExecute`). No backend custody, no signing server. The keeper is the same
"runner" anyone can be — see the keeper follow-up.
