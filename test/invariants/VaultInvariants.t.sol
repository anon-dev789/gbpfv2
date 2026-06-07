// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "../../src/Vault.sol";
import {GBPF} from "../../src/GBPF.sol";
import {MockSUsds} from "../mocks/MockSUsds.sol";
import {MockUsds} from "../mocks/MockUsds.sol";
import {MockSSRAuthOracle} from "../mocks/MockSSRAuthOracle.sol";
import {MockPSM3} from "../mocks/MockPSM3.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @dev Handler for the V4 6909-claim vault. Randomly drives recordMint, recordRedeem (requires
///      sufficient principal — bounded accordingly), flush, settle, withdrawBeneficiary.
contract VaultHandler is Test {
    uint256 internal constant RAY = 1e27;

    Vault public vault;
    GBPF public gbpf;
    MockSUsds public sUsds;
    MockUsds public usds;
    MockSSRAuthOracle public oracle;
    MockPSM3 public psm;
    MockPoolManager public pm;
    address public hook;
    address public beneficiary;

    uint256 public ghostUsdsClaimed;
    uint256 public ghostGbpfClaimed;
    uint256 public ghostBeneficiaryWithdrawn;

    constructor(
        Vault v,
        GBPF g,
        MockSUsds s,
        MockUsds u,
        MockSSRAuthOracle o,
        MockPSM3 p,
        MockPoolManager m,
        address h,
        address b
    ) {
        vault = v;
        gbpf = g;
        sUsds = s;
        usds = u;
        oracle = o;
        psm = p;
        pm = m;
        hook = h;
        beneficiary = b;
    }

    function handle_recordMint(uint96 amount, uint96 fee) external {
        uint256 a = bound(amount, 1, 1e30);
        uint256 f = bound(fee, 0, a);
        // Mirror the V4 flow: PM credits the vault with a 6909 claim and is pre-funded with the
        // real USDS that the eventual flush() will take.
        pm.mintClaim(address(vault), uint256(uint160(address(usds))), a);
        pm.fund(address(usds), a);
        vm.prank(hook);
        try vault.recordMint(a, f) {
            ghostUsdsClaimed += a;
        } catch {}
    }

    function handle_recordRedeem(uint96 sUsdsAmt, uint96 gbpfAmt, uint96 feeAmt) external {
        uint256 s = bound(sUsdsAmt, 1, 1e30);
        uint256 g = bound(gbpfAmt, 1, 1e30);
        uint256 f = bound(feeAmt, 0, s);
        // Pre-fund the PM with the GBPF that flush will take + credit a 6909 claim to the vault.
        pm.mintClaim(address(vault), uint256(uint160(address(gbpf))), g);
        pm.fund(address(gbpf), g);
        vm.prank(hook);
        try vault.recordRedeem(s, g, f) {
            ghostGbpfClaimed += g;
        } catch {}
    }

    function handle_flush() external {
        try vault.flush() {} catch {}
    }

    function handle_advance_chi(uint16 bumpBps) external {
        uint256 bps = bound(bumpBps, 0, 1000);
        if (bps == 0) return;
        uint256 current = oracle.conversionRate();
        oracle.setConversionRate(current + (current * bps / 10_000));
    }

    function handle_settle() external {
        try vault.settle() {} catch {}
    }

    function handle_withdrawBeneficiary() external {
        uint256 before = sUsds.balanceOf(beneficiary);
        try vault.withdrawBeneficiary() {
            ghostBeneficiaryWithdrawn += sUsds.balanceOf(beneficiary) - before;
        } catch {}
    }
}

contract VaultInvariantsTest is Test {
    uint256 internal constant RAY = 1e27;

    VaultHandler internal handler;
    Vault internal vault;
    GBPF internal gbpf;
    MockSUsds internal sUsds;
    MockUsds internal usds;
    MockSSRAuthOracle internal oracle;
    MockPSM3 internal psm;
    MockPoolManager internal pm;
    address internal hook;
    address internal beneficiary;

    function setUp() public {
        hook = makeAddr("hook");
        beneficiary = makeAddr("beneficiary");

        sUsds = new MockSUsds();
        usds = new MockUsds();
        oracle = new MockSSRAuthOracle(RAY);
        psm = new MockPSM3(address(usds), address(sUsds), RAY);
        pm = new MockPoolManager();
        gbpf = new GBPF();

        vault = new Vault(
            beneficiary, address(sUsds), address(usds), address(gbpf), address(oracle), address(psm), address(pm)
        );
        vault.initialize(hook);
        gbpf.initialize(hook, address(vault));

        handler = new VaultHandler(vault, gbpf, sUsds, usds, oracle, psm, pm, hook, beneficiary);
        targetContract(address(handler));
    }

    // ============================================================================================
    // Invariants
    // ============================================================================================

    /// pendingBeneficiarySUsds must never exceed the vault's sUSDS balance — would underflow on
    /// withdrawBeneficiary's transfer.
    function invariant_pending_never_exceeds_sUsdsBalance() public view {
        assertLe(
            vault.pendingBeneficiarySUsds(),
            sUsds.balanceOf(address(vault)),
            "pendingBeneficiarySUsds > vault sUSDS balance"
        );
    }

    /// pendingBeneficiaryUsdsClaim must never exceed pendingUsdsClaim — fee portion of claims
    /// can't exceed total claims.
    function invariant_beneficiary_claim_within_total_claim() public view {
        assertLe(
            vault.pendingBeneficiaryUsdsClaim(),
            vault.pendingUsdsClaim(),
            "beneficiary USDS-claim fee > total USDS claim"
        );
    }

    /// lastSettledChi never runs ahead of oracle chi.
    function invariant_lastSettledChi_never_exceeds_oracle() public view {
        assertLe(vault.lastSettledChi(), oracle.conversionRate(), "lastSettledChi ahead of oracle");
    }

    /// principalSUsds + pendingBeneficiarySUsds <= sUsds.balanceOf(vault). After every state-changing
    /// vault call, post-settle the equation is exact; pre-settle it can be exact or slightly under
    /// (yet-to-credit yield). Either way, the sum cannot exceed the actual balance.
    function invariant_sUsds_accounting_within_balance() public view {
        uint256 inVault = sUsds.balanceOf(address(vault));
        uint256 total = vault.principalSUsds() + vault.pendingBeneficiarySUsds();
        assertLe(total, inVault, "sUSDS accounting exceeds vault balance");
    }
}
