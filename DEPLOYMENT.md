# GBPF Deployment — Base Mainnet

**Status:** ✅ LIVE on Base (chain 8453). Contracts deployed + initialized, and the
seed-and-burn bootstrap (pool init + seed swap + burn) completed. The protocol is open for use.
The **Gateway** (public V3 GBPF/USDS pool + BufferVault, see GATEWAY_DESIGN.md) is also live —
see "Gateway deployment" below.

## Gateway deployment (2026-06-11, periphery — NOT part of the immutable core)

| Component | Address |
|---|---|
| Gateway pool (Uniswap V3 GBPF/USDS, 0.05%) | `0xd478Ae80D8Af91b39A100d8bC55C2219dA17df7e` |
| BufferVault (owner = deployer EOA) | `0x6aB1571CCd465568612a8a306490385CbF58B7EC` |

- Pool initialised at oracle price 1.34037 USDS/GBPF; seed rebalance deployed the ±30bp band
  (position tokenId 5310273) and pinned spot to the oracle tick (2929) — verified on-chain.
- Initial funding: 0.1 USDS (smoke scale). Add capital: transfer GBPF/USDS to the BufferVault,
  then call `rebalance()`. Withdraw: `exitAndWithdrawAll(to)` from the owner wallet.
- Peg upkeep: permissionless `BufferVault.rebalance()` on a heartbeat (pair with core
  `Vault.flush()`). Keeper not yet stood up.
### Gateway transaction hashes (blocks 47173762–47173768)

| Step | Action | Tx hash |
|------|--------|---------|
| 1 | Factory.createPool (V3 GBPF/USDS 0.05%) | `0x35157625e0bb6399036fbd6886a1bc4a2d00ed4e58fe49269d21068aa4d225c7` |
| 2 | Pool.initialize @ 1.34037 | `0xd7ffe18d8fb944283b2826cd6865513a6b8dbe87125ffc3f533ac2baef6b5085` |
| 3 | BufferVault (deploy) | `0xe6066bc5476e98b25aacf0e4e770f7d62f61510cfa2170909b12a43a70f3f0b3` |
| 4 | USDS.transfer 0.1 to BufferVault | `0xb996621277a291ad8d1d41cf7b807c4e8078bdc76c4f2ff7a2c54ec963edb274` |
| 5 | BufferVault.rebalance (seed: hook mint + band) | `0xe93fd30fa29528ab2dd9b424937cbee389a60797e13ccb0be82f2d26f3194fd1` |

Artifact: `broadcast/GatewayDeploy.s.sol/8453/run-latest.json`.
Seed rebalance token flow (decoded from tx 5): hook minted 0.037237 GBPF for 0.05 USDS;
band holds 0.028638 GBPF + 0.05 USDS; 0.008599 GBPF remains in the vault as working inventory.

## Batchers deployment (2026-06-20, periphery — NOT part of the immutable core)

Gas-amortising aggregators on top of the V4 hook: users pool one token, a permissionless
"runner" triggers one batched swap, everyone is paid back pro-rata, and the runner is reimbursed
in ETH from a self-funding gas tank (per-depositor + shared-fixed fee → USDS→USDC→WETH→ETH). See
BATCHMINTER_DESIGN.md and `script/BatchDeploy.s.sol`.

| Component | Address |
|---|---|
| BatchMinter (USDS → GBPF, owner = deployer EOA) | `0xD16D00e3eA0295cB5fCDB9e381171c8f7B101670` |
| BatchRedeemer (GBPF → USDS, owner = deployer EOA) | `0x7dd7cCd4BAb1494a274b95474b7d369717e2c188` |

- **Owner (immutable, both):** `0x398CA93b76806D3517DD3520F1aE09620Fcb5c24`. Owner powers are
  capped tuning (`setParams`) + stray rescue + ETH tank withdraw; it cannot touch queued deposits
  or escrowed (`claimable`) funds.
- Both bind to the live core: Hook `0x5613…0088`, GBPF `0x1817…6770`, USDS `0x820C…21Dc`, and
  (redeemer only) Vault `0xA9a8…3498`. Fee route uses PSM3 `0x1601…347E` →
  USDC `0x8335…2913` → Uniswap V3 USDC/WETH pool `0xd0b5…F224` → WETH `0x4200…0006`.
- **Default params:** `feeUsds` 0.05, `fixedFeeUsds` 0.10, `bonusBps` 2000, `maxDepositors` 150;
  redeemer `minGbpfDeposit` 0.2. Tunable via `setParams` (caps: 5 USDS / 20 USDS / 100% / 500).
- Deployed with **no ETH seed** — the first batch funds its own runner payout (fees are swapped
  to ETH before the runner is paid). Top up anytime via `fundTank()` or a plain ETH send.
- **Verified on Basescan** (both). Verify command: see `script/BatchDeploy.s.sol` header.
- Idle until a runner calls `executeBatch` — no keeper stood up yet.

### Batchers transaction hashes

