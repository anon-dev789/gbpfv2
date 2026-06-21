// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";

import {Hook} from "../../src/Hook.sol";
import {Vault} from "../../src/Vault.sol";
import {GBPF} from "../../src/GBPF.sol";
import {ForwarderMinter} from "../../src/periphery/ForwarderMinter.sol";
import {ForwarderRedeemer} from "../../src/periphery/ForwarderRedeemer.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Fork test for the forwarder ("send-and-forget") batchers. The headline test proves a user
///      deposits with a PLAIN TRANSFER to their computed address — no approve, no contract call —
///      and a permissionless runner sweeps and mints/redeems them, with trustless attribution.
contract ForwarderForkTest is Test {
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
    ForwarderMinter internal minter;
    ForwarderRedeemer internal redeemer;
    PoolKey internal poolKey;
    bool internal usdsIsToken0;

    address internal owner = makeAddr("owner");
    address internal runner = makeAddr("runner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

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

        minter = new ForwarderMinter(
            owner, V4_POOL_MANAGER, address(hook), address(gbpf), USDS_TOKEN, PSM3, USDC, WETH, USDC_WETH_POOL
        );
        redeemer = new ForwarderRedeemer(
            owner,
            V4_POOL_MANAGER,
            address(hook),
            address(vault),
            address(gbpf),
            USDS_TOKEN,
            PSM3,
            USDC,
            WETH,
            USDC_WETH_POOL
        );

        vm.warp(block.timestamp + 5 minutes + 1);
        vm.fee(1 gwei);
    }

    function _giveUsds(address to, uint256 amount) internal {
        vm.prank(USDS_WHALE);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS_TOKEN).transfer(to, amount);
    }

    /// @dev THE user action: a plain ERC20 transfer to the computed deposit address. No approve,
    ///      no call to the batcher.
    function _depositUsds(address user, uint256 amount) internal {
        _giveUsds(user, amount);
        address dep = minter.depositAddressOf(user); // compute BEFORE prank (prank hits next call only)
        vm.prank(user);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS_TOKEN).transfer(dep, amount);
    }

    // ============================================================
    // Headline: send-and-forget mint, trustless pro-rata
    // ============================================================

    function test_mint_send_and_forget_pro_rata() public {
        // Two users each just *send USDS to an address*. They never touch the minter contract.
        _depositUsds(alice, 6_000e18);
        _depositUsds(bob, 4_000e18);

        // Funds sit at the users' own deposit addresses until swept.
        assertEq(IERC20Like(USDS_TOKEN).balanceOf(minter.depositAddressOf(alice)), 6_000e18);
        assertEq(IERC20Like(USDS_TOKEN).balanceOf(minter.depositAddressOf(bob)), 4_000e18);

        uint256 aliceGbpfBefore = gbpf.balanceOf(alice);
        uint256 bobGbpfBefore = gbpf.balanceOf(bob);

        // Anyone runs it — the runner supplies the candidate list (discovered off-chain).
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        vm.prank(runner);
        minter.sweepAndExecute(users, 0);

        uint256 aliceGot = gbpf.balanceOf(alice) - aliceGbpfBefore;
        uint256 bobGot = gbpf.balanceOf(bob) - bobGbpfBefore;
        assertGt(aliceGot, 0, "alice got no GBPF");
        assertGt(bobGot, 0, "bob got no GBPF");
        // Pro-rata 6000:4000 ~ 3:2 (tiny flat-fee perturbation).
        assertApproxEqRel(aliceGot * 2, bobGot * 3, 1e15, "not pro-rata");

        // Deposit addresses drained; forwarder code cleared so the address is reusable.
        assertEq(IERC20Like(USDS_TOKEN).balanceOf(minter.depositAddressOf(alice)), 0);
        assertEq(IERC20Like(USDS_TOKEN).balanceOf(minter.depositAddressOf(bob)), 0);
    }

    // ============================================================
    // Attribution is trustless: a malicious runner can't reassign
    // ============================================================

    function test_runner_cannot_misattribute() public {
        _depositUsds(alice, 1_000e18); // only alice funded her address

        // A greedy runner tries to claim alice's deposit for themselves by listing only `runner`.
        address[] memory liars = new address[](1);
        liars[0] = runner;
        vm.prank(runner);
        vm.expectRevert(ForwarderMinter.NothingToDo.selector); // runner's own deposit addr is empty
        minter.sweepAndExecute(liars, 0);

        // alice's funds are untouched and still hers.
        assertEq(IERC20Like(USDS_TOKEN).balanceOf(minter.depositAddressOf(alice)), 1_000e18);

        // Sweeping alice credits ALICE no matter who calls it.
        uint256 runnerGbpf = gbpf.balanceOf(runner);
        uint256 aliceGbpf = gbpf.balanceOf(alice);
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(runner);
        minter.sweepAndExecute(u, 0);
        assertEq(gbpf.balanceOf(runner), runnerGbpf, "runner siphoned GBPF");
        assertGt(gbpf.balanceOf(alice), aliceGbpf, "alice not credited");
    }

    // ============================================================
    // Refund escape hatch
    // ============================================================

    function test_refund_returns_funds_to_owner_of_address() public {
        _giveUsds(carol, 500e18);
        uint256 carolStart = IERC20Like(USDS_TOKEN).balanceOf(carol);
        address carolDep = minter.depositAddressOf(carol);
        vm.prank(carol);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS_TOKEN).transfer(carolDep, 500e18);

        // Anyone can trigger the refund; it can only go back to carol.
        vm.prank(runner);
        minter.refund(carol);
        assertEq(IERC20Like(USDS_TOKEN).balanceOf(carol), carolStart, "carol not made whole");
        assertEq(IERC20Like(USDS_TOKEN).balanceOf(minter.depositAddressOf(carol)), 0);
    }

    // ============================================================
    // Forwarder address is reusable across batches
    // ============================================================

    function test_deposit_address_reused_across_batches() public {
        address[] memory u = new address[](1);
        u[0] = alice;

        _depositUsds(alice, 1_000e18);
        vm.prank(runner);
        minter.sweepAndExecute(u, 0);
        uint256 afterFirst = gbpf.balanceOf(alice);
        assertGt(afterFirst, 0);

        // Same address, second round — the forwarder is flushed, not redeployed.
        _depositUsds(alice, 1_000e18);
        vm.prank(runner);
        minter.sweepAndExecute(u, 0);
        assertGt(gbpf.balanceOf(alice), afterFirst, "second batch produced no GBPF");
    }

    // ============================================================
    // Mirror: send-and-forget redeem (roundtrip)
    // ============================================================

    function test_redeem_send_and_forget() public {
        // First mint via the forwarder minter so alice holds GBPF.
        _depositUsds(alice, 5_000e18);
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(runner);
        minter.sweepAndExecute(u, 0);
        uint256 aliceGbpf = gbpf.balanceOf(alice);
        assertGt(aliceGbpf, 0);

        // Now alice just SENDS her GBPF to her redeem deposit address (plain transfer).
        address aliceRedeemDep = redeemer.depositAddressOf(alice);
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(address(gbpf)).transfer(aliceRedeemDep, aliceGbpf);

        uint256 aliceUsdsBefore = IERC20Like(USDS_TOKEN).balanceOf(alice);
        vm.prank(runner);
        redeemer.sweepAndExecute(u, 0);

        assertGt(IERC20Like(USDS_TOKEN).balanceOf(alice) - aliceUsdsBefore, 0, "alice got no USDS");
        assertEq(IERC20Like(address(gbpf)).balanceOf(redeemer.depositAddressOf(alice)), 0);
    }

    // ============================================================
    // depositAddressOf is a pure function of the user (and contract)
    // ============================================================

    function test_deposit_address_deterministic_and_distinct() public view {
        assertEq(minter.depositAddressOf(alice), minter.depositAddressOf(alice), "not deterministic");
        assertTrue(minter.depositAddressOf(alice) != minter.depositAddressOf(bob), "collision across users");
        // Same user has different addresses on minter vs redeemer (different factory address).
        assertTrue(minter.depositAddressOf(alice) != redeemer.depositAddressOf(alice), "minter==redeemer addr");
    }
}
