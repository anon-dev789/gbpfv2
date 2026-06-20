// SPDX-License-Identifier: AGPL-3.0-only
//
// GBPF forwarder keeper — a Cloudflare Worker (Cron Trigger) that drives the send-and-forget
// batchers. On each tick it:
//   1. scans the deposit token's Transfer logs for plain transfers to forwarder addresses
//      (to == depositAddressOf(from)), discovering users who funded their own deposit address;
//   2. re-checks any previously-seen-but-unswept candidates (persisted in KV);
//   3. checks which forwarders actually hold a balance now;
//   4. if the waiting total clears MIN_BATCH_WEI, calls sweepAndExecute(users, 0) — the contract
//      mints/redeems them and reimburses this keeper's gas (+bonus) from its ETH tank.
//
// No server: Cloudflare runs the schedule. Gas reimbursement happens INSIDE sweepAndExecute (the
// contract pays msg.sender gasUsed*basefee*(1+bonus) from its tank, in the same tx). The executor
// key therefore only needs a small ONE-TIME ETH float to front each tx's gas up front — the
// refund lands in the same transaction, so the balance stays roughly flat (drifts up via the
// bonus). It is not an ongoing funding source.
//
// Discovery covers SELF-funded deposits (sender == owner); third-party-funded (e.g. CEX withdrawal
// where sender != owner) deposits need a register()/UI hint and are out of scope here.

import {
  createPublicClient,
  createWalletClient,
  http,
  getContractAddress,
  pad,
  parseAbiItem,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

interface Env {
  KEEPER_KV: KVNamespace;
  BASE_RPC_URL: string;
  EXECUTOR_PRIVATE_KEY: string;
  MINTER: string;
  REDEEMER: string;
  USDS: string;
  GBPF: string;
  MULTICALL3: string;
  START_BLOCK: string;
  MAX_RANGE: string;
  MIN_BATCH_WEI: string;
}

const TRANSFER_EVENT = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)"
);
const FACTORY_ABI = [
  { type: "function", name: "FORWARDER_INIT_HASH", stateMutability: "view", inputs: [], outputs: [{ type: "bytes32" }] },
  {
    type: "function",
    name: "sweepAndExecute",
    stateMutability: "nonpayable",
    inputs: [{ type: "address[]", name: "users" }, { type: "uint256", name: "minOut" }],
    outputs: [],
  },
] as const;
const BALANCEOF_ABI = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

type Kind = "minter" | "redeemer";

export default {
  async scheduled(_event: ScheduledController, env: Env, _ctx: ExecutionContext): Promise<void> {
    // Process both directions independently so one failing doesn't block the other.
    for (const kind of ["minter", "redeemer"] as Kind[]) {
      try {
        await runKeeper(env, kind);
      } catch (err) {
        console.error(`[${kind}] keeper run failed:`, err);
      }
    }
  },
};

