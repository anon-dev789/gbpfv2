// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ISSRAuthOracle} from "./interfaces/ISSRAuthOracle.sol";

/// @dev Minimal IERC20 surface used by the Vault. Only balanceOf is read directly;
///      transfers go through Solady's SafeTransferLib which uses its own low-level calls.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title GBPF collateral vault
/// @notice Immutable sUSDS custody contract for the GBPF protocol.
///
/// The Vault holds the protocol's sUSDS reserves and tracks the portion of those reserves owed
/// to the beneficiary multisig (100% of mint/redeem flat fees + 50% of sUSDS yield). Everything
/// else in the vault backs GBPF.
///
/// The Vault is a pure custody contract: it does not read GBP/USD, does not know the GBPF supply,
/// does not compute spreads, and does not mint/burn GBPF. The hook is responsible for all pricing
/// math and for calling deposit() / withdraw() with the already-computed sUSDS amounts.
///
/// Yield-share accounting: the beneficiary's share grows continuously with the SSR oracle's chi
/// index. _settleBeneficiaryYield() is invoked at the start of every state-changing function so
/// the pending counter is always current before any flow.
///
/// Access control:
/// - deposit / withdraw: HOOK only.
/// - withdrawBeneficiary / settle: permissionless (anyone can trigger settlement and forward to BENEFICIARY).
/// - No owner, no admin, no upgrade path, no selfdestruct, no delegatecall.
contract Vault {
    using SafeTransferLib for address;

    /// @dev The protocol hook that is authorised to deposit and withdraw collateral.
    ///      Set once via initialize() during deployment; cannot be changed thereafter.
    ///      Not `immutable` because of the circular deploy dependency with Hook
    ///      (Hook's constructor needs Vault's address; Vault needs Hook's address).
    ///      See DEPLOY_DESIGN.md for the dependency analysis.
    address public HOOK;

    /// @dev The hardcoded multisig that receives the beneficiary share. Fixed at deploy forever.
    address public immutable BENEFICIARY;

    /// @dev Base sUSDS token (SkyLink-bridged). The only token this vault holds or transfers.
    address public immutable SUSDS;

    /// @dev Spark's SSRAuthOracle on Base. Source for the chi index used by yield accounting.
    ISSRAuthOracle public immutable SSR_ORACLE;

    /// @dev Numerator portion of the beneficiary's yield share. With BENEFICIARY_YIELD_DENOM = 2,
    ///      a numerator of 1 means 50% of yield to beneficiary. Immutable for life of protocol.
    uint256 internal constant BENEFICIARY_YIELD_NUM = 1;
    uint256 internal constant BENEFICIARY_YIELD_DENOM = 2;

    /// @dev Total sUSDS in the vault that is owed to BENEFICIARY (fees + accrued yield share).
    ///      Must always be <= SUSDS.balanceOf(this).
    uint256 public pendingBeneficiarySUsds;

    /// @dev sUSDS principal currently earning yield on behalf of the protocol. Increases on
    ///      deposit (by sUsdsAmount - feeAmount), decreases on withdraw (by sUsdsAmount), is
    ///      unaffected by passive chi growth or by accrued yield credits. This is the figure
    ///      the yield-share formula multiplies against, *not* the live vault balance — the
    ///      live balance can include sUSDS that has not yet "earned" any yield (e.g., a deposit
    ///      that arrived in the same tx as a settlement).
    uint256 public principalSUsds;

    /// @dev chi (in ray) at the most recent yield settlement. Monotonically non-decreasing.
    uint256 public lastSettledChi;

    // ============================================================================================
    // Events
    // ============================================================================================

    event Deposit(uint256 sUsdsAmount, uint256 feeAmount);
    event Withdraw(address indexed to, uint256 sUsdsAmount, uint256 feeAmount);
    event BeneficiaryWithdrawal(uint256 amount, uint256 settledChi);
    event YieldSettled(uint256 beneficiaryShareCredited, uint256 newChi);

    // ============================================================================================
    // Errors
    // ============================================================================================

    error NotHook();
    error ZeroAmount();
    error InsufficientBackingForRedeem(uint256 requested, uint256 available);
    error NothingToWithdraw();
    error FeeExceedsAmount(uint256 fee, uint256 amount);
    error AlreadyInitialized();
    error ZeroHook();
    error NotInitialized();

    // ============================================================================================
    // Construction
    // ============================================================================================

    constructor(address beneficiary_, address sUsds_, address ssrOracle_) {
        // BENEFICIARY, SUSDS, and SSR_ORACLE are set in the constructor and truly immutable.
        // HOOK is set later via initialize() because of the circular deploy dependency: the
        // Hook contract's address must encode V4 flag bits (CREATE2 mining), and its
        // constructor takes the Vault address. So we deploy Vault first, then deploy Hook
        // with Vault's address as a constructor arg, then call vault.initialize(hook).
        BENEFICIARY = beneficiary_;
        SUSDS = sUsds_;
        SSR_ORACLE = ISSRAuthOracle(ssrOracle_);

        // Seed the yield-share index. Any yield earned before this point is not credited to
        // the beneficiary — which is correct because the vault held no protocol funds before
        // it was deployed. We use getConversionRate() (the extrapolated chi) rather than
        // getChi() (the stored chi) so the seed reflects the actual rate at deploy time, not
        // the rate as of the last bridge update.
        lastSettledChi = ISSRAuthOracle(ssrOracle_).getConversionRate();
    }

    /// @notice One-shot setter for the Hook address. Called by the deploy script after the Hook
    ///         is deployed at its mined CREATE2 address. After this call, HOOK is fixed forever.
    /// @dev    Reverts if called twice or with the zero address. The first caller of this
    ///         function effectively owns the Vault forever — the deploy script must call this
    ///         atomically in the same transaction as Vault and Hook deployment.
    function initialize(address hook_) external {
        if (HOOK != address(0)) revert AlreadyInitialized();
        if (hook_ == address(0)) revert ZeroHook();
        HOOK = hook_;
    }

    // ============================================================================================
    // Hook-only flows
    // ============================================================================================

    /// @notice Record an incoming sUSDS deposit from a mint operation.
    /// @param  sUsdsAmount  Total sUSDS that the hook has already transferred into this vault.
    /// @param  feeAmount    Portion of sUsdsAmount that is the flat protocol fee, owed to BENEFICIARY.
    ///                      Must be <= sUsdsAmount.
    /// @dev The hook is responsible for transferring sUsdsAmount of sUSDS into this contract
    ///      before calling deposit(). This function trusts that the transfer has occurred —
    ///      it does not verify a balance change to avoid double-accounting in atomic flows
    ///      where multiple internal calls happen in one transaction.
    function deposit(uint256 sUsdsAmount, uint256 feeAmount) external {
        if (HOOK == address(0)) revert NotInitialized();
        if (msg.sender != HOOK) revert NotHook();
        if (sUsdsAmount == 0) revert ZeroAmount();
        // Defence-in-depth: even though the hook is the only caller, verify that the fee
        // it's asking us to credit doesn't exceed the amount it just delivered. A bug in
        // the hook that over-credits the beneficiary would silently shrink the vault's
        // backing for GBPF; this check turns that bug into a revert.
        if (feeAmount > sUsdsAmount) revert FeeExceedsAmount(feeAmount, sUsdsAmount);

        // Settle first, so the existing principalSUsds earns yield only up to the moment
        // this deposit lands. The new (sUsdsAmount - feeAmount) is credited to principal
        // *after* settlement and so does not retroactively earn yield it didn't accrue.
        _settleBeneficiaryYield();

        if (feeAmount > 0) {
            pendingBeneficiarySUsds += feeAmount;
        }
        principalSUsds += sUsdsAmount - feeAmount;

        emit Deposit(sUsdsAmount, feeAmount);
    }

    /// @notice Pay sUSDS out to a redeemer.
    /// @param  sUsdsAmount  sUSDS to send to `to`. The hook has already computed this from the
    ///                      oracle price and curve spread.
    /// @param  to           Recipient (the redeeming user, typically).
    /// @param  feeAmount    Flat protocol fee on this redeem, owed to BENEFICIARY. Remains in
    ///                      the vault (it is sUSDS the user *did not* receive) and is added to
    ///                      pendingBeneficiarySUsds.
    function withdraw(uint256 sUsdsAmount, address to, uint256 feeAmount) external {
        if (HOOK == address(0)) revert NotInitialized();
        if (msg.sender != HOOK) revert NotHook();
        if (sUsdsAmount == 0) revert ZeroAmount();

        _settleBeneficiaryYield();

        // After settlement, available backing is principalSUsds (the post-settlement quantity
        // owed to GBPF holders). The redeem must fit BOTH the user payout and the new
        // beneficiary credit inside the backing — otherwise we'd be promising the beneficiary
        // more sUSDS than the vault holds.
        uint256 backing = principalSUsds;
        uint256 total = sUsdsAmount + feeAmount;
        if (total > backing) {
            revert InsufficientBackingForRedeem(total, backing);
        }

        if (feeAmount > 0) {
            pendingBeneficiarySUsds += feeAmount;
        }
        principalSUsds = backing - total;

        SUSDS.safeTransfer(to, sUsdsAmount);
        emit Withdraw(to, sUsdsAmount, feeAmount);
    }

    // ============================================================================================
    // Permissionless flows
    // ============================================================================================

    /// @notice Advance the yield-share index without transferring anything. Useful for indexers
    ///         and off-chain monitors that want an up-to-date pendingBeneficiarySUsds figure.
    function settle() external {
        _settleBeneficiaryYield();
    }

    /// @notice Send the beneficiary's accrued share to the hardcoded BENEFICIARY address.
    ///         Permissionless — anyone can call, but funds always go to BENEFICIARY.
    /// @dev Settles yield first so the most recent accruals are included.
    function withdrawBeneficiary() external {
        _settleBeneficiaryYield();
        uint256 amount = pendingBeneficiarySUsds;
        if (amount == 0) revert NothingToWithdraw();
        pendingBeneficiarySUsds = 0;
        SUSDS.safeTransfer(BENEFICIARY, amount);
        emit BeneficiaryWithdrawal(amount, lastSettledChi);
    }

    // ============================================================================================
    // Views
    // ============================================================================================

    /// @notice Returns the inputs the hook needs to compute solvency: vault sUSDS balance,
    ///         pending beneficiary share, and the current SSR conversion rate (in ray).
    /// @dev Settles yield first so the figures returned are always current. Not a view because
    ///      of the settlement write. For off-chain reads that must not mutate state, use
    ///      previewSolvencyInputs().
    function solvencyInputs()
        external
        returns (uint256 sUsdsBalance, uint256 pendingBeneficiary, uint256 ssrConversionRate)
    {
        _settleBeneficiaryYield();
        sUsdsBalance = _vaultBalance();
        pendingBeneficiary = pendingBeneficiarySUsds;
        ssrConversionRate = SSR_ORACLE.getConversionRate();
    }

    /// @notice Same as solvencyInputs() but pure-view; computes what settlement *would* credit
    ///         without writing. Useful for indexers, monitors, and off-chain pricing checks.
    function previewSolvencyInputs()
        external
        view
        returns (uint256 sUsdsBalance, uint256 pendingBeneficiary, uint256 ssrConversionRate)
    {
        sUsdsBalance = _vaultBalance();
        pendingBeneficiary = pendingBeneficiarySUsds + _previewBeneficiaryShare();
        ssrConversionRate = SSR_ORACLE.getConversionRate();
    }

    /// @notice Returns the current sUSDS available to back GBPF, accounting for *unsettled*
    ///         yield (i.e., what principalSUsds would be after a hypothetical settle()).
    ///         View-only; no state changes.
    function backingBalance() external view returns (uint256) {
        uint256 unsettled = _previewBeneficiaryShare();
        uint256 p = principalSUsds;
        return unsettled >= p ? 0 : p - unsettled;
    }

    // ============================================================================================
    // Internal
    // ============================================================================================

    /// @dev Credits accrued beneficiary yield to pendingBeneficiarySUsds, decrements the
    ///      same amount from principalSUsds (the beneficiary's claim is no longer principal),
    ///      and advances lastSettledChi.
    ///
    ///      Derivation. Let P = principalSUsds in sUSDS shares,
    ///      chi_0 = lastSettledChi (USDS/share, in ray), chi_1 = currentChi.
    ///      USDS yield earned on the principal between settlements: P * (chi_1 - chi_0) / RAY.
    ///      Beneficiary's USDS claim (50%):                          P * (chi_1 - chi_0) / (2 * RAY).
    ///      Converted back to sUSDS shares at the *new* rate:        P * (chi_1 - chi_0) / (2 * chi_1).
    ///
    ///      Hence: credit (in sUSDS shares) = P * chiDelta * NUM / (currentChi * DENOM).
    ///
    ///      Dividing by currentChi (not lastChi) is the correctness-critical part: the beneficiary
    ///      receives the *current value* of their USDS claim expressed in shares, not an over-
    ///      stated count that would arise from dividing by the smaller, older index.
    ///
    ///      Using principalSUsds (not vault balance minus pending) is also correctness-critical:
    ///      newly-arrived deposits MUST NOT retroactively earn yield they did not accrue.
    function _settleBeneficiaryYield() internal {
        // Use the extrapolated conversion rate, not the raw stored chi. Spark's getChi() only
        // changes when the cross-chain bridge pushes a rate update (rare); the conversion rate
        // ticks every block based on the last bridged SSR. Using getChi() would mean yield
        // accrues to the beneficiary only in lumps at bridge messages instead of continuously.
        uint256 currentChi = SSR_ORACLE.getConversionRate();
        uint256 lastChi = lastSettledChi;

        // If chi hasn't advanced (same block, or SSR=0, or oracle paused), nothing to credit.
        // Defensive: also tolerate a chi that has somehow not increased — the invariant is
        // monotonic non-decreasing, but we treat equal-or-less as a no-op to avoid underflow.
        if (currentChi <= lastChi) {
            return;
        }

        uint256 principal = principalSUsds;
        if (principal == 0) {
            // No working capital, so no yield to credit. Just roll the chi forward so the next
            // deposit doesn't try to claim yield for the elapsed-but-empty interval.
            lastSettledChi = currentChi;
            return;
        }

        uint256 chiDelta = currentChi - lastChi;

        // credit = P * chiDelta * NUM / (currentChi * DENOM), rounded down.
        // currentChi is in ray (~10^27) so the denominator is large; P * chiDelta is bounded
        // by P * currentChi (since chiDelta <= currentChi), which fits in uint256 for any
        // realistic vault balance.
        uint256 credit = principal * chiDelta * BENEFICIARY_YIELD_NUM / (currentChi * BENEFICIARY_YIELD_DENOM);

        pendingBeneficiarySUsds += credit;
        // The credited sUSDS is moved out of principal — it's no longer earning yield for the
        // protocol's account, it's owed to the beneficiary.
        principalSUsds = principal - credit;
        lastSettledChi = currentChi;

        emit YieldSettled(credit, currentChi);
    }

    /// @dev Read-only preview of how much yield would be credited if we settled right now.
    ///      Uses the same formula as _settleBeneficiaryYield; see that function for the derivation.
    function _previewBeneficiaryShare() internal view returns (uint256) {
        // See _settleBeneficiaryYield for why getConversionRate() rather than getChi().
        uint256 currentChi = SSR_ORACLE.getConversionRate();
        uint256 lastChi = lastSettledChi;
        if (currentChi <= lastChi) return 0;
        uint256 principal = principalSUsds;
        if (principal == 0) return 0;
        uint256 chiDelta = currentChi - lastChi;
        return principal * chiDelta * BENEFICIARY_YIELD_NUM / (currentChi * BENEFICIARY_YIELD_DENOM);
    }

    function _vaultBalance() internal view returns (uint256) {
        return IERC20Balance(SUSDS).balanceOf(address(this));
    }
}
