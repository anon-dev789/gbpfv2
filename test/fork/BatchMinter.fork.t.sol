// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {Deploy} from "../../script/Deploy.s.sol";

import {Hook} from "../../src/Hook.sol";
import {Vault} from "../../src/Vault.sol";
import {GBPF} from "../../src/GBPF.sol";
import {BatchMinter} from "../../src/periphery/BatchMinter.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Fork test for the BatchMinter periphery: pools USDS from several users, runs one batched
///      mint through the real V4 hook pool, checks pro-rata GBPF distribution, the ETH gas-tank
///      top-up (USDS → USDC → WETH → ETH), and the runner reimbursement.
contract BatchMinterForkTest is Test {
    using stdStorage for StdStorage;

    StdStorage internal sto;

    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant SUSDS_TOKEN = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;
    address internal constant PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    // Uniswap V3 USDC/WETH 0.05% pool on Base.
    address internal constant USDC_WETH_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    // PSM3 custodies ~70M USDS at the fork block — our whale for funding test users.
    address internal constant USDS_WHALE = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;

    Hook internal hook;
    Vault internal vault;
    GBPF internal gbpf;
    BatchMinter internal batcher;
    PoolKey internal poolKey;

    address internal owner = makeAddr("owner");
    address internal runner = makeAddr("runner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        Deploy script = new Deploy();
        Deploy.Deployment memory d = script.run();
        hook = Hook(d.hook);
        vault = Vault(d.vault);
        gbpf = GBPF(d.gbpf);

        bool usdsIsToken0 = USDS_TOKEN < address(gbpf);
        poolKey = PoolKey({
            currency0: usdsIsToken0 ? Currency.wrap(USDS_TOKEN) : Currency.wrap(address(gbpf)),
            currency1: usdsIsToken0 ? Currency.wrap(address(gbpf)) : Currency.wrap(USDS_TOKEN),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        IPoolManager(V4_POOL_MANAGER).initialize(poolKey, 79228162514264337593543950336);

        batcher = new BatchMinter(
            owner, V4_POOL_MANAGER, address(hook), address(gbpf), USDS_TOKEN, PSM3, USDC, WETH, USDC_WETH_POOL
        );

        _giveUsds(alice, 6_000e18);
        _giveUsds(bob, 4_000e18);

        // Past the oracle warmup so the adapter is healthy.
        vm.warp(block.timestamp + 5 minutes + 1);
        // Non-zero basefee so the runner reimbursement is meaningful on the fork.
        vm.fee(1 gwei);
    }

    function _giveUsds(address to, uint256 amount) internal {
        vm.prank(USDS_WHALE);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS_TOKEN).transfer(to, amount);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        IERC20Like(USDS_TOKEN).approve(address(batcher), amount);
        batcher.deposit(amount);
        vm.stopPrank();
    }

    // ============================================================
    // Core: batched mint distributes GBPF pro-rata
    // ============================================================

    function test_batch_mint_distributes_gbpf_pro_rata() public {
        _deposit(alice, 6_000e18);
        _deposit(bob, 4_000e18);

        assertEq(batcher.totalQueued(), 10_000e18);
        assertEq(batcher.depositorCount(), 2);

        uint256 aliceGbpfBefore = gbpf.balanceOf(alice);
        uint256 bobGbpfBefore = gbpf.balanceOf(bob);

        vm.prank(runner);
        batcher.executeBatch(0);

        uint256 aliceGot = gbpf.balanceOf(alice) - aliceGbpfBefore;
        uint256 bobGot = gbpf.balanceOf(bob) - bobGbpfBefore;

        // Both received GBPF.
        assertGt(aliceGot, 0, "alice got no GBPF");
        assertGt(bobGot, 0, "bob got no GBPF");

        // Pro-rata on NET (post flat-fee) contributions: 6000:4000 ≈ 3:2. The flat 0.05 USDS/
        // depositor barely perturbs the ratio; allow 0.1% to cover that + rounding dust.
        assertApproxEqRel(aliceGot * 2, bobGot * 3, 1e15, "distribution not pro-rata");

        // Queue fully reset.
        assertEq(batcher.totalQueued(), 0);
        assertEq(batcher.depositorCount(), 0);
        assertEq(batcher.pendingUsds(alice), 0);
        assertEq(batcher.pendingUsds(bob), 0);

        // At ~1.25-1.30 GBP/USD, ~9999.8 USDS (after fees: 2×0.05 + 0.10) mints ~7600-8000 GBPF.
        assertGt(aliceGot + bobGot, 7_000e18, "total GBPF implausibly low");
        assertLt(aliceGot + bobGot, 8_500e18, "total GBPF implausibly high");
    }

    // ============================================================
    // Empty batch pays nothing (requirement 6)
    // ============================================================

    function test_empty_batch_reverts() public {
        vm.deal(address(batcher), 1 ether); // tank is funded...
        vm.prank(runner);
        vm.expectRevert(BatchMinter.NothingToDo.selector);
        batcher.executeBatch(0); // ...but nothing queued, so the runner cannot drain it
    }

    // ============================================================
    // Skim → ETH tank top-up + runner reimbursement
    // ============================================================

    function test_flat_fee_funds_tank_and_pays_runner() public {
        // Size the fees to comfortably exceed gas so the tank nets positive.
        vm.prank(owner);
        batcher.setParams(1e18, 1e18, 2_000, 150); // 1 USDS/depositor + 1 USDS fixed/batch

        _deposit(alice, 6_000e18);
        _deposit(bob, 4_000e18);

        uint256 runnerEthBefore = runner.balance;

        vm.prank(runner);
        batcher.executeBatch(0);

        // The flat fee (2 × 1 USDS) routed USDS→USDC→WETH→ETH into the tank, then the runner was
        // reimbursed gas + bonus from it.
        uint256 runnerPaid = runner.balance - runnerEthBefore;

        assertEq(batcher.totalQueued(), 0, "batch did not complete");
        // The route produced ETH (a silent try/catch failure would leave both at zero).
        assertGt(runnerPaid + address(batcher).balance, 0, "no ETH produced by fee route");
        // Runner was actually reimbursed, and a buffer remains: the 2 USDS fee dwarfs the gas
        // cost at the fork's basefee, so the tank is net positive after paying the runner.
        assertGt(runnerPaid, 0, "runner not reimbursed");
        assertGt(address(batcher).balance, 0, "tank did not retain a buffer");
    }

    // ============================================================
    // Flat fee is per-depositor, not proportional to size
    // ============================================================

    function test_flat_fee_is_per_depositor_not_proportional() public {
        // A whale and a minnow pay the SAME fee. Net contributions: 9000-fee and 100-fee.
        _giveUsds(alice, 3_000e18); // top up: setUp funded 6k, this test deposits 9k
        _deposit(alice, 9_000e18); // whale
        _deposit(bob, 100e18); // minnow

        uint256 aliceBefore = gbpf.balanceOf(alice);
        uint256 bobBefore = gbpf.balanceOf(bob);

        vm.prank(runner);
        batcher.executeBatch(0);

        uint256 aliceGot = gbpf.balanceOf(alice) - aliceBefore;
        uint256 bobGot = gbpf.balanceOf(bob) - bobBefore;

        // Both pay the SAME per-head fee: feeUsds + fixedFeeUsds/n (n = 2). Their GBPF tracks NET
        // USDS: (9000 - perHead):(100 - perHead).
        uint256 perHead = batcher.feeUsds() + batcher.fixedFeeUsds() / 2;
        uint256 aliceNet = 9_000e18 - perHead;
        uint256 bobNet = 100e18 - perHead;
        // aliceGot / bobGot == aliceNet / bobNet  ⇔  aliceGot*bobNet == bobGot*aliceNet
        assertApproxEqRel(aliceGot * bobNet, bobGot * aliceNet, 1e12, "GBPF not proportional to net");
    }

    // ============================================================
    // Depositor can reclaim before a batch
    // ============================================================

    function test_withdraw_deposit_returns_usds() public {
        _deposit(alice, 6_000e18);
        _deposit(bob, 4_000e18);

        uint256 aliceUsdsBefore = IERC20Like(USDS_TOKEN).balanceOf(alice);
        vm.prank(alice);
        batcher.withdrawDeposit();

        assertEq(IERC20Like(USDS_TOKEN).balanceOf(alice) - aliceUsdsBefore, 6_000e18, "alice not refunded");
        assertEq(batcher.totalQueued(), 4_000e18, "queue total wrong after withdraw");
        assertEq(batcher.depositorCount(), 1, "alice not removed from queue");
        assertEq(batcher.pendingUsds(alice), 0);

        // Bob's batch still works after alice leaves.
        uint256 bobBefore = gbpf.balanceOf(bob);
        vm.prank(runner);
        batcher.executeBatch(0);
        assertGt(gbpf.balanceOf(bob) - bobBefore, 0, "bob got no GBPF");
    }

    // ============================================================
    // Min deposit must cover the worst-case (solo) fee
    // ============================================================

    function test_deposit_below_min_reverts() public {
        uint256 minDeposit = batcher.feeUsds() + batcher.fixedFeeUsds(); // 0.15 USDS default
        vm.startPrank(alice);
        IERC20Like(USDS_TOKEN).approve(address(batcher), type(uint256).max);
        vm.expectRevert(BatchMinter.BelowMinDeposit.selector);
        batcher.deposit(minDeposit - 1);
        // Exactly the minimum is accepted.
        batcher.deposit(minDeposit);
        vm.stopPrank();
        assertEq(batcher.pendingUsds(alice), minDeposit);
    }

    // ============================================================
    // Owner cannot rescue escrowed (claimable) GBPF  [audit fix]
    // ============================================================

    function test_owner_cannot_rescue_escrowed_gbpf() public {
        // Run a real batch so `alice` holds GBPF we can move into the contract.
        _deposit(alice, 6_000e18);
        vm.prank(runner);
        batcher.executeBatch(0);

        // Simulate 5 GBPF escrowed for a depositor whose push reverted.
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(address(gbpf)).transfer(address(batcher), 7e18); // 5 escrowed + 2 stray
        sto.target(address(batcher)).sig("totalClaimable()").checked_write(uint256(5e18));

        // Owner cannot reach into the escrowed 5 (only 2 + prior dust is free).
        vm.prank(owner);
        vm.expectRevert(bytes("GBPF reserved for escrow"));
        batcher.rescueToken(address(gbpf), 3e18, owner);

        // The genuine stray is rescuable; the 5 escrowed remains for claimants.
        vm.prank(owner);
        batcher.rescueToken(address(gbpf), 2e18, owner);
        assertGe(gbpf.balanceOf(address(batcher)), 5e18, "escrow not preserved");
    }

    // ============================================================
    // minGbpfOut guard
    // ============================================================

    function test_minGbpfOut_guard_reverts_on_unmet() public {
        _deposit(alice, 6_000e18);
        vm.prank(runner);
        vm.expectRevert(BatchMinter.SlippageOrPause.selector);
        batcher.executeBatch(type(uint256).max); // demand impossibly high output
        // Deposit remains safely queued after the abort.
        assertEq(batcher.totalQueued(), 6_000e18);
    }
}