async function runKeeper(env: Env, kind: Kind): Promise<void> {
  const factory = (kind === "minter" ? env.MINTER : env.REDEEMER) as Address;
  const token = (kind === "minter" ? env.USDS : env.GBPF) as Address;
  if (factory === "0x0000000000000000000000000000000000000000") {
    console.log(`[${kind}] factory not configured; skipping`);
    return;
  }

  const pub = createPublicClient({ chain: base, transport: http(env.BASE_RPC_URL) });

  // The CREATE2 init-code hash that fixes every deposit address. Read once, cache forever.
  const initHash = await getInitHash(env, pub, kind, factory);

  // Resolve the scan window: [cursor, min(head, cursor + MAX_RANGE)].
  const head = await pub.getBlockNumber();
  const cursorKey = `${kind}:lastBlock`;
  const startCfg = BigInt(env.START_BLOCK);
  const stored = await env.KEEPER_KV.get(cursorKey);
  let fromBlock = stored ? BigInt(stored) : startCfg;
  if (fromBlock < startCfg) fromBlock = startCfg;
  const maxRange = BigInt(env.MAX_RANGE);
  const toBlock = head < fromBlock + maxRange ? head : fromBlock + maxRange;
  if (toBlock < fromBlock) {
    console.log(`[${kind}] nothing new (head ${head} < from ${fromBlock})`);
    return;
  }

  // 1. Discover new self-funded depositors from Transfer logs in the window.
  const discovered = new Set<Address>();
  const logs = await pub.getLogs({
    address: token,
    event: TRANSFER_EVENT,
    fromBlock,
    toBlock,
  });
  for (const log of logs) {
    const from = log.args.from as Address | undefined;
    const to = log.args.to as Address | undefined;
    if (!from || !to) continue;
    if (from === "0x0000000000000000000000000000000000000000") continue;
    // Is `to` exactly this user's forwarder address? (self-funded deposit)
    const forwarder = forwarderOf(factory, from, initHash);
    if (forwarder.toLowerCase() === to.toLowerCase()) discovered.add(from);
  }

  // 2. Merge with previously-seen-but-unswept candidates.
  const pendingKey = `${kind}:pending`;
  const prior: Address[] = JSON.parse((await env.KEEPER_KV.get(pendingKey)) || "[]");
  const candidates = Array.from(new Set<Address>([...prior, ...discovered]));

  // 3. Which candidates' forwarders actually hold a balance right now?
  const funded: { user: Address; bal: bigint }[] = [];
  if (candidates.length > 0) {
    const forwarders = candidates.map((u) => forwarderOf(factory, u, initHash));
    const balances = await multicallBalances(pub, env.MULTICALL3 as Address, token, forwarders);
    for (let i = 0; i < candidates.length; i++) {
      if (balances[i] > 0n) funded.push({ user: candidates[i], bal: balances[i] });
    }
  }

  const total = funded.reduce((a, f) => a + f.bal, 0n);
  console.log(
    `[${kind}] blocks ${fromBlock}-${toBlock} | logs ${logs.length} | candidates ${candidates.length} | funded ${funded.length} | total ${total}`
  );

  // 4. Execute if the waiting total is worth a batch; otherwise keep accumulating.
  let executed = false;
  if (total >= BigInt(env.MIN_BATCH_WEI) && funded.length > 0) {
    const users = funded.map((f) => f.user);
    const account = executorAccount(env);
    try {
      // Dry-run first so we don't burn gas on a revert (e.g. oracle paused).
      await pub.simulateContract({
        address: factory,
        abi: FACTORY_ABI,
        functionName: "sweepAndExecute",
        args: [users, 0n],
        account: account.address,
      });
      const wallet = createWalletClient({ account, chain: base, transport: http(env.BASE_RPC_URL) });
      const hash = await wallet.writeContract({
        address: factory,
        abi: FACTORY_ABI,
        functionName: "sweepAndExecute",
        args: [users, 0n],
      });
      console.log(`[${kind}] sweepAndExecute sent for ${users.length} users: ${hash}`);
      executed = true;
    } catch (err) {
      console.error(`[${kind}] sweepAndExecute failed (will retry next tick):`, err);
    }
  }

  // 5. Persist cursor + remaining pending set. If we executed, those forwarders are now drained,
  //    so only carry forward funded users we did NOT sweep this tick.
  await env.KEEPER_KV.put(cursorKey, toBlock.toString());
  const stillPending = executed ? [] : funded.map((f) => f.user);
  await env.KEEPER_KV.put(pendingKey, JSON.stringify(stillPending));
}

// ---- helpers ----

function executorAccount(env: Env) {
  return privateKeyToAccount(env.EXECUTOR_PRIVATE_KEY as Hex);
}

/// Recompute the forwarder address the same way the contract does:
/// CREATE2(factory, salt = uint256(uint160(user)) left-padded to 32 bytes, FORWARDER_INIT_HASH).
function forwarderOf(factory: Address, user: Address, initHash: Hex): Address {
  return getContractAddress({
    opcode: "CREATE2",
    from: factory,
    salt: pad(user, { size: 32 }),
    bytecodeHash: initHash,
  });
}

async function getInitHash(
  env: Env,
  pub: ReturnType<typeof createPublicClient>,
  kind: Kind,
  factory: Address
): Promise<Hex> {
  const key = `${kind}:initHash`;
  const cached = await env.KEEPER_KV.get(key);
  if (cached) return cached as Hex;
  const h = (await pub.readContract({
    address: factory,
    abi: FACTORY_ABI,
    functionName: "FORWARDER_INIT_HASH",
  })) as Hex;
  await env.KEEPER_KV.put(key, h);
  return h;
}

async function multicallBalances(
  pub: ReturnType<typeof createPublicClient>,
  multicall3: Address,
  token: Address,
  holders: Address[]
): Promise<bigint[]> {
  const res = await pub.multicall({
    multicallAddress: multicall3,
    allowFailure: false,
    contracts: holders.map(
      (h) => ({ address: token, abi: BALANCEOF_ABI, functionName: "balanceOf", args: [h] }) as const
    ),
  });
  return res as bigint[];
}
