// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Hook} from "../src/Hook.sol";
import {Vault} from "../src/Vault.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {GBPF} from "../src/GBPF.sol";
import {SpreadCurve} from "../src/SpreadCurve.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockUsds} from "./mocks/MockUsds.sol";
import {MockSUsds} from "./mocks/MockSUsds.sol";
import {MockSSRAuthOracle} from "./mocks/MockSSRAuthOracle.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockPSM3} from "./mocks/MockPSM3.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract HookTest is Test {
    // -- protocol parameters --
    uint256 internal constant TWAP_WINDOW = 5 minutes;
    uint256 internal constant MAX_STALENESS = 26 hours;
    uint256 internal constant MAX_STEP_WAD = 0.02e18;
    uint256 internal constant SEQUENCER_GRACE = 1 hours;
    uint256 internal constant COOLDOWN = 15 minutes;
    uint256 internal constant FLAT_FEE_WAD = 2e15; // 20bp; mirror of Hook constant
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    // -- chainlink price --
    int256 internal constant GBP_USD_FEED = 1.25e8; // 1.25 USDS per GBP, 8 decimals
    uint256 internal constant GBP_USD_WAD = 1.25e18;

    // -- contracts --
    Hook internal hook;
    Vault internal vault;
    OracleAdapter internal oracle;
    GBPF internal gbpf;
    MockUsds internal usds;
    MockSUsds internal sUsds;
    MockSSRAuthOracle internal ssr;
    MockChainlinkFeed internal cl;
    MockChainlinkFeed internal seq;
    MockPSM3 internal psm;
    MockPoolManager internal pm;

    address internal beneficiary;
    address internal user;

    PoolKey internal poolKey;

    function setUp() public {
        vm.warp(1_700_000_000);

        beneficiary = makeAddr("beneficiary");
        user = makeAddr("user");

        usds = new MockUsds();
        sUsds = new MockSUsds();
        ssr = new MockSSRAuthOracle(RAY); // chi = 1 ray = 1 USDS per sUSDS initially
        cl = new MockChainlinkFeed(8, GBP_USD_FEED, block.timestamp);
        seq = new MockChainlinkFeed(0, 0, block.timestamp - 2 days);
        psm = new MockPSM3(address(usds), address(sUsds), RAY); // 1:1 USDS:sUSDS initially

        pm = new MockPoolManager();
        oracle = new OracleAdapter(
            address(cl), address(seq), TWAP_WINDOW, MAX_STALENESS, MAX_STEP_WAD, SEQUENCER_GRACE, COOLDOWN
        );

        // Deploy GBPF and Vault first (with HOOK unset), then the Hook (knowing both addresses),
        // then call initialize(hook) on Vault and GBPF to wire the HOOK address. This matches
        // the production deploy pattern described in DEPLOY_DESIGN.md.
        gbpf = new GBPF();
        vault = new Vault(beneficiary, address(sUsds), address(ssr));
        hook = new Hook(
            address(pm), address(vault), address(oracle), address(gbpf), address(usds), address(sUsds), address(psm)
        );
        vault.initialize(address(hook));
        gbpf.initialize(address(hook));

        // Build the canonical poolKey the hook expects.
        bool usdsIsToken0 = address(usds) < address(gbpf);
        poolKey = PoolKey({
            currency0: usdsIsToken0 ? Currency.wrap(address(usds)) : Currency.wrap(address(gbpf)),
            currency1: usdsIsToken0 ? Currency.wrap(address(gbpf)) : Currency.wrap(address(usds)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        // Bootstrap the protocol: seed $1 worth (1e18 USDS) → mint corresponding GBPF, burn it.
        // This matches the deploy-script flow committed in design_doc.md / project_gbpf_bootstrap.md.
        // We use raw vault.deposit + GBPF.mint instead of going through the hook so we can run it
        // outside a PoolManager.unlock() context.
        _bootstrap();
    }

    function _bootstrap() internal {
        // The bootstrap is conceptually: $1 USDS → 1 sUSDS (chi=1) → mint ~0.8 GBPF (at 1.25 GBP/USD)
        //   → send all the GBPF to address(0).
        // But our GBPF.mint() rejects address(0). So instead: mint to a burner address and never
        // touch it. Equivalent for our purposes (it's permanently locked).
        uint256 seedUsds = 1e18;
        usds.mint(address(this), seedUsds);
        usds.approve(address(psm), seedUsds);
        uint256 received = psm.swapExactIn(address(usds), address(sUsds), seedUsds, 0, address(vault), 0);
        vm.prank(address(hook));
        vault.deposit(received, 0);

        // Mint GBPF equivalent to the seed (at oracle rate, ignoring fees): 1 USDS / 1.25 = 0.8 GBPF.
        // Send to a "burn" address that GBPF.mint() will accept.
        uint256 seedGbpf = received * WAD / GBP_USD_WAD;
        address burn = address(0xDeaD);
        vm.prank(address(hook));
        gbpf.mint(burn, seedGbpf);
    }

    // ============================================================
    // Construction
    // ============================================================

    function test_constructor_records_immutables() public view {
        assertEq(address(hook.POOL_MANAGER()), address(pm));
        assertEq(address(hook.VAULT()), address(vault));
        assertEq(address(hook.ORACLE()), address(oracle));
        assertEq(address(hook.GBPF_TOKEN()), address(gbpf));
        assertEq(hook.USDS(), address(usds));
        assertEq(hook.SUSDS(), address(sUsds));
        assertEq(address(hook.PSM3()), address(psm));
    }

    function test_constructor_sets_USDS_IS_TOKEN0() public view {
        assertEq(hook.USDS_IS_TOKEN0(), address(usds) < address(gbpf));
    }

    function test_constructor_sets_max_approvals_to_psm() public view {
        assertEq(usds.allowance(address(hook), address(psm)), type(uint256).max);
        assertEq(sUsds.allowance(address(hook), address(psm)), type(uint256).max);
    }

    function test_constructor_computes_poolKeyHash() public view {
        assertEq(hook.POOL_KEY_HASH(), keccak256(abi.encode(poolKey)));
    }

    // ============================================================
    // beforeSwap access control + pool guard
    // ============================================================

    function test_beforeSwap_revertsIfNotPoolManager() public {
        SwapParams memory params =
            SwapParams({zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: -int256(100e18), sqrtPriceLimitX96: 0});
        vm.expectRevert(Hook.NotPoolManager.selector);
        hook.beforeSwap(user, poolKey, params, "");
    }

    function test_beforeSwap_revertsOnWrongPool() public {
        PoolKey memory bad = poolKey;
        bad.fee = 3000; // mutate
        SwapParams memory params =
            SwapParams({zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: -int256(100e18), sqrtPriceLimitX96: 0});
        vm.prank(address(pm));
        vm.expectRevert(Hook.WrongPool.selector);
        hook.beforeSwap(user, bad, params, "");
    }

    function test_beforeSwap_revertsOnZeroAmount() public {
        SwapParams memory params =
            SwapParams({zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: 0, sqrtPriceLimitX96: 0});
        vm.prank(address(pm));
        vm.expectRevert(Hook.ZeroSwap.selector);
        hook.beforeSwap(user, poolKey, params, "");
    }

    // ============================================================
    // Oracle pause blocks swaps
    // ============================================================

    function test_beforeSwap_revertsWhenOraclePaused() public {
        // Push a >2% Chainlink update to trip the deviation circuit-breaker, then call swap.
        vm.warp(block.timestamp + 1 hours);
        cl.set(1.5e8, block.timestamp); // +20% jump

        SwapParams memory params =
            SwapParams({zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: -int256(100e18), sqrtPriceLimitX96: 0});
        // Fund PM with USDS so the take would otherwise succeed.
        pm.fund(address(usds), 100e18);
        vm.prank(address(pm));
        vm.expectRevert(Hook.OraclePaused.selector);
        hook.beforeSwap(user, poolKey, params, "");
    }

    // ============================================================
    // Mint exact-input — happy path
    // ============================================================

    function test_mint_exactIn_produces_expected_gbpf() public {
        uint256 usdsIn = 1000e18;
        pm.fund(address(usds), usdsIn);

        SwapParams memory params =
            SwapParams({zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: -int256(usdsIn), sqrtPriceLimitX96: 0});

        uint256 gbpfBalBefore = gbpf.balanceOf(address(pm));

        vm.prank(address(pm));
        hook.beforeSwap(user, poolKey, params, "");

        // The vault holds the new sUSDS (less any beneficiary fee credit, which stays in vault too,
        // so vault sUSDS balance grew by ~usdsIn at chi=1).
        // We expect gbpfOut at approx 1000 / (1.25 * (1 + 0 + 0.002)) ≈ 798.4 GBPF
        // (at 100% solvency post-bootstrap so spread = 0).
        uint256 gbpfDelta = gbpf.balanceOf(address(pm)) - gbpfBalBefore;
        assertGt(gbpfDelta, 798e18, "GBPF out too low");
        assertLt(gbpfDelta, 799e18, "GBPF out too high");
    }

    function test_mint_exactIn_pendingBeneficiary_increments_by_fee() public {
        uint256 usdsIn = 1000e18;
        pm.fund(address(usds), usdsIn);

        uint256 pendingBefore = vault.pendingBeneficiarySUsds();
        SwapParams memory params =
            SwapParams({zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: -int256(usdsIn), sqrtPriceLimitX96: 0});
        vm.prank(address(pm));
        hook.beforeSwap(user, poolKey, params, "");

        uint256 pendingDelta = vault.pendingBeneficiarySUsds() - pendingBefore;
        // Fee in USDS terms: 1000 * 0.002 / (1 + 0 + 0.002) ≈ 1.996 USDS.
        // At chi=1, sUSDS = USDS, so fee in sUSDS ≈ 1.996 sUSDS.
        assertGt(pendingDelta, 1.99e18);
        assertLt(pendingDelta, 2.01e18);
    }

    // ============================================================
    // Mint exact-output
    // ============================================================

    function test_mint_exactOut_consumes_expected_usds() public {
        uint256 gbpfOutTarget = 100e18;
        // Generously fund PM with USDS so the take succeeds whatever we compute.
        pm.fund(address(usds), 1_000_000e18);

        SwapParams memory params = SwapParams({
            zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: int256(gbpfOutTarget), sqrtPriceLimitX96: 0
        });
        uint256 gbpfBalBefore = gbpf.balanceOf(address(pm));
        vm.prank(address(pm));
        hook.beforeSwap(user, poolKey, params, "");

        // PM should now hold exactly gbpfOutTarget more GBPF.
        assertEq(gbpf.balanceOf(address(pm)) - gbpfBalBefore, gbpfOutTarget);

        // USDS taken from PM should be ~ 100 GBPF * 1.25 * (1 + 0 + 0.002) ≈ 125.25 USDS.
        uint256 usdsLeftInPm = usds.balanceOf(address(pm));
        uint256 usdsConsumed = 1_000_000e18 - usdsLeftInPm;
        assertGt(usdsConsumed, 125e18);
        assertLt(usdsConsumed, 126e18);
    }

    // ============================================================
    // Redeem exact-input
    // ============================================================

    function test_redeem_exactIn_produces_expected_usds() public {
        // Mint a chunk of GBPF first (this puts GBPF onto the PoolManager — that's exactly
        // what the V4 swap path would have given a real user). Then redeem the same GBPF.
        // After mint, vault is at ~100% solvency, and redeeming all of it brings us back to
        // ~100% with a slight overshoot from the fee staying in the vault.
        _userMints(1000e18);
        // Read how much GBPF the mint produced (it ended up on the PoolManager).
        uint256 gbpfOnPm = gbpf.balanceOf(address(pm));

        // Now redeem 100 GBPF out of what the user got. Solvency should still be ~100%.
        uint256 gbpfIn = 100e18;
        require(gbpfOnPm >= gbpfIn, "test setup: not enough GBPF on PM");

        SwapParams memory params =
            SwapParams({zeroForOne: !hook.USDS_IS_TOKEN0(), amountSpecified: -int256(gbpfIn), sqrtPriceLimitX96: 0});
        uint256 usdsBalBefore = usds.balanceOf(address(pm));
        vm.prank(address(pm));
        hook.beforeSwap(user, poolKey, params, "");

        // At ~100% solvency, redeem price = twap * (1 + ~0 - 0.002) ≈ 1.2475.
        // For 100 GBPF: ~124.75 USDS. Bounds: 124–125.5.
        uint256 usdsDelta = usds.balanceOf(address(pm)) - usdsBalBefore;
        assertGt(usdsDelta, 124e18, "USDS out too low");
        assertLt(usdsDelta, 125.5e18, "USDS out too high");
    }

    // ============================================================
    // Redeem exact-output
    // ============================================================

    function test_redeem_exactOut_consumes_expected_gbpf() public {
        _userMints(1000e18); // PM now holds ~798 GBPF post-mint, vault at ~100% solvency.
        uint256 usdsTarget = 100e18;

        SwapParams memory params =
            SwapParams({zeroForOne: !hook.USDS_IS_TOKEN0(), amountSpecified: int256(usdsTarget), sqrtPriceLimitX96: 0});
        uint256 gbpfBefore = gbpf.balanceOf(address(pm));
        uint256 usdsBefore = usds.balanceOf(address(pm));
        vm.prank(address(pm));
        hook.beforeSwap(user, poolKey, params, "");

        // PM should now hold exactly usdsTarget more USDS.
        assertEq(usds.balanceOf(address(pm)) - usdsBefore, usdsTarget);

        // GBPF consumed at ~100% solvency: 100 / (1.25 * (1 + ~0 - 0.002)) ≈ 80.16 GBPF.
        uint256 gbpfConsumed = gbpfBefore - gbpf.balanceOf(address(pm));
        assertGt(gbpfConsumed, 80e18);
        assertLt(gbpfConsumed, 81e18);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _userMints(uint256 usdsAmount) internal {
        pm.fund(address(usds), usdsAmount);
        SwapParams memory params =
            SwapParams({zeroForOne: hook.USDS_IS_TOKEN0(), amountSpecified: -int256(usdsAmount), sqrtPriceLimitX96: 0});
        vm.prank(address(pm));
        hook.beforeSwap(user, poolKey, params, "");
    }
}
