# GBPF Deployment — Base Mainnet

**Status:** Contracts deployed and initialized on Base (chain 8453).
**Protocol is NOT yet live** — the seed-and-burn bootstrap (pool init + seed swap + burn) is still pending. See "Remaining steps" below.

## Deployed addresses (Base, chain 8453)

| Contract       | Address                                      |
|----------------|----------------------------------------------|
| OracleAdapter  | `0x3C650A72Ff710B0b364601F41ec57bD770aC2Ae2` |
| GBPF           | `0x6340F1333186e7e5a3990490Ae6343505DbA4762` |
| Vault          | `0xE7d22044a3124FE1be153101e368e5caF7Cef67e` |
| Hook           | `0x27f5B70b461A62e4581119A3fC65758E64054088` |

**Hook CREATE2 salt:** `0x0000000000000000000000000000000000000000000000000000000000002cab`
(Hook low 14 bits = `0x0088` = `BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG` — verified.)

**Beneficiary multisig (immutable in Vault):** `0x621D531A97185BcB5f3E513C192a3327163377D3`

## Deploy metadata

- **Source commit:** `53980bf`
- **Deployed:** block 47133419–47133426
- **Total gas paid:** ~0.0000348 ETH (5,804,468 gas @ ~0.006 gwei)
- **Broadcast artifact:** `broadcast/Deploy.s.sol/8453/run-latest.json`

### Transaction hashes

| Step | Contract / fn                  | Tx hash                                                              |
|------|--------------------------------|---------------------------------------------------------------------|
| 1    | OracleAdapter (deploy)         | `0x1dc6a7c8943bfeafc9f176522c4fc4fc37aca8d74faec322535949451e419064` |
| 2    | GBPF (deploy)                  | `0x34ffdf9b9d60c1a96f46a431f2df1779563323de3f35760abf89b247d0c6406c` |
| 3    | Vault (deploy)                 | `0x0db546a9b2bff86f15d01bde8bf806bf71e8dd3df916a9d560b9ed06dbb450c7` |
| 4    | Hook (deploy, CREATE2)         | `0x340fa460b5c19caf2400ed778b3afef3a23985ab5b6efca64285af8fb666b79f` |
| 5    | Vault.initialize(address)      | `0x5b20741566a48032fa23340c7c60cbb533571ce14d9870b83fe59b8834067c19` |
| 6    | GBPF.initialize(address,address)| `0xd232b68635fd59b0845591bee02889cec16664fb879a619e8f308ecd9450459c` |

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

## Remaining steps (protocol not live until done)

These are manual transactions, NOT in the deploy script:

1. **Initialise the V4 pool** via `PoolManager.initialize()` with canonical PoolKey:
   `{ currency0: min(USDS, GBPF), currency1: max(USDS, GBPF), fee: 0, tickSpacing: 1, hooks: 0x27f5B70b461A62e4581119A3fC65758E64054088 }`
2. **Seed swap:** exact-input mint swap of 1 USDS via the V4 PoolManager. Deployer receives ~0.8 GBPF.
   (GBPF constructor already minted 1 wei dust to 0xdEaD so the `gbpfSupply == 0` guard does not trip.)
3. **Burn the seed:** transfer all GBPF held by the deployer to `0x000000000000000000000000000000000000dEaD`.

After step 3 the protocol is fully bootstrapped and open for use.
