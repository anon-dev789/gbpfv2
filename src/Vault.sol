// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ISSRAuthOracle} from "./interfaces/ISSRAuthOracle.sol";
import {IPSM3} from "./interfaces/IPSM3.sol";

/// @dev Minimal IERC20 surface used by the Vault. Only balanceOf is read directly;
///      transfers go through Solady's SafeTransferLib which uses its own low-level calls.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal interface for the GBPF token (only used by flush to burn redeem claims).
interface IGBPFBurn {
    function burn(uint256 amount) external;
}

/// @title GBPF collateral vault
/// @notice Immutable sUSDS custody contract for the GBPF protocol with V4 6909 claim
///         accounting and deferred PSM3 conversion.
///
/// The Vault holds sUSDS reserves plus tracks two pending counters that represent
/// V4 PoolManager 6909 claims accumulated during mint/redeem swaps:
///   - pendingUsdsClaim:        USDS-denominated 6909 claims from mints (input the Vault
///                              owns on the PoolManager but hasn't yet converted to sUSDS).
///   - pendingGbpfClaim:        GBPF-denominated 6909 claims from redeems (GBPF the protocol
///                              has effectively absorbed and will burn on flush).
/// Both are realised by a permissionless flush() that the keeper runs after swaps.
///
/// During flush(), the Vault:
///   1. Calls PoolManager.unlock with itself as the IUnlockCallback.
///   2. Burns the 6909 USDS claim, takes the real USDS from PM, approves PSM3, converts to
///      sUSDS, deposits to itself, credits the principal + beneficiary share.
///   3. Burns the 6909 GBPF claim, takes the real GBPF from PM, calls GBPF.burn to destroy it.
///
/// Pending claims back GBPF at 1:1 USDS-value for solvency math (they're real obligations on
/// PM that will resolve into USDS within one block of the keeper running flush).
contract Vault is IUnlockCallback {
    using SafeTransferLib for address;

    /// @dev The protocol hook that is authorised to record claims and direct payouts.
    ///      Set once via initialize() during deployment; cannot be changed thereafter.
    address public HOOK;

    /// @dev The hardcoded multisig that receives the beneficiary share.
    address public immutable BENEFICIARY;

    /// @dev Base sUSDS token (SkyLink-bridged).
    address public immutable SUSDS;

    /// @dev Base USDS token (SkyLink-bridged).
    address public immutable USDS;

    /// @dev GBPF token (used by flush to burn redeem claims).
    address public immutable GBPF_TOKEN;

    /// @dev Spark's SSRAuthOracle on Base.
    ISSRAuthOracle public immutable SSR_ORACLE;

    /// @dev Spark PSM3 on Base — converts USDS↔sUSDS at the same SSRAuthOracle rate, no fee.
    IPSM3 public immutable PSM3;

    /// @dev Uniswap V4 PoolManager — for unlock + burn + take in flush().
    IPoolManager public immutable POOL_MANAGER;

    /// @dev Beneficiary share numerator / denominator. 1/2 = 50% of yield to beneficiary.
    uint256 internal constant BENEFICIARY_YIELD_NUM = 1;
    uint256 internal constant BENEFICIARY_YIELD_DENOM = 2;

    /// @dev sUSDS owed to BENEFICIARY (already converted; includes flat fees + yield share).
    uint256 public pendingBeneficiarySUsds;

    /// @dev sUSDS principal currently earning yield for the protocol.
    uint256 public principalSUsds;

    /// @dev chi (in ray) at the most recent yield settlement. Monotonically non-decreasing.
    uint256 public lastSettledChi;

    /// @dev V4 6909 USDS claim balance the Vault holds on the PoolManager — accumulated from
    ///      mints. Realised into real USDS during flush.
    uint256 public pendingUsdsClaim;

    /// @dev USDS-denominated fee accumulated from mints + redeems, awaiting conversion to sUSDS
    ///      and credit to pendingBeneficiarySUsds during flush.
    uint256 public pendingBeneficiaryUsdsClaim;

    /// @dev V4 6909 GBPF claim balance the Vault holds on PoolManager — accumulated from
    ///      redeems. Realised into real GBPF and burned during flush.
    uint256 public pendingGbpfClaim;

    /// @dev Used by unlockCallback to disambiguate the callback purpose. The Vault is its own
    ///      unlocker; this is a guard against external calls or misuse.
    bool internal _unlocking;

    // ============================================================================================
    // Events
    // ============================================================================================

    event RecordMint(uint256 usdsClaim, uint256 feeUsds);
    event RecordRedeem(address indexed to, uint256 sUsdsAmount, uint256 gbpfClaim, uint256 feeUsds);
    event Flush(uint256 usdsClaimRealised, uint256 sUsdsMinted, uint256 gbpfBurned);
    event BeneficiaryWithdrawal(uint256 amount, uint256 settledChi);
    event YieldSettled(uint256 beneficiaryShareCredited, uint256 newChi);

    // ============================================================================================
    // Errors
    // ============================================================================================

    error NotHook();
    error NotPoolManager();
    error ZeroAmount();
    error InsufficientBackingForRedeem(uint256 requested, uint256 available);
    error NothingToWithdraw();
    error FeeExceedsAmount(uint256 fee, uint256 amount);
    error AlreadyInitialized();
    error ZeroHook();
    error NotInitialized();
    error NothingToFlush();
    error ReentrantUnlock();

    // ============================================================================================
    // Construction
    // ============================================================================================

    constructor(
        address beneficiary_,
        address sUsds_,
        address usds_,
        address gbpfToken_,
        address ssrOracle_,
        address psm3_,
        address poolManager_
    ) {
        BENEFICIARY = beneficiary_;
        SUSDS = sUsds_;
        USDS = usds_;
        GBPF_TOKEN = gbpfToken_;
        SSR_ORACLE = ISSRAuthOracle(ssrOracle_);
        PSM3 = IPSM3(psm3_);
        POOL_MANAGER = IPoolManager(poolManager_);

        lastSettledChi = ISSRAuthOracle(ssrOracle_).getConversionRate();

        // Pre-approve PSM3 to pull USDS for the flush conversion. Done once at deploy.
        usds_.safeApprove(psm3_, type(uint256).max);
    }

    /// @notice One-shot setter for the Hook address. Called by the deploy script after the Hook
    ///         is deployed at its mined CREATE2 address. After this call, HOOK is fixed forever.
    function initialize(address hook_) external {
        if (HOOK != address(0)) revert AlreadyInitialized();
        if (hook_ == address(0)) revert ZeroHook();
        HOOK = hook_;
    }

    // ============================================================================================
    // Hook-only flows
    // ============================================================================================

    /// @notice Record a mint swap. The Hook has just had PoolManager mint a 6909 USDS claim to
    ///         this Vault for `usdsClaim`. We accumulate the claim and the fee portion.
    ///         No real ERC20 movement here — that happens in flush.
    /// @param  usdsClaim    USDS-denominated 6909 claim newly held by the Vault.
    /// @param  feeUsds      Portion of usdsClaim that is the flat protocol fee (beneficiary's share).
    function recordMint(uint256 usdsClaim, uint256 feeUsds) external {
        if (HOOK == address(0)) revert NotInitialized();
        if (msg.sender != HOOK) revert NotHook();
        if (usdsClaim == 0) revert ZeroAmount();
        if (feeUsds > usdsClaim) revert FeeExceedsAmount(feeUsds, usdsClaim);

        // Settle yield on the existing sUSDS principal before any new credits.
        _settleBeneficiaryYield();

        pendingUsdsClaim += usdsClaim;
        if (feeUsds > 0) {
            pendingBeneficiaryUsdsClaim += feeUsds;
        }

        emit RecordMint(usdsClaim, feeUsds);
    }

    /// @notice Record a redeem swap. The Hook has just had PoolManager mint a 6909 GBPF claim
    ///         to this Vault, and we must pay `sUsdsForUser` sUSDS to `to` (which the Hook will
    ///         convert to USDS via PSM3 and settle to PoolManager). The Hook has also separated
    ///         a feeSUsds portion of the vault's withdrawal that stays as beneficiary credit.
    /// @param  sUsdsToHook       sUSDS to transfer to the Hook for PSM3 conversion to USDS.
    /// @param  gbpfClaim         GBPF-denominated 6909 claim newly held by the Vault (to be burned in flush).
    /// @param  feeSUsds          Beneficiary fee in sUSDS, credited to pendingBeneficiarySUsds (stays in vault).
    function recordRedeem(uint256 sUsdsToHook, uint256 gbpfClaim, uint256 feeSUsds) external {
        if (HOOK == address(0)) revert NotInitialized();
        if (msg.sender != HOOK) revert NotHook();
        if (sUsdsToHook == 0 || gbpfClaim == 0) revert ZeroAmount();

        _settleBeneficiaryYield();

        // The redeem must fit BOTH the payout to the hook and the new beneficiary credit
        // inside principalSUsds — otherwise we'd promise the beneficiary more than the vault holds.
        uint256 backing = principalSUsds;
        uint256 total = sUsdsToHook + feeSUsds;
        if (total > backing) {
            revert InsufficientBackingForRedeem(total, backing);
        }

        if (feeSUsds > 0) {
            pendingBeneficiarySUsds += feeSUsds;
        }
        principalSUsds = backing - total;
        pendingGbpfClaim += gbpfClaim;

        SUSDS.safeTransfer(HOOK, sUsdsToHook);
        emit RecordRedeem(HOOK, sUsdsToHook, gbpfClaim, feeSUsds);
    }

    // ============================================================================================
    // Permissionless flows
    // ============================================================================================

    /// @notice Advance the yield-share index without transferring anything.
    function settle() external {
        _settleBeneficiaryYield();
    }

    /// @notice Realise all pending 6909 claims and convert. Anyone can call.
    ///         For each pending USDS claim: burn 6909, take real USDS, convert via PSM3 to sUSDS,
    ///         deposit to the vault, credit principal and beneficiary share.
    ///         For each pending GBPF claim: burn 6909, take real GBPF, burn the GBPF.
    function flush() external {
        if (pendingUsdsClaim == 0 && pendingGbpfClaim == 0) revert NothingToFlush();
        if (_unlocking) revert ReentrantUnlock();

        _settleBeneficiaryYield();

        _unlocking = true;
        POOL_MANAGER.unlock("");
        _unlocking = false;
    }

    /// @notice Send the beneficiary's accrued share to the hardcoded BENEFICIARY address.
    function withdrawBeneficiary() external {
        _settleBeneficiaryYield();
        uint256 amount = pendingBeneficiarySUsds;
        if (amount == 0) revert NothingToWithdraw();
        pendingBeneficiarySUsds = 0;
        SUSDS.safeTransfer(BENEFICIARY, amount);
        emit BeneficiaryWithdrawal(amount, lastSettledChi);
    }

    // ============================================================================================
    // PoolManager unlock callback (called from flush)
    // ============================================================================================

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (!_unlocking) revert ReentrantUnlock();

        uint256 usdsClaim = pendingUsdsClaim;
        uint256 gbpfClaim = pendingGbpfClaim;
        uint256 feeUsds = pendingBeneficiaryUsdsClaim;

        // 1. Realise USDS claim.
        uint256 sUsdsReceived;
        if (usdsClaim > 0) {
            uint256 usdsId = uint256(uint160(USDS));
            POOL_MANAGER.burn(address(this), usdsId, usdsClaim);
            POOL_MANAGER.take(Currency.wrap(USDS), address(this), usdsClaim);

            // Convert all USDS to sUSDS in one go via PSM3.
            uint256 minOut = PSM3.previewSwapExactIn(USDS, SUSDS, usdsClaim);
            sUsdsReceived = PSM3.swapExactIn(USDS, SUSDS, usdsClaim, minOut, address(this), 0);

            // Allocate to principal vs beneficiary share. We allocate by USDS proportion and
            // convert to sUSDS shares at the same rate (proportional).
            uint256 feeSUsds = sUsdsReceived * feeUsds / usdsClaim;
            principalSUsds += sUsdsReceived - feeSUsds;
            if (feeSUsds > 0) {
                pendingBeneficiarySUsds += feeSUsds;
            }

            pendingUsdsClaim = 0;
            pendingBeneficiaryUsdsClaim = 0;
        }

        // 2. Realise GBPF claim.
        if (gbpfClaim > 0) {
            uint256 gbpfId = uint256(uint160(GBPF_TOKEN));
            POOL_MANAGER.burn(address(this), gbpfId, gbpfClaim);
            POOL_MANAGER.take(Currency.wrap(GBPF_TOKEN), address(this), gbpfClaim);
            IGBPFBurn(GBPF_TOKEN).burn(gbpfClaim);
            pendingGbpfClaim = 0;
        }

        emit Flush(usdsClaim, sUsdsReceived, gbpfClaim);
        return "";
    }

    // ============================================================================================
    // Views
    // ============================================================================================

    /// @notice Returns the inputs the hook needs to compute solvency.
    /// @dev Settles yield first. `usdsClaimBacking` is the USDS-denominated 6909 claim balance
    ///      that backs GBPF at 1:1 (no SSR multiplier — these are USDS, not sUSDS shares).
    function solvencyInputs()
        external
        returns (uint256 sUsdsBalance, uint256 pendingBeneficiary, uint256 ssrConversionRate, uint256 usdsClaimBacking)
    {
        _settleBeneficiaryYield();
        sUsdsBalance = _vaultBalance();
        pendingBeneficiary = pendingBeneficiarySUsds;
        ssrConversionRate = SSR_ORACLE.getConversionRate();
        // USDS claim backing is pending claim minus the beneficiary's portion.
        uint256 claim = pendingUsdsClaim;
        uint256 feeClaim = pendingBeneficiaryUsdsClaim;
        usdsClaimBacking = claim > feeClaim ? claim - feeClaim : 0;
    }

    /// @notice View variant of solvencyInputs that does not mutate state.
    function previewSolvencyInputs()
        external
        view
        returns (uint256 sUsdsBalance, uint256 pendingBeneficiary, uint256 ssrConversionRate, uint256 usdsClaimBacking)
    {
        sUsdsBalance = _vaultBalance();
        pendingBeneficiary = pendingBeneficiarySUsds + _previewBeneficiaryShare();
        ssrConversionRate = SSR_ORACLE.getConversionRate();
        uint256 claim = pendingUsdsClaim;
        uint256 feeClaim = pendingBeneficiaryUsdsClaim;
        usdsClaimBacking = claim > feeClaim ? claim - feeClaim : 0;
    }

    // ============================================================================================
    // Internal
    // ============================================================================================

    function _settleBeneficiaryYield() internal {
        uint256 currentChi = SSR_ORACLE.getConversionRate();
        uint256 lastChi = lastSettledChi;
        if (currentChi <= lastChi) return;

        uint256 principal = principalSUsds;
        if (principal == 0) {
            lastSettledChi = currentChi;
            return;
        }

        uint256 chiDelta = currentChi - lastChi;
        uint256 credit = principal * chiDelta * BENEFICIARY_YIELD_NUM / (currentChi * BENEFICIARY_YIELD_DENOM);

        pendingBeneficiarySUsds += credit;
        principalSUsds = principal - credit;
        lastSettledChi = currentChi;

        emit YieldSettled(credit, currentChi);
    }

    function _previewBeneficiaryShare() internal view returns (uint256) {
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
