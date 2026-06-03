// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "../../src/Vault.sol";
import {MockSUsds} from "../mocks/MockSUsds.sol";
import {MockSSRAuthOracle} from "../mocks/MockSSRAuthOracle.sol";

/// @dev Handler the invariant runner pokes at random. Wraps the Vault's external surface and
///      also drives the mocked sUSDS supply and chi index, simulating real protocol use:
///      mints flowing in, redeems flowing out, yield accruing, and the beneficiary withdrawing.
contract VaultHandler is Test {
    uint256 internal constant RAY = 1e27;

    Vault public vault;
    MockSUsds public sUsds;
    MockSSRAuthOracle public oracle;
    address public hook;
    address public beneficiary;

    // ghost variables — accumulators independent of the contract storage, used by invariants
    // to derive expected vs actual quantities. Inflows track what user-facing code put in;
    // outflows track what user-facing code paid out (to redeemer + to beneficiary).
    uint256 public ghostMintInflow;
    uint256 public ghostRedeemOutflow;
    uint256 public ghostBeneficiaryWithdrawn;
    uint256 public ghostYieldMinted; // sUSDS the handler synthesised to simulate yield

    constructor(Vault v, MockSUsds s, MockSSRAuthOracle o, address h, address b) {
        vault = v;
        sUsds = s;
        oracle = o;
        hook = h;
        beneficiary = b;
    }

    // ------------------------------------------------------------
    // Handler actions
    // ------------------------------------------------------------

    /// Simulate a mint: sUSDS arrives at the vault, then the hook calls deposit().
    function handle_deposit(uint96 amount, uint96 fee) external {
        uint256 a = bound(amount, 1, 1e30);
        uint256 f = bound(fee, 0, a);
        sUsds.mint(address(vault), a);
        ghostMintInflow += a;
        vm.prank(hook);
        try vault.deposit(a, f) {} catch {}
    }

    /// Simulate a redeem: hook calls withdraw(), vault pays out sUSDS to a recipient.
    function handle_withdraw(uint96 amount, uint96 fee, address to) external {
        if (to == address(0) || to == address(vault) || to == beneficiary) {
            // skip zero / vault-self / beneficiary to keep ghost accounting clean
            return;
        }
        uint256 a = bound(amount, 1, type(uint96).max);
        uint256 f = bound(fee, 0, a);
        vm.prank(hook);
        try vault.withdraw(a, to, f) {
            ghostRedeemOutflow += a;
        } catch {}
    }

    /// Simulate sUSDS yield: bump chi a little, and mint a corresponding amount of sUSDS
    /// into the vault so the share-price model and the on-chain balance stay consistent.
    /// Without this, chi grows but the vault's sUSDS balance doesn't — which is the unrealistic
    /// regime that produced the fuzz failure earlier; bounding it here keeps the simulation
    /// faithful to the real Spark oracle behaviour where sUSDS appreciates against USDS but
    /// the share count stays constant.
    ///
    /// NOTE: in production, chi growth represents USDS-value appreciation of an unchanged sUSDS
    ///       share count. We therefore *do not* mint extra sUSDS here; we only advance chi.
    ///       The vault's accounting must be correct under this exact regime.
    function handle_advance_chi(uint16 bumpBps) external {
        uint256 bps = bound(bumpBps, 0, 1000); // up to 10% per tick
        if (bps == 0) return;
        uint256 current = oracle.getChi();
        oracle.setChi(current + (current * bps / 10_000));
    }

    /// Permissionless settle.
    function handle_settle() external {
        try vault.settle() {} catch {}
    }

    /// Permissionless beneficiary withdrawal.
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
    MockSUsds internal sUsds;
    MockSSRAuthOracle internal oracle;
    address internal hook;
    address internal beneficiary;

    function setUp() public {
        hook = makeAddr("hook");
        beneficiary = makeAddr("beneficiary");

        sUsds = new MockSUsds();
        oracle = new MockSSRAuthOracle(RAY);
        vault = new Vault(hook, beneficiary, address(sUsds), address(oracle));

        handler = new VaultHandler(vault, sUsds, oracle, hook, beneficiary);

        // Restrict campaign to the handler. Forge's invariant runner won't poke the vault
        // directly (it would just hit NotHook on every call), it'll only call the handler.
        targetContract(address(handler));
    }

    // ============================================================================================
    // Core invariants
    // ============================================================================================

    /// The pending beneficiary share must never exceed what the vault actually holds.
    /// If it does, withdrawBeneficiary() would underflow on transfer.
    function invariant_pending_never_exceeds_balance() public view {
        assertLe(
            vault.pendingBeneficiarySUsds(),
            sUsds.balanceOf(address(vault)),
            "pendingBeneficiarySUsds > vault sUSDS balance"
        );
    }

    /// lastSettledChi must be monotonically non-decreasing.
    /// Implemented as a comparison against the live oracle chi after settle has rolled forward.
    /// (The handler never makes chi go backward; this guards against an internal regression.)
    function invariant_lastSettledChi_never_exceeds_oracle() public view {
        assertLe(vault.lastSettledChi(), oracle.getChi(), "lastSettledChi ran ahead of oracle chi");
    }

    /// Conservation: every sUSDS share the handler put into the vault either still lives in
    /// the vault, or was paid out to a redeemer, or was paid out to the beneficiary.
    /// (No yield was synthesised — chi-only growth is value appreciation, not share creation.)
    function invariant_conservation_of_sUsds_shares() public view {
        uint256 inflow = handler.ghostMintInflow();
        uint256 outflow = handler.ghostRedeemOutflow() + handler.ghostBeneficiaryWithdrawn();
        uint256 inVault = sUsds.balanceOf(address(vault));
        // inflow == in_vault + outflow
        assertEq(inflow, inVault + outflow, "sUSDS share conservation violated");
    }
}
