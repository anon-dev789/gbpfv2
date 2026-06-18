// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {Deploy} from "../../script/Deploy.s.sol";

import {Hook} from "../../src/Hook.sol";
import {Vault} from "../../src/Vault.sol";
import {GBPF} from "../../src/GBPF.sol";
import {BatchRedeemer} from "../../src/periphery/BatchRedeemer.sol";

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

/// @dev Minimal V4 router (copied from Hook.fork.t.sol) used here only to mint GBPF for the test
///      users so they have something to redeem.
contract MinimalRouter is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    constructor(address pm) {
        POOL_MANAGER = IPoolManager(pm);
    }

    struct CallbackData {
        PoolKey key;
        SwapParams params;
        address payer;
        address recipient;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, address recipient) external returns (BalanceDelta) {
        bytes memory result =
            POOL_MANAGER.unlock(abi.encode(CallbackData({key: key, params: params, payer: msg.sender, recipient: recipient})));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "only PM");
        CallbackData memory cb = abi.decode(data, (CallbackData));
        BalanceDelta delta = POOL_MANAGER.swap(cb.key, cb.params, "");
        _resolve(cb.key.currency0, delta.amount0(), cb.payer, cb.recipient);
        _resolve(cb.key.currency1, delta.amount1(), cb.payer, cb.recipient);
        return abi.encode(delta);
    }

    function _resolve(Currency currency, int128 amount, address payer, address recipient) internal {
        if (amount == 0) return;
        if (amount < 0) {
            POOL_MANAGER.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20Like(Currency.unwrap(currency)).transferFrom(payer, address(POOL_MANAGER), uint256(uint128(-amount)));
            POOL_MANAGER.settle();
        } else {
            POOL_MANAGER.take(currency, recipient, uint256(uint128(amount)));
        }
    }
}

