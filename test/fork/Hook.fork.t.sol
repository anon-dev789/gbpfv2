// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";

import {Hook} from "../../src/Hook.sol";
import {Vault} from "../../src/Vault.sol";
import {GBPF} from "../../src/GBPF.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Minimal swap router that implements the V4 unlock callback. Used by the fork test to
///      drive real swaps against the real Base PoolManager. It is generic — the test pre-funds
///      it with the input token, calls swap(key, params), the PoolManager calls back through
///      unlockCallback, which executes the swap and settles the resulting deltas.
contract MinimalRouter is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    constructor(address poolManager_) {
        POOL_MANAGER = IPoolManager(poolManager_);
    }

    struct CallbackData {
        PoolKey key;
        SwapParams params;
        address payer;
        address recipient;
    }

    /// @notice Execute a swap. The caller must hold and approve the input token to this router
    ///         (or just transfer it in before calling, since we pull from `payer`).
    function swap(PoolKey calldata key, SwapParams calldata params, address recipient)
        external
        returns (BalanceDelta delta)
    {
        bytes memory data =
            abi.encode(CallbackData({key: key, params: params, payer: msg.sender, recipient: recipient}));
        bytes memory result = POOL_MANAGER.unlock(data);
        delta = abi.decode(result, (BalanceDelta));
    }

    /// @notice Called by the PoolManager when we call `unlock()`. We run the actual swap here,
    ///         then settle the resulting positive deltas (we owe PM) by transferring tokens in,
    ///         and take any negative deltas (PM owes us) and forward to the recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "router: only PoolManager");
        CallbackData memory cb = abi.decode(data, (CallbackData));

        BalanceDelta delta = POOL_MANAGER.swap(cb.key, cb.params, "");

        // Resolve currency0 leg.
        _resolveLeg(cb.key.currency0, delta.amount0(), cb.payer, cb.recipient);
        // Resolve currency1 leg.
        _resolveLeg(cb.key.currency1, delta.amount1(), cb.payer, cb.recipient);

        return abi.encode(delta);
    }

    /// @dev V4 delta from the SWAPPER's perspective:
    ///        delta < 0  → swapper owes PM (sync + transfer + settle)
    ///        delta > 0  → PM owes swapper (take)
    function _resolveLeg(Currency currency, int128 amount, address payer, address recipient) internal {
        if (amount == 0) return;
        if (amount < 0) {
            address token = Currency.unwrap(currency);
            uint256 value = uint256(uint128(-amount));
            // V4's settle pattern: sync first so PM snapshots the pre-transfer balance,
            // then transfer in, then settle to compute the credit.
            POOL_MANAGER.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20Like(token).transferFrom(payer, address(POOL_MANAGER), value);
            POOL_MANAGER.settle();
        } else {
            uint256 value = uint256(uint128(amount));
            POOL_MANAGER.take(currency, recipient, value);
        }
    }

    // The router does not hold ERC-20 balance permanently; it pulls/pushes per swap.
    // No fallback needed for any case other than the ERC20 callback hook.
}

