# Deploy design

Authoritative spec for `script/Deploy.s.sol` and any supporting deploy-time contracts. Written before implementation.

## The dependency problem

The five contracts have a circular dependency on the hook's address:

- `Hook` constructor takes `(poolManager, vault, oracle, gbpf, usds, sUsds, psm3)`.
- `Vault` constructor takes `(hook, beneficiary, sUSDS, ssrOracle)`.
- `GBPF` constructor takes `(hook)`.
- `OracleAdapter` constructor takes `(chainlink, sequencer, ...params)` — no circular dep.

The hook's address must encode the V4 hook flag bits (`BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG`) in the low 14 bits. That's mined via CREATE2 salt: `address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:]`. The salt is mined offline until the resulting address satisfies the flag mask.

The hook's `initCode` depends on its constructor args, which include the vault and gbpf addresses. So:
- We can't compute the hook's address without knowing vault and gbpf addresses.
- We can't deploy vault and gbpf without knowing the hook's address.

## Resolution: one-time initializer on Vault and GBPF

The Vault and GBPF constructors will NOT take the hook's address. Instead:

- They have a one-time `initialize(address hook)` function callable by the deployer exactly once.
- After the first call, `HOOK` is set and any further `initialize` call reverts.
- All other state and behaviour is identical to a constructor-set immutable.

Trade-off: "fully constructor-immutable" → "deploy-script-immutable." The hook address can only be set once, by whoever deploys, and the deploy script sets it within the same atomic transaction as the deploy itself.

**Why this is acceptable for "no admin" claims:**
- Anyone reading the chain after deploy can verify the HOOK was set to the correct hook contract, by checking it matches the on-chain hook address.
- The `initialize` function is the *only* state-changing function the deployer can call; everything else is hook-only.
- Once initialized, the protocol is indistinguishable from one with a constructor-set HOOK.

**Audit recommendation:** the audit must confirm `initialize` reverts on second call and that no other path can change `HOOK`.

### Alternative considered: orchestrator contract

A "Deployer" contract that holds the deploy logic and deploys all five contracts via internal CREATE2 calls. Avoids the initializer pattern at the cost of:
- A trusted Deployer contract that must be audited (its initCode hash is part of every CREATE2 address derivation).
- More complex tooling around bytecode generation.

Rejected because the initializer pattern is simpler, audit surface is smaller, and the one-time semantics are well-understood.

## Deploy ordering

```
1. Read Chainlink GBP/USD, sequencer uptime feed, sUSDS, USDS, PSM3, PoolManager
   addresses (Base mainnet; verified by fork tests).
2. Deploy OracleAdapter (no circular deps).
3. Deploy GBPF (no constructor args except a placeholder; HOOK unset).
4. Deploy Vault (HOOK unset; takes beneficiary, sUSDS, SSR oracle).
5. Compute the hook's init code:
     initCode = Hook.creationCode
              ++ abi.encode(POOL_MANAGER, address(vault), address(oracle), address(gbpf),
                            USDS, sUSDS, PSM3)
6. Mine a salt s such that keccak256(0xff ++ deployer ++ s ++ keccak256(initCode))[12:14] & 0xff
   yields BEFORE_SWAP_FLAG (0x80) | BEFORE_SWAP_RETURNS_DELTA_FLAG (0x08) = 0x88,
   and all other hook flag bits are clear.
7. Deploy Hook via CREATE2 with the mined salt.
8. Verify hook.code.length > 0 and (uint160(address(hook)) & 0x3fff) == 0x88.
9. Call vault.initialize(address(hook)) and gbpf.initialize(address(hook)). After these,
   the protocol is wired and immutable.
10. Atomic seed-and-burn:
      a. usds.mint(deployer, 1e18)  (or transfer from deployer if real USDS)
      b. usds.approve(psm3, 1e18)
      c. psm3.swapExactIn(USDS, sUSDS, 1e18, 0, address(vault), 0)
      d. Read sUSDS received → call vault.deposit(received, 0) AS THE HOOK (vm.prank in test;
         on mainnet the seed has to be done differently — see "seed on mainnet" below).
      e. gbpf.mint(BURN_ADDRESS, seedGbpf) AS THE HOOK.
```

## Seed on mainnet

Step 10.d–e require calling vault.deposit and gbpf.mint with msg.sender == hook. On a fork test we can use `vm.prank(hook)`. On mainnet there is no `vm.prank`.

Two options:

### Option I: Seed via a real mint swap through the hook + PoolManager