| Contract | Tx hash | Block |
|---|---|---|
| BatchMinter | `0x6dbe5ae2c9269219903f2aa199eec16ce932be920e11ed2750e64a3b472f9dd5` | 47553893 |
| BatchRedeemer | `0x99abd7871adaa159b2dea52bcabb8b61ca1911ac21624a4dbeefa64d12c4d80a` | 47553895 |

Artifact: `broadcast/BatchDeploy.s.sol/8453/run-latest.json`. Total deploy cost 0.0000289 ETH.

## Forwarder batchers deployment (2026-06-21, periphery — NOT part of the immutable core)

Send-and-forget version of the batchers: a user deposits with a **plain transfer** to their own
deterministic CREATE2 address (no approve, no contract call), and a permissionless keeper sweeps +
swaps + returns the result. See BATCHMINTER_DESIGN.md ("Forwarder model"), `keeper/` (Cloudflare
Worker), and `web/index.html` (the deposit UI).

| Component | Address |
|---|---|
| ForwarderMinter (USDS → GBPF, owner = deployer EOA) | `0x163e95500660bDF76D7F2dD97bb6F47d947C7226` |
| ForwarderRedeemer (GBPF → USDS, owner = deployer EOA) | `0x5b1c7dF048a7E4EbEA285B64Cb1FCa675044c9E2` |

- **Owner (immutable, both):** `0x398CA93b76806D3517DD3520F1aE09620Fcb5c24`.
- Same wiring/fee model/tank as the deposit-based pair; redeemer also flushes the Vault. Bound to
  the live Hook/GBPF/USDS (+ Vault), PSM3→USDC→V3→WETH fee route.
- **`FORWARDER_INIT_HASH` (both):** `0x12bf77d0243b216de5f0dc2feca23fb449ae21e3e071c70e2ff350b15edf3374`
  — fixes every user's deposit address as `CREATE2(factory, salt=user, this hash)`. The deposit UI
  computes the same address client-side (verified equal to on-chain `depositAddressOf`).
- **Verified on Basescan** (both). Deployed with no ETH seed.

### Forwarder batchers transaction hashes

| Contract | Tx hash | Block |
|---|---|---|
| ForwarderMinter | `0xa8652663ba9e76634f029f1e34c0841bc72b5abe6242f91af1e7db1e86edbb58` | 47608520 |
| ForwarderRedeemer | `0x712470fb5d9803c1e4f8e952866c4c14267710a11b7840ab77d2ef06e8aa3cae` | 47608520 |

Artifact: `broadcast/ForwarderDeploy.s.sol/8453/run-latest.json`.

## ⚠️ Known quirk in the LIVE OracleAdapter: preview() TWAP

The deployed (immutable) OracleAdapter's `preview()` view returns an **amplified TWAP** when a
new Chainlink observation exists that (a) has not been ingested on-chain (ingestion happens via
`update()`, i.e. on swaps) and (b) is older than the 5-minute TWAP window. A 0.072% feed step,
un-ingested for ~10h, previewed as +8.2% (observed live 2026-06-10/11). Root cause and fix:
`_previewTwap` window-start interpolation; fixed in source (post-deploy) with regression tests
in `test/OracleAdapterPreviewRegression.t.sol`.

**Impact: none on-chain.** The hook prices swaps via `update()`, which is correct (verified by
eth_call against the live instance). The BufferVault also uses `update()`.
**Rule for off-chain consumers/tooling: do NOT consume the live `preview()` twapWad; use
`latestPriceWad()` or an eth_call-simulated `update()` instead.** (The `healthy` flag of
`preview()` is unaffected and fine to use.)

> **Current deployment is the post-audit redeploy (commit `60d3895`).** An earlier deployment
> (commit `53980bf`) was abandoned after the audit; its addresses are recorded under
> "Superseded deployment" at the bottom and must NOT be used.

## Deployed addresses (Base, chain 8453) — commit 60d3895

| Contract       | Address                                      |
|----------------|----------------------------------------------|
| OracleAdapter  | `0x9c66F3F8a102d6Bf3EeaEAAe5d9ECAe88985eB2F` |
| GBPF           | `0x1817FD23ceF7Da47DF934fdc880d72e653786770` |
| Vault          | `0xA9a831a348D0Db372cf75dd7C082cFF67A453498` |
| Hook           | `0x5613c279E8Db9815DBD0CdFbd10515EAbD350088` |

**Hook CREATE2 salt:** `0x0000000000000000000000000000000000000000000000000000000000004a68`
(Hook low 14 bits = `0x0088` = `BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG` — verified.)

**Beneficiary multisig (immutable in Vault):** `0x621D531A97185BcB5f3E513C192a3327163377D3`

### Canonical V4 pool (the protocol's swap pool, bound to the Hook)

**PoolId:** `0xdf1da6c81bc6ce11acafdf6e6a80c5af1695421e36d6f80ee930474aece9ff04`

PoolKey: `{ currency0: GBPF 0x1817FD23ceF7Da47DF934fdc880d72e653786770, currency1: USDS
0x820C137fa70C8691f0e44Dc420a5e53c168921Dc, fee: 0, tickSpacing: 1, hooks:
0x5613c279E8Db9815DBD0CdFbd10515EAbD350088 }` — PoolId = keccak256(abi.encode(PoolKey)),
equal to the Hook's immutable `POOL_KEY_HASH`.

