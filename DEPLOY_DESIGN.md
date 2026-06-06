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

Step 10.d–e require calling vault.deposit and gbpf.mint with msg.sender == hook. The script can't simply call them directly because it isn't the hook.

The seed happens via a real swap through the V4 PoolManager → hook. This is one of two ways:

### Operator-driven seed (chosen)

The deploy script ends after contracts are deployed and initialized. It prints operator instructions for the post-deploy steps:

1. Initialise the V4 pool by calling `PoolManager.initialize()` with the canonical PoolKey.
2. Pre-mint 1 wei GBPF to the burn address (avoids gbpfSupply == 0 revert; see below).
3. Execute a $1 USDS exact-input mint swap via V4. Resulting GBPF goes to the deployer.
4. The deployer transfers all GBPF to 0xdEaD (normal ERC20 transfer, not a mint to address(0)).

**Why not in-script:** the swap requires the PoolManager.unlock() callback machinery and a router-style helper. Writing all that in a Foundry script is possible but adds complexity for a one-time operation that benefits from human verification anyway.

**Front-running risk:** between "contracts deployed" and "pool initialised + seeded," someone could:

- **Initialise the V4 pool with the wrong PoolKey.** The hook's WrongPool check rejects swaps against any pool with a non-canonical key. The pool is useless. No harm.
- **Initialise the pool with the *correct* key and execute the seed swap themselves.** They'd pay 1 USDS, receive ~0.8 GBPF at oracle price. The protocol is bootstrapped exactly as intended; only the GBPF ends up with them instead of the deployer's burn address. Acceptable — they paid for it.
- **Do a tiny seed (e.g. 1 wei USDS) to capture outsized supply share.** The curve responds proportionally to solvency, so they can't actually extract value — they end up with 0.8 nano-GBPF and the protocol starts with weird tiny numbers but no economic asymmetry.

The cleanest mitigation is to perform steps 1–4 atomically from a single deployer-owned EOA in a single transaction (e.g. via a multicall router) immediately after the deploy script returns.

### In-script seed (rejected)

The Foundry script could call PoolManager via a thin local router. Rejected because:
- Doubles the script's complexity.
- The first PoolManager.initialize() call is a verifiable, irreversible step that benefits from human confirmation.
- Front-running risk is the same either way: between "Hook deployed" and "first swap executed" there is *always* a window.

## The "initial mint with empty supply" problem

The Hook's `beforeSwap` reverts if `gbpfSupply == 0` (guard against divide-by-zero in solvency math). The seed mint would be the first mint, so at that moment supply would be zero — and the Hook would revert.

**Resolution: the GBPF contract's constructor mints 1 wei of GBPF to `0xdEaD`.**

`totalSupply()` is therefore non-zero from the moment GBPF is deployed, before the Hook is even initialised. The first real user mint through the Hook proceeds normally with no special bootstrap step required.

Why in the constructor (not the deploy script):
- The deploy script can't mint directly because GBPF's `mint` is hook-only. Pre-`initialize`, HOOK is zero and any `mint` call reverts `NotInitialized` (intentional defence-in-depth).
- Adding a constructor-mint sidesteps the bootstrap chicken-and-egg cleanly: dust appears at deploy time without requiring any privileged operation post-deploy.
- The 1 wei is sent to `0xdEaD` which has no key behind it and no contract code. It's effectively burned.
- Audit surface: the constructor mint is a single `_mint(DUST_BURN_ADDRESS, 1)` call. Trivial to verify.

Alternatives considered and rejected:
- **Pre-mint via the deploy script.** Impossible because mint is hook-only post-initialize, and we can't mint pre-initialize because the contracts aren't wired yet.
- **Have the hook special-case `gbpfSupply == 0`.** Adds an audited branch in the hot swap path that's never executed post-bootstrap.
- **Pre-mint via a real exact-output mint swap of 1 wei GBPF.** Catch-22: that swap itself goes through the hook, which itself reverts on zero supply.

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