/// @dev Fork test for BatchRedeemer: users mint GBPF, deposit it, one batched redeem returns USDS
///      pro-rata, the flat fee tops up the ETH tank, and the runner is reimbursed.
contract BatchRedeemerForkTest is Test {
    using stdStorage for StdStorage;

    StdStorage internal sto;

    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_WETH_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address internal constant USDS_WHALE = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;

    Hook internal hook;
    Vault internal vault;
    GBPF internal gbpf;
    BatchRedeemer internal redeemer;
    MinimalRouter internal router;
    PoolKey internal poolKey;
    bool internal usdsIsToken0;

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

        usdsIsToken0 = USDS_TOKEN < address(gbpf);
        poolKey = PoolKey({
            currency0: usdsIsToken0 ? Currency.wrap(USDS_TOKEN) : Currency.wrap(address(gbpf)),
            currency1: usdsIsToken0 ? Currency.wrap(address(gbpf)) : Currency.wrap(USDS_TOKEN),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        IPoolManager(V4_POOL_MANAGER).initialize(poolKey, 79228162514264337593543950336);

        router = new MinimalRouter(V4_POOL_MANAGER);
        vm.warp(block.timestamp + 5 minutes + 1);

        // Mint GBPF for the two users (6000 / 4000 USDS in), then flush so the vault holds sUSDS
        // backing for the redeem.
        _mintGbpf(alice, 6_000e18);
        _mintGbpf(bob, 4_000e18);
        vault.flush();

        redeemer = new BatchRedeemer(
            owner, V4_POOL_MANAGER, address(hook), address(vault), address(gbpf), USDS_TOKEN, PSM3, USDC, WETH, USDC_WETH_POOL
        );

        vm.fee(1 gwei);
    }

    function _giveUsds(address to, uint256 amount) internal {
        vm.prank(USDS_WHALE);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS_TOKEN).transfer(to, amount);
    }

    function _mintGbpf(address who, uint256 usdsIn) internal {
        _giveUsds(who, usdsIn);
        vm.startPrank(who);
        IERC20Like(USDS_TOKEN).approve(address(router), usdsIn);
        router.swap(
            poolKey,
            SwapParams({zeroForOne: usdsIsToken0, amountSpecified: -int256(usdsIn), sqrtPriceLimitX96: 0}),
            who
        );
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(address(gbpf)).approve(address(redeemer), amount);
        redeemer.deposit(amount);
        vm.stopPrank();
    }

    // ============================================================
    // Core: batched redeem distributes USDS pro-rata
    // ============================================================

    function test_batch_redeem_distributes_usds_pro_rata() public {
        uint256 aliceGbpf = gbpf.balanceOf(alice);
        uint256 bobGbpf = gbpf.balanceOf(bob);
        assertGt(aliceGbpf, 0);
        assertGt(bobGbpf, 0);

        _deposit(alice, aliceGbpf);
        _deposit(bob, bobGbpf);

        assertEq(redeemer.totalQueued(), aliceGbpf + bobGbpf);
        assertEq(redeemer.depositorCount(), 2);

        uint256 aliceUsdsBefore = IERC20Like(USDS_TOKEN).balanceOf(alice);
        uint256 bobUsdsBefore = IERC20Like(USDS_TOKEN).balanceOf(bob);

        vm.prank(runner);
        redeemer.executeBatch(0);

        uint256 aliceUsds = IERC20Like(USDS_TOKEN).balanceOf(alice) - aliceUsdsBefore;
        uint256 bobUsds = IERC20Like(USDS_TOKEN).balanceOf(bob) - bobUsdsBefore;

        assertGt(aliceUsds, 0, "alice got no USDS");
        assertGt(bobUsds, 0, "bob got no USDS");

        // USDS out tracks GBPF in (minus equal per-head fees). Ratio ≈ aliceGbpf:bobGbpf.
        assertApproxEqRel(aliceUsds * bobGbpf, bobUsds * aliceGbpf, 1e15, "redeem not pro-rata");

        // Queue fully reset.
        assertEq(redeemer.totalQueued(), 0);
        assertEq(redeemer.depositorCount(), 0);
        assertEq(redeemer.pendingGbpf(alice), 0);

        // ~10000 USDS worth of GBPF redeems back to roughly 9900-10000 USDS (40bp round-trip-ish).
        assertGt(aliceUsds + bobUsds, 9_000e18, "total USDS implausibly low");
        assertLt(aliceUsds + bobUsds, 10_100e18, "total USDS implausibly high");
    }

    // ============================================================
    // Empty batch pays nothing
    // ============================================================

    function test_empty_batch_reverts() public {
        vm.deal(address(redeemer), 1 ether);
        vm.prank(runner);
        vm.expectRevert(BatchRedeemer.NothingToDo.selector);
        redeemer.executeBatch(0);
    }

    // ============================================================
    // Fees fund tank + pay runner
    // ============================================================

    function test_fees_fund_tank_and_pay_runner() public {
        vm.prank(owner);
        redeemer.setParams(1e18, 1e18, 2_000, 150, 0.2e18); // 1 USDS/dep + 1 USDS fixed

        _deposit(alice, gbpf.balanceOf(alice));
        _deposit(bob, gbpf.balanceOf(bob));

        uint256 runnerEthBefore = runner.balance;
        vm.prank(runner);
        redeemer.executeBatch(0);
        uint256 runnerPaid = runner.balance - runnerEthBefore;

        assertEq(redeemer.totalQueued(), 0, "batch did not complete");
        assertGt(runnerPaid, 0, "runner not reimbursed");
        assertGt(address(redeemer).balance, 0, "tank did not retain a buffer");
    }

    // ============================================================
    // Withdraw before a batch
    // ============================================================

    function test_withdraw_deposit_returns_gbpf() public {
        uint256 aliceGbpf = gbpf.balanceOf(alice);
        _deposit(alice, aliceGbpf);
        _deposit(bob, gbpf.balanceOf(bob));

        vm.prank(alice);
        redeemer.withdrawDeposit();

        assertEq(gbpf.balanceOf(alice), aliceGbpf, "alice not refunded GBPF");
        assertEq(redeemer.depositorCount(), 1);
        assertEq(redeemer.pendingGbpf(alice), 0);

        // Bob's redeem still works.
        uint256 bobBefore = IERC20Like(USDS_TOKEN).balanceOf(bob);
        vm.prank(runner);
        redeemer.executeBatch(0);
        assertGt(IERC20Like(USDS_TOKEN).balanceOf(bob) - bobBefore, 0, "bob got no USDS");
    }

    // ============================================================
    // minUsdsOut guard + min deposit
    // ============================================================

    function test_minUsdsOut_guard_reverts_on_unmet() public {
        _deposit(alice, gbpf.balanceOf(alice));
        vm.prank(runner);
        vm.expectRevert(BatchRedeemer.SlippageOrPause.selector);
        redeemer.executeBatch(type(uint256).max);
        assertGt(redeemer.totalQueued(), 0); // deposit stays queued
    }

    // ============================================================
    // Owner cannot rescue escrowed (claimable) USDS  [audit fix]
    // ============================================================

    function test_owner_cannot_rescue_escrowed_usds() public {
        // Simulate 5 USDS escrowed for a depositor whose push reverted (e.g. USDS froze them).
        sto.target(address(redeemer)).sig("totalClaimable()").checked_write(uint256(5e18));
        _giveUsds(address(redeemer), 7e18); // 5 escrowed + 2 genuine stray

        // Owner cannot reach into the escrowed 5 (only 2 is free).
        vm.prank(owner);
        vm.expectRevert(bytes("USDS reserved for escrow"));
        redeemer.rescueToken(USDS_TOKEN, 3e18, owner);

        // The genuine 2 stray is rescuable; the 5 escrowed remains for claimants.
        vm.prank(owner);
        redeemer.rescueToken(USDS_TOKEN, 2e18, owner);
        assertGe(IERC20Like(USDS_TOKEN).balanceOf(address(redeemer)), 5e18, "escrow not preserved");
    }

    function test_deposit_below_min_reverts() public {
        uint256 floor = redeemer.minGbpfDeposit();
        vm.startPrank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(address(gbpf)).approve(address(redeemer), type(uint256).max);
        vm.expectRevert(BatchRedeemer.BelowMinDeposit.selector);
        redeemer.deposit(floor - 1);
        redeemer.deposit(floor); // exactly the floor is accepted
        vm.stopPrank();
        assertEq(redeemer.pendingGbpf(alice), floor);
    }
}
