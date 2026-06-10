# GBPF Deployment — Base Mainnet

**Status:** ✅ LIVE on Base (chain 8453). Contracts deployed + initialized, and the
seed-and-burn bootstrap (pool init + seed swap + burn) completed. The protocol is open for use.

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
