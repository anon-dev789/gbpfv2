// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "../../src/Vault.sol";
import {ISSRAuthOracle} from "../../src/interfaces/ISSRAuthOracle.sol";

/// @dev Verifies the Vault works against the real Spark SSRAuthOracle on Base.
///
///      Run with:
///        forge test --match-contract VaultForkTest -vv
contract VaultForkTest is Test {
    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;

    address internal constant SPARK_SSR_AUTH_ORACLE = 0x65d946e533748A998B1f0E430803e39A6388f7a1;
    address internal constant SUSDS_TOKEN = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;

    Vault internal vault;
    address internal hook;
    address internal beneficiary;
    address internal sUsdsWhale;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        hook = makeAddr("hook");
        beneficiary = makeAddr("beneficiary");

        vault = new Vault(beneficiary, SUSDS_TOKEN, SPARK_SSR_AUTH_ORACLE);
        vault.initialize(hook);

        // We need some sUSDS to deposit. Use vm.deal-equivalent for ERC20: deal cheatcode.
        sUsdsWhale = makeAddr("whale");
        deal(SUSDS_TOKEN, sUsdsWhale, 1000e18);
    }

    // ============================================================================================
    // Constructor seeded from real chi
    // ============================================================================================

    function test_constructor_seeds_lastSettledChi_from_real_oracle() public view {
        // Vault seeds from getConversionRate() (extrapolated chi), NOT getChi() (stored chi).
        // See ISSRAuthOracle interface for the difference and Vault.sol constructor for the why.
        uint256 expected = ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getConversionRate();
        assertEq(vault.lastSettledChi(), expected);
        // Sanity: at this fork block, the conversion rate should be > 1 ray (sUSDS > USDS).
        assertGt(vault.lastSettledChi(), 1e27, "chi seed <= 1 ray, looks wrong");
        // Sanity: the conversion rate should be >= the stored chi (yield monotonic).
        assertGe(vault.lastSettledChi(), ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getChi());
    }

    // ============================================================================================
    // Deposit + yield settlement against real oracle
    // ============================================================================================

    function test_deposit_against_real_susds() public {
        // Whale transfers sUSDS to the vault, then the hook calls deposit().
        vm.prank(sUsdsWhale);
        (bool ok,) = SUSDS_TOKEN.call(abi.encodeWithSignature("transfer(address,uint256)", address(vault), 100e18));
        assertTrue(ok, "sUSDS transfer to vault failed");

        vm.prank(hook);
        vault.deposit(100e18, 1e18); // 1 sUSDS fee

        assertEq(vault.pendingBeneficiarySUsds(), 1e18);
        assertEq(vault.principalSUsds(), 99e18);
    }

    function test_yield_accrues_against_real_oracle() public {
        // Deposit, warp forward a meaningful amount of time, settle, expect a positive credit.
        vm.prank(sUsdsWhale);
        (bool ok,) = SUSDS_TOKEN.call(abi.encodeWithSignature("transfer(address,uint256)", address(vault), 1000e18));
        assertTrue(ok);

        vm.prank(hook);
        vault.deposit(1000e18, 0);

        uint256 chiBefore = vault.lastSettledChi();
        // Advance ~30 days. The oracle extrapolates chi forward locally using ssr × elapsed,
        // so we should observe a non-zero credit on settle.
        vm.warp(block.timestamp + 30 days);

        vault.settle();

        uint256 chiAfter = vault.lastSettledChi();
        assertGt(chiAfter, chiBefore, "chi did not advance after 30 days");

        uint256 pending = vault.pendingBeneficiarySUsds();
        assertGt(pending, 0, "no yield credited to beneficiary after 30 days");
        // Sanity bound: at 6% APY, 30 days on 1000e18 principal = ~5e18 USDS. Half to
        // beneficiary = ~2.5e18 (less, due to share-vs-USDS conversion at the new chi).
        // Allow generous bounds.
        assertLt(pending, 10e18, "yield credit implausibly large");
    }

    function test_solvencyInputs_against_real_oracle() public {
        vm.prank(sUsdsWhale);
        (bool ok,) = SUSDS_TOKEN.call(abi.encodeWithSignature("transfer(address,uint256)", address(vault), 100e18));
        assertTrue(ok);
        vm.prank(hook);
        vault.deposit(100e18, 0);

        (uint256 bal, uint256 pending, uint256 rate) = vault.solvencyInputs();
        assertEq(bal, 100e18, "vault balance != deposited");
        assertEq(pending, 0, "pending non-zero before time has passed");
        assertGt(rate, 1e27, "ssr rate <= 1 ray");
    }

    function test_withdraw_against_real_susds() public {
        vm.prank(sUsdsWhale);
        (bool ok,) = SUSDS_TOKEN.call(abi.encodeWithSignature("transfer(address,uint256)", address(vault), 100e18));
        assertTrue(ok);

        vm.prank(hook);
        vault.deposit(100e18, 0);

        address user = makeAddr("user");
        vm.prank(hook);
        vault.withdraw(40e18, user, 0);

        // Verify user received the sUSDS.
        (bool ok2, bytes memory data) = SUSDS_TOKEN.staticcall(abi.encodeWithSignature("balanceOf(address)", user));
        assertTrue(ok2);
        assertEq(abi.decode(data, (uint256)), 40e18);
    }
}
