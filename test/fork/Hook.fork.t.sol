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

    /// @dev Settle (delta > 0: we owe PM tokens) or take (delta < 0: PM owes us tokens).
    function _resolveLeg(Currency currency, int128 amount, address payer, address recipient) internal {
        if (amount == 0) return;
        if (amount > 0) {
            // We owe PM `amount` of this currency. Pull from payer, transfer to PM, settle.
            address token = Currency.unwrap(currency);
            uint256 value = uint256(uint128(amount));
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20Like(token).transferFrom(payer, address(POOL_MANAGER), value);
            POOL_MANAGER.settle();
        } else {
            // PM owes us. Take to the recipient directly.
            uint256 value = uint256(uint128(-amount));
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

        beneficiary = makeAddr("beneficiary-multisig");
        user = makeAddr("user");

        // Run the production deploy script.
        vm.setEnv("BENEFICIARY", vm.toString(beneficiary));
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
        deal(USDS_TOKEN, user, 10_000e18);

        // Bootstrap: pre-mint 1 wei of GBPF to a burn address so the first user swap doesn't
        // trip the gbpfSupply == 0 revert. We do this by performing a small mint via the
        // router from a deployer-owned address, then transferring the resulting GBPF to dead.
        // For test simplicity, we'll just mint the seed directly via the hook (impossible on
        // mainnet but fine in test setup).
        // To keep this test pure-fork-flow, do a real swap instead:
        address seeder = makeAddr("seeder");
        deal(USDS_TOKEN, seeder, 2e18);
        vm.startPrank(seeder);
        IERC20Like(USDS_TOKEN).approve(address(router), type(uint256).max);
        SwapParams memory seedParams =
            SwapParams({zeroForOne: usdsIsToken0, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});
        router.swap(poolKey, seedParams, seeder);
        // Now the seeder holds some GBPF. Transfer it to 0xDeaD.
        uint256 seedGbpf = gbpf.balanceOf(seeder);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        gbpf.transfer(0x000000000000000000000000000000000000dEaD, seedGbpf);
        vm.stopPrank();
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
        // Curve is symmetric so ~100% solvency → spread ~0, only the 20bp fee applies.
        assertGt(gbpfReceived, 700e18, "GBPF received implausibly low");
        assertLt(gbpfReceived, 850e18, "GBPF received implausibly high");

        // Vault now holds at least 1000 sUSDS-equivalent (minus the fee credited to
        // pendingBeneficiarySUsds, but the sUSDS itself is in the vault).
        uint256 vaultSusds = IERC20Like(SUSDS_TOKEN).balanceOf(address(vault));
        assertGt(vaultSusds, 900e18, "vault sUSDS implausibly low after mint");
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

        // Now redeem half of it.
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
        // At ~1.25 USDS/GBP and 0.2% fee, ~400 GBPF → ~498 USDS.
        // The mint just before slightly drifted solvency upward so spread is slightly negative,
        // making the redeem slightly worse. Allow generous bounds.
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

        // Redeem all of it.
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