/// @dev Hook fork test: deploys the full stack against a Base mainnet fork, initialises the
///      real V4 pool, performs a real mint and a real redeem through the real PoolManager,
///      and verifies token balances + hook events.
contract HookForkTest is Test {
    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;
    address internal constant CHAINLINK_GBP_USD = 0xCceA6576904C118037695eB71195a5425E69Fa15;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant SUSDS_TOKEN = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;

    Hook internal hook;
    Vault internal vault;
    GBPF internal gbpf;
    OracleAdapter internal oracle;
    MinimalRouter internal router;
    PoolKey internal poolKey;

    address internal beneficiary;
    address internal user;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        beneficiary = 0x621D531A97185BcB5f3E513C192a3327163377D3; // hardcoded in Deploy.s.sol
        user = makeAddr("user");

        // Run the production deploy script.
        Deploy script = new Deploy();
        Deploy.Deployment memory d = script.run();
        hook = Hook(d.hook);
        vault = Vault(d.vault);
        gbpf = GBPF(d.gbpf);
        oracle = OracleAdapter(d.oracle);

        // Build the canonical PoolKey (matches the hook's POOL_KEY_HASH).
        bool usdsIsToken0 = USDS_TOKEN < address(gbpf);
        poolKey = PoolKey({
            currency0: usdsIsToken0 ? Currency.wrap(USDS_TOKEN) : Currency.wrap(address(gbpf)),
            currency1: usdsIsToken0 ? Currency.wrap(address(gbpf)) : Currency.wrap(USDS_TOKEN),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        // Initialise the V4 pool. Our hook ignores sqrtPriceX96 (oracle-driven pricing) but V4
        // requires an initial value. Use Q96-encoded 1 (= 2^96) — a placeholder that satisfies
        // V4's bounds check.
        IPoolManager(V4_POOL_MANAGER).initialize(poolKey, 79228162514264337593543950336);

        // Deploy the router and seed the user with USDS so they can mint.
        router = new MinimalRouter(V4_POOL_MANAGER);
        _giveUsds(user, 10_000e18);

        // GBPF's constructor already minted 1 wei of dust to 0xDeaD, so gbpfSupply > 0 from
        // the moment of deploy. The first user mint via the Hook proceeds normally — no need
        // for a separate bootstrap seed step.

        // Advance past the oracle warmup window so the adapter reports healthy. The Chainlink
        // answer is held over the warp (no new round), which is well within MAX_STALENESS, so the
        // TWAP is simply the held price. On mainnet the protocol is likewise only usable once a
        // full TWAP window of observations exists.
        vm.warp(block.timestamp + 5 minutes + 1);
    }

    /// @dev Bridged USDS on Base uses Sky's Usds.sol. Foundry's `deal()` cheatcode probes for
    ///      the balanceOf slot via a heuristic that picks the wrong slot on this contract.
    ///      Rather than guessing the slot ourselves, just prank-transfer from a known whale.
    ///      Spark PSM3 holds ~70M USDS on Base at the pinned fork block, so transferring out
    ///      10k USDS is trivial.
    address internal constant USDS_WHALE = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;

    function _giveUsds(address to, uint256 amount) internal {
        require(IERC20Like(USDS_TOKEN).balanceOf(USDS_WHALE) >= amount, "whale doesn't have enough USDS");
        vm.prank(USDS_WHALE);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS_TOKEN).transfer(to, amount);
        require(IERC20Like(USDS_TOKEN).balanceOf(to) >= amount, "whale transfer didn't land");
    }

    // ============================================================
    // Real-pool mint
    // ============================================================

    function test_real_pool_mint_succeeds_and_produces_gbpf() public {
        bool usdsIsToken0 = USDS_TOKEN < address(gbpf);
        uint256 userUsdsBefore = IERC20Like(USDS_TOKEN).balanceOf(user);
        uint256 userGbpfBefore = gbpf.balanceOf(user);

        vm.startPrank(user);
        IERC20Like(USDS_TOKEN).approve(address(router), type(uint256).max);
        SwapParams memory params =
            SwapParams({zeroForOne: usdsIsToken0, amountSpecified: -int256(1000e18), sqrtPriceLimitX96: 0});
        router.swap(poolKey, params, user);
        vm.stopPrank();

        // User parted with 1000 USDS exactly.
        assertEq(userUsdsBefore - IERC20Like(USDS_TOKEN).balanceOf(user), 1000e18);
        // User received some GBPF.
        uint256 gbpfReceived = gbpf.balanceOf(user) - userGbpfBefore;
        // At ~live GBP/USD (~1.25-1.30 in 2026), 1000 USDS mint should produce 750-800 GBPF.
        assertGt(gbpfReceived, 700e18, "GBPF received implausibly low");
        assertLt(gbpfReceived, 850e18, "GBPF received implausibly high");

        // Under the V4 6909-claim flow, the mint creates a pending USDS claim on the vault.
        // sUSDS only appears in the vault after flush() runs.
        uint256 vaultPendingClaim = vault.pendingUsdsClaim();
        assertGt(vaultPendingClaim, 900e18, "vault pending USDS claim implausibly low after mint");

        // Anyone can flush. Run it and verify the claim converts to sUSDS principal.
        vault.flush();
        uint256 vaultSusds = IERC20Like(SUSDS_TOKEN).balanceOf(address(vault));
        // After flush, vault holds ~1000 sUSDS (PSM3 conversion at the live SSR rate).
        assertGt(vaultSusds, 900e18, "vault sUSDS implausibly low after flush");
        // Pending claim cleared.
        assertEq(vault.pendingUsdsClaim(), 0);
    }

    // ============================================================
    // Real-pool redeem
    // ============================================================

    function test_real_pool_redeem_returns_usds() public {
        bool usdsIsToken0 = USDS_TOKEN < address(gbpf);

        // First mint so the user has GBPF to redeem.
        vm.startPrank(user);
        IERC20Like(USDS_TOKEN).approve(address(router), type(uint256).max);
        SwapParams memory mintParams =
            SwapParams({zeroForOne: usdsIsToken0, amountSpecified: -int256(1000e18), sqrtPriceLimitX96: 0});
        router.swap(poolKey, mintParams, user);
        uint256 gbpfHeld = gbpf.balanceOf(user);
        assertGt(gbpfHeld, 0);
        vm.stopPrank();

        // Flush the mint's USDS claim into real sUSDS principal so the redeem has backing.
        vault.flush();

        // Now redeem half of the GBPF.
        vm.startPrank(user);
        uint256 gbpfToRedeem = gbpfHeld / 2;
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        gbpf.approve(address(router), type(uint256).max);
        uint256 userUsdsBeforeRedeem = IERC20Like(USDS_TOKEN).balanceOf(user);
        SwapParams memory redeemParams = SwapParams({
            zeroForOne: !usdsIsToken0, // selling GBPF for USDS
            amountSpecified: -int256(gbpfToRedeem),
            sqrtPriceLimitX96: 0
        });
        router.swap(poolKey, redeemParams, user);
        vm.stopPrank();

        // User burned the right amount of GBPF.
        assertEq(gbpf.balanceOf(user), gbpfHeld - gbpfToRedeem);
        // User received USDS roughly equal to gbpfToRedeem * twap * (1 - fee).
        uint256 usdsReceived = IERC20Like(USDS_TOKEN).balanceOf(user) - userUsdsBeforeRedeem;
        assertGt(usdsReceived, gbpfToRedeem * 110 / 100, "USDS received implausibly low");
        assertLt(usdsReceived, gbpfToRedeem * 140 / 100, "USDS received implausibly high");
    }

    // ============================================================
    // Roundtrip checks
    // ============================================================

    function test_real_pool_mint_then_redeem_roundtrip_costs_fees() public {
        bool usdsIsToken0 = USDS_TOKEN < address(gbpf);

        vm.startPrank(user);
        IERC20Like(USDS_TOKEN).approve(address(router), type(uint256).max);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        gbpf.approve(address(router), type(uint256).max);

        uint256 startUsds = IERC20Like(USDS_TOKEN).balanceOf(user);

        // Mint 1000 USDS worth of GBPF.
        SwapParams memory mintParams =
            SwapParams({zeroForOne: usdsIsToken0, amountSpecified: -int256(1000e18), sqrtPriceLimitX96: 0});
        router.swap(poolKey, mintParams, user);
        uint256 gbpfHeld = gbpf.balanceOf(user);
        vm.stopPrank();

        // Flush so the USDS claim becomes real sUSDS principal, backing the upcoming redeem.
        vault.flush();

        // Redeem all of the GBPF.
        vm.startPrank(user);
        SwapParams memory redeemParams =
            SwapParams({zeroForOne: !usdsIsToken0, amountSpecified: -int256(gbpfHeld), sqrtPriceLimitX96: 0});
        router.swap(poolKey, redeemParams, user);
        vm.stopPrank();

        uint256 endUsds = IERC20Like(USDS_TOKEN).balanceOf(user);

        // The user should have lost some USDS to fees + curve. At 100% solvency the round-trip
        // cost is just 40bp (20bp each side) + tiny rounding. After the mint, solvency tilts
        // slightly above 100% (the fee stays in the vault), so the redeem side gets a slightly
        // worse spread. Expect total loss of 40-100 bp.
        assertLt(endUsds, startUsds, "user came out ahead on round trip");
        uint256 loss = startUsds - endUsds;
        assertGt(loss, 1e18, "round-trip cost less than 0.1% (suspicious)");
        assertLt(loss, 100e18, "round-trip cost > 10% (something's wrong)");
    }
}