The deployer initialises the pool, holds the seed USDS, and performs a real exact-input mint swap of $1 USDS via the PoolManager → hook. The hook does its normal flow: pulls USDS, converts to sUSDS, deposits to vault, mints GBPF. The deployer then transfers the resulting GBPF (~0.8) to address(0xDeaD) via a normal ERC20 transfer.

- ✅ No bypass of the hook's normal flow; the seed is "the first real user mint."
- ✅ No special path in the production contracts; the deploy script just executes a swap.
- ✅ The deployer's GBPF goes to a burn address via a permitted transfer (not a mint to address(0)).
- Caveat: requires the PoolManager to be aware of the pool (PoolManager.initialize() must be called first), which is one more step in the script.

### Option II: A one-shot `seed()` function on the hook

Add a `seed()` function callable exactly once that bypasses the swap flow but uses the same code path. More code, more audit surface. Rejected.

**Decision: Option I.** The hook has no seed function. The deploy script performs a real mint swap.

## The "initial mint with empty supply" problem

The hook's `beforeSwap` reverts if `gbpfSupply == 0` (guard against divide-by-zero in solvency math). The seed mint is the first mint, so at that moment supply is zero. The hook will revert.

Options:
- Special-case the first mint in the hook (no guard if supply is 0). Adds code complexity and an obvious attack surface.
- Pre-mint a tiny amount of GBPF directly before the seed swap. Bypass.
- Allow the hook to compute "infinite solvency" when supply is 0 (treat as healthy mint at oracle rate, no curve spread). Same as the special case.

**Decision: pre-mint a dust amount of GBPF directly to the burn address BEFORE the seed swap, as part of the deploy script.**

Specifically:
- Step 9b: `gbpf.mint(BURN_ADDRESS, 1)` (one wei of GBPF).
- This brings totalSupply to 1 wei. Solvency at that moment is effectively infinite (any positive amount of sUSDS / 1 wei GBPF) but the curve saturates and the math doesn't divide by zero.
- Then step 10 (the seed swap) proceeds normally.

The dust mint and the seed swap together establish a non-degenerate starting state.

Alternative: have the hook's `gbpfSupply == 0` guard return the oracle price directly (no curve, no fee) for that single transaction. **Rejected** — adds a code branch in the hot path that's almost never executed but must be audited.

## HookMiner

The `HookMiner` library:
- Takes `(deployer, requiredFlags, mask, initCodeHash, startingSalt)`.
- Iterates salts until `address & mask == requiredFlags`.
- Returns the salt and the resulting address.

For BEFORE_SWAP and RETURNS_DELTA, the required flags are `0x88` and the mask covers the low 14 bits = `0x3fff`. We require all *other* hook bits to be zero so the PoolManager doesn't call any unintended callbacks.

A salt-mining loop:
```solidity
for (uint256 s = startingSalt; s < startingSalt + 100_000_000; s++) {
    address candidate = computeCreate2Address(deployer, bytes32(s), initCodeHash);
    if (uint160(candidate) & 0x3fff == 0x88) return (bytes32(s), candidate);
}
revert("mining limit reached");
```

In practice the right answer comes within a few hundred to a few thousand iterations on a desktop. We add a generous iteration cap to fail visibly rather than infinitely loop.

## CREATE2 deployer

Two options:
- Foundry's built-in CREATE2 deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C` (standard, present on every chain).
- Safe Singleton Factory at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` (also widely deployed).

**Decision: Foundry's default CREATE2 deployer.** Simpler — `forge create` and the script's `new Hook{salt: s}(...)` syntax both use it automatically. No need to encode an external factory call.

## Pre-deploy verification

The deploy script's first step is to assert every hardcoded Base mainnet address has bytecode and responds to the expected interfaces. If anything fails, the script reverts before deploying. This is the same set of checks as `test/fork/BaseAddresses.t.sol` — we'll factor those into a reusable library that both the deploy script and the fork tests can call.

## Script outputs

After successful deploy, the script writes (to stdout and optionally a JSON file) every deployed address plus the salt used. This is the artefact for Basescan verification, address transparency, and audit.

## What we have NOT yet done

- Test the deploy script against a Base fork (next module).
- Verify the chosen CREATE2 deployer's bytecode is identical on Base mainnet to local Anvil (a sanity check before going live).
- The "real mainnet seed" step requires the deployer to actually hold $1 of USDS on Base. The script assumes this; the deploy README will instruct the operator to fund the deployer first.