Note the ordering: **GBPF is currency0** (lower address), so a mint (USDS→GBPF) swap has
`zeroForOne = false` and a redeem (GBPF→USDS) has `zeroForOne = true`. Initialised at
sqrtPriceX96 = 2^96 (placeholder — the hook prices from the oracle, not pool state).

## Deploy metadata

- **Source commit:** `60d3895` ("ran audit and fixed" — post-audit fixes across all 4 contracts)
- **Deployed:** block 47143133–47143140
- **Total gas paid:** ~0.0000369 ETH (6,153,778 gas @ ~0.006 gwei)
- **Broadcast artifact:** `broadcast/Deploy.s.sol/8453/run-latest.json`

### Transaction hashes

| Step | Contract / fn                   | Tx hash                                                              |
|------|---------------------------------|---------------------------------------------------------------------|
| 1    | OracleAdapter (deploy)          | `0xf9ff1830995eee582986c4a0d4157ccb6d40edcef50ac5d224d1ad2dd98975a0` |
| 2    | GBPF (deploy)                   | `0xdc5e387f4c3b5a36e79eaca47af93fc4774d4a9d2d20b9f8e8887879438c0a4a` |
| 3    | Vault (deploy)                  | `0x77f26edbad91051ca07ece433ac118416bc9c46f0088cc62e643c62aa24deaee` |
| 4    | Hook (deploy, CREATE2)          | `0x40815a73d365d9517f508ace542c79f2fb0fb5b4583843a27dabe7344d3fea40` |
| 5    | Vault.initialize(address)       | `0xcd301b4d8dd4b245f6057ddb1410fc2e17ba05adcec632d0855e9c07c59284f1` |
| 6    | GBPF.initialize(address,address)| `0xda79dbc25b20ecf78549cb67065d266262e66cb453808998bf33172e43d3c197` |

## Hardcoded Base dependencies (from Deploy.s.sol)

| Dependency             | Address                                      |
|------------------------|----------------------------------------------|
| Chainlink GBP/USD      | `0xCceA6576904C118037695eB71195a5425E69Fa15` |
| Chainlink Sequencer    | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
| Spark SSR Auth Oracle  | `0x65d946e533748A998B1f0E430803e39A6388f7a1` |
| sUSDS                  | `0x5875eEE11Cf8398102FdAd704C9E96607675467a` |
| USDS                   | `0x820C137fa70C8691f0e44Dc420a5e53c168921Dc` |
| V4 PoolManager         | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Spark PSM3             | `0x1601843c5E9bC251A3272907010AFa41Fa18347E` |

## Bootstrap (COMPLETED — protocol live)

Ran `script/Bootstrap.s.sol` (commit `60d3895`) from deployer `0x398CA93b76806D3517DD3520F1aE09620Fcb5c24`.
All 5 txs succeeded; total ~0.0000072 ETH. The script's final `require(deployer GBPF balance == 0)`
passed, so the seed was minted and fully burned.

| Step | Action                          | Tx hash                                                              |
|------|---------------------------------|---------------------------------------------------------------------|
| 1    | PoolManager.initialize (pool)   | `0x1ce5b495d8b6bf0ecec04b5beee6842657bf8c989440771db65f28429a506b83` |
| 2    | MinimalRouter (deploy)          | `0xb3391e5d34fbcd90c41d64b3373588012df90a15bbcea0e25d30144223c4f286` |
| 3    | USDS.approve(router)            | `0xe1d7c9e6f995c7df725c5fe75f90e6f132fbc0e65bd249501a782548cb1c48cc` |
| 4    | Router.swap (seed mint, 1 USDS) | `0x09fc2cee605404c3a2fccf09c219649a12818fc75d76ebf0e4213e4f236cc7c8` |
| 5    | GBPF.transfer(0xdEaD) (burn)    | `0x1ff9c5febe1e05300ff73b9f46b432c346f605975e3489f053993ed09b70bc7f` |

Bootstrap router (one-shot, no privileged role): `0xC126828AF3dEd1F764D20CCa8Eeb74795e99a983`
Broadcast artifact: `broadcast/Bootstrap.s.sol/8453/run-latest.json`

The protocol is fully bootstrapped and open for use.

---

## Superseded deployment (commit 53980bf — ABANDONED, do not use)

Pre-audit deploy, replaced by the post-audit redeploy above. Left for the record only.

| Contract       | Address                                      |
|----------------|----------------------------------------------|
| OracleAdapter  | `0x3C650A72Ff710B0b364601F41ec57bD770aC2Ae2` |
| GBPF           | `0x6340F1333186e7e5a3990490Ae6343505DbA4762` |
| Vault          | `0xE7d22044a3124FE1be153101e368e5caF7Cef67e` |
| Hook           | `0x27f5B70b461A62e4581119A3fC65758E64054088` |

Hook salt: `0x...2cab`. Never bootstrapped (no pool init / seed swap was run against it).
